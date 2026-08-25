# SayAll Workshop Agent 自动化测试手册

适用分支：`codex/sayall-agent-automation` 及其后通过 PR 合入 `main` 的版本。

本手册验证仓库侧的受控闭环，不把测试自动批准当作生产权限。测试前必须使用独立的 Workshop 测试配置和专用模型 API 凭据；生产 Worker 保持 `AGENT_ENVIRONMENT=production`、`AGENT_TEST_AUTO_APPROVE=false`。

## 测试前准备

1. 确认目标仓库的三个 Agent Workflow 已存在于默认分支：只读初检、批准后开发和 CI 结果回写。
2. 确认 Workshop Worker 的测试配置同时满足：
   - `AGENT_ENABLED=true`
   - `AGENT_ENVIRONMENT=test`
   - `AGENT_TEST_AUTO_APPROVE=true`
   - `AGENT_TEST_REPOSITORY=HD838A/remote-mic-app`
   - `AGENT_TEST_BASE_REF=main`
3. 确认 GitHub Actions Secret/Variable 只属于测试目标：`OPENAI_API_KEY`、`WORKSHOP_AGENT_CALLBACK_SECRET`、Agent Bot App ID/私钥、Workshop API 地址、触发 Bot login、Agent Bot login、Codex 模型和可选的兼容 Responses API Endpoint。
4. 确认 Agent Bot 只有目标仓库的 `Contents` 与 `Pull requests` 写权限，没有默认分支 bypass；测试 PR 必须保持 Draft。
5. 记录测试开始前的 Workshop Run、D1 迁移版本和目标分支 SHA。不要把 Secret、完整 Issue 私有内容或个人 Token 写进日志。

### 模型 API 配置

默认使用 OpenAI 官方 Responses API 时不设置 `SAYALL_CODEX_RESPONSES_API_ENDPOINT`，仅配置专用 `OPENAI_API_KEY`。测试阶段也可使用实现兼容 Responses API 的服务：

- Secret `OPENAI_API_KEY` 保存兼容服务的专用 Key，不能写入 Workflow、Issue、Artifact 或日志。
- Variable `SAYALL_CODEX_RESPONSES_API_ENDPOINT` 必须是完整的 Responses 地址，包含 `/v1/responses`，不能只填 `/v1`。
- Variable `SAYALL_CODEX_MODEL` 设置为服务实际列出的模型 ID；本轮测试使用 `gpt-5.6-sol`。
- Analyze 使用 `effort: medium` 且任务上限为 20 分钟，Develop 使用 `effort: medium` 并沿用现有 Job 上限。这样可以避免兼容服务长时间无回包时 Run 永久停在 `analyzing`。将来切回 OpenAI 官方 Key 时，只需替换 Secret、清空兼容 Endpoint，并把模型 Variable 改为官方账号可用的模型；Workflow 权限和审批流程不变。
- Analyze Workflow 会把 Issues、PR、Release 和评论快照压缩为查重所需字段后再交给 Codex，避免原始 GitHub JSON 过大导致兼容服务多轮工具调用长时间无回包。

## 用例一：已有 Bug 的只读初检与安全分支

推荐使用已有 Issue #106（退格键默认配置下失灵）作为初检输入；先确认该 Issue 仍开放且没有新的修复 PR。

1. 在 Workshop 管理员页面为 Issue #106 启动 Agent 初检。
2. 预期：目标仓库收到 `repository_dispatch`，Analyze Workflow 在固定基础提交上运行，D1 Run 先后出现 `queued`、`analyzing` 和结构化初检结果。
3. 预期：初检结果包含代码/Issue/测试证据、受影响路径、风险和测试计划；测试配置通过时追加 `system:test-auto` 批准事件，不能只因为 Issue 标签或正文而批准。
4. 预期：如果计划命中私有依赖、发布、认证、Workflow 或 Secret 路径，策略必须拒绝自动批准并进入 `needs_human`；不得创建开发 PR。
5. 如果使用 Issue #171 作为负向样例（已修复但未发布），预期分类为 `fixed_unreleased`，只回写证据和等待发布状态，不启动开发。

