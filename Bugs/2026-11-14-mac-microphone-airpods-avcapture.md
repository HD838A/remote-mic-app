# AirPods 作为 Mac 麦克风时采集启动失败或阻塞

状态：代码候选，待真实 AirPods 验收。不得标记为已修复或兼容。

## 现象

选择 AirPods 作为 Mac 麦克风后，按 Fn 开始采集：

- 有时约 0.3 秒后失败，日志为 `capture_start_failed error_code=-10868`。
- 有时 `engine.start()` 阻塞约 5.8 秒；用户松开 Fn 后会话以 `completion=forced reason=capture` 结束。
- 内置麦克风正常，Build 377 的首个 PCM 约 227 ms。

## 证据

`~/Library/Logs/RemoteMic/runtime.log`：

- Build 378，设备 199：`phase=failed reason=start_failed error_domain=com.apple.coreaudio.avfaudio error_code=-10868`。`-10868` 是 `kAudioUnitErr_FormatNotSupported`。
- Build 379，设备 144：`device_resolved` 后没有 `startup_timing`；约 5.75 秒后才出现 `phase=completed result=failed completion=forced reason=capture elapsed_ms=5836`。说明阻塞发生在 `engine.start()`。
- Build 377，内置麦克风：`startup_timing engine_ms=50 input_bind_ms=9 tap_ms=8 prepare_ms=15 start_ms=35`，`first_pcm elapsed_ms=227`。

## 根因假设

`AVAudioEngine` 的输入 Audio Unit 在 AirPods 的蓝牙 HFP 路由上不能可靠接受当前格式或完成启动；系统在 HFP 切换期间阻塞调用。内置麦克风不经过该路由，所以正常。

该假设能解释 `-10868` 和 5.8 秒阻塞两种表现，但缺少 AirPods 设备侧的统一日志。真实 AirPods 验收前保持假设状态。

## 修复

- 蓝牙输入改用视频通话同类的采集路径：`AVCaptureSession` + `AVCaptureDeviceInput` + `AVCaptureAudioDataOutput`。
- 输出请求 16 kHz、单声道、16 位小端整数 PCM；`AVCaptureAudioDataOutput` 负责把设备格式转换为该格式。
- 只在按住语音键时启动采集，不预热、不常驻，不改变“待命时不显示麦克风占用”的约束。
- 内置麦克风和其他非蓝牙输入继续使用原 `AVAudioEngine` 路径，避免无关回归。
- 首个 PCM 仍受 2 秒 watch dog 约束；没有 PCM 时记录 `no_audio`，不得报告正常成功。
- 新增日志：`avcapture_started`、`avcapture_failed`、`first_pcm`、`completed`。

## 验证

- `swift build --disable-keychain`：通过。
- `swift test --disable-keychain --filter MacMicrophoneInputTests`：24 项通过，包含 16 kHz 单声道 int16 `CMSampleBuffer` 转换测试。
- 真实 AirPods：未验证。测试时另一个 worktree 的 Build 381 持有单实例锁，用户选择不中断该实例，因此没有启动新包。
- 未覆盖：AirPods HFP 首次激活耗时、首个 PCM 延迟、松键尾音完整性、快速连续会话、断开恢复和第三方语音工具文字上屏。

## 验收边界

- 构建、单元测试和样本转换测试只证明各自边界，不能替代真实 AirPods。
- 真实测试必须确认：Fn 按下后出现 `avcapture_started`；首个 PCM 的 `elapsed_ms` 可接受；松开后 `completed` 的 `samples` 大于 0；不得出现 `-10868`；连续多次会话正常。
- 若 HFP 首次激活仍超过 2 秒，2 秒 watch dog 会先报告 `no_audio`；届时必须先记录真实耗时，再决定是否需要调整，不得直接放宽超时掩盖延迟。
