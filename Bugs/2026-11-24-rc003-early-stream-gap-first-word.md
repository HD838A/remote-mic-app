# RC003 语音流开始时出现 88–161ms 早期空洞

- 时间：2026-11-24（本地测试 01:08–01:10；日志 UTC 2026-11-23 17:08–17:10）
- 状态：调查中；与 2026-10-13 RC003 采样缺失关联；尚未确认用户可观察的首字缺失，未修复
- 影响范围：macOS 2.0.10 Build 442，RC003（小米遥控器），豆包语音工具，虚拟音频输出
- 功能点：`ATVV` 语音流启动、虚拟音频投递、首字完整性
- 简单描述：连续短语音的多个会话在开始后约 165–181ms 出现 88–161ms 无音频区间；若用户在按下后立即开口，首个音节可能落入该区间。
- 原始记录：本机现场日志 session `424FE1AA`，Build 442；解密明文只在本地诊断目录，未入库

## 已确认事实

同一日志中，连续 5 段短语音和 1 段 60 秒长语音均为 `completion=normal`，`interrupted_samples=0`、`pending_samples=0`、`callbacks_after_stop=0`；每段都先完成 `AUDIO PLAYBACK drained`，再出现 `VOICE KEY tail_release`。**尾音排空没有发现 App 侧丢失。**

| operation | 开始（UTC） | 时长 | 首个 PCM | 起始空洞 | 中断/残留 | 文字观察 |
| --- | --- | --- | --- | --- | --- | --- |
| 5 | 17:08:32.494Z | 2.05s | 210ms | 最大 30ms @240ms | 0 / 0 | 取消（`discontinuous_after_finish`） |
| 6 | 17:08:35.5Z | 1.70s | 18ms | **88ms @165ms** | 0 / 0 | 7 字 |
| 7 | 17:08:38.5Z | 1.82s | 19ms | **161ms @181ms** | 0 / 0 | 7 字 |
| 8 | 17:08:41.0Z | 1.65s | 22ms | **143ms @165ms** | 0 / 0 | 5 字 |
| 9 | 17:08:43.7Z | 1.53s | 166ms | 29ms @450ms | 0 / 0 | 5 字 |
| 10 | 17:09:08.0Z | 60.05s | 165ms | 48ms @53.1s | 0 / 0 | 取消（`discontinuous_after_finish`） |

同一日志早前的 operation 2 也出现 `148ms @164ms` 的同类起始空洞。合计 10 段中 4 段（operation 2、6、7、8）出现约 150ms 量级的早期无音频区间。

## 关键证据

- operation 6–8 的首个回调分别在 18/19/22ms 到达，随后在 165/181/165ms 出现 88/161/143ms 的 `max_callback_gap_ms`。即先收到一个很短的首片段，再出现约 150ms 空洞，之后才恢复连续音频。
- operation 6–8 的 `batches` 分别为 101/107/98，`expected_batches` 分别为 113/121/110；缺少约 12–14 个批次，与 150ms 量级空洞一致。
- `drop_stopped`、`drop_stale_peripheral`、`drop_stale_generation`、`drop_callback_error`、`drop_missing_value`、`drop_lifecycle`、`drop_not_ready`、`drop_cancelled_open`、`drop_after_stop`、`drop_identifier`、`identifier_drops` 全部为 0；`enqueue_failures=0`，`rx_bytes=accepted_bytes`。
- `main_probe_max_lag_ms` 为 6–15ms，`coverage_basis=main_callback_processing`；主线程没有出现足以解释 150ms 空洞的阻塞。
- operation 5 在语音开始时记录 `AUDIO HEALTH stale`，音频引擎重建约 80ms，首 PCM 210ms；这是空闲后首句的独立冷启动风险，不解释 operation 6–8 的连续空洞。
- operation 10 由 `ATVV STREAM STOP reason=remote_timeout` 结束，并在 60.046 秒出现 `VOICE KEY ... reason=remote_timeout_commit`；尾音自然排空正常。60 秒后的语音不属于本次早期空洞，属于已知 RC003 会话上限。
- 日志只记录文字字符数（operation 6–9 分别为 7/7/5/5），不记录语音或输入框内容；operation 5、10 没有正向文字观察。

## 假设与排查

### H1：RC003/ATVV 每次新流启动存在固定约 150ms 的音频空洞（优先假设）

