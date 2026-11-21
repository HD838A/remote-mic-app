# 小米语音启动重试可能丢首词

## 证据和根因

基线 `d48f7795` 的生产启动协调器首次超时后会再试一次。最小实验模拟首次超时和第二次成功，配置耗时 2,608 ms，实时 16 kHz 等价输入 41,728 个样本，旧缓存只保留最后 32,000 个，丢掉开头 9,728 个。暂无该时序的真实遥控器与输入法现场日志。

## 修复和验证

小米配置期缓存覆盖两次启动尝试与 1 秒配置和队列余量。配置成功后按原顺序投递。容量仍不足时结束该语音，记录 `configuration_buffer_overflow` 或配置失败原因、操作编号与当前中断样本数。配置完成只作用于同一语音操作；常规松键和排空继续走现有路径。

运行 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'VirtualAudioConnectionLifecycleTests|CoreVoiceInputJourneyTests|VoiceKeyModeTests'`。保留 PCM 次序可自动验证；RC001、RC003 的响应耗时、正常首尾字、快速连续语音和目标工具上屏待真实环境验收。
