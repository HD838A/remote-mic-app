# 运行日志缺少实例归属、轮转与有效降噪

- 时间：2026-08-24
- 状态：候选修复完成；自动化、事务故障夹具、Release 构建与 App 校验通过，长时间运行和真实 BLE / CoreAudio 事件仍需验收
- 影响范围：macOS 无线麦SayAll.app 的 `~/Library/Logs/RemoteMic/runtime.log`
- 功能点：运行日志、音频恢复与释放、BLE/系统错误诊断、语音验收日志收集
- 简单描述：日志无法逐行区分进程和构建、文件无大小边界，且被防抖掉的任务和无实际资源的音频释放仍大量写日志。
- 原始记录：安全审计现场快照、当前保留的 `runtime.log.1`、最新 `main` 源码

## 复现与日志证据

安全审计阶段保留的完整现场快照约 25,112,345 bytes、200,108 行；按独立字符串匹配计数，其中 `APP START` 144 次、`AUDIO RECOVERY scheduled` 133 次、`replaced_pending=true` 78 次、`AUDIO RELEASE requested` 3,517 次、`AUDIO RELEASE completed` 36,831 次，这些数量不表示事件一一配对。每行只有时间戳和消息，版本只出现在少量 `APP START` 行，没有 PID 和 Build，两个版本重叠运行时无法直接拆分时间线。

当前日志目录之后被本机其他候选构建轮转，不能再冒充上述完整快照。仍保留的 5,242,880-byte `runtime.log.1` 切片有 38,487 行，其中：

- `AUDIO RECOVERY scheduled` 27 次，18 次明确为 `replaced_pending=true`；
- `AUDIO RELEASE requested` 3,486 次，`completed` 3,529 次；
- `BLE POWER state=Optional(...)` 10 次；
- 至少 2 条更新错误把本地化中文错误文本直接写进 `error=`；
- `iconv -f UTF-8 -t UTF-8` 无法完整读取该归档，说明历史多实例交错写入已经留下非法 UTF-8 字节。

当前活动 `runtime.log` 由一个未合入的本地日志草稿写入，已经带 `pid=`，因此只用于确认目录状态，不作为最新 `main` 已修复的证据。最新 `main` 的 `AppLogger` 源码仍是单文件无界追加。

正常边界是：每行可直接归属到一个 SayAll 进程和构建；消息保持单行有效 UTF-8；日志总量有界且淘汰文件可恢复；防抖日志只对应实际执行；没有输出资源或待播放缓冲时不制造释放噪声；机器错误字段不随系统语言变化。

## 日志与代码结论

- `AppLogger` 没有 PID、版本、Build、大小检查、轮转、消息规范化或定向测试，写入失败也完全静默。
- `BridgeAppModel.scheduleAudioRecovery` 每次替换一秒防抖任务时都立即记录 `scheduled`，业务只执行最后一次，但日志保留全部被取消任务。
- `releaseVirtualAudioOutputIfUnused` 在引擎、播放器、所选设备和待播放缓冲都为空时仍调用排空与停止，形成大量空 `requested/completed`。
- 更新检查、App 打开、音频和 BLE 日志直接拼接 `localizedDescription`；`BLE POWER` 直接插值 Optional，破坏稳定的 key=value 机器格式。
- `scripts/voice-acceptance.sh` 只记当前文件起始行号；会话中一旦轮转，快照会丢失轮转前的日志。

## 根因

文件日志最初只承担开发期追加输出，没有建立生产运维的实例身份、格式、留存和频率边界。后续各模块直接拼接错误文本和生命周期事件，业务防抖、资源状态与日志边界逐渐分离；历史上两个实例同时写同一文件又放大了编码破坏与时间线混杂。

## 修复

- 每行在 UTC 时间后增加无线麦自身 `pid`、短版本和 Build；元数据值编码为单个稳定 token。消息中的换行和控制字符规范为单行有效 UTF-8。
- `swift test` / XCTest 进程默认禁用共享用户日志；显式 `AppLogger` 测试实例只写各自的临时目录。
- `runtime.log` 达到 10 MiB 时滚动为 `.1`，最多保留 `.1`～`.3`。大小检查、轮转和追加由固定隐藏锁文件串行化，日志文件使用 `O_APPEND` 写入完整 UTF-8 行。最旧归档只通过 macOS Trash 退休，失败时保留原文件并继续追加，绝不永久删除、截断或覆盖旧日志。
- 文件写入或轮转自身失败只向统一日志的 `AppLogger` category 写一条稳定错误，不输出用户路径或内容。
- 机器错误统一为成对的 `*_domain/*_code` 稳定字段；单个错误使用 `error_domain/error_code`，同一事件有多个错误时使用稳定上下文前缀。用户界面继续显示原有本地化说明，不改变用户提示。
- 音频恢复只在最终防抖任务执行时记录 begin/completed，并记录 `coalesced_events`；音频释放在没有资源和缓冲时直接返回。
- BLE 电源状态使用 `on_battery|external_power|charging|unknown|unavailable`，不再输出 Optional 或 Swift 模块名。
- 语音验收脚本在 `prepare` 记录当前日志的 device、inode 和 byte offset；后续按该 inode 在 `.3`～当前文件中续读。每个 session 使用固定锁文件与 macOS `lockf` 内核排他锁，以及可恢复的 pending/committed 事务；进程在“追加后、游标前”中断或游标写入失败后再次执行也不会重复收集。起始 inode 超出留存范围时明确失败，不再用时间过滤静默漏日志。
- macOS unified log 每次写入唯一、不可变的快照文件并记录清单；查询失败会返回非零并保留此前证据，不再截断固定 `unified.log` 或隐藏失败。

## 验证结果

- `swift test`：363/363 通过，包括 `AppLoggerTests` 7/7、音频恢复计数、空释放策略和 BLE 电源稳定值。
- `./scripts/test.sh`：42/42 通过。
- `zsh -n scripts/voice-acceptance.sh` 与 `git diff --check`：通过。
- 隔离日志夹具：起始 inode 轮转到 `.1` 后连续收集通过；两个并发 snapshot 均成功且新增行只出现一次；“追加后、游标前”故障返回 99 后恢复不重复；游标文件临时不可写时保留 pending，恢复权限后不重复；unified log 失败保留旧证据；起始 inode 超出 `.3` 后明确失败。
- `PATH="$PWD/.build/safe-build-tools:$PATH" ./scripts/build-app.sh`：Apple Silicon Release App 构建通过；安全保护器确认构建没有删除任何已存在目标。
- `./scripts/verify-app.sh dist/SayAll.app`：`APP VERIFY PASS`，本地 ad-hoc 签名构建验证通过。

## 验证边界

自动化可以证明元数据、单行规范化、可恢复轮转顺序、错误字段、恢复计数和释放策略，但不能制造真实 CoreAudio 路由风暴、真实 CoreBluetooth 错误、多天日志增长或证明候选 App 的 Trash 权限。签名候选包仍需按 `Testing/RuntimeLogging.md` 完成长时间运行、真实语音、系统蓝牙和音频路由验收。
