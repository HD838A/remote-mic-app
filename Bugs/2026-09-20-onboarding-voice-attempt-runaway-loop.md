# Onboarding 语音测试页失控循环：`removeDuplicates()` 重订阅反复触发语音 attempt

- 时间：2026-09-20
- 状态：已修复（候选）；自动化与本机真机已通过，等待维护者合入与发布后验证
- 影响范围：Onboarding 语音测试页。`482a347`（2026-09-07）之后、尚未发布的版本；
  实体遥控器、iPhone App、网页版三条控制路径在语音测试页触发语音时均可能命中。
  已发布的 `1.9.21 (174)` 不含该提交，不受影响。
- 功能点：Onboarding 语音测试页、语音 attempt 状态机、SwiftUI 订阅、进程 CPU 与运行日志
- 简单描述：语音测试页的 `isStreaming` 订阅每次视图求值都重建，导致
  `beginVoiceAttempt()` 自持触发，attempt 计数无限增长，进程接近占满一个核心，
  运行日志高速膨胀且无法正常结束语音测试。
- 原始记录：本机 `~/Library/Logs/RemoteMic/runtime.log`（2026-09-19T17:00Z 区间，
  构建自 `origin/main` `940dde5`，`ver=1.9.21 build=227`）；提交 `482a347`；
  修复 PR #468。日志未记录任何语音内容。

## Observations

- 在语音测试页用实体遥控器触发一次语音后，`ONBOARDING VOICE_ATTEMPT started`
  连续出现：`17:00:08.752` 为 `attempt=96`，`17:00:08.783` 已达 `attempt=115`
  （31ms 内 20 次），持续增长至 `attempt=18032`。
- 同时段进程 `%CPU = 90.6`。`runtime.log` 在 5 秒内由 3,085,200 字节增长到
  4,367,376 字节（约 256 KB/s，约 900 MB/小时）。
- `SIGTERM` 对该进程无效，必须 `kill -9` 才能终止；终止后日志停止增长。
- 循环区间内日志**只有** `VOICE_ATTEMPT started`：计数 14,495；
  `VOICE_ATTEMPT terminal` 计数 0；`ATVV STREAM START` / `STOP` 计数 0；
  循环区间内没有任何其它类别的事件。
- 每行 `VOICE_ATTEMPT started` 的 `audio_generation` 恒为 1，
  且 `trigger_ready=true`、`editor_mounted=true`、`window_key=true`、
  `first_responder=true` 全程不变。
- 该现象与 [语音流期间进程 CPU 接近占满单核](./2026-08-24-voice-stream-cpu-saturation.md)
  的机制不同：该文档的根因是每个音频批次发布一次 `@Published` 造成 SwiftUI
  无效化风暴；本次在循环期间**没有任何音频批次事件**，因此不是同一条路径。

## Hypotheses

### H1：`removeDuplicates()` 在视图求值中重建 publisher，导致重新订阅并重复投递当前值（ROOT CAUSE）

- Supports：`482a347` 将订阅由 `model.$isStreaming` 改为
  `model.$isStreaming.removeDuplicates()`。算子每次求值构造新的 publisher，
  订阅方因此重建订阅；新订阅没有历史值，`@Published` 立即投递当前值 `true`，
  再次进入 `.voiceTest` 分支调用 `beginVoiceAttempt()`；该函数整体重建
  `@State voiceAttempt`（`attemptID` 自增），触发视图重算，再构造新 publisher。
- Supports：循环期间 `ATVV STREAM` 事件为 0 且 `audio_generation` 恒为 1，
  说明 `isStreaming` 始终为 `true`，并未发生真/假抖动——问题是订阅重建，
  不是值变化。
- Supports：同文件内 `.onReceive(model.$hasReceivedCurrentVoiceSamples.removeDuplicates())`
  存在于 `v1.9.21` 且未出现该现象，说明该算子本身不必然导致循环，
  而是与本处理函数在 `.voiceTest` 分支内的 `@State` 写入组合后才自持。
- Conflicts：无。未取得 Time Profiler trace，不能量化 SwiftUI 求值在
  90.6% CPU 中所占比例。

