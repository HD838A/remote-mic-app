# Onboarding 诊断与步骤事件未完整写入 runtime.log

- 时间：2026-09-12
- 影响范围：Onboarding 的实时步骤日志、“复制诊断”按钮与现场日志收集

## 复现

1. 在 Onboarding 任意步骤点击“复制诊断”。
2. 剪贴板包含完整的 `FirstUseDiagnosticSnapshot.redactedText`。
3. `runtime.log` 只有 `ONBOARDING DIAGNOSTICS copied step=... failure=...`，没有同一份诊断字段；步骤通过、阻断、重试、恢复和完成也没有统一的实时事件链。

## 根因

`FirstUseDiagnosticSnapshot.redactedText` 是多行摘要，而 `AppLogger.write(_:)` 会把换行压成空格。Onboarding 只调用了简短的 copied 审计日志，没有把摘要本身交给日志系统；`FirstUseEvent` 虽然持久化，却没有统一同步到 runtime.log。

## 修复

- `AppLogger` 增加专用多行诊断写入入口，按 `BEGIN`、逐行 `FIELD`、`END` 写入；每一行仍使用现有时间、进程、版本、Build 元数据和单行控制字符清理。
- Onboarding 复制诊断在保留 copied 事件的同时，把完整脱敏摘要同步写入 `runtime.log`。
- Onboarding 的每个 `FirstUseEvent`（进入、通过、阻断、重试、恢复、完成）在事件持久化时实时写入 `ONBOARDING STEP` 或 `ONBOARDING EVENT`。
- 不记录用户输入、音频正文、路径、设备身份、凭据或第三方 App 私有状态。

## 验证

- `swift test --disable-keychain --filter AppLoggerTests`：验证 copied 事件后完整多行摘要的顺序、字段保留和控制字符清理。
- 需在候选包上重新点击 Onboarding“复制诊断”并收集新的 `runtime.log`；历史日志无法事后补全。
