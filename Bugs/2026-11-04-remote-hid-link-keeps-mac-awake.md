# 睡眠期间遥控器链路一直保持，系统把它当成唤醒源

- 时间：2026-11-04
- 状态：**已确认应用层无法修复**（睡眠前取消 CoreBluetooth 会话并断开 HID 的做法两次真机实测均无效，实现已回退）
- 影响范围：macOS 上连接小米 BLE 语音遥控器并让无线麦SayAll.app 常驻的用户
- 功能点：系统睡眠、蓝牙连接生命周期
- 简单描述：遥控器是 BLE HID 设备，睡眠期间链路由 `bluetoothd` 持有，只要它还在系统唤醒源集合里，维护性暗唤醒期间的任何链路活动都会被判为 HID 活动，把暗唤醒升级为完全唤醒并点亮屏幕。

## Observations

- 上游反馈集中在 #441、#486、#514、#601、#684、#240。共同现象是夜间周期性亮屏，`pmset -g log` 里伴随 `DarkWake to FullWake`。
- #441 记录的调用链：`bluetoothd: Bluetooth LE HID activity woke up machine fully` → `powerd: DarkWake to FullWake ... due to HID Activity` → 屏幕点亮约 10 分钟 → 下一次维护唤醒重复。
- 本机 `pmset -g log`（2026-10-31 至 2026-11-04）反复出现 `PID bluetoothd UserIsActive "Bluetooth LE HID Activity"`，每一条都在 `01:00:00` 超时结束。
- 本机 `system_profiler SPBluetoothDataType` 显示遥控器（VID 0x2717 / PID 0x32B8，Services `HID BLE`）处于 Connected，**而当时无线麦SayAll.app 主程序并未运行**，只有特权 helper。

## Hypotheses

### H1：遥控器的 HID 链路归 `bluetoothd` 所有，应用侧普通断开拆不掉（ROOT HYPOTHESIS）

- Supports：应用完全退出后链路仍然存在；`XiaomiBluetoothBridge` 的所有断开路径都是 `CBCentralManager.cancelPeripheralConnection`，它只结束本应用的 CB 会话。
- Supports（实测）：普通 `cancelPeripheralConnection` 与 `IOBluetoothDevice.closeConnection()` 都返回成功，但链路 5 秒内就恢复。
- Test：带“禁止自动复连内置服务”的取消选项后再观察断开是否保持——**桌面实验成立，真实睡眠不成立**（见下）。

### H2：虚拟音频长期持有防休眠断言是唯一原因

- Supports：`coreaudiod` 会代持 `PreventUserIdleSystemSleep` / `PreventUserIdleDisplaySleep`（`Bugs/2026-08-18-connected-virtual-audio-blocks-mac-idle-sleep.md`）。
- Conflicts：该断言解释“睡不着”，不能解释“睡着了被链路叫醒”。
- Test：10 分钟闲置释放与系统挂起释放已覆盖这一层，仍不能解释残余唤醒。

### H3：应用在暗唤醒时重新扫描把设备带起来

- Supports：#441 的 `Upgrading <session> to active scan` 记录。
- Conflicts：#522 已在挂起期间门控扫描与重连，而候选观察显示仍有唤醒。
- Test：门控生效后现象仍在，说明还有不依赖扫描的唤醒路径。

## 负结果（先做、已排除的路线）

按本机现场实验记录，以下三条都不可用，后续不必重试：

- **`IOBluetoothDevice.closeConnection()`**：返回 `kIOReturnSuccess (0)`，但 5 秒采样和系统接口观察都显示链路仍在；不能保持断开。
- **`IOBluetoothDevice.openConnection()`**：隔离之后用它做“宿主主动恢复”失败，返回 `IOReturn -536870186 (0xE00002D6)`，30 秒后仍然断开。恢复必须走 CoreBluetooth。
- **睡眠前用私有选项 `cancelPeripheralConnection:options:` 取消会话**：桌面能保持断开 60 秒，但真实睡眠中照样被 HID 活动点亮屏幕（本文件“真机实测”一节，两次）。

## Root Cause

BLE HID 链路在睡眠期间保持建立，遥控器因此留在系统唤醒源集合里。这条链路由 `bluetoothd` 为 HID 服务持有，并且独立于任何应用会话：

- 应用退出后链路仍在（见 Observations）。
- 应用取消自己的 CB 会话、甚至在应用内看到 `HID DISCONNECTED` 之后，`bluetoothd` 依然在睡眠中为同一台设备登记 `UserIsActive "Bluetooth LE HID Activity"`。

也就是说，“断开应用的 CB 会话”和“把设备从系统唤醒源里摘掉”是两件事，前者不蕴含后者。**在应用进程内没有可用的 API 完成后者**，这是本次实测的结论。

## 已尝试并否决的方案：睡眠前取消 CB 会话

2026-11-04 实现过一版候选修复，代码位于分支 `fix/remote-sleep-link-isolation`（未合入，已回退）：

- 监听 `SystemAudioLifecycleEvent.systemWillSleep`，对桥接自己 `lifecycle.isReady` 的那条会话调用 `cancelPeripheralConnection:options:`，选项为运行时 `dlsym` 取到的 `CBCancelPeripheralConnectionOptionDoNotAutoConnectBuiltInServices` 与 `CBCancelPeripheralConnectionOptionForce`。
- 先 `setSystemSuspended(true)` 再隔离，并排在 `guard started, changed` 之前；只处理桥接自己持有的会话，不按设备名或地址猜设备。
- 桌面实验数据（macOS 27.0.1，RC003）：普通取消 / `IOBluetooth.closeConnection()` 返回成功但 +5 s 链路恢复；带两个选项的取消在 +2 s 至 +60 s 共 30 次采样全部保持断开；同进程隔离后再 `CB connect` 654 ms 到 CONNECTED；真实应用冷启动 2.68 s 到 CONNECTED、4.09 s 到 READY。

