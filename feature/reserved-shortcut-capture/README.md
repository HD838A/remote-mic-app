# 系统占用快捷键录入

## 为什么开发

原录入器只监听无线麦窗口收到的 `keyDown`。`Command + Space` 等系统或其他 APP 已注册的热键可能在到达窗口前被处理，导致用户按键后页面没有结果，只能先去系统设置临时取消热键。

## 用户功能

- 未点击录入时只显示“尚未录入”或现有快捷键，不表现为正在等待输入。
- 点击“录入快捷键”后才出现页面内录入入口。
- 录入期间短暂截获一次键盘组合，避免系统或其他 APP 抢先执行原动作。
- 完成后显示“快捷键录入成功”；权限缺失或捕获器无法启动时显示明确提示。
- 普通按键的自定义快捷键和自定义 APP 的聚焦快捷键使用同一套录入行为。

## 范围与非目标

- 本次只改录入阶段，不改变 `CustomKeyboardShortcut` 的持久化格式、导入导出结构或 `KeyboardInjector` 执行逻辑。
- 事件捕获器只在用户明确点击录入后存在，录入、取消或离开编辑状态后立即停止，不常驻监听键盘。
- 本次不实现单独 Left/Right Option、Command、Control 或 Shift 的录入；该需求继续由独立 TODO 跟踪。

## 关键设计与涉及文件

- `Sources/RemoteMic/ShortcutCaptureMonitor.swift`：短生命周期 `CGEventTap`，捕获一次真实 `keyDown`，忽略自动重复和本 APP 合成事件。
- `Sources/RemoteMic/SettingsView.swift`：录入前、录入中、成功和失败的页面内状态。
- `Resources/*/Localizable.strings`：中英文状态文案。
- `Tests/RemoteMicTests/ShortcutCaptureMonitorTests.swift`：事件捕获、阻止传播、单次完成和权限失败测试。
- `Testing/CustomApplicationFocus.md`：真实 Spotlight、第三方 APP 和遥控器测试步骤。

## 隐私与兼容边界

事件 tap 仅在录入期间处理下一次键盘按下，不保存输入内容；日志只记录捕获成功或失败，不记录键码和组合键。已有快捷键配置无需迁移。

## 验证状态

- Swift 构建和既有测试通过。
- 新增事件级测试确认 Command-Space 对应事件被捕获并阻止继续传播。
- 本机桌面会话处于锁定状态，尚未完成真实 Spotlight 和真实遥控器验收；功能当前保持“等待人工验收”。

人工步骤见 [Testing/CustomApplicationFocus.md](../../Testing/CustomApplicationFocus.md#用例-2a录入已被系统或其他-app-占用的快捷键)。
