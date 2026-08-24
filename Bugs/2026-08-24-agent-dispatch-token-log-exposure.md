# Agent 一次性授权出现在 GitHub Actions 环境摘要

## 复现

- 环境：SayAll Workshop Agent 隔离测试实例与目标仓库默认分支。
- 触发条件：Workshop 通过 `repository_dispatch` 启动 Analyze 或 Develop Workflow，Workflow 在兑换步骤失败或被重跑。
- 错误结果：步骤启动时的 GitHub Actions 环境摘要显示 `DISPATCH_TOKEN` 原始值。
- 正常边界：日志可以显示公开 API 地址和 Run ID，但 Callback Secret、GitHub App 私钥、API Key、一次性授权值和管理员口令都不得出现。

## 日志结论

- Callback Secret 由 GitHub Actions Secret 提供，日志中正确显示为 `***`。
- 一次性授权来自 `github.event.client_payload`，不属于 GitHub Secret 自动掩码范围。
- 将该值直接放进 step `env` 后，Runner 会在 shell 执行前输出环境摘要，因此 shell 内再调用 `add-mask` 已经太晚。
- 现场授权已经完成首次兑换，并在管理员暂停后绑定 `cancelled` 状态，无法再次兑换；本记录不保存或复述真实值。

## 根因

Analyze 和 Develop Workflow 把 `github.event.client_payload.dispatch_token` 直接映射为 step 级 `DISPATCH_TOKEN`。Runner 的环境摘要早于脚本内的任何防护逻辑，导致非 Secret 上下文的值被记录。

## 修复

- 不再把一次性授权写入 step `env`。
- shell 从 GitHub 提供的 `GITHUB_EVENT_PATH` 读取 `client_payload.dispatch_token`。
- 读取后立即调用 GitHub Actions `add-mask`，再执行格式校验和兑换请求。
- 保留现有一次性、短时、上下文哈希和暂停后拒绝重复兑换的服务端门禁。

## 验证

- `actionlint` 检查 Analyze/Develop Workflow。
- 使用隔离测试 Run 完成一次真实兑换，并检查步骤环境摘要不再包含 `DISPATCH_TOKEN`。
- 暂停后重跑同一 Workflow，确认重复兑换被服务端拒绝，日志不出现一次性授权原文。
- 检查 Callback Secret、API Key、GitHub App 私钥和管理员口令均未出现在日志与测试报告中。

## 验证边界

一次性授权即使泄漏也不能替代回调签名，且只能兑换一次；但它仍属于短时敏感凭据，因此必须按不落日志处理。历史测试 Run 的授权已失效，新的 Workflow 修复负责阻止后续日志暴露。
