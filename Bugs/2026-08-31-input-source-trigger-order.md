+# Issue #307：输入源激活后再注入右 Command

## 复现与日志

21 次右 Command 会话中 10 次豆包未开始采集；失败日志显示输入源激活晚于 Command DOWN，遥控器、音频入队和按键注入均正常。

## 根因

旧实现先调用 `KeyboardInjector.setVoiceKeyPressed`，再调用 `TISSelectInputSource`；而输入源激活是异步的。

## 修复

Command 按下前先准备目标输入源，并在 500ms 内轮询确认当前输入源 ID 已切换；超时则恢复原输入源、回滚 latch，不发送 Command。释放路径仍只在会话结束时恢复受管输入源。

## 验证

- `swift test --filter VoiceKeyModeTests`
- 自动化覆盖准备确认发生在按键注入之前。
- 豆包/微信输入法冷启动热启动各 20 次与真实硬件仍需人工验收。

