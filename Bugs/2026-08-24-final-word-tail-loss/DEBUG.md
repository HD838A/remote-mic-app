# 语音结束时最后一个词偶发未识别调查

- 时间：2026-08-24
- 状态：调查中；现有证据不足以确认唯一根因，先增加诊断日志，未修改语音行为
- 现场机器：当前 Mac，`/Applications/SayAll.app` `1.9.8 (131)`，Developer ID Team `L3QHLDRPAY`
- 现场设置：豆包输入法、`voiceFnTapModeEnabled = false`、RC003、虚拟音频路线
- 原始日志：`~/Library/Logs/RemoteMic/runtime.log`

## Observations

- 用户观察到语音结束时经常缺少最后一个单词或词汇，但没有记录每一次失败的精确时间和原句，因此当前不能把某一条日志与一次肉眼可见的失败逐一对应。
- 当前 App 使用豆包输入法，且 `voiceFnTapModeEnabled = false`。因此现场走的是遥控器硬件 Fn 与 `route=virtual_audio` 路线，不是 App 管理 Fn 开始/停止并等待音频排空的 `fn_tap` 路线。
- 严格意义上的最后一次 `1.9.8 (131)` 启动为 `17:00:20Z–17:00:58Z`，其中没有 ATVV 语音会话。本轮统计使用上一段从 `15:42:32Z` 开始且包含真实语音的 `1.9.8` 运行。
- 该运行的 22 次 RC003 会话全部为 `enqueue_failures=0`，全部最终记录 `AUDIO PLAYBACK drained`，没有 `AUDIO PLAYBACK interrupted`。这不符合 2026-08-09 已修复的“`STREAM_STOP` 立即清空播放器”旧问题。
- 22 次会话中有 20 次在 `STREAM_STOP` 时仍有待播放缓冲，合计 37 个，单次最多 4 个。按 RC003 每批 240 sample、16kHz 估算，约有 15～60ms 音频仍在播放队列；现有日志只有秒级时间，无法知道系统 Fn 松开与最后缓冲实际播放完成相差多少毫秒。
- 多个现场序列显示 HID 松开事件、`ATVV STREAM summary ... pending_buffers=N`、`ATVV STREAM STOP`、`AUDIO PLAYBACK drained` 连续发生。当前日志不能证明豆包在 Fn 松开前已经收到最后缓冲。
- `XiaomiBluetoothBridge.stopStreaming()` 在停止时先执行 `accumulator.reset()`，没有记录当时是否存在不足 120 字节的残留帧；同步包和重复 `STREAM_START` 也可能在此前清空残留帧。
- `XiaomiBluetoothBridge.handleAudio()` 在停止后 300ms 内收到音频通知时直接返回，既不解码也不记录。当前日志无法知道是否存在控制通道先停止、音频通道后到的通知交错。
- 当前 `AppLogger` 的 ISO 8601 时间戳不含毫秒，无法对 Fn、控制通知、音频通知和播放器排空做有效时序比较。
- 本地转写历史的 `TRANSCRIPT CAPTURE canceled reason=discontinuous_text_change` 只表示 Codex 输入框的 Accessibility 文本变化不符合本地归档规则；它不会删除或改写输入框文字，不能单独解释豆包为什么没有识别最后一个词。

## Hypotheses

### H1：硬件 Fn 已松开，但虚拟麦克风尾部仍在播放（ROOT HYPOTHESIS）

- Supports：现场明确是硬件 Fn 路线；22 次中 20 次停止时存在待播放缓冲；所有音频都成功入队并最终排空；Fn 松开与播放器排空没有协调。
- Conflicts：现有时间戳只有秒级；待播放缓冲通常为 1～4 个，尚不能证明其持续时间足以稳定造成整词缺失；没有失败会话的精确肉眼标记。
- Test：记录毫秒时间、Fn down/up 边沿、停止时 Fn 状态、待播放缓冲及最终排空时间。若失败会话稳定表现为 Fn up 早于排空，则确认该时序风险。

### H2：`STREAM_STOP` 清除了残留帧，或停止后仍有晚到音频被静默忽略

- Supports：停止路径无条件清空 `FrameAccumulator.pending`；停止后 300ms 的音频通知无日志直接丢弃；控制和音频来自不同特征值。
- Conflicts：ATVV 设备通常应以完整帧结束，CoreBluetooth 也可能保持通知到达顺序；当前没有任何现场证据证明残留字节或晚到通知真实发生。
- Test：记录停止、同步包和重复开始时被清空的 `partial_frame_bytes`，并记录停止后被忽略音频的 `delay_ms`、通知字节数和 session。任何失败会话出现非零值都将显著提高该假设可信度。

