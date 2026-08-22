# 研究发现

- `ButtonAction` 位于 `Sources/RemoteMic/RemoteButtons.swift`，映射 UI 使用 `allCases`、`category` 和 `displayName`，新增动作后会自动进入选择器。
- `HIDRemoteMonitor.startRepeatIfNeeded` 会对 `allowsRepeat == true` 的方向/系统动作做按住重复；滚轮动作应保持可重复。
- `KeyboardInjector.send` 是外部动作统一注入接缝；现有键盘动作通过 `CGEvent`，系统音量通过 system-defined event。
- 滚轮事件应使用 `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`，以 `CGScrollEventUnit.line` 发送上下滚动量。
- 影响范围限定为动作枚举、两套本地化文案、键盘注入器和对应回归测试。
