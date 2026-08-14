# 快捷指令私有模块集成

## 为什么开发

快捷指令需要在无线麦中配置、测试并绑定遥控器，但邀请码资格、输入框学习、宏执行和本地私有数据不应进入公开源码仓库。

## 用户功能介绍

包含私有模块的内测构建会为已有资格用户保留邀请码状态，并通过受控入口显示邀请码录入区域。资格有效后，侧边栏显示“快捷指令”，用户可以创建多步骤指令、录入快捷键、学习输入框并绑定到遥控器的单击、双击或长按。资格关闭或模块缺失时，原有按键映射继续工作。

## 范围与非目标

- 公开仓库只维护可选 Swift Package 接入、页面委托、按键事件转发和关闭状态回归。
- 私有 `sayall-macro-platform` 维护邀请码、Feature Flag、页面、宏库、执行器、输入框学习和本地存储。
- 本次不发布预览版，不开放市场、社区上传或任意脚本。

## 关键设计

- 构建时通过 `SAYALL_MACRO_PLATFORM_PATH` 可选加载 `SayAllMacroRemoteMic`。
- 运行时使用独立快捷指令资格；没有有效资格时私有模块不接管任何按键。
- 公开构建未注入私有模块时使用安全 no-op 适配器，保持 SwiftPM 构建和稳定功能不变。
- 按键绑定使用遥控器 Profile ID、按键 raw value 和触发方式传递，不让两个仓库互相依赖内部类型。

## 涉及文件

- `Package.swift`
- `Sources/RemoteMic/MacroFeatureIntegration.swift`
- `Sources/RemoteMic/HIDRemoteMonitor.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Sources/RemoteMic/SettingsView.swift`
- `Sources/RemoteMic/RemoteMicApp.swift`
- `scripts/build-app.sh`
- `scripts/verify-app.sh`
- `scripts/check-repository-boundaries.sh`
- `Tests/RemoteMicTests/BuildSigningTests.swift`
- `Tests/RemoteMicTests/HardwareSimulationIntegrationTests.swift`
- `Tests/RemoteMicTests/SettingsPageRegressionTests.swift`

## 隐私和兼容边界

- 公开仓库不包含邀请码校验、资格令牌、宏定义、输入框学习数据或私有页面实现。
- 未授权、资格失效和未注入模块三种状态都不修改现有按键配置，也不影响 HID、蓝牙和音频监控。
- 快捷指令本机数据由私有模块保存；不会上传快捷键、输入框特征或按键记录。
- 邀请资格客户端兼容生产服务带小数秒的 ISO 8601 时间；失败时显示状态并写入脱敏日志，不记录邀请码或资格凭据。

## 当前状态

代码和本地 App 打包接入完成。2026-08-14 已修复生产资格时间解析导致的“服务端兑换成功但客户端无反应”，并同步覆盖共享资格客户端；详细过程见 [`Bugs/2026-08-14-early-access-fractional-server-time.md`](../../Bugs/2026-08-14-early-access-fractional-server-time.md)。等待 Developer ID 安装包、重启恢复、真实遥控器、第三方 App 输入框及窗口页面人工验收。
