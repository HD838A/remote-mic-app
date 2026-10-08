# 遥控器配置升级兼容性

适用：2.0.0 后的型号解码修复候选。

## 准备与操作

1. 在隔离测试账号或隔离 UserDefaults 中保存旧 Chromecast 型号值 `chromecase_voice_remote`。同时保存小米设备、自定义按键映射和选中设备。
2. 用候选版本读取设置。
3. 检查没有“遥控器设备配置”读取失败提示，两个设备、选中设备和自定义映射均保留。
4. 保存配置并再次启动，确认当前型号值为 `chromecast_voice_remote`，映射仍一致。
5. 使用正常当前型号配置重复步骤；使用真正损坏的 JSON 确认仍告警并保留 `.corrupt` 备份。

丢失任一原有设备、绑定或映射，或旧拼写触发告警，均判定失败。不要用用户生产设置进行破坏性实验。

## 证据与边界

运行 `swift test --disable-keychain --filter 'SettingsCorruptionRecoveryTests|VoiceRemoteCatalogTests'`。
23 项测试通过。测试驱动真实 AppSettings 加载，覆盖隔离配置和现有损坏恢复基线。
自动化不替代用户升级验收。此修改不改变硬件协议、语音会话和音频路径。
现场失败日志可由用户主动提供 `.rmlog`，支持环境仅提取稳定错误类型；不得提交原始日志或私钥。
