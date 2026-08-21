# Onboarding 离开输入法页后重复触发输入法确认

- 时间：2026-08-21
- 状态：已修复，等待豆包/微信输入法真机验收
- 影响范围：macOS Onboarding 的豆包输入法和微信输入法路径；选择输入法后进入后续步骤、输入框重新聚焦或 App 回到前台
- 功能点：Onboarding 输入法选择与系统输入源切换
- 简单描述：用户在输入法选择页完成选择后，离开该页仍可能再次触发系统“是否启用豆包/微信输入法？”确认。

## 复现证据

现场日志 `/Users/andy/Library/Logs/RemoteMic/runtime.log` 显示，在同一轮 Onboarding 中：

- `2026-08-16T17:56:33Z` 进入 `voiceTest` 后出现一次 `ONBOARDING INPUT SOURCE tool=weixin result=selected`；
- `2026-08-16T17:57:02Z`、`17:57:09Z`、`17:57:19Z`、`17:57:36Z`、`17:57:44Z`、`17:57:48Z` 等离开 `voiceTool` 后仍反复出现 `tool=doubao result=selected`；
- `2026-08-17T17:46:48Z` 进入 `voiceTool` 后选择豆包，随后在 `voiceTest` 和输入框聚焦流程再次出现相同事件。

日志没有记录系统弹窗文本，但事件顺序与页面生命周期重复调用输入源 API 一致。当前代理环境无法稳定弹出真实第三方输入法确认框，因此系统弹窗本身仍需真机复验。

## 根因

`OnboardingView` 在以下生命周期中都调用 `switchToSelectedInputMethod()`：输入法页进入、App 回到前台、进入语音测试页、语音测试输入框获得焦点，以及用户选择输入法。离开输入法页后，后续调用仍可能执行 `TISEnableInputSource` / `TISSelectInputSource`，从而重复触发系统确认。

完成后的 Fn 按下自动准备由 `PreferredInputSourceMonitor` 独立负责，不应依赖 Onboarding 后续页面反复调用。

## 修复计划

只保留输入法选择页的主动切换入口；进入语音测试页和输入框重新聚焦时不再调用系统输入源切换 API。保留选择结果持久化以及完成后按 Fn 的运行时自动切换行为，并增加源码回归测试防止生命周期调用回归。

## 修复与验证

- `OnboardingView` 只在 `.voiceTool` 页面主动调用输入源切换；语音测试页、输入框重新聚焦和 App 回到前台不会再次调用。
- `PreferredInputSourceMonitor` 未修改，完成后的 Fn 按下自动准备仍保持原行为。
- `swift test --filter OnboardingFlowTests`：28 项通过；`swift test --filter PreferredInputSourceMonitorTests`：4 项通过。
- `swift test`：318 项、31 个 suite 通过；`SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：42/42 通过；arm64 和 x86_64 Release 构建通过。

## 验证边界

自动化可验证调用门禁和完整 Swift 构建；真实系统确认框是否不再出现、豆包/微信输入法最终文字上屏仍需在真实 macOS 环境人工验收。
