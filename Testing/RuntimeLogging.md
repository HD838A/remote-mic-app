# 运行日志运维验收

## 适用范围

- 分支：`codex/improve-runtime-log-quality-20260824`；合入版本以目标 `main` 为准
- 功能：`runtime.log` 实例元数据、单行格式、可恢复轮转、错误字段、音频日志降噪与验收日志收集

## 测试前准备

1. 退出其他无线麦SayAll.app 实例，记录待测 App 的短版本、Build 和自身 PID。
2. 打开 `~/Library/Logs/RemoteMic/`，保留现有文件，不清空、不覆盖，也不永久删除用户日志。
3. 准备 MiRemoteV 2ch 或 BlackHole 2ch；真实 BLE 项准备 RC001 / RC003。
4. 小阈值轮转由 `AppLoggerTests` 在独立临时目录执行，不为测试而扩大或破坏用户的正式日志。
5. 执行 `swift test` 前后检查用户日志没有来自测试 runner 的新增行；测试中的显式 logger 只使用临时路径。

## 用例 1：逐行实例元数据与单行格式

1. 启动 App，触发设置切换、测试音和一次遥控器状态变化。
2. 检查新写入的每一行。
3. 运行 `swift test --filter AppLoggerTests` 的控制字符用例。

预期：每行以 UTC 毫秒时间开头，随后为 `pid=<SayAll PID> ver=<短版本> build=<Build>`；同一进程三项值稳定。单个事件不跨行，不包含 NUL、Tab 或其他控制字符，文件可作为 UTF-8 读取。

失败判定：普通行缺少任一元数据、记录外部输入事件来源 PID，或一个事件破坏为多行/非法 UTF-8。

## 用例 2：大小轮转与可恢复退休

1. 运行 `swift test --filter AppLoggerTests`，使用 1-byte 阈值连续写入 5 条事件。
2. 同一临时路径使用两个 logger 并发追加 1,000 条带中文的事件。
3. 检查临时目录中的当前文件、`.1`～`.3`、隐藏 lock 文件和 retirement handler 保存的旧归档。
4. 在 Finder 废纸篓中确认生产默认 retirement 使用可恢复移动；不得出现永久删除命令或直接截断旧文件。

预期：当前文件是最新事件，`.1`～`.3` 按新到旧排列，第 5 次轮转淘汰的最旧文件仍可恢复。两个 logger 的 1,000 条消息全部存在、每行完整且可解码为 UTF-8。retirement 或移动失败时保留数据，当前日志可以继续追加。

失败判定：出现 `.4`、归档顺序颠倒、旧文件被永久删除/截断/覆盖，或轮转失败导致后续日志完全停止。

## 用例 3：机器错误字段与 BLE 电源状态

1. 用自动化构造带本地化说明的 NSError。
2. 断网触发一次更新检查失败。
3. 连接支持电池状态的遥控器，等待一次电源状态读取。

预期：机器错误使用成对的 `*_domain=<稳定域> *_code=<数字>` 字段；单个错误为 `error_domain/error_code`，同一事件有多个错误时使用 `seize_error_domain/seize_error_code` 等稳定上下文前缀。用户界面仍显示可读提示。BLE 行使用 `state=on_battery|external_power|charging|unknown|unavailable`。

失败判定：日志出现系统语言相关错误句子、只有 `error=<数字>` / `seize_error=<数字>` 而没有对应 domain/code、未转义空格、`Optional(` 或 Swift 模块名。

## 用例 4：音频恢复与空释放降噪

1. 连续改变系统音频路由，触发多次一秒防抖恢复通知。
2. 观察防抖窗口后的恢复日志。
3. 在音频引擎、播放器、所选设备和待播放缓冲都为空时，重复触发释放入口。
4. 再执行一次真实测试音或语音并结束。

预期：连续通知只产生最终一组 `AUDIO RECOVERY begin/completed`，begin 带 `coalesced_events=<数量>`；全空状态不写重复 `AUDIO RELEASE requested/completed`；存在实际资源或缓冲时仍完成排空和释放。

失败判定：仍为每个被替换任务记录 `scheduled`、全空状态继续刷释放日志，或真实音频资源无法释放。

## 用例 5：验收脚本跨轮转收集

1. 执行 `scripts/voice-acceptance.sh prepare`，记录 session 路径。
2. 核对 session 内的 `start-log-id`、`start-log-offset` 和 `runtime-cursors.log` 已记录 device、inode 与 byte offset。
3. 在会话开始后先写入一条标记，再让起始日志轮转到 `.1`，在新当前日志写入第二条标记，然后执行 `snapshot`。
4. 核对 session 内的 `runtime.log` 按顺序只包含开始 offset 之后的两条标记；再次 `snapshot` 不应重复已有内容。
5. 同时启动两个 `snapshot`，确认 session 排他锁让它们串行提交且不重复日志。
6. 在隔离夹具设置 `VOICE_ACCEPTANCE_TEST_FAILPOINT=after_runtime_append`，模拟“内容已追加、游标尚未提交”后中断；取消 failpoint 再次执行，确认 pending 事务被恢复且内容不重复。
7. 将 `VOICE_ACCEPTANCE_LOG_COMMAND` 指向失败命令，确认本次命令非零退出、此前 `unified-*` 证据仍保留，并在 `unified-failures.log` 记录失败文件。
8. 使用隔离夹具连续轮转四次，使游标 inode 超出 `.3` 留存范围，再执行 `snapshot`。

预期：脚本从记录的 inode/offset 开始，按 `.3`、`.2`、`.1`、当前文件的时间顺序追加新内容，保留轮转前后的本会话事件，不混入 offset 之前的行，也不重复此前已收集内容。并发调用由 session 锁串行化；中断事务可恢复；每次 unified log 使用唯一文件并写入 `unified-snapshots.log`。起始 inode 已不在留存范围时命令非零退出并明确报告 `is no longer retained; snapshot aborted`。

失败判定：轮转前事件丢失、同一归档重复收集、开始 offset 之前日志混入、并发/中断导致重复、unified log 失败覆盖旧证据，或找不到起始 inode 时仍返回成功。

## 稳定功能回归

- RC003 普通 `STREAM_START → AUDIO → STREAM_STOP`、Nearby iPhone、Watch 和 Web 语音保持正常。
- 测试音可播放并完成；系统睡眠/唤醒后的音频释放与恢复不变。
- 设置页和菜单栏“显示日志”仍打开同一日志目录。
- App 不记录音频内容、输入文字、Token、设备 UUID、前台 App 或外部事件来源 PID。

## 日志收集与验证边界

- 提交问题时优先提供 `scripts/voice-acceptance.sh` 输出的 session 路径及命令最后打印的具体 `unified-*` 文件；手工收集时提供准确 UTC 时间，并同时保留当前 `runtime.log` 与存在的 `.1`～`.3`。
- 自动化只证明格式、轮转和策略；真实 CoreAudio 路由风暴、CoreBluetooth 错误、废纸篓权限与多天留存仍需签名候选包验收。
