# 修饰键语音模式松键后立即切回原输入法，豆包识别结果卡在组合态无法上屏

- 时间：2026-11-19
- 状态：候选修复，自动化通过，真实 RC003 + 豆包输入法待现场验收
- 影响范围：语音键为 Command / Option / 右侧修饰键组合，语音工具为需要切换系统输入源的豆包、微信输入法，且语音开始前的输入法不是该语音输入法（`managed=true`）
- 功能点：`PreferredInputSourceMonitor` 显式语音会话的输入源恢复时机

## 错误证据

现场：语音键 `右 ⌘ + 右 ⌥`，豆包“按住说话”设为同一组合，日常输入法为搜狗。豆包能开始收音、识别内容正确，但结果停在豆包的组合态浮层，不进入输入框。同一台机器上：

- 语音键改为 Fn：正常上屏。
- 用外接键盘直接按豆包的左 ⌘ 长按（不经 SayAll）：正常上屏，之后系统才切回搜狗。
- 语音开始前已经是豆包输入法时（`managed=false`）：正常上屏。

SayAll 明文运行日志（本地 build 255）：每次失败都是 `VOICE INPUT source_prepare tool=doubao result=selected managed=true`，松键时 `VOICE KEY ... edge=up` 与 `VOICE INPUT source_restore result=selected reason=voice_session_end` 在同一毫秒或 13 ms 内。Fn 模式不经过显式会话，日志中没有对应的 `source_restore`。

macOS 统一日志（只读取输入法进程公开的 InputMethodKit 与 AVCaptureSession 系统日志，不读取第三方私有数据）逐次比对 14:25–15:07 的 32 次豆包会话：

| 情况 | 豆包采集停止 → `Inserting text` | 结果 |
| --- | --- | --- |
| Fn、外接键盘左 ⌘、`managed=false` | 158–552 ms 后出现 | 上屏 |
| 修饰键模式且 `managed=true` | 从未出现，只有连续 `Setting marked text` 后关闭浮层 | 卡在组合态 |

14:41:04 失败样本的关键顺序：

```text
14:41:07.167 SayAll  VOICE KEY right_command_option edge=up
14:41:07.180 SayAll  VOICE INPUT source_restore result=selected   ← 切回搜狗
14:41:07.326 豆包    AVCaptureSession stopRunning                 ← 松键后约 150 ms 才停止采集
14:41:07.342–.465 豆包 Setting marked text ×5                     ← 仍在更新组合态
14:41:07.725 豆包    ASRPanel finishing close                     ← 没有 Inserting text
```

外接键盘左 ⌘ 的成功样本（15:05:43）：采集在 15:05:46.752 停止，15:05:47.155 `Inserting text`，系统直到 15:05:55 才切回搜狗。

## 根因

`BridgeAppModel.updateVoiceKeyState` 在修饰键模式下提交松键事件后立即调用 `preferredInputSourceMonitor.endVoiceSession()`；`endVoiceSession` 同步执行 `finishManagedInputSourceSession`，当场把输入源恢复为语音开始前的值。

此时豆包还没有停止采集，更没有把 marked text 提交到输入框。输入源被切走后豆包不再是活动输入法，组合态无法提交。Fn 模式不经过显式会话；外接键盘与 `managed=false` 场景都不会在松键瞬间切换输入源，因此不受影响。

该行为来自修饰键模式本身（`69a0274a`），不是右侧组合键引入的；组合键只是走同一路径。

## 最小修复

`Sources/RemoteMic/PreferredInputSourceMonitor.swift`：

- `endVoiceSession()` 在触发键已经发出（激活已完成）且显式 owner 是最后一个 owner 时，不再立即恢复，而是标记 `restoreDeferred` 并在 `explicitRestoreDelay = 1.5 s` 后恢复。延迟依据现场数据：松键到采集停止约 150–330 ms，采集停止到提交约 160–550 ms，总计约 0.9 s 以内，保留余量。
- 等待期间再次开始语音（同一语音工具、输入源仍是目标）：取消本次恢复并沿用当前输入法，不再切走又切回；最后一次会话结束后只恢复一次。
- 等待期间用户手动改了输入源：到期时沿用已有 `user_changed` 判定，不覆盖用户选择。
- 等待期间目标语音工具变化：立即按原逻辑结束旧会话的恢复，再开始新会话。
- `stop()`（App 停止）立即恢复；`stop(preservingExplicitVoiceSession: true)`（权限或设置重新应用）保留待恢复状态。
- 激活被取消、触发键从未发出时仍立即恢复；Fn 监听路径保持即时恢复。
- 日志新增 `VOICE INPUT source_restore phase=deferred reason=voice_session_end delay_ms=1500` 与 `source_restore phase=cancelled reason=new_voice_session|source_changed`，最终恢复仍记录原有 `source_restore result=...`。

不改动：语音键按下/松开的事件时序、首字路径、音频排空与尾音、Fn 硬件映射。

## 验证

- 新增回归：
  - `explicitVoiceEndDefersRestoreUntilTheVoiceToolCanCommit`：撤掉修复后失败（立即恢复、未调度），恢复后通过。
  - `newVoiceSessionDuringDeferredRestoreKeepsTheVoiceInputSource`
  - `deferredRestoreDoesNotOverrideASourceChosenWhileWaiting`
  - `stopDuringDeferredRestoreRestoresImmediatelyOnce`
  - `cancelledActivationStillRestoresImmediately`
  - `fnKeyReleaseKeepsImmediateRestore`
- 4 个原有用例改为注入调度器后再触发到期恢复，断言内容不变。
- 公开模式全量 `swift test --disable-keychain`：1539 tests passed。

## 验证边界

- 自动化不驱动真实 TIS、豆包或微信输入法，也不能证明 1.5 s 对所有语音工具和网络条件都足够；延迟值只来自本机豆包实测。
- 待现场验收：`右 ⌘ + 右 ⌥`、单键 Command/Option 在搜狗为日常输入法时文字上屏；松键后约 1.5 s 内输入法仍显示为豆包，之后切回搜狗；连续快速会话不出现输入法来回闪烁；等待期间手动切换输入法不被覆盖；Fn 模式行为不变。
