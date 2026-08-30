+# Issue #106：默认配置返回键不可用

## 复现与日志

默认关闭自定义映射时，返回键没有 macOS 原生键盘事件；`HIDRemoteMonitor` 直接停止读取报告，因此退格动作不会执行。用户反馈打开自定义映射后恢复，和代码行为一致。

## 根因

返回键 HID usage 为 `0xF1`，`RemoteButton.back.nativeEvent == nil`；系统托管模式无法产生该键的原生事件。

## 修复

对已识别实体遥控器增加非独占、仅返回键的监听路径。映射关闭时只解析返回键并执行默认 `deleteBackward`，不接管其它按键，也不启动全量事件抑制。

## 验证

- `swift test --filter RemoteButtonsTests`
- 自动化覆盖映射关闭时的 back-only 接线。
- 真实遥控器、输入监控/辅助功能权限和目标文本应用仍需真机验收。

