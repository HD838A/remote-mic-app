# Codex MCP 配置使用无效 TOML 转义

## 状态

代码修复与自动化验证完成，等待新测试 App 中的真实 Codex 连接验收。

## 复现条件

1. 在“回眸 → 本地 Agent 访问”开启“允许访问”。
2. 对已安装的 Codex 点击“连接”。
3. 无线麦SayAll.app 把随包 Helper 的绝对路径写入 `~/.codex/config.toml`。
4. 关闭并重新打开 Codex，创建新会话。

错误行为：Codex 在加载配置时报告 `missing escaped value`，新会话无法创建。生成的 `command` 把路径分隔符 `/` 写成 JSON 风格的 `\/`。

正常行为边界：Codex 托管区块必须是合法 TOML；绝对路径中的 `/` 保持原样，只转义 TOML basic string 明确定义的引号、反斜杠和控制字符。

## 现场证据与日志结论

- 用户截图显示 Codex 在读取 `~/.codex/config.toml` 时，于 SayAll MCP `command` 行报告缺少合法转义值。
- 修复前的定向测试实际生成 `command = "\/Applications\/..."`，稳定复现同一错误。
- 调查时现场 `config.toml` 已没有该托管区块，授权库也已没有对应客户端授权，因此没有继续改写用户现有配置。
- 用户曾把一次性访问凭据贴入聊天；调查和文档均不记录凭据内容。该授权已不在当前授权库中。

## 代码根因

`SayAllMCPIntegrationConfig.tomlString` 直接复用 `JSONEncoder`。JSON 允许把 `/` 编码为 `\/`，但 TOML basic string 不接受该转义，因此 Codex 会拒绝整个配置文件。

## 修复

- 改用专用 TOML basic string 编码：`/` 保持不变，合法处理引号、反斜杠、退格、制表、换行、换页、回车和其他控制字符。
- Codex 连接状态显示具体客户端名称，例如“已连接 · 请重新打开 Codex”。
- 快速连接说明明确只需关闭并重新打开对应 AI 工具，无需重启无线麦。

## 验证

- 修复前：`swift test --filter SayAllMCPIntegrationConfigTests` 失败，确认存在 `\/`。
- 修复后：同一定向测试通过，绝对路径保持 `/`，引号、反斜杠和换行使用合法 TOML 转义。
- `swift test --filter LocalizationTests` 通过，中英文格式占位符一致。
- `swift test --filter SettingsPageRegressionTests` 通过，连接状态继续使用客户端显示名称。
- 完整 `swift test` 共 263 项、27 个 Suite 全部通过。
- Apple Silicon 测试 App 已重新构建；`scripts/verify-app.sh 'dist/Remote Mic.app'`、arm64 架构和 ad-hoc 深度签名校验通过，随包 Helper 存在且可执行。
- 自动化没有再次写入真实 Codex 配置；仍需使用新测试 App 对真实 Codex 执行连接、重新打开客户端、创建会话和 MCP 查询验收。
