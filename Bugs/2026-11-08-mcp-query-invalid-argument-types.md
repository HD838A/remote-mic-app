# MCP 查询忽略类型错误的筛选项

用 Build 310 的 Helper 和两款 App 的四条合成记录复现。日期传数字、排序传布尔值、游标传数组时，查询仍返回全部四条记录。有效筛选和分页原本可以工作。测试未使用真实回眸。

JSON-RPC 已收到参数。解析器用可选类型转换处理这些字段，将类型错误和缺省合并为同一状态。修复后逐项拒绝非字符串，并拒绝非对象的工具参数。有效字符串、缺省项及已发布查询字段沿用原语义。

用 `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain --product SayAllMCP` 构建。通过 stdin/stdout 验证每个错误类型、默认查询、过滤分页、关停和撤销。
