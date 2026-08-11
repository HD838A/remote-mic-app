# Onboarding 新配对遥控器 BLE 与 HID 状态不刷新

- 时间：2026-08-11
- 状态：候选修复完成，等待 RC001 / RC003 真机验收
- 影响范围：macOS `1.8.10 (102)` 候选；Onboarding 遥控器页；新配对或重新配对 RC001 / RC003
- 功能点：CoreBluetooth discovery、HID monitor、Onboarding 前台恢复
- 简单描述：系统已连接新遥控器时 App 可能仍显示查找；BLE 显示连接后，系统按键有效但 App 仍收不到普通按键，重启后可能恢复。

## 复现证据

用户截图确认了两个独立状态边界：

1. 系统蓝牙已连接，但 Onboarding 的“遥控器已连接”检查仍未通过；
2. Onboarding 的 BLE 检查已通过，但“实体按键已收到”未通过，macOS 音量键仍能工作。

真实现场日志 SHA-256 为 `1c97fb79a30e42d9b39c876cfde73b589bf5b272de887727982b84a8b38f2a5b`。关键事件为：

- discovery 最终通过 `source=scan name=MI RC` 找到新设备并进入 `BLE READY`；
- `VOICE FN MAPPING ... matched=2 applied=1`；
- `HID PERMISSIONS input=true accessibility=true`；
- `HID START rejected power_suppressed=false`；
- 多次重启后仍保持相同部分成功结果。

## 调查

根因有两部分：从系统设置返回时没有刷新 discovery；多个 HID service 只有部分成功写入 Power 安全映射时，旧逻辑会拒绝启动全部 HID monitor。

候选修复在返回遥控器页时刷新 discovery，并使用 HID Location ID 只监听已完整应用 Power→F20 的安全设备。失败 service 和缺失 Location 的设备继续 fail-closed，不放宽锁屏保护。

## 验证边界

自动化已覆盖前台 discovery 接线、部分映射安全集合、同 Location 部分失败、缺失 Location fail-closed 和 monitor 过滤。真实系统配对、CoreBluetooth 已连接外设查询、IOHIDManager 热插拔、双遥控器和最终按键响应仍需 RC001 / RC003 真机复验。
