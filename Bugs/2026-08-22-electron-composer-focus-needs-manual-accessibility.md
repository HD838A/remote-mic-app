# Electron 应用聚焦失败：未声明辅助技术客户端导致 web 内容树为空

- 时间：2026-08-22
- 状态：Electron 目标已真机验收通过；非 Chromium 壳的降级修复等待真机复验
- 影响范围：macOS 1.9.8（含本地自构建版）；预置动作 `openClaude` / `openCodex` 的 `accessibilityComposer` 聚焦路径；自定义 APP 的 `recordedAccessibility` 聚焦路径同类风险
- 功能点：打开 App 后聚焦输入框
- 简单描述：权限齐全时，按键打开 Claude Desktop 或 Codex 后，输入框聚焦稳定失败并记录 `APP FOCUS failed method=accessibility reason=composer_not_found`。
- 原始记录：真机复现与判定实验由用户在 2026-08-22T14:33–14:34 完成，日志已确认。

## 复现状态

已在真机稳定复现：

1. 安装本仓库自构建的 1.9.8 版本，确认日志中 `input=true accessibility=true`。
2. 将 TV 键映射为「打开 Claude」或「打开 Codex」。
3. 按下 TV 键。

错误结果：应用被正常打开并置于前台，但聚焦阶段稳定输出
`APP FOCUS failed bundle=com.anthropic.claudefordesktop method=accessibility reason=composer_not_found`，
Codex 同样失败。

正常边界：同一版本对非 Electron 目标的聚焦与其余按键动作均正常；权限检查通过，没有 `reason=not_trusted`。

## 判定实验（关键证据）

开启 VoiceOver（Cmd+F5）后重按 TV 键：

- 14:33 旁白刚启动、辅助功能树尚未建好时，仍然失败；
- 14:34 数秒后重按，日志变为 `APP FOCUS succeeded bundle=com.anthropic.claudefordesktop` 与
  `APP FOCUS succeeded bundle=com.openai.codex`。

该实验把根因从「扫描算法找不到输入框」区分为「树本身不存在」，并同时说明树的建立需要时间。

## Root Cause

Chromium / Electron 默认不为 web 内容构建辅助功能树，只有当辅助技术客户端主动声明自己时才会构建。VoiceOver 通过设置应用元素的增强属性触发构建；无线麦从未声明，因此 `focusComposer` 扫描到的只是没有 web 内容的空壳，重试多少次都不可能找到 composer。原有 8 × 200ms 的重试窗口也短于真机上约 1~2 秒的建树时间。

## 真机验收与第二个根因（2026-08-22 复验）

使用含首轮修复的新构建，权限齐全、VoiceOver 关闭、两个应用冷重启后：

- Claude Desktop：`APP FOCUS manual_accessibility ... result=success` → `APP FOCUS succeeded`，**通过**。首轮修复对 Electron 完全生效。
- ChatGPT（`/Applications/ChatGPT.app`，Bundle ID `com.openai.codex`）：每次都是
  `APP FOCUS manual_accessibility bundle=com.openai.codex attempt=0 result=attribute_unsupported`，聚焦仍然失败。

但该应用在最初的 VoiceOver 判定实验中是可以成功的（14:34 出现 `APP FOCUS succeeded bundle=com.openai.codex`）。

第二个根因：这个应用的 web 内容树同样是懒加载，但它不是 Electron，因此不认 Chromium / Electron 私有的 `AXManualAccessibility` 约定；VoiceOver 能唤醒它，说明它响应的是标准的 `AXEnhancedUserInterface`（WKWebView 等外壳都认这个属性）。

## 修复

- 在 `scheduleAccessibilityComposerFocus` 与自定义 APP 的 `recordedAccessibility` 路径中，每轮尝试开始处对目标进程的 `AXUIElement` 设置 `AXManualAccessibility = true`（Electron 约定属性，幂等）。非 Electron 应用返回 `attributeUnsupported`，静默忽略，不改变原有流程。
- 降级链：`AXManualAccessibility` 返回 `attributeUnsupported` 时，对同一个 app element 改设 `AXEnhancedUserInterface = true`。该属性的窗口变形与动画副作用主要报告在 Electron 上，而走到降级路径的恰恰是非 Chromium 外壳；Electron 应用在第一步就成功，不会进入第二步。顺序与取舍写在代码注释中。
- composer 重试窗口从 8 × 200ms（1.4 秒）放宽到 12 × 250ms（2.75 秒），覆盖真机观察到的 1~2 秒建树耗时；自定义 APP 路径的时序保持不变，避免影响已验收行为。
- 新增日志 `APP FOCUS manual_accessibility bundle=<id> attempt=<n> result=<name>`，只在首次尝试和第一次建树成功时记录；走降级链时 `result` 为 `fallback_enhanced_success` 或 `fallback_enhanced_<error>`，可直接区分是哪个属性回答的。失败原因保持 `composer_not_found` 不变。

## 验证边界

- 已完成：`xcrun swift build` 通过；`scripts/test.sh` 自检 43 项通过；`scripts/build-app.sh` 产出 ad-hoc 签名 App 并通过 `codesign --verify --deep --strict`。
- 已完成（仅编译期）：新增的纯函数单测（结果名映射、日志节流、重试窗口 ≥ 2 秒）已通过类型检查；本机只有 Command Line Tools，缺少 `Testing` 模块，Swift Testing 套件必须在装有 Xcode 的机器或 CI 上执行。
- 已完成（真机）：Claude Desktop 冷重启后按键聚焦成功，日志 `result=success` → `APP FOCUS succeeded`。
- 待完成（真机）：ChatGPT（`com.openai.codex`）在降级链修复后复验，期望日志变为 `result=fallback_enhanced_success` 且随后 `APP FOCUS succeeded`；同时确认该应用与其他非 Chromium 应用没有出现窗口变形、缩放或异常动画，Electron 应用仍在第一步成功、不进入降级路径。
- 自动化不能证明 Electron 真实建树时间、`AXManualAccessibility` 在各 Electron 版本上的行为，以及最终输入框是否真正获得焦点。
