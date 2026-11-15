# PreferredInputSourceMonitor 取消测试依赖真实 timer，CI 偶发超时失败

- 时间：2026-11-15
- 状态：候选修复，定向 20/20、完整测试、项目自检和仓库检查通过；等待 CI
- 影响范围：`PreferredInputSourceMonitorTests.productionWaiterProcessesCancellationWhileActivationIsPending(stopMonitor:)`
- 功能点：显式语音会话等待输入源激活时的取消路径
- 简单描述：CI 上偶发记录 `activation_timeout`，期望是 `activation_cancelled`
- 原始记录：main macOS CI Run `43712090802`；PR #1037 的 CI 审计评论记录过同一竞态

## 现场证据

- 失败 Run：`43712090802`，Job `Public Swift tests and dual-architecture build`，步骤 `Run Swift tests`。
- 失败用例：`PreferredInputSourceMonitorTests.productionWaiterProcessesCancellationWhileActivationIsPending(stopMonitor: true)`。
- `PreferredInputSourceMonitorTests.swift:626` 期望日志包含 `result=activation_cancelled`。
- `PreferredInputSourceMonitorTests.swift:627` 期望日志不包含 `result=activation_timeout`。
- 实际结果：等待输入源激活超时，日志记录 `activation_timeout`。
- 测试运行：1427 tests / 104 suites failed with 2 issues。
- Apple Silicon 与 Intel Ventura lane 仅因 `PUBLIC_RESULT=failure` 连带失败，没有独立错误。

## 根因

测试用真实 timer 制造取消：

- `prepareInputSource` 把一个 0.04 秒的 `Timer` 加到 main RunLoop。
- 生产 waiter 的激活等待上限是 0.5 秒。
- CI runner 负载高时，main actor/RunLoop 没有及时执行 0.04 秒 timer。
- waiter 先到达 0.5 秒超时，`activationShouldContinue()` 仍为 true，于是记录 `activation_timeout`。

这是测试时序竞态，不是产品取消逻辑稳定失效。本地单独连续运行旧测试 5 次均通过，每次约 0.086 秒；PR #1037 的同一用例在重跑后也通过。

## 修复

- 移除真实 0.04 秒 `Timer`。
- 用 `didPrepare` 标记区分 prepare 之前和之后的当前输入源读取。
- 在 prepare 后第一次读取当前输入源时调用 `stop()` 或 `endVoiceSession()`，再返回原输入源。
- waiter 下一轮 `shouldContinue()` 返回 false，稳定进入 `activation_cancelled` 路径。
- 测试仍使用生产 waiter，不注入假 waiter；只去掉对真实 timer 调度的依赖。

## 验证

- 定向：`swift test --disable-keychain --filter 'PreferredInputSourceMonitorTests.productionWaiterProcessesCancellationWhileActivationIsPending'`，连续 20/20 通过，单次约 0.001 秒。
- 完整测试：`swift test --disable-keychain`，1456 tests / 105 suites 通过。
- 项目自检：`scripts/test.sh` 48/48 通过；`scripts/check-repository-boundaries.sh`、`scripts/verify-repository-governance.sh`、`git diff --check` 通过。
- 无产品源码改动；不改 `PreferredInputSourceMonitor` 行为。

## 验证边界

这次只消除测试对真实 timer 调度的依赖，不新增产品行为验证。测试仍覆盖生产 waiter 的取消判定和恢复路径；输入源激活的真实系统时序仍由现有真机/系统级验收负责。
