# 运行日志运维验收

## 适用范围

本手册验证当前 `.rmlog` 会话文件、顺序元数据、加密失败闭锁和普通运行日志的脱敏边界。`.rmlog` 是二进制加密文件，不能用 Finder 直接打开，也不能把它当作 UTF-8 `runtime.log` 阅读。

## 测试前准备

1. 记录待测版本、Build 和 App 进程 PID；退出其他 SayAll 实例。
2. 不清空或覆盖 `~/Library/Logs/RemoteMic/`，保留既有文件用于回收和权限检查。
3. 本地测试使用临时目录和测试公钥；测试私钥只在测试进程内存中生成，不写入仓库。
4. 所有 SwiftPM 命令使用 `--disable-keychain`。

## 用例 1：会话文件与权限

1. 在配置了测试/构建公钥的包中启动 App，触发一次普通设置操作。
2. 查看 `~/Library/Logs/RemoteMic/` 中新出现的 `sayall.app-YYYY-MM-DD-session-XXXXXXXX.rmlog`。
3. 检查目录权限为 `0700`、文件权限为 `0600`，文件头为 `RMLG2`。
4. 重启 App，再触发一次操作，确认创建新的 session 文件，不覆盖旧文件。

预期：文件正文不能直接读出 `APP`、用户文字或其他明文；解密后每条记录包含 UTC 时间、`pid`、`ver`、`build` 和单调递增 `seq`。不同进程追加时不能产生交叉或半条记录。

失败判定：出现明文回退、权限过宽、第二次启动覆盖旧文件、记录缺少 `seq`，或日志目录出现用户目录之外的路径/身份信息。

## 用例 2：公钥缺失必须闭锁

1. 使用未注入 `SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64` 且 Bundle 没有 `SayAllDiagnosticPublicKey` 的本地包启动。
2. 触发普通日志和一次类型化环境事件。
3. 检查日志目录与系统开发日志。

预期：不创建明文或伪装成加密的日志文件；系统开发日志最多记录 `encryption_public_key_missing` 等稳定原因。App 不崩溃，Sentry 仍不会因为缺少本地公钥而自动启动。

## 用例 3：顺序、控制字符和大小上限

运行：

```bash
swift test --disable-keychain --filter AppLoggerTests
```

预期测试覆盖：加密记录、内部测试解密、`seq` 顺序、控制字符归一化、诊断摘要的 BEGIN/FIELD/END 顺序、公钥缺失 fail closed、文件大小上限和 XCTest 进程禁用共享日志。

失败判定：任何测试失败，或为了测试读取了生产用户文件。

## 用例 4：内部解密工具边界

1. 由受控支持环境取得与构建公钥对应的私钥，不将私钥复制到用户机器或公开仓库。
2. 使用内部工具解析 `RMLG2` 头、解包文件密钥，再按长度前缀和 `seq` 顺序解密 AES-GCM 记录。
3. 篡改一条记录或关联数据后再次解密。

预期：原文件可按时间和 `seq` 顺序读取；篡改记录验证失败并停止该记录，不把损坏内容当作成功日志。公开 App 只负责加密，不具备解密能力。

## 用例 5：普通日志隐私

触发权限、蓝牙、音频、输入工具和语音会话的成功、失败、取消、超时、重试与恢复路径，并由内部工具查看解密结果。

预期：只出现稳定分类、错误 domain/code、计数、样本数和耗时；不出现用户语音、文字、剪贴板、路径、窗口标题、BLE 地址/名称、CoreAudio UID、第三方 App 私有配置或凭据。`received`、`decoded`、`enqueued` 不得被记成最终成功。

## 用例 6：公开构建不包含私有诊断传输

确认公开仓库没有 Sentry 依赖、DSN 注入或私有 Package 路径：

```dotenv
SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64=
```

执行：

```bash
swift test --disable-keychain --filter DiagnosticLogUploaderTests
```

预期：公开构建返回 `serviceNotConfigured`，不调用私有传输、不初始化 Sentry、不读取本地 `.rmlog`，本地日志不被删除。

## 用例 7：Sentry 发送内容（需受控 DSN）

只有在私有 Package 和私有受控构建环境提供测试 DSN 后执行；不使用生产账号或真实用户数据。公开仓库本身不执行该用例。

1. 在内存中放入一个批准的环境快照、一个未批准的公开事件，以及可选私有 provider 的安全记录。
2. 点击“发送诊断信息”或调用上传器测试入口。
3. 在 Sentry 测试项目检查事件。

预期只产生批准的 `PUBLIC_EVENT` 和通过独立 schema 校验的 `PRIVATE_EVENT`。公开字段限于 `LOGGING.md` 白名单；私有事件只包含通用信封、稳定业务阶段、粗粒度状态、原因码、重试、耗时和短生命周期关联号。无 User、Tags、Contexts、附件、崩溃、Session、性能、网络、Breadcrumb、IP、Bundle ID、路径、身份或真实业务对象标识。

以下情况必须被拒绝：公开事件未知字段、重复保留字段、换行、URL、路径、自由文本、邮箱、Token、验证码、原始订单/支付标识、checkout URL、价格、精确权益到期时间、Bundle/Package 名称、BLE 名称和 `localizedDescription`。发送失败不得把私有记录标记为已上传。

## 自动化与人工边界

- 自动化可证明格式、字段白名单、加密写入、公钥闭锁、DSN 缺失和 Sentry 发送器调用边界。
- 2026-09-27 已在受控测试项目完成真实网络发送、控制台字段检查、私有事件成功确认、重复发送去重和内部工具解密测试；仓库 `.env` 仍保持 DSN 与公钥为空。
- 仍需在生产环境单独验收生产私钥保管/轮换，以及真实用户主动提供现场日志后的支持流程。
- 全量回归命令：

```bash
swift test --disable-keychain
swift build --disable-keychain
git diff --check
```
