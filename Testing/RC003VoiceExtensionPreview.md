# RC003 长语音续流实验（已移除）

状态：2026-11-12 已移除。`--rc003-voice-extension-test`、测试包入口，以及 App 内基于物理 `STREAM_STOP` 的自动 `MIC_OPEN` / 定时 `MIC_EXTEND` 续流逻辑经真机验证不可用，已从代码删除。本文件只保留历史结论，不再作为测试入口。

## 历史结论

- 曾尝试在 RC003 物理语音段 `STREAM_STOP` 后自动重开 `MIC_OPEN`，并每 8 秒发送 `MIC_EXTEND`，最长 120 秒。
- 真机验证未能证明重开后的音频持续进入同一目标输入框；该实验入口不可用。
- 当前正常产品行为仍是按住语音键收音，松开或遥控器物理段结束时结束会话；不支持跨物理段续流。
- 相关历史证据见 [RC003 一分钟语音会话停止](../Bugs/2026-08-10-rc003-one-minute-voice-session-timeout.md)。

## 2026-11-13 会话补充记录

### 历史调试原因

- 2026-08-10 的现场问题是 RC003 普通语音约 60 秒后物理停止，用户仍按住时音频先结束；这是固件租期边界，不是普通松键行为。
- 2026-08-26 开始的独立实验尝试在物理 `STREAM_STOP` 后自动发送 `MIC_OPEN`，随后每 8 秒发送 `MIC_EXTEND`，最高 120 秒。
- 真机证据显示：主动 `MIC_OPEN` 可能返回 `STREAM START session=0`，但没有任何 audio characteristic 数据；控制流成功不等于真实收音成功。同一连接下普通语音键随后能收到连续 120-byte 音频包。
- 因此该实验入口不能作为产品功能保留；本次删除只移除不可用实验，不改变正常语音键的按住/松键生命周期，也不删除 `ATVVProtocol.microphoneExtend()` 纯协议编码器。
- #766 的 Fn 点按无缝续录是独立产品路径，不包含也不删除本实验入口；#1026 处理的是远端 60 秒超时后的 Fn 抬起，也不是本实验入口。

### 本次测试记录

- `swift test --disable-keychain --filter 'ATVVProtocolTests|ATVVAudioDiagnosticsTests'`：45 项 / 3 suites 通过。
- `git diff --check`：通过。
- 同一个删除补丁在本地测试 worktree 完成 release App 构建、签名和安装（build 343）；该本地包额外带有一条未提交的 `ATVV CONTROL` 诊断日志，不属于本 PR。
- 本次会话使用的 build 348 仍来自 `origin/main` 的主线代码，RC003 实验入口尚未合并删除；因此 build 348 不能作为本 PR 的真机验收证据。
- 待完成：合并后重新构建，确认 `--rc003-voice-extension-test` 不再存在，并在真实 RC003 上确认普通语音键不出现 `RC003 EXTENSION` 日志。

- 关联边界：#1029 处理正常停止的尾音释放，#1030 处理本地转写候选；它们都不是本实验入口，也不改变 RC003 的 60 秒固件边界。
