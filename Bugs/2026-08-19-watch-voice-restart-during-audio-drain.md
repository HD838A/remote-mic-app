# Watch 停止后立即重新收音被判定占用

## 状态

候选修复完成，自动化通过，等待实际测试 Mac 与真实 Apple Watch 验收。

## 影响范围

- Mac `1.8.25 (121)` 与 iOS / Watch `0.8.12 (18)`。
- 大部分语音会话正常；主要影响停止后立即开始下一句的极短时间窗口。

## 复现

1. Watch 通过 BLE 开始收音并说话数秒。
2. 停止后立即再次点按开始。
3. 旧实现偶尔向 Watch 返回占用错误；等待约一秒再点通常恢复。

## 日志与代码证据

- Watch `13:33:30` 请求停止，Mac `13:33:35` 才收到；同秒新开始被记录为 `start_rejected reason=busy requested=watch active=watch`。
- Watch 端停止被旧音频 FIFO 阻塞是主要延迟来源，配套仓库已改为停止优先并清理未发送旧音频。
- 即使停止及时到达，Mac `stopPhoneVoice` 仍会等待虚拟输出播放完已有缓冲，最长 0.75 秒；此期间 `activeMobileVoiceSource` 保持为 Watch，新的 `startPhoneVoice` 必然返回 busy。

## 根因

Mac 把“仍在接收语音”和“已经停止接收、仅排空尾部缓冲”都表示为同一个 active 状态，缺少 stopping 阶段。旧排空回调也没有独立 generation，无法安全地允许下一次开始等待旧停止完成。

## 修复

- 增加 `active / stopping / pending restart` 的最小状态边界。
- 同一来源在 stopping 阶段请求开始时延迟完成请求；旧音频排空后释放旧语音键和统计会话，再启动新会话并回送结果。
- 不同来源仍返回 busy，不允许 iPhone、Watch 或 Web 在旧会话停止中互相接管。
- 每次停止使用 generation；旧排空回调不能清理或结束新的移动语音会话。
- App 停止时取消待重启请求并返回 unavailable，避免客户端永久等待。
- 用户在等待新 `voiceReady` 时再次停止，会取消待重启请求；旧排空完成后不会留下一个没有客户端接收的幽灵语音会话。
- 不修改虚拟麦克风格式、0.75 秒尾部排空上限、实体遥控器、BLE 音频协议或网络监听策略。

同时检查了实体遥控器连接管理：发现桥会排除已登记遥控器标识，当前代码没有证据证明同一个遥控器被两个桥重复连接。现场只有一次实体遥控器重试与 Watch 断联时间接近，因此本次不改变实体遥控器重试策略。

## 验证

- `swift test --filter WatchBluetoothVoiceJourneyTests`：3 项通过。
- 覆盖同一 Watch 停止中延迟重启、空闲立即开始、不同来源继续互斥和现有 `voiceReady` 首次启动旅程。
- Mac 全量 229 项测试与 Release 构建通过；固定 revision 的 `SayAllMacRemote` 26 项测试与 Release 构建通过。
- 配套 iOS/Watch 全量 84 项测试、Watch 协议与生命周期 44 项测试及 iOS Release Simulator 构建通过。

## 真机边界

自动化没有真实 Watch、CoreBluetooth 射频、MiRemoteV 2ch 和第三方语音工具。需在实际测试 Mac 上连续执行至少 20 次“停止后立即开始”，确认没有占用错误、两句不合并、尾音和首句可辨、系统语音键正确释放与重新按下。
