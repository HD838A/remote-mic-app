# MCP 撤销等待客户端清理

快速连接撤销先调用客户端配置清理，然后才写本机撤销状态。Claude Code 的命令可能等待 15 秒。注入客户端命令后，在清理开始时检查隔离授权存储，原实现的 `revokedAt` 仍为空。原有测试仅检查清理失败后的最终状态。

先持久化撤销，再调用客户端清理。清理失败仍显示现有错误。日志用一次性操作 ID 关联请求、本机撤销和结果。

用 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'SayAllMCP|MCPClientIntegrationService'` 验证。客户端命令使用注入实现，覆盖清理开始前已撤销、清理失败后仍保持撤销和现有快速连接回归。
