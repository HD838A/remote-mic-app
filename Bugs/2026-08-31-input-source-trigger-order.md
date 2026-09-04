+# Issue #307：输入源激活后再注入右 Command

## 复现与日志

21 次右 Command 会话中 10 次豆包未开始采集；失败日志显示输入源激活晚于 Command DOWN，遥控器、音频入队和按键注入均正常。

## 根因

旧实现先调用 `KeyboardInjector.setVoiceKeyPressed`，再调用 `TISSelectInputSource`；而输入源激活是异步的。

首次候选修复把激活轮询放进了 Fn 与显式 Command 共用的输入源会话入口，导致 Fn 路径在无法读取当前输入源时每次额外等待 500ms。定向测试稳定复现为两次实际准备、四条含 `source_prepare` 的日志，其中两条是 `activation_timeout`。代码检查还确认，激活等待期间的提前松手可重入共享 RunLoop，使 UP 先于尚未发出的 DOWN；DOWN 注入失败时也没有结束已准备的输入源会话。蓝牙 `didDecode` 同样可在等待期间重入并直接 enqueue，使目标 PTT 丢失 DOWN 前的首段 PCM；移动端或重复 START 若在此时重入，还可能注册没有真实 DOWN 的 owner。输入源会话在确认前未登记 pending 状态，也会被真实 Fn DOWN 覆盖 owner；失败恢复还可能覆盖用户刚切换的第三输入源。

## 修复

Command 按下前先准备目标输入源，并在 500ms 内轮询确认当前输入源 ID 已切换；超时则回滚 latch，不发送 Command。等待期间登记 pending 输入源会话并合并真实 Fn owner，缓存最多 500ms 的蓝牙 PCM，DOWN 成功后按原顺序补送；其他语音 START 在 DOWN 完成前会被拒绝，同设备重复蓝牙 START 在入口幂等忽略，完成后多 owner 共享行为不变。提前松手、监听停止、注入失败或强制释放会清空缓存且不发送孤立 UP；当前仍是受管目标或原输入源时会重选原输入源以抵消迟到激活，只有用户已改选第三输入源时跳过恢复。激活轮询只用于显式 Command 会话，Fn 路径维持原有的即时准备和响应。

## 验证

- `swift test --filter VoiceKeyModeTests`
- `swift test --filter PreferredInputSourceMonitorTests.functionKeyDownPreparesTheRememberedInputMethodOncePerPress`
- `swift test --filter PreferredInputSourceMonitorTests.cancellingExplicitVoiceDuringActivationStopsWaitingAndRestores`
- `swift test --filter ATVVProtocolTests`
- `swift test --filter PreferredInputSourceMonitorTests` 连续 3 次通过，避免真实主 RunLoop 重入测试互相干扰。
- `swift test`：441 个测试、37 个 suite 全部通过。
- 自动化覆盖准备确认发生在按键注入之前。
- 自动化覆盖 Fn 每次按下只查询、准备和记录一次，以及 Command 提前松手、注入失败、早到 PCM 补送和取消清理边界。
- 豆包/微信输入法冷启动热启动各 20 次与真实硬件仍需人工验收。
