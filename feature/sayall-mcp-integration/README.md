# 本地 Agent 访问集成

## 为什么开发

无线麦SayAll.app 已能在用户主动开启后把语音转文字历史保存到本机，但其他 Agent 原本需要单独下载、构建和配置 `GetSayAll/sayall-mcp`。本功能把同一套只读 MCP、授权和审计能力直接集成进 Mac App，并保持默认关闭。

## 用户功能

- 在“回眸”页面底部开启“本地 Agent 访问”；首次安装和缺少设置事件时保持关闭。
- 为 Codex、Claude Desktop、Cursor 或其他 MCP 客户端创建独立只读授权。
- 一次性复制标准 MCP JSON 或 Codex TOML；明文令牌不写入 App 偏好、授权日志或审计日志。
- 查看已授权客户端，并在总开关关闭时仍可单独撤销。
- Agent 可以列出历史中的 App，或按时间、Bundle ID、顺序和游标分页读取记录。

## 范围与非目标

本次只提供本机 `stdio` MCP 读取能力。不会开放写入、修改、删除、恢复、AI 总结、Embedding、云同步、HTTP、TCP、Bonjour 或后台常驻服务。关闭 Agent 访问不会删除授权事件或回眸历史，也不会改变语音捕获、蓝牙、音频、Fn、Nearby iOS 或网页版协议。

## 关键设计与开发过程

- 将上游 TypeScript/Node.js 行为原生实现为 Swift `SayAllMCP` Helper，随 App 放入 `Contents/Helpers`，用户不需要安装 Node.js。
- 保持与 `GetSayAll/sayall-mcp` revision `eaac711` 的目录、NDJSON 事件、环境变量、工具名、查询字段、MCP 协议协商和令牌哈希格式兼容。
- 总开关、授权、撤销和审计继续使用追加事件；目录权限 `0700`、文件权限 `0600`，拒绝符号链接和非普通文件。
- 每个客户端使用 256-bit 随机令牌，只保存 SHA-256 哈希；Helper 启动及每次工具调用都重新检查开关、令牌和撤销状态。
- Helper 只使用 stdin/stdout 处理 MCP JSON-RPC，不监听网络端口；stdout 仅输出协议消息，诊断写 stderr。
- 历史读取独立于写入链路，限制单日文件大小、单条文字长度、筛选数量、分页大小和游标长度；公开结果不包含 session ID、磁盘路径、`applicationKey` 或捕获诊断字段。

## 涉及文件

- `Package.swift`：增加 `SayAllMCPKit` 共享库和 `SayAllMCP` 可执行目标。
- `Sources/SayAllMCPKit/`：路径安全、授权、审计、历史查询、配置生成和服务门禁。
- `Sources/SayAllMCP/main.swift`：CLI 兼容命令和 MCP stdio JSON-RPC 服务。
- `Sources/RemoteMic/TranscriptAgentAccessModel.swift`：App 内开关、授权、撤销和一次性配置状态。
- `Sources/RemoteMic/TranscriptAgentAccessSection.swift`：回眸页面内平铺的 Agent 管理界面。
- `Sources/RemoteMic/TranscriptHistorySection.swift`：在最底部“全部删除”之前接入 Agent 管理区。
- `scripts/build-app.sh`、`scripts/verify-app.sh`：打包、签名并校验 Helper。
- `Tests/RemoteMicTests/SayAllMCP*Tests.swift`：默认关闭、事件兼容、授权、撤销、查询、分页和配置自动化。

## 隐私与兼容边界

无线麦SayAll.app 和 Helper 不主动上传历史。被授权的 AI 客户端可能把 MCP 返回的文字发送给自己的模型服务商，用户应在创建授权前确认对应客户端的数据处理方式。同一 macOS 登录用户下的恶意非沙盒进程不属于本功能可以完全隔离的边界，因为该进程也可能尝试直接读取用户自己的 Application Support 文件。

既有 `GetSayAll/sayall-mcp` 授权事件可被 App 读取；App 新建的授权也使用相同格式。配置包含当前 App 内 Helper 的绝对路径，移动或重新安装到不同路径后需要重新复制配置，但不必重新创建未撤销授权。

## 验证与当前状态

当前状态：原生 Helper、默认关闭、App 内授权管理、两个只读工具和打包接线已经实现；完整自动化、临时数据 stdio 协议闭环、Apple Silicon Release App 结构校验和生产最小窗口界面检查已通过，等待真实 MCP 客户端验收。

自动化结果：`swift test` 共 246 项、26 个 Suite 全部通过，其中 MCP 专项 10 项、4 个 Suite；临时 `CFFIXED_USER_HOME` 环境已验证默认关闭、创建授权、MCP `2025-11-25` 初始化、`tools/list`、空历史查询和关闭后旧凭据立即拒绝。Apple Silicon Release 构建完成，并通过随包 Helper 存在、可执行、arm64、macOS 14 最低版本和 ad-hoc 签名校验。实际“回眸”页面确认历史保持主内容，Agent 区位于历史之后、“全部删除”之前且默认关闭。人工测试见 [`Testing/SayAllMCPIntegration.md`](../../Testing/SayAllMCPIntegration.md)。

已知限制：配置令牌只在创建后的当前页面状态中提供；关闭页面或再次生成后无法恢复明文，需要撤销并创建新授权。真实 Codex、Claude Desktop、Cursor 等客户端是否把返回内容上传，由各客户端自身决定。
