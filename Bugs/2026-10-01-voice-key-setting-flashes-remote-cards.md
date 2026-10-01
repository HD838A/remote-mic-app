# 切换语音键模式时顶部遥控器卡片闪烁

- 时间：2026-10-01
- 状态：候选修复完成，自动化与构建验证通过；待 Siri Remote 真机复验
- 影响范围：macOS 设置 → 按键映射，已连接 Siri Remote 的内部完整构建
- 功能点：语音键模式、Fn 点按兼容设置与 Siri Remote 连接生命周期

## 复现条件

1. 同时连接小米遥控器与 Siri Remote，打开“按键映射”。
2. 保持顶部遥控器卡片可见。
3. 在底部依次切换“Fn/地球键、左 Command、右 Command、右 Option”，或切换“语音键模拟 Fn 点按”。

错误行为：每次切换后顶部 Siri Remote 卡片短暂消失再出现，型号栏整体重新排版，看起来像闪烁。正常行为是语音键注入映射即时更新，但已经建立的遥控器连接与卡片保持稳定。

## 日志结论

现有模式日志记录 `VOICE KEY mode_change requested/completed`；Siri Remote 连接日志会在重启期间产生断开和重新连接。代码顺序进一步确认：模式切换调用 `applyHIDSettings()`，该函数无条件执行 `siriRemoteFeature.restart(...)`，连接回调随即暂时移除 `connectedAppleRemoteProfileIDs`，顶部选择器只渲染已连接档案，因此卡片消失再出现。用户已确认未开启 Fn 模拟，固定 Fn 点按会话不是本次闪烁的前置条件。

## 根因

`applyHIDSettings()` 同时承担小米 HID/Fn 映射刷新与 Siri Remote 自定义映射重启。语音键模式只改变 Mac 端按键注入方式，不改变 Siri Remote 的连接配置，却仍走了完整私有遥控器重启路径。

## 修复

- 为 `applyHIDSettings` 增加明确的 `restartSiriRemote` 策略参数，默认继续保持原有重启语义。
- 只有语音键模式和 Fn 点按设置变化时传入 `false`，更新 HID/Fn 映射但保留当前 Siri Remote 连接。
- HID 映射延迟恢复沿用同一策略，避免切换后由重试任务再次触发延迟闪烁。
- 记录脱敏日志 `SIRI REMOTE SETTINGS result=preserved reason=voice_key_configuration_change`，区分“设置已应用但连接按设计保留”与重启失败。
- 自定义按键总开关、配置导入、权限恢复等可能改变 Siri Remote 事件接管方式的入口仍使用默认重启，不扩大行为变化。

## 验证

- 修复前新增回归测试 `changingVoiceKeySettingsDoesNotRestartSiriRemote`，在主线代码上按预期失败。
- 修复后 `VoiceKeyModeTests` 与 Siri Remote 宿主接线相关测试通过。
- `swift build --disable-keychain -c release` 与 `git diff --check` 通过。
- 真机待验证：连接 A2540/A2854 后连续切换四种语音键模式和 Fn 点按，顶部卡片不消失；普通按键、自定义映射、触摸与下一次语音会话仍正常。

## 自动化与真机边界

自动化能够证明语音设置入口不会调用重启，并且延迟恢复继承“不重启”策略；无法替代真实 Siri Remote 的蓝牙/HID 连接回调、顶部卡片视觉稳定性和切换后的首次真实语音。
