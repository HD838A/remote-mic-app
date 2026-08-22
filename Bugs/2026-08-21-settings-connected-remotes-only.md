# 设置页只展示已连接遥控器

- 时间：2026-08-21
- 状态：已修复，自动化与构建验证通过；真实 RC001/RC003 双设备和首次配对仍需现场验收
- 影响范围：macOS 设置页“连接与语音”、 “按键映射”的遥控器选择区域
- 功能点：多遥控器设备卡展示

## 复现证据

在同一偏好中登记 4 个遥控器 profile，只保持第 2、4 个 BLE bridge 为 Ready，打开设置页：

1. “连接与语音”纵向列表显示 4 张卡，其中第 1、3 张显示“未连接”。
2. “按键映射”页头横向列表同样显示断开的历史设备，挤压标题和开关区域。

用户提供的两张截图分别记录了上述连接页和按键映射页状态。正常边界是：设备仍可保存在本地并由后台继续发现/重连，但设置页设备选择区域只应展示当前可操作的已连接遥控器。

## 日志结论

检查 `~/Library/Logs/RemoteMic/runtime.log` 后，日志能够确认 HID 报告和蓝牙运行时仍在处理事件；没有记录“断开 profile 被错误连接”的事件。问题发生在 UI profile 遍历层，而不是 BLE/HID 状态机或 profile 持久化层。

## 根因

`Sources/RemoteMic/SettingsView.swift` 的 `remoteDeviceSelector` 直接遍历 `settings.remoteDeviceProfiles`，没有使用 `BridgeAppModel.connectedRemoteProfileIDs` 过滤。`BridgeAppModel` 已维护准确的 Ready profile 集合，因此无需修改 discovery、注册或持久化逻辑。

## 修复

- `remoteDeviceSelector` 只渲染 `model.isRemoteConnected(_:)` 为真的 profile。
- 没有已连接 profile 时显示查找状态；按键映射页保留“立即重新连接”入口，连接页仍保留原有重连按钮。
- 不删除或隐藏 `AppSettings.remoteDeviceProfiles` 中的历史配置；新设备完成发现并进入 Ready 后会自动出现。

## 验证

- `SettingsPageRegressionTests.remoteSelectorsOnlyShowConnectedProfilesAndKeepDiscoveryFallback` 检查过滤条件、两种布局和空状态入口。
- `swift test` 共 319 项、31 个 suite 通过；Debug 构建随测试完整编译通过。
- 使用生产 `SettingsView` 离屏生成并检查深色中文 `800 × 650` 的连接页与按键映射页：无已连接设备时查找状态和重连入口可见，页头与开关未被挤压。
- 真实验收：两只遥控器同时在线、单只在线、全部断开、首次无 profile、首次发现后出现，以及断开/重连时列表实时变化。

## 自动化与真机边界

自动化可以验证源码接线和构建，不能模拟 CoreBluetooth Ready 状态、真实遥控器配对或 macOS 设置页的硬件时序。首次使用用户不会因过滤而失去入口：首次无已连接遥控器时显示查找状态，连接页仍可点击重连；真实设备发现后 profile 仍由现有运行时登记并显示。
