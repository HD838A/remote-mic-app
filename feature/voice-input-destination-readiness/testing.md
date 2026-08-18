# 验证记录

## 自动化范围

- 目标就绪：0、200 ms、1 秒、3 秒。
- 音频：等待中缓存、提前松开、5 秒 80,000 sample 完整回放。
- 取消：超时、App 退出、切换目标、新请求覆盖旧请求、动作失败。
- 安全：禁用、非编辑、Secure Text Field、Protected Content、密码和 Token 语义拒绝。
- 兼容：无 pending 时原 150 ms Fn 时间线、默认关闭 Fn、普通会话配对和失败回滚。
- 模拟硬件：RC001 与 RC003 的 `STREAM_START → AUDIO → STREAM_STOP` 生产解码和第一次语音完整旅程。

## 运行命令

```zsh
swift test --filter VoiceInputDestinationCoordinatorTests
swift test --filter CoreVoiceInputJourneyTests
swift test --filter VoiceFnTapSessionControllerTests
/Users/andy/Develop/Src/AISrc/hardware-simulation/scripts/test-remote-mic.sh <仓库路径>
swift test
./scripts/test.sh
swift build -c release
./scripts/build-app.sh
./scripts/verify-app.sh "dist/SayAll.app"
```

## 人工验收

完整步骤见 [`Testing/VoiceInputDestinationReadiness.md`](../../Testing/VoiceInputDestinationReadiness.md)。实体遥控器、第三方 App、真实输入法和最终文字上屏未被单元测试替代；发布预览版时必须明确保留这些边界。
