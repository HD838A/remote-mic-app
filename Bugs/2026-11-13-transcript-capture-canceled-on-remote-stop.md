# 远端 60 秒停止后本地转写候选被取消

- 时间：2026-11-13
- 状态：候选修复，定向自动化与本地构建待复验；真实 RC003 超过 60 秒复测待完成
- 影响范围：macOS 本地语音记录；遥控器在 60 秒物理停止时，已经出现的本地转写候选
- 功能点：本地语音转写记录、远端物理 `STREAM_STOP` 收尾
- 简单描述：远端在 60 秒左右停止音频后，App 的音频和录音资产正常收尾，但本地转写捕获以 `discontinuous_text_change` 取消，没有保存已经出现的文字。
- 开发基线：`origin/main` `6a3075651875a2724013ebce11407302eeb91281`

## 错误证据与日志边界

本地测试包 build 343，公开兼容模式。2026-11-12 15:59:09–16:00:09 UTC（本机 23:59–00:00）的明文诊断日志记录了同一会话：

```text
15:59:09.359 ATVV AUDIO diagnostic operation_id=1 phase=started
15:59:09.446 TRANSCRIPT CAPTURE target_ready retry=false
15:59:09.447 ATVV STREAM START session=115
16:00:09.415 ATVV CONTROL opcode=0x00 bytes=2 raw=0008
16:00:09.416 ATVV STREAM STOP session=115 partial_frame_bytes=0
16:00:09.428 TRANSCRIPT CAPTURE canceled reason=discontinuous_text_change
16:00:09.782 ATVV AUDIO diagnostic operation_id=1 phase=completed completion=normal ...
```

音频收尾统计为 `samples=917040`、`coverage_pct=95.4`、`dropped=0`、`interrupted=0`，录音资产保存成功；日志中没有同一会话的 `TRANSCRIPT CAPTURE saved`。同一模式的更早 build 343 会话也在 60 秒停止后出现 `canceled reason=discontinuous_text_change`，没有保存候选。

`raw=0008` 的停止发生在开始后 60.060 秒，和用户松手的 `raw=0002` 不同；这是远端固件在 60 秒限制处主动停止音频。60 秒之后的音频没有进入 App，不能由本地转写补回。

日志只保留脱敏后的控制码、计数和原因字段；不记录用户语音内容。

## 假设与实验

- H1：远端停止后音频链路正常，但转写捕获被取消。日志中的 `completion=normal` 与紧随其后的 `TRANSCRIPT CAPTURE canceled` 支持该假设。
- H2：音频尾部丢失导致没有文字。该会话的 `AUDIO completed` 显示正常完成，`dropped=0`、`interrupted=0`，且已有录音资产；这不解释已有候选为什么在停止后被丢弃。
- H3：转写工具没有产生任何文字。日志显示捕获已经 `target_ready`，随后在目标文本不连续变化时取消；需要修复捕获状态机，而不是假设工具没有输出。

最小实验：在 `TranscriptCaptureCoordinator` 的结束轮询中，先让目标文本形成合法候选，再将其替换为不连续文本。旧实现直接 `cancel(reason: "discontinuous_text_change")`，候选丢失；修复后的实现应保存最后一个通过连续差异校验的候选。

## 根因

`TranscriptCaptureCoordinator.poll` 在会话已经结束（`endedAt != nil`）后，仍把“目标文本不连续变化”当作必须取消的异常。旧的快速发送修复已覆盖输入框清空、目标变化和下一会话开始，但没有覆盖“结束后目标文本被整体替换或重写”的分支；远端 60 秒停止触发了这个分支，导致已经通过校验的候选被丢弃。

这不是 RC003 扩展删除引起的；该实验入口默认关闭，删除在正常路径上没有行为变化。远端 60 秒物理停止是触发条件，App 侧的问题是停止后的捕获收尾策略。

## 修复

- 在结束轮询的 `discontinuous_text_change` 分支，改用 `completeAcceptedChangeOrCancel`。
- 如果此前已有通过安全目标、同一输入元素和连续差异校验的候选，保存该候选并记录 `saved reason=discontinuous_after_finish`。
- 没有合法候选时仍取消，记录 `canceled reason=discontinuous_after_finish`，不扩大采集范围。
- 不改变远端 60 秒硬停、音频收尾、录音资产或 RC003 扩展开关。

## 验证

已执行：

- `swift test --disable-keychain --filter TranscriptCaptureCoordinatorTests`：13 项 / 1 suite 通过，包含新增的“结束时保留最后候选”和“没有候选仍取消”两项。
- `swift test --disable-keychain --filter 'TranscriptCaptureCoordinatorTests|FirstVoiceReflectionJourneyTests|RecordingAssetStoreTests|SettingsPageRegressionTests'`：98 项 / 4 suites 通过。
- `git diff --check`：通过。

待执行：

- 本地 release App 构建与真实 RC003 超过 60 秒复测。

## 验证边界

自动化快照只能证明捕获状态机；真实 RC003 的 60 秒固件停止、第三方输入法文字、目标 App 的 Accessibility 文本变化仍需真机复测。修复只保存停止前已经出现的文字，不延长远端 60 秒音频，也不恢复 60 秒后的尾音。
