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

## 用例 2：公钥缺失使用普通日志

1. 使用未注入 `SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64` 且 Bundle 没有 `SayAllDiagnosticPublicKey` 的本地包启动。
2. 触发普通日志和一次类型化环境事件。
3. 检查日志目录与系统开发日志。

预期：不创建 `.rmlog`；日志写入 `~/Library/Logs/RemoteMic/runtime.log`。普通日志仍只包含脱敏的稳定字段，目录权限为 `0700`、文件权限为 `0600`。系统开发日志最多记录 `encryption_public_key_missing` 等稳定原因。App 不崩溃，Sentry 仍不会因为缺少本地公钥而自动启动。

## 用例 3：内部包必须拒绝缺失或无效公钥

1. 不设置 `SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64`，以 `REQUIRE_DIAGNOSTIC_PUBLIC_KEY=1` 运行 `scripts/build-app.sh`。
2. 分别传入无效 Base64、解码后不是 32 字节的值，重复构建。
3. 使用有效的 32 字节 Curve25519 公钥完成构建，再以 `REQUIRE_DIAGNOSTIC_PUBLIC_KEY=1 scripts/verify-app.sh /path/to/SayAll.app` 验证最终 App。
4. 从最终 App 的 `Info.plist` 移除或损坏 `SayAllDiagnosticPublicKey`，确认最终验证失败。

预期：前三种无效输入都在签名和上传前失败；有效公钥被写入最终 `Info.plist` 且最终 App 验证通过；最终资产缺失或损坏该字段时不得继续作为内部测试包分发。验证输出不得打印公钥或对应私钥。

## 用例 4：顺序、控制字符和大小上限

运行：

```bash
swift test --disable-keychain --filter AppLoggerTests
```

预期测试覆盖：加密记录、普通日志回退、内部测试解密、`seq` 顺序、控制字符归一化、诊断摘要的 BEGIN/FIELD/END 顺序、文件大小上限和 XCTest 进程禁用共享日志。

失败判定：任何测试失败，或为了测试读取了生产用户文件。

## 用例 5：内部解密工具边界

1. 由受控支持环境取得与构建公钥对应的私钥，不将私钥复制到用户机器或公开仓库。
2. 使用内部工具解析 `RMLG2` 头、解包文件密钥，再按长度前缀和 `seq` 顺序解密 AES-GCM 记录。
3. 篡改一条记录或关联数据后再次解密。

预期：原文件可按时间和 `seq` 顺序读取；篡改记录验证失败并停止该记录，不把损坏内容当作成功日志。公开 App 只负责加密，不具备解密能力。

## 用例 6：普通日志隐私

触发权限、蓝牙、音频、输入工具和语音会话的成功、失败、取消、超时、重试与恢复路径，并由内部工具查看解密结果。

预期：只出现稳定分类、错误 domain/code、计数、样本数和耗时；不出现用户语音、文字、剪贴板、路径、窗口标题、BLE 地址/名称、CoreAudio UID、第三方 App 私有配置或凭据。`received`、`decoded`、`enqueued` 不得被记成最终成功。

## 用例 7：公开构建不包含私有诊断传输

确认公开仓库没有 Sentry 依赖、DSN 注入或私有 Package 路径：

```dotenv
SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64=
```

执行：

```bash
swift test --disable-keychain --filter DiagnosticLogUploaderTests
```

预期：公开构建返回 `serviceNotConfigured`，不调用私有传输、不初始化 Sentry、不读取本地 `.rmlog`，本地日志不被删除。

## 用例 8：Sentry 发送内容（需受控 DSN）

只有在私有 Package 和私有受控构建环境提供测试 DSN 后执行；不使用生产账号或真实用户数据。公开仓库本身不执行该用例。

1. 在安全事件存储中放入一个批准的环境快照、一个未批准的公开事件，以及可选私有 provider 的安全记录。
2. 点击“发送诊断信息”或调用上传器测试入口。
3. 在 Sentry 测试项目检查事件。

