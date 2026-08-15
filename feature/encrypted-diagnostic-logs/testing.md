# 测试摘要

完整人工步骤见 [`Testing/EncryptedDiagnosticLogs.md`](../../Testing/EncryptedDiagnosticLogs.md)。

发布前必须同时确认：磁盘不存在日志明文、按天和容量轮转正确、只保留 5 天、未点击时没有 Sentry 请求、点击后只发送今天和昨天、服务端内容已经脱敏，以及设置页在最小窗口和浅色/深色下没有裁切。

自动化和本机构建不能替代真实 Sentry 项目、真实网络故障、跨自然日运行和最终签名 App 的人工验收。
