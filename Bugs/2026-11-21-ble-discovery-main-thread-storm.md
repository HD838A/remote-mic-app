# 连接页扫描逐设备写忽略日志导致主线程 BLE 风暴

- 时间：2026-11-21
- 状态：候选修复；自动化通过，真实 CoreBluetooth 环境、滚动帧率和多型号遥控器验收待完成
- 影响范围：macOS；2.0.8 及之后；周边 BLE 设备较多且打开连接页或保持连接页可见时
- 功能点：`XiaomiBluetoothBridge` 扫描回调、`VoiceRemoteAdmission`、连接页发现窗口

## 现场证据

用户提供 2.0.8 build 404 的加密 `.rmlog`。按受控流程解密后，单次会话从 10:27:41 到 13:32:59，共 6055 条记录。

同一批文件里的 `runtime.log*` 来自 1.9.21 build 174 的旧进程，不是 2.0.8。旧日志只用于版本对比，不用于归因 2.0.8。

2.0.8 会话中：

```text
BLE ADOPT IGNORED source=scan reason=no_voice_service
LOG REPEAT aggregation=discovery_observation repeat_count=...
```

- `BLE ADOPT IGNORED` 聚合重复量约 6.3 万次。
- 扫描窗口内实际重复率约 75–226 次/秒。
- 最大一组为 2,349 次 / 12.2 秒。
- `CBCentralManager` 的 delegate 队列是 `.main`。
- 连接页 `onAppear` 调用 `refreshRemoteDiscovery()`，随后出现 20 秒 `BLE DISCOVERY_WINDOW`。
- 用户反馈同一时段设置页滚动卡顿，日志显示设置窗口打开时正好进入发现窗口。

## 1.9.21 对比

1.9.21 的 23 天日志共 312,559 行：

```text
BLE ADOPT IGNORED        0
BLE DISCOVERY_WINDOW     0
BLE SCANNING             3156
```

1.9.21 代码仍使用主队列 `CBCentralManager`，但 `didDiscover` 在进入准入前就有廉价过滤：

```swift
targetIdentifier == nil || peripheral.identifier == targetIdentifier
serviceMatch || isCandidate(peripheral) || nameMatcher.matches(advertisedName)
```

不满足条件的普通蓝牙设备直接返回，不执行完整准入，也不写逐设备忽略日志。连接页 `onAppear` 也没有自动开始发现窗口。

因此“老版本不卡顿”与代码和日志一致：差异不在 CoreBluetooth 是否回调，而在 2.0.8 对每个回调执行了完整 `adopt` 和逐设备日志。

## 根因

2.0.8 的 `didDiscover` 对每个广播调用 `adopt`：

1. `VoiceRemoteAdmission.decide` 计算准入结论。
2. `.ignore` 分支构造并写入 `BLE ADOPT IGNORED`。
3. `AppLogger` 的 60 秒聚合只合并写盘，字符串构造、准入判断和队列提交仍在主线程逐次发生。
4. `AllowDuplicates: false` 没有阻止当前 macOS 和环境中的重复回调。
5. 连接页打开时自动启动 20 秒发现窗口，使风暴与设置页滚动重叠。

这不是 CPU 或内存不足，而是主线程上的高频同步工作。它可以直接造成滚动掉帧，也会和 SwiftUI/玻璃渲染争主线程。

## 修复

- 新增纯策略 `BluetoothDiscoveryScanPolicy.shouldInspect`。
- `didDiscover` 先做廉价过滤，只有以下设备进入 `adopt`：
  - 保存目标本身；
  - 已知身份；
  - 广播 ATVV 服务；
  - 已知遥控器名称；
  - 明确的外来产品名称，交给统一准入层记录拒绝原因。
- 其余普通 BLE 广播直接返回，只累加 `ignoredUnrelatedDiscoveryCount`（按回调次数，不是唯一设备数）。
- 扫描开始时缓存 `excludedIdentifiers` / `knownIdentifiers` 快照，`didDiscover` 和 `adopt` 只读快照；窗口结束前重取一次，已连接候选使用当前配置，避免每个回调重复构造 Set。
- 自动发现窗口增加守卫：已有目标桥处于连接、重连或 ready 时，`refreshRemoteDiscovery` 和 `startBluetoothDiscoveryIfNeeded` 不再自动开窗口；目标桥进入忙碌状态时取消正在进行的自动窗口。
- 手动“查找遥控器”和 onboarding 添加新遥控器继续使用 `manual: true` 路径，不受稳定连接守卫影响；`discoveryWasManual` 保证手动窗口不会被自动取消。
- 扫描结束时只写一条汇总：

```text
BLE DISCOVERY_WINDOW phase=completed result=waiting ignored_unrelated=<n>
BLE SCAN TIMEOUT ... result=retrying reason=scan_window_expired ... ignored_unrelated=<n>
```

- 不记录设备标识、名称或地址。
- 保留 `BLE ADOPT IGNORED` 给通过第一层过滤但仍被忽略的候选，继续支持诊断。

## 验证

自动化：

- `BluetoothLifecycleTests` 新增发现过滤策略、身份快照复用、稳定连接自动发现守卫和接线回归。
- 覆盖保存目标、已知身份、ATVV 服务、已知名称、外来产品、AirPods/Watch/音箱等无关设备。
- 覆盖稳定连接时自动发现被抑制、手动/onboarding 仍可扫描的源码路径。
- 公开宿主构建和全量测试在修复提交中记录。

待现场验证：

- 在 20 台以上 BLE 设备环境中打开连接页，确认 `ignored_unrelated` 汇总且滚动无明显掉帧。
- 稳定连接后切回 App 或重开连接页，确认没有新的自动 `BLE DISCOVERY_WINDOW phase=started`；手动查找和 onboarding 仍能发现新遥控器。
- RC001、RC003 已保存身份重连，已知型号新遥控器发现，外来产品拒绝。
- 断连、睡眠唤醒、扫描超时和连续打开连接页。
- 设置页滚动帧率与 `sample SayAll` 主线程栈。

## 边界

- 本修复降低每个回调的主线程工作，不改变 CoreBluetooth 的 delegate 投递线程。
- 如果真实环境中 CoreBluetooth 自身仍在主线程造成不可接受的延迟，需要单独评估串行队列和状态线程安全，不在本次修改范围。
- 1.9.21 对比来自单个用户进程和一份日志，不构成跨机器性能基线。
- 自动化不能证明真实滚动帧率、真实设备发现时机或语音首尾音；这些仍需现场验收。