预期只产生批准的 `PUBLIC_EVENT` 和通过独立 schema 校验的 `PRIVATE_EVENT`。公开字段限于 `LOGGING.md` 白名单；公开事件跨重启测试见 [加密诊断验收用例 H](EncryptedDiagnosticLogs.md#用例-h公开事件跨重启与发送确认)；私有事件只包含通用信封、稳定业务阶段、粗粒度状态、原因码、重试、耗时和短生命周期关联号。无 User、Tags、Contexts、附件、崩溃、Session、性能、网络、Breadcrumb、IP、Bundle ID、路径、身份或真实业务对象标识。

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

## 用例 9：RC003 音频链路诊断与日志预算

适用范围：PR 653 的日志补全候选。蓝牙回调仍在主线程。原尾部缺失问题未修复。

自动化命令：

```bash
swift test --disable-keychain --disable-sandbox --filter ATVVAudioDiagnosticsTests
```

预期：接受和拒绝计数完整，停流后尾包进入唯一终态。配置或 Fn 缓冲未排程时，不得因播放器 pending 为零而宣称成功。输出超时与共享 generation 标为未知。诊断不发送协议命令，不 flush，不修改 Fn。

日志预算：新 ATVV 诊断每 10 秒最多一条 progress，每段最多 12 条 progress；started、first_pcm、stopping、completed 各最多一次。software_trigger 的 down/up 各最多一次；receive_stalled、receive_resumed 各最多一次。该模块每段最多 20 条；其他组件沿用既有事件行并补关联字段。20,000 个拒绝包及有效 PCM 包回放，各自总诊断文本小于 16 KB。含软件键、重复静默和恢复的完整 20,000 包回放小于 20 KB。上述数字不代表整个 App 的日志大小上限。

补充自动化预期：

- 不发送 STOP 且不再投递音频时，两秒观察器输出一次 receive_stalled，终态保持 pending。它不关闭麦克风、不松键、不清缓存。
- 回调恢复时输出一次 receive_resumed；再次停收只累计 silence_episodes。停止后观察器不继续写日志。
- 主线程观察任务迟到时，observation_max_lag_ms 记录该任务自身迟到。callback_wait_ms 与 transport_arrival 仍为 unknown。
- 软件键按会话关联 down/up。software_down_to_first_pcm_ms 和 software_up_to_last_playback_ms 使用单调时钟。后一个值为正，表示尾音播放晚于软件键提交。
- 按键提交失败后重试成功时，最终字段记录成功和失败次数，边沿日志不重复。始终标记 target_response=unknown。
- 配置缓冲上限 32,000 样本、Command 缓冲上限 8,000 样本沿用主线。超过上限时分别累计 buffer_configuration_overflow_samples 和 buffer_command_overflow_samples。
- 缓冲取消和配置失败分别计数。dropped_samples 必须包含这些损失；确认丢失时不得写 completion=normal。

真实环境步骤：

1. 使用真实 RC003 与目标语音工具，记录版本、Build 和测试时段。
2. 分别说短句、10 秒和 30 秒长句；正常松键后等候 10 秒。
3. 快速连续录制三段，核对每段首字和尾字。
4. 在录音中断开遥控器，再连接并录制一段。
5. 分别测试输出已就绪与冷启动配置、录音启用与禁用、Fn 模式启用与关闭，以及左右 Command 和 Right Option。
6. 使用现有诊断入口收集加密 rmlog，由内部支持环境按 seq 解密。

每步预期：用户行为与主线相同；每段可沿 operation_id 关联入口、拒绝、解码、路由、播放和录音结果。断连有异常原因，恢复使用新的关联号。正常结果只证明已收到的样本完整播放，外部工具结果仍须人工核对。

失败判定：逐音频包输出、同段多个终态、尾包丢弃未入账、缓冲被记为播放成功、下一段样本被计为上一段成功，或日志出现文字、音频、设备身份、路径和凭据。

未知边界：主线程回调前排队、无线到达、真实硬件按下和外部工具收音不可观察。Fn 只记录全局可见事件时间。现有公开转写捕获只记录 text_present，不记录正文，也不自动启用捕获。

2026-10-13 初版：定向 101 项 / 6 套及全量 857 项 / 67 套通过，构建通过。补充日志版：定向 99 项 / 5 套通过；本次全量 863 项 / 67 套和构建通过。本轮自动化覆盖上述账目与体积规则；真实设备、首字延迟、尾字完整、第三方工具文字和加密现场采集尚未验收。Bug 记录见 [RC003 诊断](../Bugs/2026-10-13-rc003-audio-delivery-rate-shortfall.md)。
