# 历史蓝牙缓存持续固定频率重连

- 时间：2026-08-24
- 状态：候选修复完成，等待真机验证
- 影响范围：macOS `1.9.8 (131)`；保存过多个 RC001 / RC003 profile，部分遥控器长期离线或 CoreBluetooth 缓存已失效的用户
- 功能点：CoreBluetooth 缓存重连、失败退避、多遥控器 profile
- 简单描述：失效的历史蓝牙 identifier 每约 11 秒发起一次连接，连续失败不会降频。
- 原始记录：本机 `~/Library/Logs/RemoteMic/runtime.log`、当前偏好中的 profile 数量、运行进程和 `main` 提交 `550b6e16b4bec57f3285b3cdd30000f2b9821704`

## 复现

1. 在同一个偏好域保留 3 个带蓝牙 identifier 的遥控器 profile。
2. 只让其中 1 个遥控器可用，另外 2 个历史设备保持离线或使其 CoreBluetooth 缓存不可连接。
3. 启动无线麦SayAll.app并持续观察运行日志。
4. 正常边界是在线遥控器进入 Ready；离线历史 profile 可以进行一次缓存探测，失败后应降频或回到被动扫描，不能持续主动连接。

现场只有一个 `/Applications/SayAll.app/Contents/MacOS/RemoteMic` 进程。`2026-08-23T18:00:30Z` 至 `18:08:08Z` 的日志中共有 82 条 `BLE CONNECTING source=target_identifier` 和 80 条 `BLE CONNECT TIMEOUT`；每个失效 profile 都重复执行“连接 8 秒超时 → 等待固定 3 秒 → 再次连接缓存 identifier”。稍后一次启动同样表现为一个 profile Ready，另外两个 profile 成对超时。

## 日志结论

- 固定的 8 秒连接超时与源码 `startConnectionTimeout` 一致。
- 每次超时后约 3 秒重新出现 `source=target_identifier`，与旧实现所有自动路径写死 `reconnectAfter: 3` 一致。
- 当前只有一个 App 进程，因此成对日志来自两个失效 profile 各自持有的 bridge，不是多实例重复写同一条日志。
- 在线遥控器仍可进入 `BLE READY` 并完成语音，说明问题边界是历史缓存 bridge 的恢复策略，不是蓝牙权限或全部遥控器失效。

## 假设

### H1：自动重连没有连续失败计数（根因之一）

- 支持：所有 timeout、connect failure、初始化 failure 和 disconnect 路径最终都使用固定 3 秒。
- 冲突：无。
- 实验：按日志时间线计算相邻周期，连续失败数十次仍保持约 11 秒完整周期，没有增长。

### H2：失效缓存会在每个周期重新触发主动连接（根因之一）

- 支持：`targetIdentifier` 是固定值；每个周期都优先调用 `retrievePeripherals(withIdentifiers:)`。多遥控器改造后，`scheduleReconnect(discardCachedIdentity:)` 参数不再改变任何状态。
- 冲突：清除持久 identifier 会破坏 profile 与按键映射，不能沿用单遥控器时期直接删除偏好的做法。
- 实验：偏好中 3 个蓝牙 profile 与“1 个 Ready、2 个缓存循环”的日志数量一致；源码中 `discardCachedIdentity` 已是无效参数。

### H3：两个 App 实例造成重复重连

- 支持：日志中的 timeout 经常成对出现。
- 冲突：现场进程检查只有一个 SayAll 实例；同一进程内存在 3 个目标 bridge。
- 实验：同时核对进程、profile 数量和 Ready/timeout 数量，否定多实例是本问题的必要条件。

## 根因

多遥控器 profile 改造保留了每个设备的固定 CoreBluetooth identifier，却移除了原来单设备模式下清除缓存的行为；失效 bridge 因此永远优先连接同一个缓存对象。所有自动恢复路径又共享固定 3 秒延迟且没有失败状态，形成无上限连接风暴。

## 修复

- 增加纯状态的 `BluetoothReconnectPolicy`：连续自动失败使用 3、6、12、24、48、60 秒的指数退避，加入可测试的 ±10% 抖动并封顶 60 秒；封顶档实际范围为 54～60 秒。
- 缓存直连的首次连接或初始化失败后，只在当前进程内禁止再次通过 `retrievePeripherals` 主动探测；bridge 转入现有扫描路径，并继续只接受原目标 UUID。
- 不删除或改写持久 profile、蓝牙 identifier、HID fingerprint 和按键映射。App 启动、停止、用户点击“立即重新连接”以及设备真正 Ready 时重置退避；手动操作仍可立即重新允许一次缓存探测。
- 自动 timeout、connect failure、初始化 failure 和 disconnect 都通过同一策略计算下一次延迟；预先计算的取消延迟在 CoreBluetooth 回调中复用，不重复累计失败次数。
- 外设状态在蓝牙断电、resetting 或新连接周期开始时会清除预计算延迟，避免旧的 48/60 秒等待跨越蓝牙恢复并污染下一次失败。
- 日志记录失败次数、实际延迟和是否绕过缓存，但不记录设备 UUID。

## 验证

已执行：

- `swift test --filter BluetoothLifecycleTests`
  - 覆盖退避序列、60 秒上限、确定性抖动、缓存绕过、reset 后从第一级重新开始，以及外设状态重置会清除预计算延迟。

仍需在全部修改完成后执行：

- `git diff --check`
- 完整相关测试与项目自检。

## 验证边界

纯策略与接线测试可以证明延迟计算、缓存状态和预计算延迟清理，但不能驱动真实 `CBCentralManager`、验证 macOS 是否继续返回已失效的 peripheral，或证明真实遥控器恢复广播后的连接时序。

合入或发布前仍需使用真实 RC001 / RC003 复验：一个在线 profile 加两个离线历史 profile持续至少 3 分钟；手动立即重连；离线设备恢复；睡眠唤醒；蓝牙关闭再开启；同一 profile 的名称、按键映射、普通按键以及第一次 `STREAM_START → AUDIO → STREAM_STOP` 保持正常。未完成这些步骤前不能表述为已经真机验收。