- Supports：连续三段短语音在相近的 165–181ms 位置出现 88–161ms 空洞；App 侧无丢弃、无入队失败、主线程低延迟；缺失批次从未到达。
- Conflicts：并非每段都出现（operation 5、9 没有），operation 2 也不是紧接上一段；不能证明只由快速连续语音触发。
- Test：同一短句做“按下立即说”与“按下后等 250ms 再说”的 A/B 各 10 次；检查首字是否只在立即开口时缺失，并确认空洞是否每次都在 165–181ms 出现。

### H2：BLE 调度或遥控器编码器启动导致空洞

- Supports：150ms 量级接近多个 BLE 连接间隔；`rx_bytes=accepted_bytes`，空洞发生在宿主收到之前。
- Conflicts：现有日志没有 HCI 包级时间线，无法区分遥控器未发送、BLE 未投递和 helper 未上报。
- Test：对同一复现会话采集 HCI/PacketLogger 或 helper 侧 PCM 到达时间线，按包核对 165–181ms 区间是否有数据发出/到达。

### H3：App 播放队列或主线程投递延迟

- Supports：无。
- Conflicts：`main_probe_max_lag_ms` 仅 6–15ms；`drop_*` 全零；每段 drain 正常；空洞计入 `max_callback_gap_ms` 而不是输出端 pending。
- Test：继续用现有 `timeline` 与 `AUDIO DRAIN` 对照；若空洞期间没有 callback 或字节到达，可排除 App 播放队列。

### H4：音频引擎冷启动

- Supports：operation 5 出现 `AUDIO HEALTH stale`，重建 80ms，首 PCM 210ms。
- Conflicts：operation 6–8 没有引擎重建，仍出现更大空洞。
- Test：空闲 5 分钟后首句单独统计；与连续会话的第二、三段分开归因。

## 与 2026-10-13 采样缺失的关系

- [2026-10-13 长会话尾部缺失](2026-10-13-rc003-audio-delivery-rate-shortfall.md) 记录的是同一类“已收到样本账目完整、但总批次少于预期”的 RC003 采样缺失。2026-11-24 21:09 的 10 秒会话（operation 2）用户确认：目标框只有前 8/12 字，回眸录音同样缺最后 4 字；会话 9.961s、音频 9.135s，少 826ms；`batches=609`、`expected_batches=664`，少 55 批（825ms），App 侧丢弃、入队和 writer 计数正常。
- 因此本文的 165–181ms 起始空洞应视为同一 RC003 采样缺失的早期位置子现象，不单独当作另一种根因；后续 HCI/遥控器端计数需要同时覆盖起始 165–181ms 和该 10 秒会话的 55 个缺失批次。
- 两篇记录都不使用覆盖率单独判定根因。

## 待完成证据

1. 用户按 A/B 方案复测，提供每次期望文字与实际显示，确认是否真的出现首字缺失，以及缺失是否与 165–181ms 空洞对齐。
2. 连续快速再次按下重复 10 次，确认早期空洞是否稳定出现在第二、第三段开头。
3. 同一 10 秒录音案例重复 10 次，记录 `batches` / `expected_batches`、音频时长差和是否缺尾字。
4. 采集 HCI/PacketLogger 或 helper 侧到达时间，区分遥控器、BLE 和宿主边界。
5. 对照 RC001 与 RC003，确认是否型号/固件特有。
6. 在根因确认前不增加静音填充、预滚或重排音频的实现；这些可能掩盖空洞并改变首字/尾字语义。

## 验证边界

- 目前只有一台 Mac、一只 RC003、一个 Build 442 和同一目标输入框的 10 段样本；不能据此宣称所有 RC003 或所有用户都会丢首字。
- 尚未完成用户可观察文字缺失的确证；本记录只确认“音频到达前存在约 150ms 空洞”这一事实和首字风险。
- 现有日志没有 HCI 包级时间戳，不能把根因归到蓝牙、固件或 App 任一侧。
- 本次未修改产品代码；以上结论不构成修复、兼容性或发布验收。

## 关联记录

- 通用语音完整性门槛：[HardwareVoiceAudioContract](../Testing/HardwareVoiceAudioContract.md)
- RC003 长会话尾部缺失：[2026-10-13-rc003-audio-delivery-rate-shortfall](./2026-10-13-rc003-audio-delivery-rate-shortfall.md)
- 正常松键尾音排空：[2026-11-13-bluetooth-tail-release](./2026-11-13-bluetooth-tail-release.md)
- 日志字段与首字/尾字记录要求：[LOGGING.md](../LOGGING.md)
