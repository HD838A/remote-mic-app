# BLE 重连在缓存直连被绕过后退化为「只扫描」，卡死到用户手动重连

- 时间：2026-10-11
- 状态：候选修复与定向自动化通过；等待真实 RC003 现场复验
- 影响范围：macOS `1.9.21 (174)`（`main` 同逻辑），小米蓝牙遥控器 2 Pro（rc003）等已保存 profile 的 BLE 语音链路
- 功能点：CoreBluetooth 断线重连、扫描恢复、ATVV 语音链路
- 简单描述：链路断开后若第一次自动重连失败，桥会永久停用「按已保存 UUID 直连」，只保留广播扫描；而仍处于系统连接态的遥控器不再广播，扫描永远命中不了；扫描又没有窗口，attempt 永不结束，重连循环静默终止，只能靠用户点「立即重新连接」。
- 原始记录：本机 `~/Library/Logs/RemoteMic/runtime.log`（2026-10-02 09:02Z 起，32 200 行）、`main` 提交 `aa9f3ce`、Issue #438

## 现场证据（本机日志，非模拟）

9 天内 11 次 `BLE DISCONNECTED`（全部 `error_domain=CBErrorDomain error_code=6`，即连接超时）。其中 3 次没有自行恢复：

| 掉线时刻（UTC） | 卡住时长 | 恢复方式 |
| --- | --- | --- |
| 2026-10-06 11:28:57 | 75 分 41 秒 | 手动 → `source=target_identifier` |
| 2026-10-11 03:26:17 | 16 分 51 秒 | 手动 → `source=target_identifier` |
| 2026-10-11 03:19:38 | 2 分 14 秒 | 手动 |

2026-10-11 现场（本地时间 11:26）：

```text
03:26:17 BLE DISCONNECTED phase=ready(22) error_domain=CBErrorDomain error_code=6
03:26:17 BLE RECONNECT scheduled failure_count=1 delay_ms=2968 cached_identifier_bypassed=false
03:26:20 BLE CENTRAL state=5 lifecycle=scanning(23) generation=23
03:26:20 BLE CONNECTING source=target_identifier name=小米蓝牙语音遥控器
03:26:22 BLE CONNECTED name=小米蓝牙语音遥控器
03:26:24 BLE DISCONNECTED phase=discovering(23) error_domain=CBErrorDomain error_code=6
03:26:24 BLE RECONNECT scheduled failure_count=2 delay_ms=5497 cached_identifier_bypassed=true
03:26:29 BLE CENTRAL state=5 lifecycle=scanning(24) generation=24
03:26:29 BLE SCANNING                    ← 此后 16 分 45 秒没有任何 BLE 事件
03:43:14 BLE CENTRAL state=5 lifecycle=scanning(25) generation=25
03:43:14 BLE CONNECTING source=target_identifier name=小米蓝牙语音遥控器
03:43:14 BLE CONNECTED                     ← 24 ms 连上
```

- 静默期内 `HID REPORT accepted` 仍在持续：按键走独立 HID 链路，遥控器就在旁边、电量 81%，**不是**「设备不在场」。
- 恢复动作来自用户手动「立即重新连接」（`reconnectNow()` → `reconnectPolicy.reset()`），因此 generation 25 才重新走回 `source=target_identifier`；24 ms 的连接耗时说明该外设**一直处于系统连接态**。
- 静默期内没有 `BLE RECONNECT scheduled`：说明退避循环已经不再产生下一次尝试，而不是「重试了但失败」。

对照组（同机日志）：

- 2026-10-06 07:38:42 掉线，15 秒后由 `source=scan` 自行恢复 → 该次遥控器确实在广播。
- 2026-10-11 03:50–05:30 健康运行 100 分钟 → 全程 `BLE READY`，无重连事件。

## 代码根因

