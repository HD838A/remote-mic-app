# 加密诊断日志与 Sentry 验收

## 适用范围

验证本地加密日志、公钥缺失闭锁、内部解密边界和用户主动 Sentry 上传。仓库 `.env` 与公开开发构建继续保持 DSN 为空；真实网络发送只在注入受控测试 DSN 的本机测试包中执行。2026-09-27 已完成一次受控 Sentry 控制台验收，生产构建仍不得从仓库读取 DSN 或私钥。

## 设计不变量

1. App 每次启动创建独立 `.rmlog` session 文件，正文使用 AES-GCM 加密。
2. 文件密钥只存在于当前进程内存，并由构建公钥包裹；解密私钥不在 App、本地 `.env` 或公开仓库中。
3. Sentry 不读取 `.rmlog`，不解密本地日志，不上传整份日志。
4. 未点击发送时不初始化 Sentry、不产生网络请求。
5. 当前批准的公开事件是环境、权限、连接、音频配置、语音会话和 Onboarding 语音测试；语音会话覆盖小米、苹果遥控器、Chromecast、iPhone、Apple Watch 和 Web 来源的开始、拒绝、结束/失败时序，并携带聚合音频完整性指标。
6. 可选私有模块只能通过独立 provider 提供类型化 `PRIVATE_EVENT`；公开宿主不读取私有原始日志或维护私有业务事件目录。私有记录最多保留 256 条、默认 7 天、跨重启持久化，只有发送成功后才按记录 ID 标记已上传。
7. 不上传用户内容、账号身份、邮箱、Token、验证码、原始订单/支付标识、checkout URL、价格、精确权益到期时间、路径、设备身份、第三方 App 私有状态或凭据。允许上传不关联身份的稳定业务阶段、粗粒度状态、原因码和短生命周期关联号。

## 测试前准备

- 使用最新分支构建；所有 SwiftPM 命令加 `--disable-keychain`。
- 保留用户日志目录原有内容，不清空、不覆盖、不永久删除。
- 单元测试使用临时目录和进程内生成的测试私钥；不使用真实生产日志。
- 检查根目录 `.env` 中 `REMOTE_MIC_SENTRY_DSN=` 与 `SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64=` 均为空。

## 用例 A：加密文件

1. 启动注入测试公钥的 App，触发设置切换、音频操作和一条类型化环境事件。
2. 查看 `~/Library/Logs/RemoteMic/` 新文件，确认文件名形如 `sayall.app-YYYY-MM-DD-session-XXXXXXXX.rmlog`。
3. 用 `file`、十六进制查看器或文本编辑器检查文件正文。

预期：文件以 `RMLG2` 开头，正文不能直接读出事件正文、输入文字或用户语音；目录权限为 `0700`，文件权限为 `0600`。重启后生成新 session 文件，旧文件不被覆盖。

## 用例 B：公钥缺失

1. 移除环境变量和 Bundle 中的诊断公钥。
2. 启动 App 并触发普通日志。

预期：不创建明文日志，不把失败原因写入日志正文；系统开发日志只允许出现 `encryption_public_key_missing` 等稳定原因。App 可继续运行。

## 用例 C：顺序与完整性

执行：

```bash
swift test --disable-keychain --filter AppLoggerTests
```

预期通过：

- AES-GCM 记录可由测试私钥按 session 头解包；
- `seq` 从零递增且解密顺序稳定；
- 控制字符和换行被归一化为单行；
- 诊断摘要保持 BEGIN、FIELD、END 顺序；
- 文件大小上限生效；
- 公钥缺失时没有明文回退。

## 用例 D：DSN 为空

执行：

```bash
swift test --disable-keychain --filter DiagnosticLogUploaderTests
```

预期：

- DSN 为空返回 `serviceNotConfigured`；
- 没有调用 sender；
- 不读取 `.rmlog`；
- 不初始化 Sentry；
- 不删除或修改本地日志。

## 用例 E：Sentry 白名单过滤

仅在受控测试 DSN 可用时执行，禁止使用生产账号和真实用户数据。

1. 准备一个批准的环境事件、一个批准的语音会话事件、一个可选私有 provider 的安全记录和一个未批准的公开事件。
2. 触发上传。
3. 检查 Sentry 测试项目中收到的日志正文和属性。

