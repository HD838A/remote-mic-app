# 小米语音等待配置时串会话

## 证据与根因

以首个会话拥有语音键且输出尚未就绪为起点，执行另一台遥控器的 ATVV 开始与停止分支。旧代码先写入第二台等待标识和释放第一台语音键，随后才拒绝第二台。第二台停止时仍留下等待标识。同一台在首次松键后等待配置期间再次按下也会被误判为重复开始。证据来自真实分支提取实验，暂无实机现场日志。

## 修复与验证

在写入任何状态前确认归属。每个后续物理 ATVV 操作独立收集 PCM 与松键，第一句话排空后按顺序继续。配置超时、队列超限、取消与断连清理状态并记录终态和丢失样本。运行 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'ATVVProtocolTests|ATVVAudioDiagnosticsTests|CoreVoiceInputJourneyTests|VirtualAudioConnectionLifecycleTests|VoiceKeyModeTests'`。RC001、RC003 与实际虚拟麦克风和目标语音工具待验证。
