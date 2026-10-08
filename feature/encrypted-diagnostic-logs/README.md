# 加密诊断日志

## 用户可见行为

设置页提供“发送诊断信息”和“打开日志目录”。发送是用户主动操作；未配置 Sentry DSN 时会明确显示服务尚未配置，不影响本地日志保存。

## 数据边界

- 本地 `.rmlog` 使用公钥包裹的 AES-GCM 会话密钥加密。App 不保存解密私钥，支持人员在受控环境中使用私钥读取。
- Sentry 不读取本地日志文件，只接收通过各自 schema 校验的结构化安全事件：公开事件跨重启保留最近 7 天的最多 256 条待发送记录，可选私有事件由独立 provider 提供。
- 当前允许的 Sentry 消息包括设置读取结果、环境快照、权限状态、遥控器连接状态、音频配置结果、语音会话时序和 Onboarding 语音测试结果。语音会话覆盖小米/苹果遥控器、Chromecast、iPhone、Apple Watch 和 Web 来源，包含耗时、音频收到/调度/播放/中断/pending 样本和失败计数，但不包含音频内容。
- 私有模块可以上传不关联身份的稳定业务阶段、粗粒度状态、原因码、重试、耗时和短生命周期关联号；公开宿主不维护这些私有业务目录，也不读取私有原始日志或数据库。
- 不上传用户内容、第三方 App 私有状态、身份、邮箱、Token、验证码、原始订单/支付标识、checkout URL、价格、精确权益到期时间、路径、设备身份、凭据或自由文本。

## 实现范围

`AppLogger` 负责本地加密写入和公开安全事件持久化；可选私有 provider 负责自己的安全事件持久化；公开宿主的 `DiagnosticLogUploader` 只负责用户主动触发后的事件编排，实际 Sentry 发送由私有 Package 的 `SayAllDiagnosticsHostAdapter` 完成。三者不通过读取本地日志文件互相连接。

## 验证

自动化测试：

```bash
swift test --disable-keychain --filter 'AppLoggerTests|PublicDiagnosticEventStoreTests'
swift test --disable-keychain --filter DiagnosticLogUploaderTests
```

完整步骤见 [`Testing/EncryptedDiagnosticLogs.md`](../../Testing/EncryptedDiagnosticLogs.md) 和 [`LOGGING.md`](../../LOGGING.md)。

公开开发环境和公开构建不包含 Sentry DSN 或 Sentry SDK。受控 Sentry 验收只能使用私有 Package 和私有构建环境；生产私钥保管/轮换与真实用户现场日志支持流程仍需生产环境验收。
