# Onboarding 已授权权限无法再次打开系统设置

- 时间：2026-08-20
- 状态：候选修复完成，等待正式签名升级权限连续性验收
- 影响范围：macOS Onboarding 权限页；蓝牙、输入监控、辅助功能已经授权的用户
- 功能点：首次使用设置向导、系统权限排障
- 简单描述：权限卡显示已授权后仍只是静态状态，用户无法从 Onboarding 再次打开对应系统设置检查或重置权限。

## 复现

1. 进入 Onboarding 权限页并使蓝牙、输入监控和辅助功能均显示已授权。
2. 点击任一已授权权限卡。
3. 旧实现没有响应，也不会打开对应系统隐私设置。

源码回归测试 `permissionRowsRemainClickableAfterAuthorization` 在旧实现产生 5 个 assertion issue，确认三条权限卡没有 action，且蓝牙已授权分支不会打开 `Privacy_Bluetooth`。

## 日志检查

该问题发生在本地静态 SwiftUI 卡片交互层，点击旧卡片不会调用权限请求、打开系统设置或改变运行时状态，因此没有可对应的业务日志。结合可稳定复现的无响应行为和源码检查，范围可直接收敛到 `OnboardingView.permissionRow`，不涉及蓝牙、HID 或 TCC 状态读取失败。

## 根因

`OnboardingView.permissionRow` 使用静态 `HStack` 展示状态，没有接受或执行 action。蓝牙权限方法在已授权时只会调用重连，也没有打开蓝牙隐私页；输入监控和辅助功能虽然已有打开系统设置的方法，但权限卡没有接线。

## 修复

1. 将整个权限卡改为 plain Button，并为蓝牙、输入监控和辅助功能分别接入已有权限操作。
2. 保留实时权限状态和继续门禁；点击卡片本身不会改变授权判断。
3. 已授权蓝牙卡直接打开蓝牙隐私设置，不额外重连或打断现有连接。
4. 未决定的蓝牙权限仍由现有重连路径触发系统授权；拒绝或受限时打开蓝牙隐私设置。
5. 卡片尾部增加进入箭头，让已授权状态也明确可点击；中文字号保持不低于 12pt，不新增页面滚动。

## App 改名与权限连续性

已检查旧 `/Applications/Remote Mic.app` 与公开 `v1.9.3` 的 `SayAll.app`：两者都使用 `com.hd838a.RemoteMic` Bundle ID、`RemoteMic` 可执行文件、Developer ID Team `L3QHLDRPAY`，designated requirement 一致。正式签名升级仅改变 App 文件名和显示名时，macOS TCC 原则上会把它们视为同一代码身份，蓝牙、输入监控和辅助功能可以延续。

本地 ad-hoc 测试包没有相同 Team ID 和 designated requirement，不能继承正式包权限，也不能作为改名权限连续性的验收证据。第三方重签名、Bundle ID 或 Team 变化以及系统 TCC/LaunchServices 异常仍可能要求重新授权。

## 验证

- 旧实现：`swift test --filter permissionRowsRemainClickableAfterAuthorization` 失败，共 5 个 assertion issue。
- 候选实现：同一测试通过。
- `swift test --filter OnboardingFlowTests`：27 项通过。
- `swift test`：313 项、31 个 suite 通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：42/42 通过。
- 生产 `OnboardingView` 权限页浅色、深色截图均为 Retina `2040 × 1608`，对应含标题栏的 `1020 × 804` 逻辑窗口和 `1020 × 772` 内容区；三张卡片、尾部进入箭头、修复卡和底部导航无裁切、无内部滚动，两种外观没有黑白分栏。

## 验证边界

自动化、截图与签名静态审计可以证明交互接线、页面布局和正式包代码身份一致，不能替代真实 macOS TCC 升级，也不能证明系统设置 URL 在所有支持的 macOS 版本都准确落到目标页。仍需在同一测试账号先授权正式签名 `Remote Mic.app`，再升级到正式签名 `SayAll.app`，逐项确认系统设置状态、设置页跳转及蓝牙、HID、辅助功能真实行为无需重新授权。
