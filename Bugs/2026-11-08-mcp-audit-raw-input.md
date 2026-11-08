# MCP 审计保存了原始请求值

用 Build 310 的真实 Helper 和隔离测试数据复现。未授权启动传入的客户端 ID，以及已授权查询传入的无效日期，在审计文件中逐字出现。两项使用独立的合成标记。初始化、正常分页、关闭访问和撤销均通过。

服务层将原始客户端 ID 和日期字符串传入审计编码器。修复后使用授权记录中的 UUID。授权失败时写入 `unknown`，查询只记录结果、原因和数量等诊断元数据。既有审计文件保留原样。

验证使用 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'SayAllMCP|MCPClientIntegrationService'`。另外用合成数据经由 stdin/stdout 复验。这些检查覆盖本机 Helper 和审计文件。
