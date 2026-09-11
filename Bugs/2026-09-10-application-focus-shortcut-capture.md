# App 聚焦快捷键无法配置 Cmd+L

## 反馈与复现边界

用户在“打开自定义 APP → 使用 APP 快捷键聚焦”中无法录入 Cmd+L 和其他快捷键。截图显示“尚未录入”，没有记录录入启动后的状态，不能由截图确定系统事件已经到达捕获器。

本轮电脑锁屏，CUA 无法解锁，因此没有复现用户真实桌面上的完整操作。已用生产 `ShortcutCaptureMonitor.swift` 的独立启动 harness 将 `accessibilityTrusted` 注入为 false，复现所有键在开始捕获前都被阻断：

```text
FAIL: Cmd+L cannot be recorded because startup is blocked: accessibilityPermissionRequired
```

原有 4 项 monitor 测试通过，说明已进入 handler 的事件可解码；这不证明系统 event tap 已实际启用。新的回归覆盖前台 Cmd+L 录入、全局 tap 创建失败、合成事件放行、取消后迟到回调和应用配置保存。

## 日志结论

正式修改前检查本机 SayAll 的 runtime.log，没有对应 `SHORTCUT CAPTURE` 现场记录。旧实现只由界面记录成功或失败，没有开始录入或全局捕获启动日志，无法区分用户没有点击、权限缺失和系统事件没有到达。不能把本轮受控权限复现认定为用户现场的唯一根因。

## 已确认原因与修复

- 旧录入器将所有录入都绑定到全局辅助功能权限和 event tap；即使只想在自身窗口录入普通 Cmd+L，也会因全局能力不可用而立即失败。现在优先保留原全局捕获，失败时只监听无线麦自身前台窗口的 NSEvent。跨应用动作执行仍沿用原权限门禁。
- App 聚焦快捷键编辑区缺少普通自定义快捷键已有的标准键盘选择器。现在可直接点击 Command 和 L 等按键配置，无需依赖系统事件捕获；配置选择不会执行快捷键。
- 录入与页面键盘共用按 profile ID 更新的方法，保留当前 App 的其它聚焦配置。取消会移除监听，排队但未送达的捕获不能在取消后修改配置。
- 日志新增进程内操作编号、requested/started/completed/cancelled/failed 和 global/foreground 模式，不记录实际键值、路径或目标 App 身份。前台回退明确不保证拦截系统保留组合键，界面不再作绝对保证。

## 验证

```sh
swift test --disable-keychain --filter 'ApplicationFocusShortcutTests|ShortcutCaptureMonitorTests|RemoteButtonsTests|SettingsPageRegressionTests|LocalizationTests'
swift test --disable-keychain
SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh
./scripts/check-repository-boundaries.sh
CONFIGURATION=debug ./scripts/build-app.sh
```

- 定向测试 165 项通过；完整测试 469 项通过；项目自检 44 项通过。
- 独立启动 harness 修后返回 foreground success，取消日志完整；测试注册真实 NSEvent local monitor，但没有向系统发送键盘事件。
- 新增字母事件回归曾因测试并行调用 macOS 文本输入源 API 触发 HIToolbox abort；已让相关测试在 MainActor 执行，与生产 main run loop 路径一致，完整重跑通过。
- 标准键盘选 Cmd+L → profile 保存 → 重新加载 → 所选 App 聚焦参数的自动化通过；其它 App 配置不变。
- 原生 Debug App 构建和 `swift build --disable-keychain -c release` 通过；中文浅/深色、英文浅色与完整键盘生产视图截图已核对，原图见 `Screenshots/app-shortcuts/`。最终 CI 结果以对应 PR 为准。

## 人工验收

[自定义 App 聚焦测试手册](../Testing/CustomApplicationFocus.md) 的用例 2B 包含权限、前后台、取消、配置隔离和窗口矩阵。真实 Cmd+L、Cmd+Q/W、Spotlight 保留键、Cursor/Codex 最终输入框焦点和实体遥控器尚未验收；构造事件、配置路由和离屏截图不能替代这些结果。本修改不涉及语音键、音频或硬件协议。