### H3：语音结束时立即恢复原输入法，打断第三方输入法最终提交

- Supports：当前 `main` 已增加 Fn up 时恢复原输入源；第三方输入法可能在 Fn 松开后才完成最终候选提交。
- Conflicts：现场 App 是 `1.9.8 (131)`，日志中的 `VOICE INPUT source_prepare` 还是旧格式，没有运行输入源恢复逻辑，因此它不能解释本次已观察到的问题，只是后续版本需要排除的新增时序变量。
- Test：新诊断包记录 Fn up 与 `source_restore` 的毫秒顺序；分别测试“原输入法已是豆包”和“从英文临时切入豆包”两种情况。

### H4：遥控器在最后一个词仍有声音时就停止发送，缺少必要的尾音或停顿

- Supports：按住说话场景中用户可能说完立即松手；现有日志只有 sample 数量，没有末尾 300ms 的无内容信号指标。
- Conflicts：不能仅凭用户操作推断硬件或固件截断；完整音频已入队和排空也不能说明末尾是人声还是静音。
- Test：只记录末尾 300ms 及最后 100ms 的 sample 数、非零 sample 数、峰值和 RMS，不记录原始音频。若失败时最后 100ms 信号仍明显活跃且紧贴停止，说明缺少尾部保护窗口的可能性较高。

### H5：旧的播放器 flush 或音频入队失败再次发生

- Supports：历史上曾出现同类尾部丢失。
- Conflicts：本轮 22 次全部 `flush=false`、`enqueue_failures=0`，且全部排空，没有 interrupted；当前代码的普通蓝牙停止策略也固定不 flush。
- Test：继续保留现有 summary、drained、interrupted 日志即可；当前证据暂时否定该假设。

## Experiments

1. **统计 `1.9.8` 最近有真实语音的现场运行。** 从 `15:42:32Z` 的 `APP START version=1.9.8` 后解析 `ATVV STREAM summary`：`sessions=22`、`pending_sessions=20`、`pending_sum=37`、`max_pending=4`、`enqueue_failure_sessions=0`。结果支持 H1 的“停止时仍有音频在途”，但秒级日志无法确认 Fn 与排空的先后差值。
2. **只读检查停止路径。** `stopStreaming()` 在 delegate 回调前清空 accumulator；停止后 300ms 音频直接 return。确认 H2 所需证据当前确实没有被记录，但没有证明该路径已经在现场发生。
3. **检查现场路线。** 偏好为豆包且 `voiceFnTapModeEnabled=0`；日志为 `route=virtual_audio`。确认现场不具备 `VoiceFnTapSessionController.beginDrain → stopTap` 的受控排空时序，支持优先观察 H1。

## Current Conclusion

目前可以确认音频并非普遍解码失败、入队失败或被旧停止策略立即清空；但不能在 H1、H2、H4 之间确认唯一根因。正式修复前必须先取得带毫秒时序、残留帧、晚到通知和尾部信号指标的失败会话日志。

## Diagnostic Change

本轮只增加以下无内容日志，不改变蓝牙、Fn、输入法、音频排空或文字提交行为：

- runtime.log 时间戳增加毫秒；
- 记录豆包/微信相关 Fn down/up 边沿；
- 停止摘要记录 Fn 状态、最后音频距停止时间、末尾约 300ms 及最后 100ms 的非零 sample、峰值和 RMS；
- `STREAM_STOP` 在进入停止流程时立即记录残留帧字节数；同步包和重复开始清空残帧时也单独记录；
- 停止后 300ms 内被忽略的音频记录延迟和字节数；
- 继续使用 trace/session 关联，不记录语音原始数据、识别文字或输入框正文。

## Validation Boundary

自动化只能验证日志计算和既有行为未改变。根因必须用真实 RC003、豆包输入法和一次肉眼确认“最后词缺失”的标记会话判断；没有该现场关联前，不得把任一假设写成已确认修复。

## Validation Results

- `swift test --filter 'BluetoothVoiceTailDiagnosticsTests|PreferredInputSourceMonitorTests|ATVVProtocolTests'`：通过，20 个测试、0 失败。
- `swift test`：通过，339 个测试、0 失败。
- `./scripts/test.sh`：通过，42 个自检、0 失败，Swift Package 构建通过。
- `swift build -c release`：通过，Production 配置编译与链接完成。
- 构建只出现仓库既有的 macOS 14 `onChange(of:perform:)` 弃用警告，与本次诊断日志无关。
- 尚未用真实 RC003 制造并标记一次“最后词缺失”会话，因此当前状态仍是“诊断能力已补充，根因未确认，业务行为未修复”。
