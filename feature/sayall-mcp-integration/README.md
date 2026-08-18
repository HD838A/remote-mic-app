# 本地 Agent 访问集成

## 为什么开发

无线麦SayAll.app 已能在用户主动开启后把语音转文字历史保存到本机，但其他 Agent 缺少一个无需安装编程工具、可授权、可撤销的读取入口。本功能把唯一正式 MCP 运行时放进 Mac App，并由独立公开仓库 `GetSayAll/sayall-mcp` 提供接口契约和集成资料。

## 用户功能

- 在“回眸”页面底部开启“本地 Agent 访问”；首次安装和缺少设置文件时保持关闭。
- 一键连接 Codex、Claude Code、Cursor 和 OpenCode；每个客户端使用独立只读授权，连接后可从同一页面移除。
- 其他客户端可一次性复制标准 MCP JSON 或 Codex TOML；明文令牌不写入 App 偏好、授权文件或审计日志。
- 查看已授权客户端，并在总开关关闭时仍可单独撤销。
- Agent 可以列出历史中的 App，或按时间、Bundle ID、顺序和游标分页读取记录。

## 范围与非目标

本次只提供本机 `stdio` MCP 读取能力。不会开放写入、修改、删除、恢复、AI 总结、Embedding、云同步、HTTP、TCP、Bonjour、后台常驻服务或运行时插件加载。关闭 Agent 访问不会删除授权状态或回眸历史，也不会改变语音捕获、蓝牙、音频、Fn、Nearby iOS 或网页版协议。

## 关键设计与开发过程

- App 包内的 Swift `Contents/Helpers/SayAllMCP` 是唯一正式运行时，用户不需要安装 Node.js、npm、Homebrew、Xcode 或克隆源码。
- `GetSayAll/sayall-mcp` 只保存公开接口契约、JSON Schema、配置示例、兼容政策和测试资料，不再提供另一套运行时。
- Helper 只接受 `serve` 参数，使用 stdin/stdout 处理 MCP JSON-RPC，不监听网络端口；stdout 仅输出协议消息，诊断写 stderr。
- 授权状态保存在 `Application Support/RemoteMic/MCP/v1/access.json`，包含 `schemaVersion: 1`、总开关和授权列表；目录权限 `0700`、文件权限 `0600`，拒绝符号链接和非普通文件。
- 每个客户端使用 256-bit 随机令牌，只保存 SHA-256 哈希；Helper 启动及每次工具调用都重新检查开关、令牌和撤销状态。
- Codex 只维护带 SayAll 标记的独立 TOML 区块；Cursor 和 OpenCode 只在严格 JSON 可解析时合并 `sayall_history`；Claude Code 使用官方用户级 CLI。写入前创建权限为 `0600` 的碰撞安全备份，冲突或 JSONC 不强行覆盖。
- Codex TOML 使用独立的 basic string 转义器，路径分隔符 `/` 保持原样；连接状态提示关闭并重新打开具体 AI 客户端，无需重启无线麦。
- 快速连接在生成令牌前先检查客户端入口和配置；预检失败不创建授权，安装中途失败会丢弃未成功交付的临时授权。同一快速客户端和同名手动客户端最多保留一份有效授权；页面只列出有效授权，并按失败类型显示具体客户端错误。
- 历史读取独立于写入链路，限制单日文件大小、单条文字长度、筛选数量、分页大小和游标长度；公开结果不包含 session ID、磁盘路径、`applicationKey` 或捕获诊断字段。

## 涉及文件

