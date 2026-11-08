---
name: sayall-history
display_name: SayAll 回眸
display_name_en: SayAll Reflections
description: 只读查询无线麦 SayAll 在当前 Mac 上保存的回眸文字；适用于按时间或应用检索、整理和总结用户明确保存的语音输入记录。
description_zh: 只读查询无线麦 SayAll 在当前 Mac 上保存的回眸文字。
description_en: Read transcript history explicitly saved by SayAll on the current Mac.
version: 0.1.0
author: SayAll
---

# SayAll 回眸

仅在用户明确要求读取其无线麦 SayAll“回眸”记录时使用本连接器。连接器只有只读能力，不得声称可以写入、修改或删除记录。

## 工具选择

1. 使用 `list_transcript_apps` 获取回眸中存在的应用、记录数量和时间边界。该工具不返回正文。
2. 使用 `query_transcripts` 按时间、Bundle ID、顺序和分页游标读取记录。
3. 用户没有要求全量历史时，先选择最小时间范围和最小记录数量。需要继续读取时再使用 `nextCursor` 分页。

## 调用规则

- 涉及特定应用时，先用 `list_transcript_apps` 确认真实 Bundle ID，不根据应用名称猜测。
- `limit` 从满足当前任务的小值开始，单次不得超过工具 Schema 上限。
- 不要把返回的正文、Client ID 或访问令牌写入文件、日志、示例或其他服务。
- 不要向用户索要聊天中的明文凭据。授权必须由用户在无线麦 SayAll 中创建，并只填入 WorkBuddy 的本地连接器凭据表单。
- 第三方模型可能处理工具返回的文字；在用户要求读取敏感或大范围历史时，先提醒其确认 WorkBuddy 的数据处理政策。

## 错误恢复

- `access_disabled`：请用户在无线麦 SayAll“回眸”页面主动开启“本地 Agent 访问”。
- `authorization_unavailable`：授权已撤销或不存在，请用户创建新的 WorkBuddy 专用授权。
- `invalid_credentials`：Client ID 或 Access Token 不匹配，请用户撤销旧授权并重新创建，不要回显凭据。
- Helper 不存在：请用户把完整的无线麦 SayAll 安装到 `/Applications/SayAll.app`，不要从源码、Node.js 包或其他 App 的内部目录替代。