1. **缓存直连被永久禁用**：`BluetoothReconnectPolicy.allowsCachedTargetRetrieval` 在首次「连接中/发现中」失败后置为 `false`（`BluetoothLifecycle.swift:255`，PR #182 的刻意设计），此后只有 `start()` / `stop()` / `reconnectNow()` / 真正 Ready 才会重置（`XiaomiBluetoothBridge.swift:233/248/273/898`）。自动重连路径没有任何恢复入口。
2. **系统已连接候选只在没有已保存身份时查询**：`discoverOrScan` 中 `retrieveConnectedPeripherals(withServices:)` 被 `if targetIdentifier == nil` 挡住（旧 `XiaomiBluetoothBridge.swift:472`）。用户机器上有已保存 profile，所以这条唯一能发现「系统已连接但不广播」设备的路永远不走。
3. **扫描没有窗口**：`scanForPeripherals` 之后没有任何超时。广播扫描不会因为「找不到」回调，于是 attempt 永远停在 `.scanning`：`finishAttempt` 不再执行，退避计数不再增长，日志里也不会再出现 `BLE RECONNECT scheduled`。

三者叠加 = 「第一次重连失败后必然需要人工介入」，与用户反馈「偶尔掉线，要手动点重新连接」完全一致。

## 假设与否证

- H1「遥控器离线/没电」：否证——静默期内 HID 按键事件持续，电量 81%，手动重连 24 ms 成功。
- H2「用户手动点重连只是心理作用，实际会自动恢复」：否证——两次静默分别 16 分 51 秒和 75 分 41 秒，且其间零 BLE 事件。
- H3「扫描仍在进行只是没命中」：部分成立（确实在 scanning），但因为没有窗口，它永远不会结束 attempt，等价于循环终止；这是根因之一而非解释。

## 最小修复

1. `VoiceRemoteDiscoveryPolicy.shouldQuerySystemConnectedCandidates(hasSavedTarget:allowsCachedTargetRetrieval:)`：缓存直连被禁用时，也查询系统当前已连接的 ATVV 候选。身份判定仍走 `VoiceRemoteAdmission.decide`，有已保存身份时非目标 UUID 一律 `.ignore`，不会误收别的遥控器。
2. `BluetoothScanRecoveryPolicy`：扫描窗口 20 秒；到期且仍停留在本轮 `.scanning` 时记录 `BLE SCAN TIMEOUT` 并调用 `scheduleReconnect()`，让退避循环继续推进（不改变退避语义，也不重置缓存绕过状态）。
3. 窗口在 `resetPeripheral()` / `connect()` / `stop()` / 系统挂起时取消，避免旧 generation 的定时器误伤新 attempt。

明确不做：不改动退避时长与抖动、不删除或改写 profile 与按键映射、不改 ATVV 协议、不引入主动探测风暴（缓存绕过状态仍由既有策略控制）。

## 验证

- `swift test --disable-keychain --filter BluetoothLifecycleTests`：26 项通过，含新增 `systemConnectedCandidatesAreQueriedWhenTheSavedIdentityCannotBeUsedDirectly`、`scanWindowExpiresOnlyTheCurrentScanningAttempt`。
- `swift test --disable-keychain`：见本 PR 正文的完整结果。
- 脱敏日志验证：新增 `BLE SCAN TIMEOUT window_ms=` 只含窗口长度，不含设备标识、UUID 或用户内容。
- 外部对照（不改动本仓库）：同一现场日志上运行的独立看门狗回放，5 个历史窗口（2 个卡死、3 个健康/休眠）判定全部符合预期；`pkill + open` 恢复实测 2.54 秒回到 `BLE READY`。

## 验证边界

单元测试只能证明策略判定与状态机接线，不能驱动真实 `CBCentralManager`。以下仍需真实 RC003 现场验收：

- 掉线后第一次重连失败 → 后续周期是否在扫描窗口内通过系统已连接候选恢复；
- 遥控器真的离开房间（不广播、也不在系统连接态）时，循环是否按 20 秒窗口 + 退避继续、且不产生连接风暴；
- 睡眠唤醒、蓝牙关闭再开启后与 #356 / #438 / #522 的既有恢复路径不冲突。