- `Package.swift`：提供 `SayAllMCPKit` 共享库和 `SayAllMCP` 可执行目标。
- `Sources/SayAllMCPKit/`：路径安全、版本化授权状态、审计、历史查询、配置生成和服务门禁。
- `Sources/SayAllMCP/main.swift`：唯一 `serve` 入口和 MCP stdio JSON-RPC 服务。
- `Sources/RemoteMic/TranscriptAgentAccessModel.swift`：App 内开关、授权、撤销和一次性配置状态。
- `Sources/RemoteMic/TranscriptAgentAccessSection.swift`：回眸页面内平铺的 Agent 管理界面。
- `Sources/RemoteMic/MCPClientIntegrationService.swift`：四客户端检测、快速连接、安全配置合并、备份和移除。
- `Sources/RemoteMic/TranscriptHistorySection.swift`：在最底部“全部删除”之前接入 Agent 管理区。
- `scripts/build-app.sh`、`scripts/verify-app.sh`：打包、签名并校验 Helper。
- `Tests/RemoteMicTests/SayAllMCP*Tests.swift`、`MCPClientIntegrationServiceTests.swift`：默认关闭、v1 状态、授权、撤销、查询、分页、四客户端配置和唯一入口自动化。
- `AI_SETUP.md`、`AI_SETUP.en.md`：供 AI 阅读的完整安装、授权、连接、验证和排障指南。

## 隐私与兼容边界

无线麦SayAll.app 和 Helper 不主动上传历史。被授权的 AI 客户端可能把 MCP 返回的文字发送给自己的模型服务商，用户应在创建授权前确认对应客户端的数据处理方式。同一 macOS 登录用户下的恶意非沙盒进程不属于本功能可以完全隔离的边界，因为该进程也可能尝试直接读取用户自己的 Application Support 文件。

本功能未上线，因此不兼容未发布的 Node 实现、旧目录或旧事件格式。正式 `v1` 发布后执行以下向后兼容政策：

- 保持 App 包内 Helper 路径、`serve` 参数、`SAYALL_MCP_CLIENT_ID` 和 `SAYALL_MCP_ACCESS_TOKEN` 环境变量稳定；
- 不改名或删除 `list_transcript_apps`、`query_transcripts`，不改变已发布输入字段语义，不删除或改名已发布的必需输出字段；
- 新能力可以增加可选输入字段或新工具；由于 `v1` 输出 Schema 是封闭对象，新增输出字段使用新工具名或并行 `v2`；
- 新版无线麦SayAll.app 继续读取 `RemoteMic/MCP/v1/access.json` 和 `RemoteMic/Transcripts/v1`；未来格式使用新版本目录，不覆盖 `v1`；
- 当前版本拒绝未知的未来 `access.json` Schema，避免错误解释新格式；这不影响未来新版继续读取已发布的 `v1` 数据。

配置包含当前 App 内 Helper 的绝对路径。只要 App 保持在同一路径，新版继续兼容旧 Agent 配置；用户移动或重新安装到不同路径后，需要从 App 重新复制配置。

## 验证与当前状态

当前状态：原生 Helper、默认关闭、App 内授权管理、四客户端快速连接、手动配置降级、两个只读工具和打包接线已经实现；Codex 无效 TOML 路径转义已修复，等待真实 MCP 客户端验收。

完整 `swift test` 共 263 项、27 个 Suite 全部通过；其中快速连接自动化覆盖连接前预检、健康客户端单次成功、失败临时授权丢弃、撤销记录隐藏、Codex 托管区块与合法 TOML 路径转义、Claude Code CLI、Cursor/OpenCode 合并、同名冲突、JSONC 拒绝、私有备份和移除。其余自动化覆盖默认关闭、v1 状态文件、未来 Schema 拒绝、令牌哈希和权限、有效授权唯一性、撤销、历史解析、时间/App 筛选、分页、内部字段排除、配置生成和 Helper 唯一入口。临时数据真实 stdio 已验证初始化、`tools/list`、两个工具、默认关闭拒绝、stdout/stderr 分离及无下一页时显式返回 `nextCursor: null`；四份公开 Schema 与 Helper 完全一致。人工测试见 [`Testing/SayAllMCPIntegration.md`](../../Testing/SayAllMCPIntegration.md)。

已知限制：手动配置令牌只在创建后的当前页面状态中提供；关闭页面或再次生成后无法恢复明文，需要撤销并创建新授权。快速连接要求目标客户端已安装且现有配置可安全解析；冲突、JSONC、损坏的 CLI 或客户端拒绝安装时，需要先修复客户端环境或使用手动配置。底层状态文件继续保留用户主动撤销的旧授权以维持审计兼容，但页面不再把它们显示为已授权客户端。真实 Codex、Claude Code、Cursor、OpenCode 是否把返回内容上传，由各客户端自身决定。
