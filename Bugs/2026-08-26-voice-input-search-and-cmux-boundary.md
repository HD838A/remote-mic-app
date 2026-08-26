# 1.9.13 搜索框与 cmux 语音输入边界

- 时间：2026-08-26
- 状态：已完成最小候选修复，等待 1.9.13 真实语音场景验收
- 影响范围：用户反馈版本 1.9.13；Spotlight、Launchpad、飞书/Lark 搜索框，以及 cmux 的 tmux/CLI 终端
- 简单描述：用户反馈上述位置可以调起语音，但最终文字未输入或行为异常。
- 现场日志：本次 1.9.13 反馈未提供日志。共享目录中的日志属于 1.8.3、1.8.25、1.9.8、1.9.10 和 1.9.12，只用于对照旧的音频/Accessibility 失败路径。

## 复现与证据

当前没有反馈机器和真实第三方 App 的可控复现，因此不能声称已在反馈环境复现 1.9.13。代码边界可以稳定确认：

1. 原短按定位功能明确排除 `search/find/filter`、密码/令牌、设置，以及 `terminal/console/shell` 等语义。因此搜索框和普通终端无法被通用路径定位。
2. cmux 另有公开 CLI + Accessibility 的终端聚焦路径，但此前只接在“打开 cmux”动作；短按定位当前 App 时没有复用该路径。
3. 旧日志中存在 `enqueue_failures=0` 后 `TRANSCRIPT CAPTURE` 快照不可用的会话。原实现会在结束后的第一次快照失败时立即取消，短暂的 AX 不可用会直接丢失已经出现的文字。

## 根因判断

- 搜索框/设置框/普通终端：原实现的语义排除导致这些可编辑目标无法被定位；按产品要求改为允许，仍保留密码/令牌/密钥等真正敏感字段保护。
- cmux 短按定位：高概率是路径缺口。cmux 的专用终端聚焦已存在，但短按入口使用通用聊天 composer 扫描，因终端语义被排除而找不到目标。
- 转写无文字：高概率包含 Accessibility 快照瞬时不可用；旧实现的立即取消会放大该瞬时故障。1.9.13 新反馈尚无日志，最终比例待现场验证。

## 最小修复

- `KeyboardInjector.focusFrontmostComposer` 检测前台为 cmux 时，复用现有 `surface.current → surface.focus → Terminal content area` 路径，并通过同一完成回调报告最终聚焦结果；通用候选规则允许搜索、设置和普通终端输入框，但继续拒绝密码/令牌/密钥字段。
- `TranscriptCaptureCoordinator` 在结束后的快照暂时不可用时，在既有总超时内按轮询间隔重试，并只记录一次 `TRANSCRIPT CAPTURE waiting reason=snapshot_unavailable_after_finish`；超时后若已有连续文字候选则保存，否则取消。
- 通用 composer 失败时追加窗口、候选和按安全类别统计的脱敏日志，不记录输入框文本、URL、账号或语音内容。

## 验证

- 定向 `swift test --filter 'TranscriptCaptureCoordinatorTests|RemoteButtonsTests'`：114 项测试通过。
- 完整 `swift test`：404 项测试、36 个 suite 通过；新增候选测试确认搜索、设置和终端输入框可评分，API Key 仍被拒绝。
- 本机尝试通过 Spotlight 进程和 Dock/系统事件激活 Spotlight、Launchpad；当前 Codex 桌面会话未显示系统搜索窗口，Launchpad 也不是可直接打开的独立 App，因此未完成真实系统窗口点击和语音输入验收。
- 新增自动化覆盖：结束后 AX 快照短暂不可用再恢复时，已接受文字仍能保存。
- cmux 真实 CLI、tmux/CLI 模式、Spotlight、Launchpad、飞书/Lark、豆包和实体遥控器尚未在反馈机器上完成完整语音验收；需要 1.9.13 日志关联 `APP FOCUS scan`、`APP FOCUS ... cmux_*`、`TRANSCRIPT CAPTURE waiting`、`TRANSCRIPT CAPTURE saved/canceled` 与同一语音会话的 `ATVV STREAM summary`。
