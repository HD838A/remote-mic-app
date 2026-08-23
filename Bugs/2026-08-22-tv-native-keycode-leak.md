# TV 键原生键码与实际硬件不符导致 § 泄漏

## 触发条件

- 遥控器以非独占（monitored）模式连接（`activeDeviceIsSeized == false`，即系统 HID 与 App 监听并存）。
- TV 键被绑定为任何非原生动作（例如"切换鼠标模式"或其他自定义动作）。
- 此时每次按下 TV 键，App 执行绑定动作的同时，遥控器键盘接口的原生按键事件仍会到达前台 App。

## 复现证据

- 真机：小米遥控器 2 Pro（BLE 识别 rc003），monitored 模式。
- 会话层事件 tap 实测：TV 键的键盘接口实际向系统发送 `keyCode=10`（ISO § 键），`flags=0x100`，连按 30 次全部到达会话层。
- 对照实测：合成 keyCode 50 的键盘事件产出的是 · 而非 §，证实 50 不是 TV 键的真实原生键码。
- 对照实测：电源键走独立的 power_suppressed 机制，不存在同类泄漏。

## 日志结论

- 泄漏路径不产生 App 侧错误日志：`KeyboardEventSuppressor` 按 `nativeEvent` 布防，TV 键布防的是 keyCode 50；真实的 keyCode 10 事件永远匹配不上布防描述符，抑制器静默放行。日志中按键动作本身正常执行（`HID BUTTON ... action=...`），"动作已执行"不等于"原生事件已被抑制"。

## 根因

`Sources/RemoteMic/RemoteButtons.swift` 的 `RemoteButton.nativeEvent` 表把 `.tv` 映射为 `keyboard(keyCode: 50)`。该值来自 initial public release，与 rc003 键盘接口实际发射的 keyCode 10 不符，可能一直就错。monitored 模式下原生事件能否被抑制完全取决于这张表与硬件实际发射是否一致。

## 修复

- `RemoteButtons.swift`：`.tv` 的 `nativeEvent` 改为 `keyboard(keyCode: 10)`，并加注释标明实测依据。
- 测试：`RemoteButtonsTests.nativeEventDescriptorsCoverPotentialDuplicateEvents` 与 SelfTest 的 "native duplicate-event descriptors" 断言组各补 TV==10 一项。

## 验证

- `SKIP_SWIFT_PACKAGE_BUILD=1 scripts/test.sh`：42 项通过（含更新后的 "native duplicate-event descriptors" 断言）。
- 手工单元测试链路（本机 Swift 6.1 等效 runner）：`RemoteButtonsTests.nativeEventDescriptorsCoverPotentialDuplicateEvents` 通过。
- 真机回归（待做）：monitored 模式下把 TV 绑定为非原生动作，连按 TV，确认前台输入框不再出现 §，且绑定动作正常执行。

## 验证边界

- 实测证据只来自一台 rc003；RC001 及其他固件版本的 TV 键原生键码未验证（若不同固件发射不同键码，需要按设备指纹分别建表，当前无证据表明存在这种差异）。
- seized（独占）模式本就不受影响：系统 HID 不消费遥控器事件。
- 本机工具链为 Swift 6.1（Xcode 16.4），仓库要求 6.2；单元测试通过手工等效链路执行，CI 上的完整 `swift test` 以 PR 检查为准。
