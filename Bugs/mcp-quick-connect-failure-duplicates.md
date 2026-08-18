# MCP 快速连接失败记录重复

## 状态

代码修复与自动化验证完成，等待用户使用真实客户端验收。

## 复现条件

1. 在“回眸 → 本地 Agent 访问”开启“允许访问”。
2. 目标客户端被检测为已安装，但其安装入口不可用：
   - Claude Code CLI 启动即崩溃；或
   - Cursor 的 `~/.cursor/mcp.json` 不是合法 JSON。
3. 点击对应客户端的“连接”。
4. 连接在数毫秒内失败，按钮恢复为“连接”；重复点击多次。

错误行为：每次失败都先创建授权、再标记撤销；“已授权客户端”展示全部撤销记录，造成同一客户端被重复安装多次的错觉。页面只显示统一的“自动连接失败”，无法判断客户端环境问题。

正常行为边界：失败的临时授权不应进入用户可见授权列表；同一快速连接客户端最多有一个有效授权；客户端或配置预检失败时不应先创建令牌；错误提示应说明是 CLI、配置格式、同名冲突还是配置写入失败。

## 现场证据与日志结论

- 授权状态共有 17 条记录、4 条有效记录：Claude Code 9 条全部撤销，Cursor 3 条全部撤销，Codex 2 条中 1 条有效，OpenCode 1 条有效，另有 2 条手动授权有效。
- Claude Code 每次授权从创建到撤销约 5ms；本机 `/opt/homebrew/bin/claude` 在 Node.js `v26.5.0` 下执行 `--version` 或 MCP 帮助命令都会在自身 JavaScript 入口崩溃，因此不是无线麦 MCP Helper 失败。
- Cursor 每次授权从创建到撤销约 2–3ms；`~/.cursor/mcp.json` 的严格 JSON 解析失败，错误为第 43 行第 1 列存在无法匹配的 `}`。无线麦没有覆盖该文件。
- Codex 托管 TOML 区块与 OpenCode `mcp.sayall_history` 均存在，说明相同 App 和 Helper 在健康配置入口下能够成功安装。

## 代码根因

- `TranscriptAgentAccessModel.connect` 在客户端配置预检之前调用 `createAuthorization`，安装失败后只调用 `revokeAuthorization`。
- `SayAllMCPAuthorizationStore` 追加每次授权，但没有用于“从未成功交付的临时授权”的丢弃入口，也没有事务级的有效客户端唯一性约束。
- `TranscriptAgentAccessSection.authorizationList` 直接展示全部授权，包括已撤销的失败记录。
- `TranscriptAgentAccessError.integrationFailed` 把 CLI 崩溃、无效 JSON、同名冲突和写入失败合并为同一文案。

## 修复方案

- 在生成授权前执行客户端专属预检。
- 安装中途失败时安全丢弃本次未成功交付的临时授权。
- 在授权存储层约束同一快速集成只能有一个有效授权，并阻止重复的有效手动客户端名称。
- 授权列表只展示有效授权；历史撤销记录仍保留在版本化状态文件中，但不制造重复安装错觉。
- 按客户端和错误类型显示明确的页面内错误，不增加弹窗。

## 验证

- `swift test --filter MCPClientIntegrationServiceTests`：13 项通过，覆盖 Claude CLI 预检失败零授权、Cursor 无效 JSON 零授权、安装中途失败丢弃临时授权、健康客户端只成功一次、撤销记录不显示、四客户端配置与移除。
- `swift test --filter SayAllMCPAuthorizationStoreTests`：6 项通过，覆盖有效快速集成和同名客户端唯一性、失败临时授权丢弃及旧状态兼容。
- `swift test`：262 项、27 个 Suite 全部通过。
- Apple Silicon Release App 已重新构建；`scripts/verify-app.sh 'dist/Remote Mic.app'` 通过随包 Helper、双语资源、架构和 ad-hoc 深度签名校验。
- 自动化只使用临时目录与注入命令执行器，没有修改真实 Codex、Claude Code、Cursor 或 OpenCode 配置。
- 现场 Claude Code CLI 仍因其 Node.js `v26.5.0` 环境崩溃，真实 Claude 安装必须先修复客户端；现场 Cursor 配置仍存在第 43 行多余 `}`，真实 Cursor 安装必须先修复配置。健康入口下的成功路径已由自动化覆盖，Codex 和 OpenCode 在用户现场已有有效连接。
