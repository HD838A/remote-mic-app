# WorkBuddy 回眸连接器测试手册

适用于装有完整无线麦 SayAll 的 Mac。连接器要求 WorkBuddy 4.24.0 或更新版本，并使用 `/Applications/SayAll.app/Contents/Helpers/SayAllMCP`。这是连接器候选，平台导入和真实客户端验收待完成。

## 准备连接器和授权

1. 将 `packaging/workbuddy/sayall-history/` 内的文件打包成 ZIP。ZIP 根目录应直接包含 `connector-meta.json`、`mcp.json`、`token-schema.json`、`icon.svg` 和 `skills/`。用 WorkBuddy 官方连接器测试或审核入口加载候选包。
2. 在无线麦 SayAll 的“回眸”中用两款 App 生成无隐私的测试记录。开启“本地 Agent 访问”，以 WorkBuddy 为名称创建专用只读授权。
3. 在新授权下展开“WorkBuddy 连接器”。点击“复制客户端 ID”，粘贴到连接器表单的“客户端 ID”字段。然后点击“复制访问令牌”，粘贴到“访问令牌”字段。每次只复制一项，完成后清空剪贴板。
4. 确认回眸页面只显示复制操作。复制后的剪贴板每次只含对应的字段值。连接时确认 WorkBuddy 接受两项必填字段，并将访问令牌显示为密码输入。启用连接器后，确认能初始化并发现 `list_transcript_apps` 和 `query_transcripts`。

如平台拒绝 ZIP、缺少任一字段、令牌未遮蔽、Helper 无法启动或工具列表不全，判定失败。平台需要按 [WorkBuddy 连接器规范](https://open.workbuddy.cn/docs/connector) 解析表单并注入凭据。

## 验证读取和撤销

| 操作 | 通过标准 |
| --- | --- |
| 调用 `list_transcript_apps` | 返回测试 App 和数量，不返回正文 |
| 用一个 App 的 Bundle ID 和较小的 `limit` 调用 `query_transcripts` | 只返回所选 App 的测试记录。继续分页时无重复或遗漏 |
| 退出并重新打开 WorkBuddy，重复读取 | 原授权继续有效，返回范围一致 |
| 在回眸撤销 WorkBuddy 授权，再读取 | 返回 `authorization_unavailable`，其他客户端的授权可继续使用 |
| 重新授权后关闭“本地 Agent 访问”，再读取 | 返回 `access_disabled`。回眸页面仍能查看已保存的测试记录 |
| 开启总开关，用错误凭据启动 | 返回 `invalid_credentials`，无回眸正文 |

若返回超出指定范围的文字、撤销后仍可读取，或重启后丢失有效授权，判定失败。使用一个现有快速连接客户端重复工具发现和最小范围查询，验证其基线。

## 验证边界

自动化使用隔离的授权存储，验证表单字段与本地 Helper 的配置相符，以及对应授权的启用和撤销。平台 ZIP 解析、真实凭据注入、WorkBuddy 重启和工具调用须用 WorkBuddy 实测。失败记录只收集客户端与连接器版本、失败阶段、工具名、结果及原因码。禁止分享正文、凭据、完整响应或本机路径。
