# 重启后无法发送此前的公开诊断事件

- 证据：2.0.0 主线只在 `AppLogger` 内存中保留公开事件，最多 256 条；退出进程后全部丢失。配置解码失败只写普通加密日志，没有生成可上传事件。Sentry 上传器按设计不读取 `.rmlog`。
- 根因实验：记录批准事件，创建新的 Logger 实例，再读取待发送事件，主线为空；sender 失败应保留，成功才确认。
- 修复：新增只包含已批准 canonical 字段的持久存储，最多 256 条、7 天，目录 `0700`、文件 `0600`。配置解码错误映射为稳定类别，不上传原始键、错误正文或用户配置。保留加密日志与主动上传之间的边界。
- 回归：`swift test --disable-keychain --filter 'PublicDiagnosticEventStoreTests|AppLoggerTests|DiagnosticLogUploaderTests|SettingsCorruptionRecoveryTests'`，50 项通过。覆盖跨重启、失败重试、成功确认、容量、过期、权限、篡改拒绝、现有加密日志与损坏配置基线。
- 范围：只保留批准的最近事件；无法补回安装此修复前已经丢失的内存事件，不能将 Sentry 称为完整本地日志。
- 边界：自动化使用合成数据。候选 App 和真实 Sentry 网络验收待完成；2.0.0 Draft 安装资产未更新。
