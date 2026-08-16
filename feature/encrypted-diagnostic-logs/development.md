# 开发记录

## 精确接入点

- `Sources/RemoteMic/AppLogger.swift`：把单一明文文件替换为按天加密文件，执行 10MB 容量门禁、5 天清理，并只解密今天和昨天供诊断发送。
- `Sources/RemoteMic/DiagnosticLogKeyStore.swift`：生成并复用 256-bit AES 密钥，优先使用 Data Protection Keychain，必要时回退 App 专用 Keychain。
- `Sources/RemoteMic/DiagnosticLogUploader.swift`：执行上传前脱敏；仅在用户操作后启动官方 Sentry SDK、发送结构化 Logs、检查残留 Envelope，并关闭 SDK 和删除临时缓存。
- `Sources/RemoteMic/AppEnvironmentSnapshot.swift`：生成只含系统、硬件型号、版本、语言、麦克风设置和非个性化配置的启动快照。
- `Sources/RemoteMic/RemoteMicApp.swift`：在 App 完成启动时记录一次环境快照，位置早于首次使用向导的运行时门禁。
- `Sources/RemoteMic/BridgeAppModel.swift`：提供唯一的用户主动发送入口和页面内结果状态。
- `Sources/RemoteMic/SettingsView.swift`：在现有诊断卡中增加发送按钮，不新增 Sheet、Popover 或自动流程。
- `Resources/*/Localizable.strings`：说明保留期、上传范围和主动发送边界。
- `scripts/build-app.sh`：只从 `REMOTE_MIC_SENTRY_DSN` 注入最终 App；未配置时确保 Info.plist 不包含该字段。
- `scripts/build-app.sh`、`scripts/verify-app.sh`：把静态 Sentry SDK 的官方 `PrivacyInfo.xcprivacy` 放入并校验最终 App Resources；Sentry 不作为动态 Framework 嵌入。
- `scripts/test.sh`：把日志密钥存储加入显式 self-test 编译清单，确保非 SwiftPM 自检链路也能构建。
- `Tests/RemoteMicTests/*Diagnostic*`、`AppLoggerTests.swift`、`AppEnvironmentSnapshotTests.swift` 和 `SettingsPageRegressionTests.swift`：覆盖本地存储、密钥、脱敏、SDK 配置、旧文件迁移、启动环境字段和用户操作门禁。

## 文件格式

每日文件以 `RMLG1\n` 开头。每条记录是 4 字节大端密文长度和一段独立的 AES-GCM combined data；当天的 `YYYY-MM-DD` 作为 AAD，防止记录被无提示地移动到另一天文件。10MB 限制按最终加密文件大小计算，达到上限后当天后续日志被丢弃，不创建额外分卷。

## 上传边界

项目通过 SwiftPM 固定 Sentry Cocoa `9.26.0` 的静态 `Sentry` 产品。上传器只在 `sendDiagnosticLogs()` 被设置页按钮调用后启动 SDK；SDK 的缓存目录是权限受限的随机临时目录，关闭自动崩溃、会话、性能、App Hang、MetricKit、网络跟踪、自动面包屑和自动启动上报。上传完成后执行 flush，若仍有待发送 Envelope 则返回失败；随后关闭 SDK 并删除临时目录。上传文档固定为调用时本地日期的今天和昨天；其他三天仅用于本地排障留存。

## 关键决策

1. 本地日志必须先加密再落盘，不能先写明文再异步转换。
2. 用户明确要求官方 SDK 后，改用 Sentry Structured Logs API；SDK 不在 App 启动时初始化，且全部自动遥测明确关闭。SDK 无法完全避免发送期临时 Envelope，因此将缓存隔离到随机临时目录，并在每次用户触发完成后删除。
3. 上传的是由 App 解密并脱敏后的文本，因此开发者可在 Sentry 中查询；加密密钥和原始 `.rmlog` 不上传。
4. 没有 DSN、没有日志或发送后仍有待处理 Envelope 时只在当前页面显示状态，不弹连续确认框，也不保留 SDK 缓存进行后台自动重试。
5. 启动环境快照只保留诊断所需的系统和配置类别；音频设备只记录是否已配置，不记录 UID 或自定义名称，按键配置只记录总开关，不记录具体映射。

## 验证状态

- 日志加密、今天/昨天读取、5 天保留、容量上限和旧明文清理：自动化通过。
- Keychain 密钥创建与复用：真实 macOS Security API 测试通过。
- 上传前脱敏、无 DSN 不调用发送器、官方 SDK 接入与自动遥测关闭：自动化通过。
- `sayall.app` 文件前缀、旧 `runtime-*.rmlog` 迁移、启动快照字段与隐私排除：自动化通过。
- App 启动路径不调用上传器、设置按钮是唯一入口：回归测试通过。
- 尝试使用真实 `SettingsView` 进行浅色/深色离屏渲染，但 macOS 玻璃与 Material 合成层在缓存截图中为黑色，窗口捕获又受屏幕录制权限限制，因此没有把无效截图作为 UI 通过证据；临时夹具已全部撤回。
- 真实 Sentry 接收、网络失败恢复、默认最小窗口页面和最终签名 App：尚未人工验收。