### H2：遥控器或蓝牙链路重复触发语音开始事件

- Supports：attempt 计数高速增长，表面上像重复事件。
- Conflicts：`ATVV STREAM START` 计数为 0，循环区间内没有任何蓝牙或音频事件；
  若为重复触发，应出现对应的流事件与 `audio_generation` 递增。否定。

## Experiment

### E1：静态回放订阅重建路径

- 依据 `482a347` 的 diff 确认：改动同时把 `settings.onboardingStep == .voiceTest`
  从 `guard` 移入 `switch`，并新增 `.remote` 分支。`.voiceTest` 分支是唯一调用
  `beginVoiceAttempt()` 的位置（全仓仅此一处调用点，`OnboardingView.swift:177`）。
- 结论：`beginVoiceAttempt()` 只能由该订阅触发，而它自身会写入 `@State`，
  构成闭合回环。该回环在 `isStreaming == true` 时自持。

### E2：去掉算子后的实测

- 将订阅还原为 `model.$isStreaming`，其余代码不动，同机构建运行。
- 结果：语音测试页 attempt 正常走到终态；`runtime.log` 稳定在约 12 KB；
  `VOICE_ATTEMPT started` 与 `terminal` 一一对应。
- 同一次运行完成了一次通过的语音测试：
  `VOICE_ATTEMPT terminal attempt=6 result=passed probable_cause=passed`、
  `audio_received_samples=54960`、`played_samples=54960`、
  `enqueue_failures=0`、`focus_loss_count=0`、`transcript_wait_ms=40`。

### E3：自动化回归

- `swift test --filter OnboardingFlowTests`：50 项全部通过。
- `swift build`：通过。

## 根因

`482a347` 在 `OnboardingView` 的 `isStreaming` 订阅上引入
`.removeDuplicates()`。该算子在视图 `body` 内对 `@Published` 投影构造新
publisher，使订阅在每次求值后重建；新订阅无历史值，立即收到当前的
`isStreaming == true`，于是再次调用会写入 `@State` 的 `beginVoiceAttempt()`，
形成自持循环。日志中 `ATVV STREAM` 事件为 0、`audio_generation` 恒为 1，
是判定「订阅重建而非值抖动」的决定性证据。

## 修复

```diff
-        .onReceive(model.$isStreaming.removeDuplicates()) { isStreaming in
+        .onReceive(model.$isStreaming) { isStreaming in
```

回到 `v1.9.21` 已在使用、未出现该问题的 `model.$isStreaming`。
修复 PR：#468（仅此一行，不含其它改动）。

## 验证

- 自动化：`swift test --filter OnboardingFlowTests` 50 项通过。
- 构建：`swift build` 通过。
- 真机：实体 RC003 遥控器 + 真实 `MiRemoteV 2ch` + 真实豆包输入法，
  macOS 15.7.2 / arm64，完成一次通过的语音测试（数据见 E2）。
- 日志：修复后语音测试页日志稳定在约 12 KB，无重复 attempt。
- 未执行：macOS 26 上的运行验证；iPhone App 与网页版控制方式下的语音测试页；
  真机性能对照（未取得 Time Profiler trace）。

## 边界与遗留

- 本机为源码构建（`build 227`），与已发布 `174` 不同，日志可区分。
- 该缺陷未在已发布版本中，但会随下一个包含 `482a347` 的版本发布给所有用户；
  命中条件是在语音测试页触发任意一次语音，无需其它前提。
- 去掉去重后，`.remote` 步骤的 `recordRemoteVoiceButtonPress()` 不再去重。
  评估：`@Published` 仅在赋值时发布，`isStreaming` 只在
  `beginVoiceSession` / `endVoiceSessionIfNeeded` 中变更；该计数仅用于
  `shouldShowVoiceButtonCorrection` 的 `> 0` 判断，重复计数不改变提示逻辑的
  最终结果。**该评估需维护者确认。**
- 若认为去重仍属必要，更合适的落点是把去重放在 `BridgeAppModel` 提供的
  派生 publisher 上，而不是在视图 `body` 内对 `@Published` 施加算子。
