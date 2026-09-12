# 休眠唤醒后 BLE 语音链路永久失联：唤醒恢复从未被调用

- 时间：2026-09-06
- 状态：候选修复完成，自动化与部分真机验证通过；卡死态救援仍待现场复现
- 影响范围：macOS 1.9.21 (174)；实体遥控器 BLE 语音链路、语音键中和与电源键抑制
- 功能点：CoreBluetooth 睡眠唤醒恢复
- 简单描述：Mac 休眠唤醒后语音输入永久失效，系统蓝牙仍显示已连接、普通按键全部正常，必须重启 App 才能恢复。
- 原始记录：用户现场 `runtime.log`，1.9.21 (174)，macOS 26.6.2 (25G83)，RC003

## 复现

1. 遥控器已连接、语音输入正常工作。
2. 让 Mac 休眠，随后唤醒。
3. 按遥控器普通按键：正常。按语音键：无任何语音会话。

现场共 4 次休眠唤醒（11:49、12:00、13:02、13:13），每次形态完全一致。

## 日志结论

### 最后一次正常

```text
11:28:30.824  VOICE FN MAPPING applied=true neutralized=true power_suppressed=true matched=1 applied=1
11:28:30.861  ATVV STREAM START session=50
11:28:34.312  ATVV STREAM summary duration_ms=3450 route=fn_tap enqueue_failures=0
```

### 休眠唤醒

```text
11:49:44.506  SYSTEM AUDIO event=system_will_sleep reasons=screen_sleeping,system_sleeping
11:49:49.547  BLE CENTRAL state=4 lifecycle=scanning(2) generation=2
11:49:49.614  HID DISCONNECTED
11:49:51.769  BLE CENTRAL state=5 lifecycle=scanning(3) generation=3
11:49:52.003  HID CONNECTED mode=monitored
11:49:52.164  SYSTEM AUDIO event=system_did_wake suspended=true reasons=screen_sleeping
11:49:52.164  SYSTEM AUDIO resume_deferred event=system_did_wake remaining_reasons=screen_sleeping
11:49:52.563  SYSTEM AUDIO event=screen_did_wake suspended=false reasons=none
11:49:52.563  SYSTEM AUDIO resume_skipped reason=system_screen_did_wake required=false ready_bridges=0
```

此后 90 分钟内 BLE 只有 `scanning(N)` 反复递增（最高 `scanning(22)`），从未出现 `BLE CONNECTING` / `CONNECTED` / `READY`。

**整份日志中 `BLE WAKE` 出现 0 次。**

### 「立即重新连接」无效，重启 App 立即恢复

```text
13:19:42.929  BLE CENTRAL state=5 lifecycle=scanning(22) generation=22   ← 点击重连，仅扫描
...
13:21:52.728  BLE CONNECTING source=target_identifier                    ← 重启后
13:21:52.751  BLE CONNECTED
13:21:53.205  BLE READY
```

| | 唤醒后的旧进程 | 重启后的新进程 |
|---|---|---|
| 连接路径 | `scanning(2)` → … → `scanning(22)` | `source=target_identifier` |
| 结果 | 90 分钟未成功 | 23 毫秒连上 |

`scanForPeripherals` 不会返回系统层面已连接的外设（HID 正常工作即为佐证），因此扫描循环不可能成功。

## 根因

`SystemAudioLifecycleEvent` 的处理顺序导致唤醒恢复两条路径各缺一半：

```swift
// BridgeAppModel.swift
guard !systemAudioSuspensionState.isSuspended else {
    AppLogger.shared.write("SYSTEM AUDIO resume_deferred ...")
    return                                          // ← 早退
}
resumeVirtualAudioOutputIfNeeded(...)
if BluetoothWakeRecoveryPolicy.shouldForceReconnect(event: event, started: started) {
    recoverBluetoothAfterSystemWake()               // ← 到不了这一行
}
```

```swift
// BluetoothLifecycle.swift
static func shouldForceReconnect(event:started:) -> Bool {
    started && event == .systemDidWake              // ← 只接受 systemDidWake
}
```

macOS 唤醒时屏幕晚于系统醒来：

| 事件 | `isSuspended` | 结果 |
|---|---|---|
| `system_did_wake` | `true`（`screen_sleeping`） | 被 `resume_deferred` 早退 |
| `screen_did_wake` | `false` | 通过 guard，但 `event != .systemDidWake` |

`git log -S` 显示两处代码的引入顺序：`resume_deferred` 早退来自 2026-08-18 `7e49f00`，而唤醒恢复调用来自 2026-08-26 `6b8a979`（PR #243）。**PR #243 的恢复调用被 8 天前既有的早退屏蔽，在本场景下从未执行过。**

HID 映射丢失是下游后果：`applyHIDSettings()` 由 `bluetoothBridge(_:didChange:)` 中 `case .ready` 驱动，BLE 从未 ready，因此语音键中和与电源键抑制也从未重新应用。现场日志中 `VOICE FN MAPPING` 在 11:28:30 之后直到 App 重启为止再未出现，唤醒后大量 `HID REPORT accepted ... usage_count=1 buttons=none` 即为未被中和的语音键。

## 修复

