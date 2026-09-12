# 连接页出现无法删除的幽灵遥控器卡片

- 时间：2026-09-05
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：附近存在其他小米遥控设备（或同一只遥控器出现第二个 BLE 身份）的用户
- 功能点：BLE 连接回调向 `remoteDeviceProfiles` 落盘设备档案
- 简单描述：连接页出现两张遥控器卡片，一张是真实遥控器，另一张永久显示为「小米遥控器」且无型号无电量。界面没有删除设备的入口，该卡片无法清除。

## 复现与现场证据

该缺陷来自我在长期日常使用中的真实现场（运行当时基于上游 v1.8.25 的构建）：连接页出现两张卡片，「小米蓝牙遥控器 2」（真实遥控器，打勾选中）与「小米遥控器」（永久存在，电量显示 `—`）。

存储（`defaults export com.hd838a.RemoteMic` → `remoteDeviceProfiles`）确认是两条持久化档案而不是渲染重复：真实档案 `model=rc001`、已绑定 HID 指纹；幽灵档案 `model=unknown`、无指纹。显示名来自 `profile.displayNameFallbackKey`，`remote.device.model.unknown` 在中文串表中就是「小米遥控器」，所以第二张卡片是**型号未知**的档案。

运行日志中除真实遥控器外只出现过一个第二设备，广播名 `MI RC`（在 `XiaomiVoiceRemoteNameMatcher.approvedNames` 白名单内，所以常驻发现桥会主动连它）：两次 `BLE CONNECTED name=MI RC`，各约 9 秒后断开，**没有任何一条 `BLE READY name=MI RC`**。

真实遥控器的正常连接次序确认了关键时序——电量和型号都在 `BLE READY` **之前**到达：

```text
01:44:54Z BLE CONNECTED name=小米蓝牙语音遥控器
01:44:54Z BLE BATTERY level=73
01:44:54Z BLE MODEL identified=rc001
01:44:54Z BLE READY name=小米蓝牙语音遥控器
```

## 根因

落盘入口不止 `.ready` 一处。`remoteProfileID(for:)`（`BridgeAppModel.swift`）原本是：

```swift
return settings.profileID(forBluetoothIdentifier: identifier)
    ?? settings.registerBluetoothRemote(identifier: identifier)
```

即「查不到就建」。它的三个调用方是 `didUpdateBatteryLevel`、`didIdentifyRemoteModel`、`didUpdatePowerState` 三个纯读数回调，而上面的日志证明这些读数**先于** `.ready` 到达。于是任何通过名称白名单、连上并回答了一次电量读取的外设都会立刻留下一条持久化档案，之后即使 ATVV 握手从未完成、连接就此断开，档案也已经写进 `UserDefaults`。

由于型号只在 `didIdentifyRemoteModel` 写入，这类档案通常停在 `model = .unknown`，界面就退回「小米遥控器」这个兜底名。

放大后果的两点：

- `registerBluetoothRemote` 只在存在「未绑定且型号未知」的空档案时复用槽位；真实遥控器早已占用该槽位，因此幽灵一定是新增一张卡片。
- 全仓没有任何 remove / delete / forget 设备档案的实现，所以这张卡片一旦产生就无法从界面清除。点击它还会通过 `selectRemoteProfile` 把当前映射切到那份空配置，看起来像设置丢失。

## 修复

只保留一个落盘入口，并保证不因此丢读数。

- `remoteProfileID(for:)` 改为纯查询，不再创建。
- 三个读数回调在档案尚不存在时，把值按 **peripheral identifier** 暂存进 `pendingRemoteBatteryLevels` / `pendingRemotePowerStates` / `pendingRemoteModels`。
- `registerBluetoothBridgeIfNeeded` 成为唯一创建点（由 `didChange` 的 `.ready` 分支与语音开始的 `activateRemoteProfile` 进入），落盘后立即调用新增的 `applyPendingRemoteTelemetry` 把暂存值补进 `remoteBatteryLevels` / `remotePowerStates` / `updateRemoteProfileModel`。
- 暂存表在桥离开就绪状态时（`didChange` 的非 `.ready` 分支）连同现存值一并清空；读数回调收到 `nil`（读取失败）时直接把对应键删除，而不是保留上一次成功值。

