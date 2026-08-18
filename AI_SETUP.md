# 无线麦SayAll.app：AI 安装与 MCP 配置指南

这份文档提供给 Codex、Claude Code、Cursor、OpenCode 等 AI Agent 阅读。目标是在不安装 Node.js、npm、Homebrew、Xcode或其他开发依赖的情况下，帮助用户配置无线麦SayAll.app，并在用户明确授权后连接本机只读语音历史 MCP。

## 必须遵守的权限边界

- “本地 Agent 访问”默认关闭。AI 不得替用户静默开启，也不得绕过无线麦SayAll.app 中的确认。
- 只在用户明确要求连接某个 AI 客户端后配置该客户端。
- 不要要求用户把访问令牌粘贴到聊天、Issue、日志或公开文件中，也不要回显或上传令牌。
- MCP 只读“回眸”历史，不能写入、修改或删除记录。
- 无线麦SayAll.app 和随包 Helper 不上传历史；连接后的 AI 客户端可能将读取的文字发送给自己的模型服务商，配置前应提醒用户确认该服务商的数据政策。

## 1. 检查完整 App

默认安装位置：

```text
/Applications/SayAll.app
```

随包 Swift MCP Helper：

```text
/Applications/SayAll.app/Contents/Helpers/SayAllMCP
```

确认 App 与 Helper 均存在，而且 Helper 可执行。缺少 Helper 时，应让用户重新安装完整无线麦SayAll.app，不要尝试用 Node.js 或源码替代。

## 2. 让用户开启本地历史与访问权限

请让用户在无线麦SayAll.app 中完成以下操作：

1. 打开侧边栏“回眸”。
2. 如需记录新的语音转文字历史，开启页头的“记录回眸”。
3. 在页面下方找到“本地 Agent 访问”，主动开启“允许访问”。
4. 在“连接 AI 工具”中点击目标客户端的“连接”。
5. 连接成功后关闭并重新打开目标客户端；无需重启无线麦SayAll.app。

App 内快速连接支持 Codex、Claude Code、Cursor 和 OpenCode。它会为每个客户端创建独立只读授权，并在改写已有配置前创建私有备份。遇到同名 MCP、无效 JSON 或带注释的 JSONC 时不会强行覆盖。

快速连接会先检查客户端入口和配置，再生成授权。预检或安装失败不会在“已授权客户端”中留下重复记录；同一客户端只能有一份有效快速连接，并会在页面内显示具体失败原因。

## 3. 优先验证快速连接

重新打开客户端后，检查是否出现名为 `sayall_history` 的 MCP Server，并依次验证：

1. MCP `initialize` 成功。
2. `tools/list` 中存在 `list_transcript_apps` 和 `query_transcripts`。
3. 调用 `list_transcript_apps`，确认只返回应用摘要，不返回语音正文。
4. 使用小的 `limit` 调用 `query_transcripts`，确认能读取用户允许访问的本地测试记录。

如果总开关关闭或授权已撤销，读取失败是预期行为。不要尝试绕过。

## 4. 自动连接失败时的手动配置

让用户在“其他客户端或手动配置”中输入客户端名称，点击“创建只读授权”，然后直接把生成的配置粘贴到目标客户端的本机配置文件。令牌只显示一次。

### Codex

配置文件：

```text
~/.codex/config.toml
```

从无线麦SayAll.app 点击“复制 Codex TOML”，粘贴为独立配置段：

```toml
[mcp_servers.sayall_history]
command = "/Applications/SayAll.app/Contents/Helpers/SayAllMCP"
args = ["serve"]
env = { SAYALL_MCP_CLIENT_ID = "<由 App 生成>", SAYALL_MCP_ACCESS_TOKEN = "<由 App 生成>" }
```

### Claude Code

从无线麦SayAll.app 点击“复制标准 MCP JSON”，取出 `sayall_history` 对象后使用 Claude Code 官方用户级命令：

```text
claude mcp add-json --scope user sayall_history '<stdio server JSON>'
```

不要在终端历史、聊天或脚本中长期保存包含真实令牌的命令。完成后重启 Claude Code，并用 `claude mcp get sayall_history` 检查注册结果。

### Cursor

全局配置文件：

```text
~/.cursor/mcp.json
```

把 App 生成的标准 MCP JSON 中 `mcpServers.sayall_history` 合并进现有 `mcpServers`。必须保留其他 Server。文件若包含注释、JSONC 或无法解析，不要整体重写；改由用户在 Cursor 设置中手动添加。

### OpenCode

全局配置文件：

```text
~/.config/opencode/opencode.json
```

OpenCode 本地 Server 的格式为：

```json
{
  "mcp": {
    "sayall_history": {
      "type": "local",
      "command": [
        "/Applications/SayAll.app/Contents/Helpers/SayAllMCP",
        "serve"
      ],
      "environment": {
        "SAYALL_MCP_CLIENT_ID": "<由 App 生成>",
        "SAYALL_MCP_ACCESS_TOKEN": "<由 App 生成>"
      },
      "enabled": true
    }
  }
}
```

必须合并并保留现有 `mcp` 条目。配置为 JSONC 或无法严格解析时，不要自动重写。

## 5. 故障排查

- 未看到快速连接按钮：确认安装的是包含本功能的新版本完整 App。
- 客户端显示“未检测到安装”：先安装目标客户端，再重新打开“回眸”。
- 提示同名 MCP：检查目标配置中的 `sayall_history`，不要覆盖用户自行维护的同名 Server；可以改用手动配置或先由用户移除冲突项。
- Codex 报告 `missing escaped value`：检查是否是旧测试版生成了包含 `\/` 的 Helper 路径；撤销旧授权并使用修复后的无线麦SayAll.app 重新连接，不要继续使用已经贴入聊天或公开位置的令牌。
- Helper 不存在或不可执行：重新安装完整无线麦SayAll.app。
- 页面提示 App 位置已变化：旧配置仍指向移动前的 Helper。先在无线麦SayAll.app 中移除对应连接，再重新连接；不要手工覆盖其他 MCP Server。
- 能连接但不能读取：确认“允许访问”仍开启、对应授权未撤销，并且“回眸”中已有记录。
- App 被移动到其他目录：旧配置中的绝对 Helper 路径会失效；把 App 放回 `/Applications`，或在 App 内移除连接后重新连接。
- 更换客户端或不再使用：在“已授权客户端”或对应客户端卡中移除连接。关闭总开关会立即阻止全部客户端，但不会删除历史。

## 6. 兼容与隐私

正式 `v1` 会保持 Helper 路径、`serve` 参数、两个环境变量以及 `list_transcript_apps`、`query_transcripts` 的已发布语义向后兼容。新版可以增加可选能力，但不会要求普通用户安装编程环境。

历史与授权状态保存在当前 macOS 用户的 Application Support 中。授权文件只保存令牌和 Helper 路径的哈希，不保存明文令牌或原始 App 路径；客户端配置必须保存实际令牌和 Helper 路径才能启动本地 MCP，因此这些配置应保持用户私有权限，不能同步到公开仓库。
