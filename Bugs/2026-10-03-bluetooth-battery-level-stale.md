# 蓝牙遥控器电量长时间停留在旧值

## 状态

候选修复完成，等待 RC001 / RC003 真机电量变化验收。

## 影响范围

- Issue [#463](https://github.com/HD838A/remote-mic-app/issues/463)
- 小米 RC001 / RC003 的设置页设备卡电量
- 不改变蓝牙连接、ATVV 语音、HID 映射或音频会话生命周期

## 复现与现场证据

反馈截图中，macOS 蓝牙界面已经显示遥控器电量为 `85%`，无线麦SayAll.app 的设备卡仍停留在
`100%`。现场没有附带运行日志、遥控器型号、固件版本和等待时长，因此本轮无法在同一实体设备上
重放电量下降过程，也不能确认设备是否支持 Battery Level characteristic 的 notify / indicate。

代码级复现条件可以确定：连接时只对 Battery Level (`2A19`) 和 Battery Level Status (`2BED`)
各读取一次；只有 characteristic 声明 notify / indicate 时才订阅。对于不支持通知的遥控器，连接保持期间
不会再次读取，所以首次读到的电量会一直留在页面上，直到重连或 App 重启。

## 日志结论

反馈没有提供现场日志。改动前日志只会在连接时出现一次 `BLE BATTERY level=...`，无法区分
“设备没有通知新值”和“App 没有再次读取”。这也是本轮补充轮询生命周期日志的原因。

## 根因

`XiaomiBluetoothBridge` 已保存电量 characteristic，但没有为“不支持通知”或“通知订阅失败”的设备
安排后续读取。设置页回前台和重新进入连接 / 映射页面时只刷新系统设备名称，也没有主动刷新电量。

## 修复

1. characteristic 没有通知能力、尚未成功进入 notifying，或通知订阅失败时，每 5 分钟低频读取一次。
2. App 回到前台、进入相关设置页面或连接状态变化触发既有设备元数据刷新时，立即主动读取一次电量。
3. 休眠、断连、停止或 peripheral 重置时取消轮询；恢复且桥仍 Ready 时再按需启动。
4. 相同电量和相同供电状态不重复更新 UI、也不重复输出值日志；读取请求、失败、轮询启动和停止均使用
   脱敏稳定字段记录。
5. 已正常订阅通知的设备不执行周期轮询，避免无意义的蓝牙请求。

## 验证

- `BluetoothLifecycleTests` 覆盖 5 分钟间隔、通知成功后不轮询、无通知 / 通知失败时轮询，以及前台元数据
  刷新接线。
- `swift test --disable-keychain --filter BluetoothLifecycleTests`：24 项通过。
- `swift test --disable-keychain`：790 项、60 个测试套件全部通过；仅有仓库既有的 deprecated warning。
- 未完成 RC001 / RC003 真机从 `100%` 下降到其他值的等待测试，也未验证特定固件实际是否发送通知。
  自动化只能证明刷新策略和生命周期，不代表 CoreBluetooth 真机行为已经验收。
