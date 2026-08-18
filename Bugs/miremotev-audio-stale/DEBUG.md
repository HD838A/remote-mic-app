# MiRemoteV 音频 stale 调试记录

## 范围与方法

- 基线：`origin/main`（`a2288d26751ee51dc5a02d91309cd609fc7c2659`）。
- 目标：解释“设备仍被识别、重新选择 MiRemoteV 2ch 后恢复”的宿主侧原因。
- 方法：严格按 Observe → Hypothesize → Experiment → Conclude；真实用户现场日志缺失，模拟结果不等于真机复现。

## Observe

1. 用户反馈机没有对应时间段日志、macOS/App 版本或第三方 App 名称，不能直接观察现场的驱动、宿主和消费者状态。
2. 本机 `~/Library/Logs/RemoteMic/runtime.log` 中存在 6 次 `AUDIO ENGINE configuration_ignored ... reason=still_bound`；事件发生在启动重绑或 CoreAudio 路由变化后，但日志没有记录 `AVAudioPlayerNode.isPlaying`。
3. `VirtualAudioOutput.isReadyForTestTone` 只检查已选设备和 `engine.isRunning`；配置通知只再检查实际设备 ID，因此播放器停止仍可能被判定为健康。
4. `enqueue(samples:)` 在 player 对象存在、engine 运行时即返回成功；它不检查 player 是否正在播放，可能形成“缓冲已接受但没有消费”的假成功。
5. `NSWorkspace.didWakeNotification` 当前只刷新私有功能资格，没有要求音频子系统重新检查健康状态。
6. 手动重新选择设备会执行完整 `stop → 新建 engine/player → 重新绑定 → start/play`，与用户反馈的恢复操作一致。

## Hypothesize

### H1：播放器停止但引擎和设备绑定仍被误判为健康

- 支持证据：健康谓词和配置通知都不检查 `player.isPlaying`；enqueue 也不检查实际播放状态；完整重绑会新建并启动 player。
- 冲突证据：反馈机没有日志，尚未证明现场发生过 `engine=true/player=false`。
- 可证伪条件：AVAudioPlayerNode 不可能在 engine 仍运行时停止，或该状态会被现有逻辑可靠恢复。

### H2：睡眠唤醒后 CoreAudio 已重配，但宿主没有触发音频恢复

- 支持证据：App 已收到唤醒通知，却没有调用音频恢复；问题描述为“偶发”且手动重绑恢复。
- 冲突证据：用户没有说明失效是否紧随睡眠、锁屏或设备切换。
- 可证伪条件：所有相关唤醒路径都会可靠产生现有硬件/engine 配置通知并完成恢复。

### H3：MiRemoteV 驱动仍写入，但第三方 App 持有旧输入 stream/device

- 支持证据：第三方 App 可能缓存输入流；宿主重绑可能间接改变 HAL 状态并促使消费者恢复。
- 冲突证据：操作发生在无线麦SayAll.app内且完整重建宿主输出，宿主侧解释更直接。
- 可证伪条件：系统录音工具与多个第三方 App 同时失声，且宿主 player/engine 状态异常。

### H4：CoreAudio 重枚举后设备 ID 或底层 stream 变化，宿主仍持有旧实例

- 支持证据：当前绑定判断主要比较 AudioDeviceID；路由变化日志中确实出现过设备列表和默认设备变动。
- 冲突证据：固定 UID 的 MiRemoteV 在本机日志中长期保持 id=99，硬件监听也会触发重绑。
- 可证伪条件：失效前后 UID/ID/stream 均稳定，而 player 状态已停止。

## Experiment

### E1：构造 engine 运行但 player 停止的最小 AVFoundation 状态

- 命令（4 行）：

  ```sh
  swift -e 'import AVFoundation
  let e=AVAudioEngine(), p=AVAudioPlayerNode(); e.attach(p); e.connect(p,to:e.mainMixerNode,format:nil)
  try e.start(); p.play(); p.stop()
  print("engine=\(e.isRunning) player=\(p.isPlaying)")'
  ```

- 结果：`engine=true player=false`；补充打印确认 `play()` 后为 `engine=true player=true`，调用 `player.stop()` 后只剩 engine 运行。
- 解释：H1 的关键分叉在真实 AVFoundation 对象上可达；仍不代表真实 MiRemoteV 现场已复现。

### E2：把 E1 状态代入修复前生产健康与配置通知谓词

- 命令（3 行）：

  ```sh
  swift -e 'let selected=true, engine=true, player=false, bound=true
  let currentReady=selected && engine; let ignoresChange=currentReady && bound
  print("ready=\(currentReady) ignore=\(ignoresChange) player=\(player)")'
  ```

- 结果：`ready=true ignore=true player=false`。
- 解释：修复前代码会把可达的 stopped-player 状态报告为 ready，并在配置通知中跳过恢复；enqueue 同样会接受缓冲。这是可重复的宿主侧 stale 状态。

### E3：修复后回放同一健康状态

- 测试（2 个关键断言）：
  - `engine=true / player=false / bound=true` → playback ready 与 configuration healthy 均为 false。
  - `engine=true / player=true / bound=false` → configuration healthy 为 false。
- 结果：`VirtualAudioConnectionLifecycleTests` 9/9 通过；旧 stale 状态不再进入 ready/ignore 分支，所有语音入口均有实时健康门禁回归。
- 解释：同一模拟输入从修复前的错误通过变为修复后的失败关闭，并会由语音开始门禁或配置通知请求重绑。

## Conclude

H1 已由 E1 和 E2 确认：生产健康谓词遗漏播放器播放状态，使 `engine=true / bound=true / player=false` 被误判为健康；配置通知、语音开始门禁和缓冲写入因此都可能跳过恢复。手动重新选择设备完整重建 player，所以能解除该状态。

E3 确认修复后同一状态会失败关闭并进入重绑路径。H2、H3、H4 仍没有现场证据，不能写成用户反馈机的已确认事实。本轮正式修复只覆盖已确认的宿主健康检测缺口，并在每次语音开始前重新读取实时健康状态；不尝试控制第三方 App，也不宣称修复了未知的驱动或消费者问题。

## 最终验证

- `swift test --filter VirtualAudioConnectionLifecycleTests`：9/9 通过。
- `swift test`：228/228，19 suites 通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：42/42 通过。
- `swift build -c release`：通过。
- `./scripts/check-repository-boundaries.sh`：通过。
- `./scripts/verify-release-dependency-pins.sh`：通过。
- `git diff --check`：通过。

以上验证没有执行真实 RC001/RC003、iPhone、Apple Watch、Web、MiRemoteV HAL、睡眠唤醒或第三方语音工具验收。
