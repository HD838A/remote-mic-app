+# Issue #291：蓝牙已连接但实体按键持续等待检测

## 复现与日志

现场日志显示 BLE 已连接、权限已授予，但 HID 状态长期为 `waiting_for_device`，系统音量键仍有反应；重启系统后恢复。该时序对应 HID manager 已启动但未收到有效报告。

## 根因

监听器在等待阶段没有生命周期 watchdog；manager/probe 状态卡住后，用户只能重启系统触发重新枚举。

## 修复

HID manager 启动后增加 2 秒 watchdog：无 active device 时执行一次完整 manager rebuild，最多两次；任意有效报告到达立即取消 watchdog。重建会关闭旧 manager、probe 和回调，重新枚举设备，并记录 attempt。

## 验证

- `swift test --filter RemoteButtonsTests`
- 自动化覆盖跨 manager rebuild 最多两次重试，以及拒绝报告不取消、有效报告才取消 watchdog。
- RC001/RC003、睡眠唤醒、第三方 HID 工具占用仍需真机验收。