预期只收到批准的 `PUBLIC_EVENT` 环境/语音事件和通过独立 schema 校验的 `PRIVATE_EVENT`。公开正文字段必须来自白名单；私有记录只允许通用信封和最多 32 个单行 token 属性。应用写入的自定义属性只允许 `diagnostic.user_initiated=true`、`diagnostic.schema_version=1` 和非负的 `diagnostic.sequence`；Sentry 平台仍可附加时间、severity、trace、payload size 和 SDK 版本等非用户元数据。同一个 `operation_id` 的 started/completed（或 failed/rejected）事件应能还原一次语音会话，并可按 `source` 与 `remote_model_family` 区分硬件或移动来源。

下面的内容必须被拒绝或永不生成：

- `PUBLIC_EVENT` 的未知字段、任意记录的重复保留字段、换行、空格值、URL、路径和自由文本；
- 邮箱、Token、Cookie、验证码、原始订单/支付标识、checkout URL、价格和精确权益到期时间；
- Bundle ID、Package 名称/路径、BLE 名称/MAC、CoreAudio UID、主机名/IP；
- `localizedDescription`、用户输入、语音转写和音频数据；
- Sentry User、Tags、Contexts、附件、崩溃、Session、性能、网络和 Breadcrumb。

## 用例 F：失败与恢复

1. 在 DSN 为空、事件为空、DSN 格式非法和 sender 抛错四种状态下触发上传。
2. 在 Sentry 受控测试环境断网后重试。
3. 使用 fake 私有 provider 检查待发送记录的读取次数和已上传标记。
4. 检查本地日志目录。

预期：界面只显示“未配置”“没有安全诊断事件”或“发送失败”等普通用户可理解的状态；DSN 缺失时不读取私有 provider；发送失败或记录被拒绝时不标记已上传；成功时只标记真正发送的记录 ID；失败不删除本地 `.rmlog`，重复点击不会并发启动多个上传。

## 用例 G：私有事件跨重启与上限

在包含私有 Package 的受控构建中执行：

1. 产生登录、绑定、订单、Checkout、订单轮询和权益刷新等安全业务事件后退出 App。
2. 重新启动，确认 provider 仍能读取未上传记录。
3. 模拟超过 7 天和超过 256 条的记录，再次读取。
4. 模拟一次发送失败，再模拟一次发送成功。

预期：跨重启只保留未上传且未过期的记录；容量保持 256 条；失败后记录仍在；成功后仅对应记录 ID 被标记。Sentry 正文可以看到稳定业务阶段、粗粒度状态、原因码、重试和耗时，但不能看到身份、真实订单/支付对象、URL、价格或错误正文。

## 证据与边界

- 自动化证据：`AppLoggerTests`、`DiagnosticLogUploaderTests`、私有 Package 事件存储测试、全量 `swift test --disable-keychain` 和 `swift build --disable-keychain`。
- 内部工具证据：受控私钥可以读取测试 `.rmlog`；公开 App 不含私钥。内部工具以 `0600` 原子创建明文，拒绝覆盖已有文件和符号链接。
- 2026-09-27 受控 E2E：测试 App 首轮主动发送 20 条安全诊断事件，其中 8 条为跨重启保留的类型化私有事件；发送成功后 pending 归零，再次发送显示没有可发送事件。Sentry 查询确认 `email=`、`token=`、`order_id=`、`payment_id=`、`checkout_url=`、`bundle=`、`/Users/`、`package_path=` 和 `device.name=` 均为零命中，展开事件没有 Sentry User。项目端 Data Scrubber、Default Scrubbers 和“禁止存储 IP”均已开启；开关保存后发送的新合成事件同样没有 IP 字段或 Sentry User。
- 本地文件证据：目录权限为 `0700`、文件权限为 `0600`、头部为 `RMLG2\n`，`strings` 无法读出事件正文；内部工具成功按顺序解密，明文验收文件随后移入废纸篓。
- 尚未完成：生产私钥的正式保管、备份与轮换，以及真实用户主动提供现场 `.rmlog` 后的受控支持流程验收。真实日志或密钥不得提交仓库。