`.ready` 由能力协商确认后设置，前置条件是 ATVV 能力被接受，因此它等价于「这确实是一只小米语音遥控器」。清空时机不可能吃掉正在建立的连接的读数：`.discovering` 早在 `didConnect` 就已赋值，所有特征读取必然晚于它；`state` 的 `didSet` 有变化去重，同值再赋值不会再次通知委托。

未放宽名称白名单，未改动 `registerBluetoothRemote` 的槽位复用语义，未新增删除设备的能力（现存的幽灵卡片不在本次修复范围内）。

## 次生缺陷（暂存机制引入、已随本修复关闭）

暂存机制本身制造了一条过期数据回放路径：某外设上报电量 4%、握手失败、断开；数小时后同一外设握手成功而这次电量读取失败（`didUpdateBatteryLevel(nil)`）。「清空 + `nil` 作废」两项共同关闭该路径，并各有一项测试与反向验证。

## 已知并接受的代价

- 真实遥控器若连上但 ATVV 初始化失败，现在完全不出卡片（此前会出一张型号未知的卡片）。连接状态仍由 `connectionStatus` 反映。
- 常驻发现桥的排除集合只包含 `bluetoothBridges` 的键，修复前幽灵档案会在下次启动时获得独立桥、从发现桥候选中「退休」；修复后幽灵不再落盘，发现桥可能反复挑中它、初始化失败、重连。**这不是锁死**：`finishAttempt` 会 `resetPeripheral()` 后重新走连接循环，真实新遥控器仍可能在后续扫描中被选中，代价是首次配对可能变慢。真实失败率未测量，因此**刻意不加**失败身份退避——在没有真机数据前，激进的退避会把偶发初始化超时的真实遥控器锁在当次会话之外，比本代价更严重。

## 验证

三项反向验证（撤掉对应修复则只有对应测试变红）：

| 撤掉的修复 | 变红的测试 | 失败信息 |
| --- | --- | --- |
| `remoteProfileID(for:)` 改回「查不到就建」 | 幽灵路径 + 正向对照 | `remoteDeviceProfiles.count → 2` |
| 非就绪分支不清空暂存表 | 过期回放 | `batteryLevel → 4`、`model → .rc001` |
| 电量暂存重新加 `let level` 守卫 | 读取失败作废 | `batteryLevel → 73` |

修复后：

- `swift test` 全量通过，新增 `Tests/RemoteMicTests/RemoteProfilePersistenceTests.swift` 四项：
  - 幽灵路径：先占满唯一空槽位，外设依次上报电量、电源、型号后进入 `.failed`，档案数必须仍为 1 且该身份查不到档案；
  - 正向对照：同样次序的读数之后进入 `.ready`，档案必须新增，且电量/电源/型号都是握手前读到的值（缺少这项，「永不落盘」也能通过第一项）；
  - 过期回放：读数 → `.failed` → 之后才 `.ready`，三项都必须为空；
  - 读取失败作废：先读到 73，再收到 `nil`，`.ready` 后必须为空。
- `scripts/test.sh`、`scripts/check-repository-boundaries.sh` 通过。

## 自动化与真机边界

单元测试驱动的是 `BridgeAppModel` 的委托回调，`XiaomiBluetoothBridge` 由注入 `targetIdentifier` 构造，**没有真实 CoreBluetooth**。以下均未验证：

- 真实 `MI RC` 类设备在附近时确实不再新增卡片；
- 全新 RC001/RC003 首次连接后卡片上的型号与电量正确显示（本次改动最主要的回归风险）；
- 真实遥控器在电量读数与 `.ready` 之间断连重连时的表现；
- 发现桥反复挑中失败外设对真实新遥控器首次配对的实际影响时长；
- 现存幽灵档案不受本修复影响，仍会显示。

另一处自动化缺口：测试中外设身份来自注入的 `targetIdentifier`；现场幽灵来自发现桥通过 `peripheral.identifier` 解析身份。身份解析之后的路径完全相同，但「发现桥解析身份」这一段本身未被测试覆盖，需要给 `XiaomiBluetoothBridge` 增加测试注入点，本次未加。

真机验收按 [`Testing/GhostRemoteProfileGate.md`](../Testing/GhostRemoteProfileGate.md) 执行，完成前不得认为本 Bug 关闭。
