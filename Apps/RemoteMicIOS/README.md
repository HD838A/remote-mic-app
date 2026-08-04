# Remote Mic iOS

`RemoteMicIOS` 是独立的 iOS 17+ SwiftUI 伴侣 App。它拥有独立的 App Store Connect 应用记录、发布流程和软件许可证。

## 工程与发布

- Scheme：`RemoteMicIOS`
- 最低系统：iOS 17.0
- 签名：Automatic Signing / Apple cloud-managed signing

开发者团队和应用标识由发布配置维护，不在公开说明文档中列出。iOS 与 macOS App 拥有独立的应用记录，不组成 App Store Universal Purchase。

## 当前范围

当前版本提供方向、确定、返回、主页、菜单、TV、关机、音量和按住说话等核心遥控交互，并为每个按键提供明显的震动反馈。页面使用固定单屏布局，不支持滚动。

中间六个按钮使用已经确认的固定布局：第一行依次为“返回 / 菜单 / 音量+”，第二行依次为“主页 / TV / 音量-”。除非产品需求明确变更，否则开发和重构不得调整该顺序。

iOS App 会自动发现附近运行新版无线麦的 Mac，显示真实 Mac 名称，并复用 Mac 端现有按键映射和虚拟音频输出。首次连接时，双方显示同一个两位校验码；用户在 Mac 明确允许后，按键和 16kHz 单声道麦克风音频通过安全连接传输。

首次允许后，该次 iOS App 安装会成为受信任设备，后续附近连接自动授权。删除并重新安装 iOS App，或在 Mac 设置中清除受信任设备后，需要重新确认。当前版本没有跨互联网控制能力；iOS 与 macOS App 必须同时更新到包含手机伴侣连接功能的版本才能使用真实遥控和语音链路。

从遥控页右上角可以重新发现 Mac 并进入 Mac App 信息页。该页面固定为单屏、不支持滚动，展示连接详情与检查结果、实体麦克风遥控器建议、GitHub 最新版下载链接，并支持通过系统分享（包括 AirDrop）发送链接或复制链接。布局已在 iPhone 12 模拟器验证完整显示；iPhone 只作为临时应急方案，日常仍推荐使用按键反馈更清楚、更稳定的实体麦克风遥控器。

## Xcode Cloud / TestFlight

Xcode Cloud 工作流使用以下固定配置：

- 工作流：`RemoteMic iOS TestFlight`
- 源码仓库：`HD838A/remote-mic-app`
- Start Condition：`Branch Changes`
- Custom Branch：`release/testflight`
- Scheme：`RemoteMicIOS`
- Action：iOS `Archive`
- Distribution Preparation：`App Store Connect`（构建可用于内部及外部 TestFlight）
- Post-action：分发到 App Store Connect 内部测试组 `Internal Beta`
- Build Number：由 Xcode Cloud 自动分配，不在仓库脚本中改写
- 当前发布版本：`0.8.5`

日常开发不直接在 `release/testflight` 上进行。只有经过确认的提交进入该分支并 Push 后，才会触发 TestFlight 构建。

自动化发布任务以 `release/testflight` Push 成功为交接边界。Push 后不等待或轮询 Xcode Cloud、App Store Connect 和 TestFlight 的异步处理状态；只有在当前任务明确要求监控时才继续检查。构建完成和测试组可安装状态由发布人员稍后在 App Store Connect 中确认。

Xcode Cloud 使用 Apple 管理的云端分发签名和描述文件。macOS 发布所使用的 Developer ID Application、Developer ID Installer、notarytool profile、Sparkle 私钥、P12 和本地临时 Keychain 均不用于此 iOS 工作流，也不得提交到仓库。

本地验证按改动范围执行：纯 iOS UI 修改不运行完整 Mac 测试；共享协议或 Mac 代码变化时才补充相关 Mac 测试。涉及布局变化时至少使用 iPhone 12 尺寸确认单屏完整显示；页面和状态未变化时不重复生成相同截图。

## 本地构建

工程由 `project.yml` 通过 XcodeGen 生成：

```sh
cd Apps/RemoteMicIOS
xcodegen generate
xcodebuild \
  -project RemoteMicIOS.xcodeproj \
  -scheme RemoteMicIOS \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## 许可

`Apps/RemoteMicIOS/` 中的软件代码采用 [GNU General Public License v3.0 only（GPL-3.0-only）](LICENSE.md)。

以下品牌资产不属于 GPL-3.0-only 授权范围，继续受仓库根目录的 Logo 专有许可约束：

- `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- `Resources/Assets.xcassets/AppLogo.imageset/AppLogo.png`
- 由上述文件生成或演绎的版本

未经版权所有者书面授权，不得将这些资产用作其他 App、Fork、修改版本、产品或服务的图标、Logo 或品牌标识。
