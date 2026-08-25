# TV 键在不同键盘布局下的原生键码泄漏

## 触发条件

- 遥控器以非独占（monitored）模式连接（`activeDeviceIsSeized == false`，即系统 HID 与 App 监听并存）。
- TV 键被绑定为任何非原生动作（例如"切换鼠标模式"或其他自定义动作）。
- 此时每次按下 TV 键，App 执行绑定动作的同时，遥控器键盘接口的原生按键事件仍会到达前台 App。

## 复现证据

- 真机：小米遥控器 2 Pro（BLE 识别 rc003），monitored 模式。
- 会话层事件 tap 实测：TV 键的键盘接口实际向系统发送 `keyCode=10`（ISO § 键），`flags=0x100`，连按 30 次全部到达会话层。
- 当时的对照实测只能证明该台 Mac 在当时键盘布局下使用 keyCode 10，不能排除其他布局使用 keyCode 50。
- 对照实测：电源键走独立的 power_suppressed 机制，不存在同类泄漏。
- 2026-08-25 现场再现：在当前键盘布局下，TV 键打开 Codex 后输入反引号。运行日志同时证明 `HID FILTER ready=true`、`mode=monitored`和 `action=openCodex`。本机键盘布局只读翻译证明 keyCode 10 产生 `§`，keyCode 50 产生反引号。

## 日志结论

- 泄漏路径不产生 App 侧错误日志：`KeyboardEventSuppressor` 按 `nativeEvent` 布防，TV 键布防的是 keyCode 50；真实的 keyCode 10 事件永远匹配不上布防描述符，抑制器静默放行。日志中按键动作本身正常执行（`HID BUTTON ... action=...`），"动作已执行"不等于"原生事件已被抑制"。

## 根因

`RemoteButton.nativeEvent` 只能记一个虚拟键码。TV 键的 HID usage 在 macOS 上会根据 ISO/ANSI 键盘布局表现为 keyCode 10 或 50；只防其中一个时，另一布局下的原生事件会被静默放行。

## 修复

- `RemoteButtons.swift`：保留已实测的 keyCode 10 为主描述符，同时把 keyCode 10 和 50 都列为 TV 键可能的原生事件。
- `KeyboardEventSuppressor.swift`：同一个 TV 按下/松开边缘同时布防两个键码，其他按键仍只布防原有单一描述符。
- 测试：新增 ISO/ANSI 两个 TV 键码都被抑制、松开后恢复实体键盘的回归。

## 验证

- `SKIP_SWIFT_PACKAGE_BUILD=1 scripts/test.sh`：42 项通过（含更新后的 "native duplicate-event descriptors" 断言）。
- 手工单元测试链路（本机 Swift 6.1 等效 runner）：`RemoteButtonsTests.nativeEventDescriptorsCoverPotentialDuplicateEvents` 通过。
- 真机回归（待做）：monitored 模式下把 TV 绑定为非原生动作，连按 TV，确认前台输入框不再出现 §，且绑定动作正常执行。

## 验证边界

- 实测证据仍只来自一台 rc003；RC001 及其他固件版本未验证。当前修复针对已观测的 macOS ISO/ANSI 虚拟键码差异，不假设固件改变。
- seized（独占）模式本就不受影响：系统 HID 不消费遥控器事件。
- 本机工具链为 Swift 6.1（Xcode 16.4），仓库要求 6.2；单元测试通过手工等效链路执行，CI 上的完整 `swift test` 以 PR 检查为准。
