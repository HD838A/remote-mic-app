# 休眠期间仍持续蓝牙扫描和重连

## 状态

候选修复完成，自动化通过；等待真实整夜休眠、实体遥控器和 `pmset` 验收。

## 影响范围

- 平台：macOS
- 功能：小米蓝牙语音遥控器发现、重连与系统休眠生命周期
- 对应 Issue：[#441](https://github.com/HD838A/remote-mic-app/issues/441)

## 复现与正常边界

复现条件是无线麦SayAll.app保持运行、遥控器连接或处于重连状态，然后让屏幕和系统进入休眠。
现场日志证明虚拟音频已经按预期释放，但休眠期间蓝牙桥仍继续安排主动扫描和重连。

正常边界：已经 ready 的连接和正在进行的真实语音不能因休眠通知被主动断开；本次只暂停尚未完成的
发现、连接和重连活动，不改变配对信息、ATVV 会话、HID 映射或音频尾包处理。

## 日志证据

休眠事件和音频释放在同一时间段内已经完成：

```text
2026-09-28T02:38:40.572Z SYSTEM AUDIO event=screen_did_sleep ... suspended=true reasons=screen_sleeping
2026-09-28T02:38:40.615Z AUDIO RELEASE completed reason=system_screen_did_sleep
```

但屏幕仍处于休眠状态时，日志继续出现蓝牙重连与扫描：

```text
2026-09-28T03:21:01.118Z AUDIO REBIND deferred reason=bluetooth_ready system_suspended=true
2026-09-28T03:21:01.118Z BLE RECONNECT scheduled ...
2026-09-28T03:21:04.158Z BLE SCANNING
2026-09-28T03:21:12.599Z BLE RECONNECT scheduled ...
2026-09-28T03:21:19.366Z BLE SCANNING
```

这些记录确认“音频未释放”不是本轮剩余问题；可确认的缺口是蓝牙扫描和重连没有使用同一组系统挂起原因。
现场没有采集 `bluetoothd` 的完整主动扫描日志，因此“每次扫描必然导致 FullWake”仍属于系统侧待验证边界。

## 代码根因

`BridgeAppModel.handleSystemAudioLifecycle` 只把 `SystemAudioSuspensionState` 用于虚拟音频释放和恢复。
`XiaomiBluetoothBridge` 的以下入口均不感知该状态：

- 初始连接和 `discoverOrScan`；
- 手动或自动 `reconnectNow`；
- 系统/会话恢复触发的 `recoverVoiceLink`；
- 已排期的重连、连接超时和初始化超时闭包；
- CoreBluetooth 电源状态恢复后的重新发现。

因此音频资源已经释放时，桥仍可在休眠期间重新进入 `BLE SCANNING`。

## 修复

修复保持在既有生命周期内，没有新增蓝牙协议或重构状态机：

1. `BluetoothSystemSuspensionState` 记录桥是否被系统挂起，以及休眠期间是否中断了连接周期。
2. 最早收到挂起事件时停止主动扫描，取消待执行的重连、连接超时和初始化超时。
3. 扫描、连接、恢复和重连入口在挂起期间只记录一次可恢复需求，不启动新的 CoreBluetooth 活动。
4. 最后一个系统挂起原因解除后，沿用现有恢复策略；只有被中断且尚未 ready 的桥才补一次连接周期。
5. 新建桥会先继承当前系统挂起状态，再调用 `start()`，避免 App 启动与休眠事件交错时短暂扫描。

已经 ready 的连接不会在挂起动作中被主动断开；真实语音、尾包、配对信息和既有系统唤醒恢复策略保持不变。

## 验证

修复前先新增 `BluetoothLifecycleTests`，测试因缺少 `BluetoothSystemSuspensionState` 明确编译失败。
加入最小实现后：

- `swift test --disable-keychain --filter BluetoothLifecycleTests`：22/22 通过；
- 覆盖 ready 连接不要求重启、扫描/等待重连需要恢复、休眠期间断连需要恢复、重复事件幂等；
- 源码接线回归确认桥在启动前继承挂起状态，并且蓝牙门控发生在音频启动 early-return 之前。
- `swift test --disable-keychain`：734/734 通过；
- `SKIP_SWIFT_PACKAGE_BUILD=1 zsh scripts/test.sh`：48/48 通过；
- `scripts/verify-repository-governance.sh origin/main` 与 `git diff --check` 通过；
- Release App 构建成功，`scripts/verify-app.sh dist/SayAll.app` 通过。

本机 Xcode 位于用户下载目录，第一次 Release 构建因此把工具链的绝对路径写入 Mach-O `LC_RPATH`，
产物路径泄漏门禁按预期拒绝。使用 `/Applications` 下的临时符号链接和全新独立构建缓存重建后通过；
符号链接验证后已移入 macOS 废纸篓，没有修改系统 `xcode-select`。

## 真机验证边界

自动化不能证明 CoreBluetooth 在真实 DarkWake 中不再发起系统扫描，也不能证明 FullWake 次数、电池消耗或
`bluetoothd` 的 HID Activity 断言已经下降。合入或发布前仍需按
[`Testing/MacIdleSleepAudioRelease.md`](../Testing/MacIdleSleepAudioRelease.md) 执行真实整夜休眠：

- 对比休眠前后 `pmset -g assertions` 与 `pmset -g log`；
- 确认挂起后没有新的 `BLE SCANNING` / `BLE RECONNECT scheduled`；
- 唤醒后第一段实体遥控器语音不丢首字、不断尾；
- 覆盖休眠中断连、重叠挂起原因和快速用户切换。
