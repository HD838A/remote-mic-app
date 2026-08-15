# 开发记录

## 精确接入点

- `Sources/RemoteMic/AppLogger.swift`：把单一明文文件替换为按天加密文件，执行 10MB 容量门禁、5 天清理，并只解密今天和昨天供诊断发送。
- `Sources/RemoteMic/DiagnosticLogKeyStore.swift`：生成并复用 256-bit AES 密钥，优先使用 Data Protection Keychain，必要时回退 App 专用 Keychain。
- `Sources/RemoteMic/DiagnosticLogUploader.swift`：执行上传前脱敏，并通过 Sentry Envelope HTTPS 接口发送结构化日志。
- `Sources/RemoteMic/BridgeAppModel.swift`：提供唯一的用户主动发送入口和页面内结果状态。
- `Sources/RemoteMic/SettingsView.swift`：在现有诊断卡中增加发送按钮，不新增 Sheet、Popover 或自动流程。
- `Resources/*/Localizable.strings`：说明保留期、上传范围和主动发送边界。
- `scripts/build-app.sh`：只从 `REMOTE_MIC_SENTRY_DSN` 注入最终 App；未配置时确保 Info.plist 不包含该字段。
- `scripts/test.sh`：把日志密钥存储加入显式 self-test 编译清单，确保非 SwiftPM 自检链路也能构建。
- `Tests/RemoteMicTests/*Diagnostic*`、`AppLoggerTests.swift` 和 `SettingsPageRegressionTests.swift`：覆盖本地存储、密钥、脱敏、Envelope 和用户操作门禁。

## 文件格式

每日文件以 `RMLG1\n` 开头。每条记录是 4 字节大端密文长度和一段独立的 AES-GCM combined data；当天的 `YYYY-MM-DD` 作为 AAD，防止记录被无提示地移动到另一天文件。10MB 限制按最终加密文件大小计算，达到上限后当天后续日志被丢弃，不创建额外分卷。

## 上传边界

项目没有链接 Sentry SDK。上传器只在 `sendDiagnosticLogs()` 被设置页按钮调用后运行，使用无磁盘缓存的临时 `URLSession`，每批最多 250 条。上传文档固定为调用时本地日期的今天和昨天；其他三天仅用于本地排障留存。

## 关键决策

1. 本地日志必须先加密再落盘，不能先写明文再异步转换。
2. 为避免第三方 SDK 自动行为和额外明文缓存，使用 Sentry 官方 Envelope 摄取协议，不启用自动崩溃、性能或会话遥测。
3. 上传的是由 App 解密并脱敏后的文本，因此开发者可在 Sentry 中查询；加密密钥和原始 `.rmlog` 不上传。
4. 没有 DSN、没有日志、断网或服务拒绝时只在当前页面显示状态，不弹连续确认框，也不自动重试上传。

## 验证状态

- 日志加密、今天/昨天读取、5 天保留、容量上限和旧明文清理：自动化通过。
- Keychain 密钥创建与复用：真实 macOS Security API 测试通过。
- 上传前脱敏、无 DSN 不调用发送器、Sentry endpoint 和 Envelope 格式：自动化通过。
- App 启动路径不调用上传器、设置按钮是唯一入口：回归测试通过。
- 尝试使用真实 `SettingsView` 进行浅色/深色离屏渲染，但 macOS 玻璃与 Material 合成层在缓存截图中为黑色，窗口捕获又受屏幕录制权限限制，因此没有把无效截图作为 UI 通过证据；临时夹具已全部撤回。
- 真实 Sentry 接收、网络失败恢复、默认最小窗口页面和最终签名 App：尚未人工验收。