桌面数据全部指向“有效”，这正是需要真机复核的原因：**桌面链路能断开，不等于系统把设备移出了唤醒源**。

## 真机实测（决定性证据）

- 环境：MacBook Pro，macOS 27.0.1，合盖 + 外接显示器供电（`clamshelled: YES`、`isPluggedIn 1`）。
- 应用：Build 304（候选修复已包含），前台运行，虚拟音频就绪。
- 设备：小米蓝牙语音遥控器 RC003，VID `0x2717` / PID `0x32B8`，服务 `HID BLE`，已配对连接。
- 两次都由用户主动点睡眠，中间未碰键鼠；每次都在 30 秒内被点亮屏幕。

### 第一次：23:42（隔离已执行）

应用侧（`~/Library/Logs/RemoteMic/runtime.log`，时间已转本地时区）：

```text
23:42:11.378 SYSTEM AUDIO event=system_will_sleep changed=true suspended=true ready_bridges=1 configured_bridges=2
23:42:11.382 BLE SLEEP_ISOLATION requested reason=system_will_sleep sent=true generation=1
23:42:11.382 BLE SLEEP_ISOLATION completed reason=system_will_sleep isolated=1 configured=2
23:42:11.454 BLE DISCONNECTED phase=ready(1) error_domain=none error_code=0
23:42:11.535 HID DISCONNECTED
```

系统侧（`/usr/bin/log show`，`process == "powerd"`）：

```text
23:42:41.415 Entering Sleep state due to 'Software Sleep pid=442'
23:42:45.040 DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty
23:42:46.968 Process bluetoothd.395 Created UserIsActive "Bluetooth LE HID Activity"
23:42:47.028 DarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity
```

隔离后 72 ms 应用就看到了 `BLE DISCONNECTED`，再 81 ms 看到 `HID DISCONNECTED`；系统仍在入睡后 6 秒把 `Bluetooth LE HID Activity` 记到 `bluetoothd` 名下，2 秒后升级为完全唤醒。

### 第二次：23:46（复测，排除误测）

```text
23:46:25.202 SYSTEM AUDIO event=system_will_sleep changed=true suspended=true ready_bridges=1 configured_bridges=2
23:46:25.203 BLE SLEEP_ISOLATION requested reason=system_will_sleep sent=true generation=3
23:46:25.203 BLE SYSTEM_SUSPENSION phase=started result=paused reason=system_will_sleep lifecycle=ready(3) ready_preserved=true
23:46:25.247 BLE DISCONNECTED phase=ready(3) error_domain=none error_code=0
23:46:25.348 HID DISCONNECTED
```

```text
23:46:55.167 Entering Sleep state due to 'Software Sleep pid=442'
23:46:58.754 apsd prepareForDarkWake  (kern.wakereason 'smc.sysState.Wake(0x70070000) wifibt')
23:47:00.344 Process bluetoothd.395 TurnedOn UserIsActive "Bluetooth LE HID Activity"
23:47:00.402 DarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity
```

### 结论

两次都满足“隔离确实执行、会话确实断开、HID 确实断开”，两次都在入睡后约 5 秒被同一个 HID 断言点亮屏幕。所以：

- 不是“隔离没跑到”，也不是“隔离条件判断错”——`sent=true` 与 `isolated=1` 都出现了。
- 不是“断开被系统立刻重连”造成的假象——应用侧链路直到唤醒都没恢复。
- 剩下的唯一解释是：**遥控器作为 BLE HID 设备，其链路由 `bluetoothd` 持有，应用层断开自己的会话不改变它的唤醒源身份。**

这也解释了 #441 里“应用完全退出仍被唤醒”的观察——同一机制，只是那一次连会话都没有。

## 复现方法

```bash
# 1. 睡前确认隔离是否执行（应用日志为 UTC 时间戳）
grep SLEEP_ISOLATION ~/Library/Logs/RemoteMic/runtime.log | tail -n 5

# 2. 唤醒后看是谁点的灯（zsh 里 log 是内建命令，必须写绝对路径）
/usr/bin/log show --start '2026-11-04 23:46:50' --end '2026-11-04 23:47:10' --style syslog \
  --predicate 'process == "powerd" AND (eventMessage CONTAINS "FullWake" OR eventMessage CONTAINS "UserIsActive")'

# 3. 看整机的暗唤醒记录
pmset -g log | grep -E 'DarkWake to FullWake|Bluetooth LE HID Activity'
```

判据：只要 `Bluetooth LE HID Activity` 仍然出现在 `bluetoothd` 名下、且紧跟 `DarkWake to FullWake ... due to HID Activity`，就与本次结论一致，不要仅凭 `SLEEP_ISOLATION sent=true` 宣称修复。

## 后续方向

应用层到此为止。剩下两条都在系统层，代价或风险都明显，做之前需要产品决策：

1. **关闭系统的“允许蓝牙设备唤醒这台电脑”**：效果最直接，但蓝牙键盘鼠标会一起失去唤醒能力。本次未实测。
2. **继续深入 `bluetoothd` 私有接口**：跨 macOS 版本不可控，且需要特权常驻，不建议为单个外设引入。

在拿到新证据之前，不建议再提交任何“应用侧睡眠隔离”的 PR；`#778` 与本次实现走的是同一条路（同选择器、同两个运行时符号、同选项字典），本机结论对它同样成立。
