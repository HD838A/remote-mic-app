# 研究发现

- 当前设备 profile 按遥控器区分，`AppSettings.configuredAction(... profileID:)` 通过 `RemoteDeviceProfile` 读取；这与按前台应用配置是两个独立维度。
- `HIDRemoteMonitor` 已经读取 `frontmostBundleIdentifier`，但目前主要用于 native passthrough / repeat policy，尚未参与动作配置选择。
- `ButtonAction`、`ConfiguredButtonAction` 和映射 UI 位于 `RemoteButtons.swift`、`AppSettings.swift`、`SettingsView.swift`；新增动作可以沿用现有 picker 和持久化架构。
- `KeyboardInjector.send` 是外部动作注入接缝；滚轮动作目前固定使用 line delta 5 / -5，需要改为从设置传入方向与速度。
- 现有 Codex 相关动作主要是打开 / 聚焦 Codex；新增动作应使用普通 CGEvent/辅助功能路径，不依赖 Codex 私有 API。
- 应用覆盖配置使用 bundle identifier 匹配，应用 profile 未覆盖的字段回退到当前遥控器设备映射；这样不会改变其他应用行为。
- Codex 停止生成使用 Escape，聚焦输入框复用现有 `focusComposer` 无障碍定位，滚动到最新使用 Command-End；三个动作均禁止按住重复。
- 滚轮速度限制为 1...10，默认 5；反向设置只改变滚轮 delta 的符号，不影响语音、Command-Tab 或方向键。
- 新字段均为可选导入字段，旧配置缺失时使用空应用 profile、速度 5、非反向默认值。
- Release 主应用类型检查和打包通过；系统默认 SwiftPM 构建受本机 CLT/SDK 环境限制，使用 `--disable-sandbox` 构建成功。
- Codex 翻页可直接映射 macOS 原生 Page Up / Page Down key code（116 / 121）；无需新增 Codex API 或滚轮参数，现有应用 profile picker 会自动发现新动作。
- 实测日志显示遥控器已正确解析为 `codexPageUp` / `codexPageDown`，但 Codex 未响应合成 Page Up/Page Down；GitHub MacosUseSDK 的可复用滚轮实现使用目标坐标、`wheelCount=2` 和约 15ms 事件间隔，因此翻页动作改为独立的大步长滚轮事件。