失败判定：没有固定 `base_sha`、没有可复核证据、重复事件创建多个 Run、未批准就启动可写 Codex、或测试自动批准在生产配置生效。

## 用例二：从 Workshop 新建需求或 Bug 的完整闭环

使用一条低风险、文档型需求，避免触碰发布和私有依赖。例如：

```text
标题：[Agent E2E] 补充受控开发流程说明
描述：在 Testing/AgentAutomation.md 中补充一段公开的 Agent 测试说明。
验收：只修改 Testing/AgentAutomation.md；不得修改 Sources、Tests、.github、.sayall、脚本、版本或签名文件。
```

1. 通过 Workshop 新建事项，确认 Worker 只创建一个 GitHub Issue，并在 Issue 正文写入提交昵称和北京时间日期。
2. 预期：Issue 进入只读 Analyze Workflow；新反馈在分析通过前不直接物化成 `TODO.md` 完成项。
3. 预期：测试环境只追加正式的 `system:test-auto` 审批事件，开发授权绑定 Run、Issue 哈希、计划哈希、基础分支和有效期。
4. 预期：Develop Workflow 使用临时工作区生成 Patch Artifact；Patch 只能包含允许路径，不能包含删除、符号链接、二进制凭据或 Workflow 修改。
5. 预期：独立发布 Job 使用 Agent Bot 创建 `codex/sayall-agent-...` 分支和 Draft PR；Codex Job 没有 GitHub 写 Token、Agent Bot 私钥或生产 Secret。
6. 预期：PR 的受保护检查完成后，Checks Report Workflow 将 `testing` 更新为 `ready_to_merge`（失败则写入 `failed`）；测试阶段不自动合并、不触发正式部署。
7. 刷新 Workshop，确认 Run、Issue、Workflow、Commit、Draft PR 和 D1 事件可以互相追溯。

失败判定：创建重复 Issue/PR、Patch 超出批准路径、Agent 直接推送 `main`、公开日志出现 Token、CI 结果回写到错误 Run、或刷新后状态丢失。

## 用例三：审批与并发保护

1. 在生产模式下提交低风险事项，确认初检完成后状态停在 `awaiting_admin_approval`。
2. 不点击批准，确认没有 Develop Workflow、Patch、分支或 PR。
3. 修改 Issue 正文或让基础分支前进，再提交旧版本批准参数；预期返回冲突并要求重新初检。
4. 双击批准或重复发送同一回调；预期只有一个批准事件和一个开发授权，重复事件保持幂等。
5. 让授权过期后再兑换；预期兑换失败，不能进入 `developing`。
6. 暂停已经兑换授权的 Analyze/Develop Run，再重跑原 Workflow；预期重复兑换被拒绝，D1 仍保持 `cancelled`。
7. 检查兑换步骤的环境摘要和失败日志；不得出现 `DISPATCH_TOKEN` 或一次性授权原文，Callback Secret 和 API Key 必须继续显示为掩码或完全不出现。

## 稳定回归项

- `swift test`、仓库自检和现有 macOS CI 必需检查仍按项目既有手册执行。
- Agent PR 必须保持 Draft，默认分支规则、签名/公证和发布 Environment 不得被改变。
- 私有依赖 CI 的人工安全门禁不能被 Agent 标签、Issue 评论或客户端字段绕过。
- 测试完成后关闭测试自动批准，撤销测试授权并关闭/归档测试 Issue；保留 Run、Workflow、Commit 和 PR 作为可审计证据。

## 日志与验证边界

自动化可以证明：状态机、HMAC、一次性授权、Patch 策略、Bot 分支/PR 和回调幂等。它不能单独证明真实遥控器、音频、Apple 签名、公证、私有依赖安全审查或最终用户体验。任何真实设备、受保护 Environment 或发布验证都必须另行记录，不得把模拟 Runner 结果写成真机验收。
