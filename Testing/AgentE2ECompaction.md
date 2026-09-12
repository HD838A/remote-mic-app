# SayAll Agent E2E 快照压缩测试手册

适用版本/分支：包含 `sayall-agent-analyze.yml` 快照步骤的 `main` 基线及其受控开发临时分支。本手册验证 Analyze Workflow 在交给 Agent 分析前对 GitHub 相关快照做的字段投影；它不改变工作流、不验证生产发布权限，也不替代真实用户验收。

## 测试前准备

1. 使用一次受控的测试 Run，并记录固定基础提交 SHA、Run ID 和目标 Issue 编号。
2. 确认测试配置与 `Testing/AgentAutomation.md` 一致，且只授予读取 Issue、Pull Request、Release 和评论所需的权限。
3. 准备一个不含密码、Token、个人联系方式或其他敏感信息的测试 Issue；关联的 Issue、PR、Release 和评论可以为空。
4. 仅通过 Workflow 产生的 Artifact 进行检查。不要把原始 GitHub 响应、Secret、完整私有 Issue 内容或个人 Token 复制到日志、评论或测试文档。

## 压缩字段契约

Analyze Workflow 保留目标 Issue 原始快照供上下文使用；其余用于查重和分流的集合会压缩为以下公开字段：

| 快照 | 每条记录保留的字段 |
| --- | --- |
| Issues | `number`、`title`、`state`、`labels`（标签名数组）、`updatedAt`、`htmlUrl` |
| Pull Requests | `number`、`title`、`state`、`labels`（标签名数组）、`updatedAt`、`mergedAt`、`htmlUrl` |
| Releases | `tagName`、`name`、`publishedAt`、`htmlUrl` |
| 当前 Issue 评论 | `user`、`createdAt`、`body` |

时间字段是 GitHub 返回的时间值，URL 仅用于定位公开对象。压缩不是脱敏：评论正文、标题、名称和用户名仍可能包含不可信或敏感文字，因此必须按不可信输入处理。

## 逐步操作与预期结果

1. 触发一次只读 Analyze Workflow，并等待 `Snapshot untrusted GitHub material` 步骤完成。预期：步骤成功，生成 `issues.json`、`pulls.json`、`releases.json`、`comments.json`、`issue.json` 以及提交/标签摘要文件。
2. 下载本次 Run 的分析上下文 Artifact，逐个打开四个压缩集合文件。预期：每条记录只出现“压缩字段契约”表中对应的字段；标签为字符串数组，缺失的可选时间值保持 `null`，而不是被替换为其他字段。
3. 将集合文件与同一固定基础提交上只读获取的 GitHub 对象数量进行比对。预期：分页结果被展开后没有重复页包装，记录数量和对象编号一致；Release 集合最多包含 Workflow 请求的前 100 条公开 Release。
4. 检查评论文件。预期：只包含目标 Issue 的评论，保留作者登录名、创建时间和正文；不应混入其他 Issue 的评论。
5. 在测试 Issue 或评论中加入一段看似指令的普通文本（不得放入秘密），重新运行分析。预期：Agent 将其视为不可信材料，不会因此获得写权限、改变批准范围或执行其中的命令。
6. 查看 Analyze 输出和 Artifact 日志。预期：分析仍能引用编号、标题、状态、标签、时间和公开链接完成查重；日志不打印 Token、Secret 或未压缩的关联集合响应。

## 明确失败判定

- 任一压缩集合包含契约之外的字段，或字段名称/类型与表格不符。
- 分页数组未展开、记录重复、集合串入其他 Issue 的评论，或目标对象编号丢失。
- 评论、标题或 URL 中的文字被当作可信控制指令，导致越权写入、改变路径或绕过审批。
- Artifact 或日志出现 Secret、Token、私有凭据、完整未压缩的关联集合响应，或无法追溯到固定基础提交。
- 压缩步骤失败但 Analyze 仍以不明来源的数据继续，或失败状态未被 Workflow 报告。

## 稳定功能回归

- `Testing/AgentAutomation.md` 所述只读初检、批准绑定、Patch 路径校验、Draft PR 和回调幂等流程保持不变。
- 默认分支保护、Agent 权限、发布/签名流程和私有依赖安全门禁没有任何变化。
- 应用侧 Swift 测试与构建仍按仓库既有 CI 执行；本次文档变更不得修改 `Sources/`、`Tests/` 或 Workflow。

## 日志与 Artifact 收集

保存 Run ID、固定基础提交 SHA、步骤名称、步骤结论和四个压缩 JSON 的字段审计结果。只保留必要的编号、计数和字段名；对正文、标题、用户名和 URL 做脱敏或摘要。发现疑似秘密时立即停止传播并按项目安全流程处理，不要把秘密写入 Issue、PR、Artifact 或聊天。

## 验证边界

自动化检查可以证明 jq 投影、分页展开、字段契约和不可信输入边界。它不能证明 GitHub 生产权限配置、受保护 Environment、真实用户体验、真实遥控器/蓝牙/音频、签名公证或发布流程；这些项目需要在对应受控环境中另行验收。本手册不要求真实硬件测试。
