# 排空尾音期间音频重配置导致语音会话永久卡死

- 时间：2026-09-05
- 状态：已修复，自动化通过；真机与真实音频设备切换验收未完成
- 影响范围：所有使用 Fn 轻触（Typeless）语音路径的用户；手机语音停止与虚拟音频释放两条路径同类风险
- 功能点：`VirtualAudioOutput` 的尾音排空回调、`VoiceFnTapSessionController` 的 `.draining` 阶段
- 简单描述：语音键松开后约 0.75 秒的排空窗口内如果发生音频重配置（设备变化、引擎重启、输出释放），排空完成回调会被静默丢弃，会话永久停在 `.draining`，之后每一次按语音键都被拒绝，只能退出并重启 App 才能恢复。

## 复现

属于可从源码与控制流直接确认的时序缺陷，用最小实验即可复现，不需要现场条件。

`Sources/RemoteMic/AudioOutput.swift` 中，排空完成回调只有一个槽位 `drainCompletion`，配合 `drainGeneration` 做时序校验。

- `endSessionAfterDraining(maximumDelay:completion:)`：`drainGeneration &+= 1`，把回调存入 `drainCompletion`，并用 `DispatchQueue.main.asyncAfter` 按该 generation 挂一个兜底。
- `finishDrainIfNeeded(generation:completion:)`：仅当 `generation == drainGeneration && drainCompletion != nil` 才继续。
- 修复前的 `flushPlayer()` 与 `stop()`：同时执行 `drainCompletion = nil` **和** `drainGeneration &+= 1`，但从不调用该回调。

两个动作叠加造成双重丢失：回调引用被丢弃，同一时刻 generation 递增又让兜底闭包的判定失效。于是**没有任何路径**会再调用它。

等待方是 `Sources/RemoteMic/VoiceFnTapSessionController.swift`：

- `beginDrain` 把 `phase` 置为 `.draining(sessionGeneration)`；
- 只有排空回调经 `beginStopTap` 才能离开 `.draining`；
- `startVoice` / `receive` / `stopVoice` 在 `.draining` 下都不开新会话。

因此会话永久停在 `.draining`，收尾 Fn 轻触也不会发出，目标 App（Typeless / 豆包输入法）那一侧的听写还处于打开状态，用户只能退出重启 App。

附带的同类丢失：`endSessionAfterDraining` 在槽位已被占用时直接覆盖，先到的等待方（手机语音停止或虚拟音频释放）同样永久失联。

## 修复

**`Sources/RemoteMic/AudioOutput.swift`——把排空回调改成「一次且必达」**

- `flushPlayer()` 与 `stop()` 各自在同一次持锁内把回调**取出**再置 `nil` 并递增 generation，解锁后用 `defer` 在函数结尾调用一次。打断也是一种结果，等待方需要被告知排空已结束，而不是继续等待。
- `endSessionAfterDraining` 在写入新回调前把槽位原有占用者取出，并在新排空布置完成后用 `defer` 调用一次。

保持一个槽位、不改成等待队列：`drainGeneration` 保证同一时刻只有最新一次排空有意义，而现在每条清空槽位的路径都必须先把占用者取走并调用，槽位不可能被静默覆盖。

锁纪律与重入（本次改动的主要风险，逐条排除）：

- 回调一律在 `playbackLock` 解锁之后调用（`playbackLock` 是不可重入的 `NSLock`）；`defer` 的位置保证回调不会打在半拆半建的播放节点上。
- 不会重复调用：回调引用只存在于 `drainCompletion` 一个槽位，所有读取它的位置都在同一次持锁内把它置 `nil`。
- `flushPlayer` → 重启失败 → 嵌套 `stop()` 不会重复调用：回调在最开头已被取走，嵌套路径只取到 `nil`。
- 回调回头调用 `stop()`（虚拟音频释放路径的既有写法）不递归：槽位已是 `nil`，递归深度上限为 2。
- 正常路径不会多写日志：归零后走 `flushPlayer()` 时 `interruptedContexts` 为空，不会把「已排空」误报成「被打断」。

**`Sources/RemoteMic/VoiceFnTapSessionController.swift`——控制器侧截止时间兜底**

新增 `drainTimeout = 2` 秒，`beginDrain` 在 `drainAudio` 之前挂一个指向 `beginStopTap(generation:)` 的任务。即使回调已保证必达，这一层仍然必要：`endSessionAfterDraining` 的兜底闭包以 `[weak self]` 捕获输出对象，输出被释放后闭包静默失效，任何回调都不会到达。

- generation 受保：复用 `beginStopTap` 的既有守卫，迟到触发无法影响后续健康会话；
- 正常路径会取消：任务进入 `scheduledTasks`，`resetSessionState()` 在每条正常退出路径上取消它；挂载点在 `drainAudio` 之前，同步返回的排空也能被取消；
- 到期后的收尾与正常路径完全同路，下一次按键可被接受；
- 2 秒明显高于音频侧 0.75 秒兜底，健康会话永远由 `drainAudio` 先离开 `.draining`。

**`Tests/SelfTest/main.swift`——假调度器适配（不改断言）**

该自测的假调度器取消动作是空实现，被取消的截止任务仍留在队列里。`.draining` 多挂一个截止任务后，原本「取一个操作」不足以取到收尾按键释放。改为执行队列里全部操作（截止任务因阶段守卫为空操作）。`check(...)` 的条件与数量一字未改。

`enqueue(samples:)` 的计数自增抽出公开接缝 `registerPendingVoiceBuffer()`（生产路径不变），使排空账目可以在没有真实输出设备的情况下被测试驱动。

## 验证

自动化：

- `swift test` 全量通过；新增 6 项行为断言（不 grep 源码文本），全部用 `maximumDelay: 60` 把音频侧自己的兜底定时器排除在测试之外：
  1. `reconfiguringTheOutputMidDrainStillReportsTheDrainExactlyOnce` —— 排空期间 `endSession()` 打断，回调恰好一次，随后 `stop()` 不再触发；
  2. `tearingTheEngineDownMidDrainStillReportsTheDrainExactlyOnce` —— 排空期间 `stop()` 打断，回调恰好一次；
  3. `aDrainCompletionThatTearsTheOutputDownAgainReportsOnlyOnce` —— 回调内部再次 `stop()` 不递归、不重复；
  4. `aSecondDrainRequestDoesNotStrandTheFirstWaiter` —— 第二次排空请求把第一个等待方交还并调用，而不是覆盖丢弃；
  5. `aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress` —— 排空回答永远不到达时，截止时间让会话收尾并**接受下一次按键**；
  6. `aTimelyDrainCancelsTheDeadlineBeforeItCanCutTheNextSession` —— 正常排空后截止时间不得影响后续健康会话。
- `scripts/test.sh` 自检测试通过（check 数量不变）；
- `scripts/check-repository-boundaries.sh` 通过。

未覆盖（按 `Testing/VoiceDrainInterruptionRecovery.md` 由真机验收）：

- 真实 RC003 + Typeless/豆包在排空闲隙切换音频设备的端到端行为；
- 真实设备插拔下恢复是否仍然及时；
- 与 `Bugs/2026-08-19-watch-voice-restart-during-audio-drain.md` 场景的交互。
