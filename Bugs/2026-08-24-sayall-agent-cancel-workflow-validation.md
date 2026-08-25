# SayAll Agent 暂停未取消运行中的 Workflow

## 复现

- 环境：SayAll Workshop Agent 测试实例与 `HD838A/remote-mic-app` 默认分支。
- 触发条件：管理员批准一个 Agent Run，Develop Workflow 兑换一次性授权并进入运行中；随后在 Workshop 点击“立即暂停”。
- 错误结果：Workshop D1 已变为 `cancelled`，但 `SayAll Agent Cancel` Workflow 校验失败，目标 Develop Workflow 没有收到 GitHub Actions cancel 请求。
- 正常边界：已完成的目标 Workflow 应幂等返回成功；运行中的 Analyze/Develop Workflow 应被取消；其他事件或其他 Workflow 不得被取消。

## 日志

- 取消 Workflow 在 `Validate and cancel Agent workflow` 步骤以退出码 `1` 失败。
- GitHub Actions Run API 返回的 `.name` 是 `run-name` 生成的动态标题，而不是 Workflow 文件顶层的固定 `name`。
- 同一响应的 `.path`、`.event` 和 `.display_title` 能分别确认允许的 Workflow 文件、`repository_dispatch` 事件和 Workshop Run ID。

## 根因

取消 Workflow 使用固定字符串校验 API 响应的 `.name`。Analyze/Develop Workflow 配置了 `run-name`，实际 `.name` 会包含动态 Run ID，因此合法目标也会被拒绝。

## 修复

- 仅修改 `.github/workflows/sayall-agent-cancel.yml`。
- 将固定 `.name` 校验替换为精确允许列表：
  - `.github/workflows/sayall-agent-analyze.yml`
  - `.github/workflows/sayall-agent-develop.yml`
- 保留 `repository_dispatch`、标题内 Workshop Run ID、数字 Workflow Run ID 和目标状态校验。

## 验证

- `git diff --check` 通过。
- `actionlint .github/workflows/sayall-agent-cancel.yml` 通过。
- 使用原失败 Run 的 GitHub Actions API 响应执行新 `jq` 条件，校验从失败变为通过。
- 合入默认分支后仍需重新执行一次真实“批准 → 兑换授权 → 立即暂停”，确认目标 Workflow 的最终结论为 `cancelled`，取消 Workflow 成功，且 Workshop Run 不会被迟到回调复活。

## 验证边界

本地验证覆盖错误校验条件和 Workflow 静态检查。真实 GitHub Actions 取消需要默认分支上的修复版本和运行中的目标 Workflow，结果记录在 SayAll Workshop 的 Agent E2E 报告中。
