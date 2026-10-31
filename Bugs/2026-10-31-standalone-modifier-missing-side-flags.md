# 独立修饰键事件缺少左右设备标志

## 状态与范围

- 关联：[Issue #782](https://github.com/HD838A/remote-mic-app/issues/782)。
- 开发基线：`c2aa042739c6e15919640d2d868942b5cf01859f`。
- 状态：候选修复；自动化结果见下文，真实遥控器与目标语音工具仍待验收。
- 范围：普通按键配置的独立左/右 Command、Option、Control、Shift。Fn 保持原有标志；不改变语音键、组合快捷键、配置格式、蓝牙或音频生命周期。

## 错误证据与正常边界

Issue 报告：将遥控器普通按键配置为独立右 Option 后，依赖右侧设备位的语音工具没有开始听写；实体键盘右 Option 正常。反馈中提供的脱敏日志摘要显示发送标志为 `524288`（`0x80000`），缺少右 Option 设备位 `0x40`。

未取得原始现场日志，也未在本机复现目标工具响应。根因验证使用不向 WindowServer 投递事件的注入器回归，不能据此宣称真实语音输入已验收。

修改产品代码前，先修正既有右 Option 测试，并新增全部八个左右修饰键、Fn、旧配置和失败恢复用例。执行：

```bash
swift test --disable-keychain --filter 'RemoteButtonsTests.standalone'
```

旧实现的 4 个测试中，3 个失败，共 12 条断言失败：独立右 Option 得到 `0x80000` 而非 `0x80040`；八个左右修饰键均缺少各自设备位；随后再次发送右 Option 仍缺少该位。权限拒绝用例通过；Fn 和旧配置读取、匹配、编码往返没有失败。

## 日志与代码结论

`StandaloneKeyboardModifier.modifierFlags` 只返回通用修饰标志，既有 `KeyboardInjector.send` 的独立修饰键分支直接发送 `shortcut.cgEventFlags`。同一键族的左右虚拟键码不同，但事件标志没有携带相应设备位。现有测试还把右 Option 的纯 `.maskAlternate` 标志写成预期，无法发现该缺陷。

语音键路径的 `VoiceKeyMode.eventFlags` 已经带左右设备位。此前 [PR #531](https://github.com/HD838A/remote-mic-app/pull/531) 修复组合快捷键时明确保留了独立修饰键的原路径，不覆盖本问题。

## 最小修复与兼容性

- 为独立修饰键增加 `deviceFlag`，使用系统 `NX_DEVICE*KEYMASK` 常量；只在发送按下事件时与通用标志合并。
- 不修改 `modifierFlags`、`CustomKeyboardShortcut.cgEventFlags` 或 `matching(_:)`。旧配置仍使用原有通用标志与键码，无需迁移、重新录入或改变导入导出格式。
- 保持一次按下、一次空标志释放。按下返回失败仍尝试释放；任一发送失败返回 `false`，后续调用独立执行。不增加重试、延时或全局键盘状态修改。
- 独立修饰键日志记录同一短生命周期 `operation_id` 下的请求与唯一终态、权限拒绝原因、按下/释放提交结果和耗时。移除该分支的原始键码及标志值；不记录配置名称或输入内容。
- `result=submitted` 只表示两个事件提交器均返回成功；`user_visible_result=unknown` 明确区分提交与第三方工具实际响应。同步路径没有独立的异步取消、超时或重试阶段。

## 验证结果

环境：macOS 26.0.1、Apple Silicon、Swift 6.2.4。所有 SwiftPM 调用均传入 `--disable-keychain`。

- 修复后的 5 项独立修饰键专项测试通过，包括八个左右修饰键、Fn、旧配置、权限拒绝、失败释放、下一次调用和日志用例。
- 默认完整套件运行 1139 项，出现 5 条 issue：1 条为 `ShortcutCaptureMonitorTests.resolvesCommaOnMainAfterReturningFromTheTapThread` 期望英文逗号而实际得到中文逗号；另 4 条为焦点回调超时。逗号失败已在上述精确主线的干净隔离 checkout 独立复现，前后工作区均干净；未修改输入法或系统偏好，也未进一步隔离具体输入法原因。
- `swift test --disable-keychain --filter ComposerFocusRequestTests` 定向运行 8 项通过。
- `swift test --disable-keychain --no-parallel --skip ShortcutCaptureMonitorTests.resolvesCommaOnMainAfterReturningFromTheTapThread`：1138 项、81 个套件通过。只排除已独立复现的基线失败；未修改或放宽既有测试，未跳过焦点测试。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：48 项自检通过。
- `swift build --disable-keychain -c release --triple arm64-apple-macosx14.0`：通过。
- `RELEASE_VARIANT=intel swift build --disable-keychain -c release --triple x86_64-apple-macosx13.0`：交叉编译通过，不代表 Intel 真机运行。
- 仓库边界、治理、本地化文案检查、改动中的 Markdown 相对链接及 `git diff --check` 通过。

GitHub CI 尚未运行，以上本地结果不替代 required checks。逗号基线失败与默认完整套件的焦点超时必须在 PR 中保留说明。

## 真实环境待验收

按 [快捷键测试手册的独立修饰键用例](../Testing/KeyboardShortcutPicker.md#用例-3单独左右修饰键) 验证：

1. 在目标语音工具的可见设置中选择右 Option，先用实体键盘建立正常响应对照。
2. 使用候选构建，把遥控器普通按键配置为独立右 Option，确认触发一次听写切换；再次触发能正常结束。
3. 对左右 Command、Option、Control、Shift 以及 Fn 分别验证左右语义、连续触发和无粘键；使用目标工具实际支持的触发方式。
4. 用旧配置重启、导出再导入，确认无需重新录入。撤销辅助功能权限时不应发送按键；重新授权并重启后恢复。
5. 回归普通组合快捷键和语音键。检查请求与唯一终态可关联；事件提交不替代屏幕上的最终响应证据。

本次未提供签名、公证的安装测试包，未访问第三方 App 私有配置，未完成真实遥控器、WindowServer、Blurt、Intel 真机或私有组件集成验收。必要现场验证完成前，保持候选与 Draft 状态。
