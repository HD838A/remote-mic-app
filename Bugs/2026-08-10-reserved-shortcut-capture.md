# 已占用组合键无法录入

## 触发条件与错误行为

- 用户在快捷键编辑区尝试录入已由 macOS 或其他 APP 注册的组合键，例如 Spotlight 的 `Command + Space`。
- 原页面可能持续显示“等待按键…”，但没有保存结果；临时取消系统快捷键后才能录入。
- 未点击录入时，空配置也显示“等待按键…”，容易让用户误以为页面已经开始监听。

本轮修复前没有在真实桌面会话重新操作旧版本：本机 GUI 验收时桌面已锁定。用户现场反馈、仓库 TODO 和旧实现的事件边界可以确认问题路径，但不能把本轮自动化描述成旧版本真实复现。

## 日志结论

修复前的录入流程没有写入快捷键捕获日志；现有 `runtime.log` 中没有对应成功或失败记录。旧实现静默等待，因此日志无法区分“用户没有按键”和“事件被系统提前消费”。

## 根因

旧 `ShortcutCaptureView.Coordinator` 使用：

```swift
NSEvent.addLocalMonitorForEvents(matching: .keyDown)
```

本地 monitor 只能处理已经投递到无线麦窗口的事件。系统或其他 APP 的全局热键可以更早消费组合键，导致录入器根本收不到 `keyDown`。同时空状态复用了“等待按键”文案，造成录入生命周期不清晰。

## 修复

- 用户点击录入后创建 `.cgSessionEventTap`、`.headInsertEventTap`、`.defaultTap` 的短生命周期捕获器。
- 第一次真实 `keyDown` 转换为现有 `CustomKeyboardShortcut` 后阻止事件继续传播，随后立即结束录入。
- 忽略键盘自动重复和带有 `KeyboardInjector.syntheticEventMarker` 的本 APP 合成事件。
- 事件 tap 不可创建时显示权限或启动失败信息，并记录不包含键码的诊断日志。
- 页面初始状态改为“尚未录入”，只有点击后才显示录入入口，完成后显示成功反馈。

## 验证

- `swift test --filter ShortcutCaptureMonitorTests`：4 项通过。
- `swift test --filter SettingsPageRegressionTests`：4 项通过。
- 事件级测试覆盖 Command-Space 捕获并阻止传播、只回调一次、自动重复过滤、合成事件放行和辅助功能权限失败。
- 完整 `swift test`、项目自检和 Release 构建将在最终交付前执行。

## 验证边界

自动化构造的 Quartz 键盘事件不能替代真实 Spotlight 注册、真实第三方 APP 全局热键或真实遥控器执行。由于桌面会话锁定，本轮尚未完成页面点击、真实 `Command + Space` 和遥控器触发验收；TODO 与测试手册保持未完成状态。
