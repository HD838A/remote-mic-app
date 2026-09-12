# MiRemoteV 2ch 启动时历史选择丢失导致无法语音

- 时间：2026-09-12
- 状态：候选修复，等待真实 MiRemoteV 2ch 与第三方语音工具验收
- 影响范围：已完成配置的用户重启无线麦SayAll.app后，虚拟音频选择可能为空，语音无声或无法唤起第三方输入法
- 功能点：启动音频设备选择、MiRemoteV 2ch 输出绑定、语音开始前音频恢复

## 观察

现场目录 `bug-第二天无法连接无法语音` 的日志显示：启动阶段蓝牙连接可以建立，但 `selectedAudioDeviceUID` 为空，随后反复出现 `audio.output.none_selected`。用户在设置中重新选择 `MiRemoteV 2ch` 后，音频恢复；恢复后的语音流 `enqueue_failures=0`，9 月 10 日记录 500 次、9 月 11 日记录 9 次，未见持续播放失败。

## 复现与边界

已确认的触发边界是“当前选择 UID 为空”。现有健康重绑逻辑只能重建已经明确选择的设备，无法在没有 UID 时决定要绑定哪个虚拟设备，因此会把蓝牙已连接误认为语音链路已就绪。无法在本机复现用户现场的真实 CoreAudio/第三方输入法状态，真实硬件验收仍待完成。

## 根因假设与结论

最小代码检查确认：启动时读取的当前选择为空，配置调用使用空 UID；历史上曾明确选择的设备没有独立持久化字段。根因范围收敛为“当前选择状态丢失后没有安全的历史选择恢复”，不是蓝牙连接或音频包入队问题。结论置信度：高（日志顺序、手动重选后的恢复结果和代码路径一致）。

## 修复策略

- 在 `AppSettings` 中保留最近一次非空的 `lastKnownAudioDeviceUID`；当前选择被清空时不覆盖该历史值。
- 启动枚举输出设备后，按“当前选择 → 可用的历史 UID → 有历史配置且仅一个受支持候选”的顺序恢复。
- 同时存在多个候选、历史设备缺失、无历史配置或无受支持设备时不猜测。
- 记录不含 UID 的稳定设备类型和恢复结果：`candidate`、`completed`、`failed` 或 `skipped`；不输出设备标识、路径、用户内容或第三方 App 私有状态。

## 验证

- 自动化：`AudioSelectionRecoveryTests` 覆盖当前选择优先、MiRemoteV 历史 UID 恢复、唯一候选恢复、多候选不猜、无历史不选、历史设备缺失不切换、重启持久化和启动日志接线。
- 代理实测：待运行定向 Swift 测试、完整 Swift 测试、项目脚本与仓库边界检查。
- 真实设备/第三方工具：尚未在反馈机器完成重启、MiRemoteV 2ch 枚举、RC001/RC003 和目标语音工具文字上屏验收；不能以自动化结果替代真机结论。

## 相关文件

- `Sources/RemoteMic/AppSettings.swift`
- `Sources/RemoteMic/AudioOutput.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Tests/RemoteMicTests/AudioSelectionRecoveryTests.swift`
- `Testing/MiRemoteVAudioStaleRecovery.md`
