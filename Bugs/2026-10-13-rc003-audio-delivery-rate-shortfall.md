# RC003 长会话尾部缺失诊断

状态：问题待定位；PR 653 只补日志。2026-11-24 新增 10 秒录音尾字缺失现场证据。

独立蓝牙回调队列与跨线程取值候选修复已撤回。主线程、协议命令、Fn、门控和音频处理沿用主线。

原文关于“唯一根因”及“系统丢包机制”的断言已撤回。现有证据不能确认丢失发生在哪一层。

完整 Bug 记录、字段、日志预算和验证边界见 [诊断记录](2026-10-13-rc003-audio-delivery-rate-shortfall.html)。现场步骤见 [运行日志验收](../Testing/RuntimeLogging.md#用例-9rc003-音频链路诊断与日志预算)。

## 2026-11-24 新增现场证据：10 秒录音也缺尾字

- 环境：macOS 2.0.10 Build 442，RC003，豆包语音工具，虚拟音频输出；日志 session `424FE1AA`。
- 用户报告：回眸中 21:09 的 10 秒录音最后 4 个字“都不好看”没有；目标输入框同样只有前 8 个字。原句“你的这个动画一点都不好看”共 12 个字。
- 会话 9.961 秒，音频/录音 9.135 秒，少 826ms；`batches=609`、`expected_batches=664`，少 55 个批次；55 × 240 samples = 13,200 samples = 825ms。
- `drop_*`、`identifier_drops`、`enqueue_failures` 全零；`rx_bytes=accepted_bytes`；`scheduled=played=decoded=146160`；录音 writer 提交/写入 146160，`writer_rejected_samples=0`、`writer_failures=0`。
- `interrupted_samples=0`、`pending_samples=0`；先 `AUDIO PLAYBACK drained` 再 `VOICE KEY tail_release`；`last_pcm_to_stop_ms=15`，末尾 300ms 仍有信号。排除立即 flush 和正常排空截断。
- 按 [2026-10-16 判断顺序](2026-10-16-rc003-audio-gap-diagnostics.md)：接收批次缺失，缺口在 Mac 回调之前；仍需蓝牙抓包或遥控器端计数区分无线与遥控器侧。覆盖率 91.7%，落在本记录 84%～96% 的现场范围；不能仅凭覆盖率判定根因。
- 与 [2026-11-24 起始空洞记录](2026-11-24-rc003-early-stream-gap-first-word.md) 同属“已收到样本账目完整、但总批次少于预期”的 RC003 采样缺失；起始空洞偏向首字风险，本条造成尾部丢字。两者作为同一根因调查的关联证据。
- 边界：单台 Mac、单只 RC003、单次用户确认；未做 HCI 抓包，不能确认丢在无线还是遥控器端。

## 2026-11-24 22:46 16 秒长句与 1.9.21/2.0.10 对比

- 现场：Build 442，RC003，豆包，虚拟音频；回眸 22:46 的 16 秒录音（operation 10）。用户确认目标输入框同样缺尾字。
- 会话 15.557 秒，音频/录音 14.685 秒，少 872ms；`batches=979`、`expected_batches=1037`，少 58 个批次；58 × 240 samples = 13,920 samples = 870ms。App 侧丢弃、入队、播放和录音 writer 计数一致；不是排空、回眸归档或 60 秒上限。
- 1.9.21 与 2.0.10 的音频接收/解码/录音路径基本一致：两者 `CBCentralManager` 都使用 `.main`，`handleAudio`、ADPCM 解码和帧累积未变。2026-10-13 提交记录中的 1.9.21 Build 174 现场 29 次会话覆盖率为 **83.9%～95.8%**；2.0.10 本机 10 段为 **87.2%～96.8%**，没有证据表明 2.0.10 的接收丢包是新回归。
- 2.0.10 新增的主线程逐批工作包括 `settings.recordLocalVoiceSamples`、`ATVVAudioDiagnostics`、`AudioOutput` 音量缩放与 `engineQueue` 投递、启动队列和待配置缓冲。它们是主线程抖动的放大器，但现有样本不足以证明新增回归。
- 回眸原始录音回放在 1.9.21 和 2.0.10 都已存在，不能把可听性差异归因于 2.0.10 新增功能。更可能是本次句子更长、尾字落在缺失区间，或此前未逐条回放；这不能证明 1.9.21 没有丢样本。
- **专用回调队列不能直接复用**：`856d169e` 就是 PR #1028。该构建（build 346）在真实 RC003 会话中造成更严重回归：同长度会话覆盖率 **96.4% → 94.3%**，通知 **1912/1984 → 1863/1975**，录音 **28.680s → 27.945s**，目标文字 **93 字 → 0 字**；App 侧 `dropped_samples=0`、`interrupted_samples=0`。PR #1028 已关闭，主队列 `.main` 保留；详见 [2026-11-13 蓝牙尾音排空记录](2026-11-13-bluetooth-tail-release.md#2026-11-13-会话补充记录) 与 [PR #1028](https://github.com/HD838A/remote-mic-app/pull/1028)。
- `6c9a34a5` 的同类改动也在 `d3c004f6` 中折回 `.main`；当前 2.0.10 日志 `callback_queue=main` 与源码一致。`856d169e` 的 1628 帧 ingress 测试只证明回调队列能接住帧，不能证明主线程业务、Fn 合成、播放排空或目标工具文字正确；build 346 的 0 字结果说明测试覆盖不足。
- 下一步必须先解释 build 346 的回归（队列顺序、主线程投递、Fn/目标工具时序），再设计不重复该失败路径的方案；不得直接接回 `856d169e`。同一 16 秒句子重复 10 次、比较 `batches/expected_batches`、`audio_ms/duration_ms`、目标框和回眸录音尾字仍是必要对照。

## 2026-11-24 2.0.10 主线程减负候选（已做 20/50 秒本机复测）

- 不改 CoreBluetooth 回调队列，不重放 #1028。只减少每个 15ms 音频批次在主线程上的固定工作：
  - `recordVoiceAudioReceipt` 不再逐批调用 `settings.recordLocalVoiceSamples`，也不再逐批抓取输出快照；本地用量改为会话结束时按 `receivedSamples` 一次记账。
  - `VirtualAudioOutput.makeBuffer` 直接写入 `AVAudioPCMBuffer`，去掉每批临时 `[Float]` 数组分配。
- 目的：降低主线程抖动，避免 CoreBluetooth 接收缓冲在主线程忙时积压；不改变 BLE 回调队列、Fn、控制事件顺序、录音内容或排空语义。
- 用量归属变化：跨本地午夜的会话会在结束时按 `endedAt` 回溯拆分样本，单次会话的日期归属最多偏移该会话的样本；不改变总时长和总样本。
- 自动化：`swift build --disable-keychain`、1661 项完整测试（116 个套件）、99 项定向测试（`LocalUsageLedgerTests`、`VirtualAudioConnectionLifecycleTests`、`ATVVAudioDiagnosticsTests`、`CoreVoiceInputJourneyTests`、`BluetoothVoiceTailDiagnosticsTests`）和 50 项项目自检通过。
- 本机候选包：Build 443，`~/Applications/SayAll.app`，公开 ad-hoc 签名，`source_commit=4d258262899df16ae2a1f439ca3f4566eaad5fa7`，`dirty=true`（包含本节记录）；已在 2026-11-25 00:15 启动。

### 2026-11-25 00:17–00:23 复测结果

- 短会话明显改善：4 段 19.6–20.8 秒会话的覆盖率分别为 97.5%、97.3%、97.1%、96.0%，用户确认尾字完整。
- 长会话仍缺尾字：
  - 50.294 秒会话（operation 4）：`batches=3147` / `expected=3353`，覆盖率 93.9%，录音 47.36 秒；目标文本记录结束于“区分无线和遥控器。”，缺少“侧缺失”。本地辅助 ASR 对录音的识别同样结束于 47.10 秒的“区分无线和遥控器”，没有“侧缺失”。
  - 53.132 秒会话（operation 6）：`batches=2901` / `expected=3542`，覆盖率 81.9%，录音 43.648 秒；本地辅助 ASR 结束于 43.48 秒的“区分无限和摇困器测”，同样没有“缺失”。目标文本捕获因 `discontinuous_after_finish` 未归档。
- 两个长会话的 `enqueue_failures`、`dropped_*`、`interrupted_samples` 均为 0；`scheduled_samples=played_samples=routed_samples=audio_written_samples`；`main_probe_max_lag_ms` 分别为 38 和 38，没有长时间主线程停顿；`last_callback_to_stop_ms` 为 28/15，末尾仍有 PCM。App 侧没有可丢弃的尾音。
- 结论：Build 443 的减负对 20 秒级会话有效，但 50 秒级缺口仍在到达 App 之前。目标工具不是唯一截断点，录音文件本身也结束在缺失字之前。
- 与 [PR #1032](https://github.com/HD838A/remote-mic-app/pull/1032) 的 PacketLogger 真机结论一致：RC003 在物理松键前约 14ms 停止发送 HCI 音频，松键后没有迟到音频；App 回调数与 HCI 通知数一致。本次两个长会话的 `last_callback_to_stop_ms` 为 28/15，也符合该边界。因此 App 侧无法补回没有发送到 Mac 的尾字。
- 剩余路径不是继续在 Fn 释放或录音排空上加等待，而是产品交互（提示用户在最后词后稍停再松键）或 RC003 固件/发送边界。当前没有验证过的主机侧尾部修复；需要区分“用户松键过早”和“固件确实提前停采”时，应复用 #1032 的 HCI 方法，不在本 PR 重复实现。
- 辅助 ASR 使用本机 `mlx-community/whisper-small-mlx`，存在少量识别错字，只用于判断尾句是否包含“侧缺失”；缺失字以用户复核为准。
- 真机对照待完成：同一 16 秒句子重复 10 次，以及“最后词后停 1.5 秒再松键”的 50 秒对照；比较 `batches/expected_batches`、`audio_ms/duration_ms`、目标框和回眸录音尾字。未完成前不宣称修复，也不把 20 秒改善归因于单一代码改动。
- 边界：这次只降低主线程负载，不证明它能消除 RC003 无线/固件侧缺失；若覆盖率不变，仍需 HCI/遥控器端计数。