1. 新增待恢复标志：`systemWillSleep` 与 `systemDidWake` 置位，在第一个真正解除挂起的时刻执行恢复并清除。恢复意图因此能跨越被 defer 的 `systemDidWake`。
2. `systemDidWake` 自身也置位，覆盖未观察到 `systemWillSleep` 的唤醒。
3. 纯显示器睡眠/唤醒不置位——这类事件在机器保持唤醒时持续发生，不得重启连接周期。既有测试 `onlySystemWakeForcesBluetoothRecovery` 的原意由此保留。
4. 所有 bridge 已 ready 时跳过强制重连并记录 `BLE WAKE recovery_skipped reason=bridges_already_ready`：短暂休眠可能在 resume 路径运行前由 CoreBluetooth 自行恢复连接，此时强制重连会拆掉一个健康的 bridge。

未改动 ATVV 协议、虚拟音频路由、语音键按下/释放时序或手势定义。

## 验证

### 自动化

- `swift test`：440 项、37 个 suite 全部通过（基线 434 + 新增 6）。
- 新增 `BluetoothWakeRecoveryPendingTests`（5 项）覆盖：系统睡眠置位、系统唤醒自行置位、纯显示器事件不置位、armed + started 才恢复、已 ready 不恢复、resume 路径接线。
- 既有 `BluetoothLifecycleTests.onlySystemWakeForcesBluetoothRecovery` 迁移到新 API，原意（屏幕唤醒不触发恢复）不变。
- 测试诚实性验证：将 `pendingRecovery` 的置位分支改为 `return current` 后，3 项测试按预期失败；恢复实现后全绿。

### 真机

Apple Silicon、macOS 26.6.2、RC003，本地 ad-hoc 签名构建。

修复前（生产 1.9.21 (174)）：4 次休眠唤醒，`BLE WAKE` 计数 0，BLE 卡在 scanning 90 分钟。

修复后，屏幕先睡再系统睡的完整序列：

```text
23:44:29.349  SYSTEM AUDIO event=screen_did_sleep  suspended=true  reasons=screen_sleeping
23:44:37.441  SYSTEM AUDIO event=system_will_sleep suspended=true  reasons=screen_sleeping,system_sleeping
23:44:42.490  BLE CENTRAL state=4
23:45:12.941  BLE CONNECTED
23:45:13.489  SYSTEM AUDIO event=system_did_wake   suspended=true  reasons=screen_sleeping
23:45:13.893  BLE READY
23:45:13.893  SYSTEM AUDIO event=screen_did_wake   suspended=false reasons=none
23:45:13.984  BLE WAKE recovery_skipped reason=bridges_already_ready ready_bridges=1
```

待恢复标志跨越了被 defer 的 `system_did_wake`，在 `screen_did_wake` 解除挂起的时刻被求值——即原缺陷的修复点。已 ready 门禁同时生效。

另一次较浅的休眠（屏幕未先睡）在加入 ready 门禁前记录到 `recovery_begin ... ready_bridges=1` 随即拆掉健康连接重连，该现象即为门禁的直接来源。

## 自动化与真机边界

- **未复现「卡在 scanning 连不上」的救援场景。** 两轮真机测试中 CoreBluetooth 均自行恢复，因此本次只证明恢复会在正确时机被调用，未证明它能救回一个已经卡死的 bridge。该状态为间歇性状态机条件（原始现场仅休眠约 5 秒即触发），无法按需构造。
- 现场证据显示「立即重新连接」（同样调用 `reconnectNow()`）对已卡死 90 分钟的 bridge 无效。本修复使恢复在唤醒瞬间执行，此时退避计数尚未累积，与 90 分钟后再抢救并非同一局面——但这是推断，非实测结论。
- `discoverOrScan()` 中 `reconnectPolicy.allowsCachedTargetRetrieval` 在反复失败后关闭，随后只剩扫描路径。该退避与卡死态的确切关系未在本次确定，可能需要独立跟踪。
- 电源键抑制失效由 `power_suppressed` 未重新应用推断，未实际按下电源键验证。
- 本地构建中手机 / 网页 / Watch 组件为 stub（无法访问私有包 `GetSayAll/sayall-mac-remote`）；ATVV / BLE / HID 物理遥控器路径为未修改的仓库代码。
- 单机单遥控器，未覆盖 RC001、多遥控器或合盖 DarkWake 场景。

## 与既有 PR 的关系

- **PR #243**（已合入）引入了本修复所修的唤醒恢复调用。本修复使其在真实事件顺序下能够执行。
- **PR #280 / #302**（open）处理合盖 DarkWake 的反复恢复，方案为睡眠时主动 suspend + 唤醒 15 秒稳定窗口，与本修复触及同一区域。#302 中「保留未观察到 `systemWillSleep` 时的主动 wake recovery」这一兼容回退在本场景无效——现场**观察到了** `system_will_sleep`，走的正是被屏蔽的路径。若 #302 先合入，本修复需要重放。
- **PR #290 / #296**（已合入）处理 BLE Ready 时 HID service 尚未枚举（`matched=0`）的有限重试。本场景相反：BLE 从未 ready，`applyHIDSettings()` 的触发条件不成立，重试机制无从启动。
