# RC003 语音键漏成字母 i，首次语音测试判定为手动输入

- 现场：2026-11-06，SayAll build 285，Intel MacBook Pro，macOS 14.2.1，RC003，豆包输入法。
- 现象：按住语音键后，ABC 输入源下的输入框出现字母 `i`。豆包输入法未启动，语音测试连续 4 次以 `voice.manual_input` 结束。

## 现场证据

首次失败时，诊断显示语音会话开始、收到音频并结束，音频已投递，输入框有文字且记录为物理键盘输入。同期存在 `connected_fallback` 和 `remote.button_not_ready`。在已连接的遥控器上用 `hidutil` 补写 `0x0C → Fn` 后，用户报告不再出现 `i`，豆包输入法正常启动，连续 3 次语音测试通过。系统自带 Fn/Globe 在同机可以正常启动豆包输入法。

同日重装 build 285 后没有稳定复现。另一次处于 `connected_fallback` 的测试也没有漏出 `i`。手动测试中，`0xFF000003` 和规范值 `0x000000FF00000003` 用作 `0x0C` 的目标值均能触发 Fn。现有证据支持补齐 `0x0C` 映射，仍需确认 HID 接管前后的原始 usage、映射写入时序和旧映射来源。

## 根因与修复

- 原映射只管理 F5（`0x3E`），因此无法将作为 `0x0C` 送到系统的按键转换为 Fn。默认 Fn 模式与软件触发模式现在分别映射或中和两种 usage，恢复时还原该服务原有的条目。
- PR 初稿按 `NSEvent.characters` 过滤控制字符，导致部分真实编辑未被判定为手动输入。审查用 `NSTextView` 执行 Ctrl+K、Ctrl+Y 复现，Ctrl+Y 的事件携带 U+0019 并实际插入文本。原主线判为手动输入，PR 初稿放行。门禁现在只对 Fn/Globe 键作例外，并保留现有的物理事件来源检查和 `voice.manual_input` 终态日志。

## 验证

- 定向命令：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'OnboardingFlowTests|RemoteVoiceFunctionMapperTests|VoiceKeyModeTests'`。
- 定向测试共 149 项通过。回归覆盖 Fn 触发、Ctrl+Y 等物理编辑、未知或合成事件、两种 usage 的映射和事务恢复。AppKit 对照确认初稿放行 Ctrl+Y，修订后将该事件归类为手动输入。
- 现场的 Intel 对照使用旧构建和临时映射。改后构建的首次连接、真实文字、极速按放、连续语音、断连恢复及重复触发检查按[首次使用测试手册](../Testing/FirstRunOnboarding.md#rc003-语音键与手动输入pr-909)单独验收。
