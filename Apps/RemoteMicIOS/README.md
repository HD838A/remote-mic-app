# Remote Mic iOS

`RemoteMicIOS` 是独立的 iOS 17+ SwiftUI 伴侣 App。它与仓库中的 macOS App 使用同一个 Apple Developer Team，但拥有独立的 Bundle ID、App Store Connect 应用记录、发布流程和软件许可证。

## 工程标识

- Team ID：`L3QHLDRPAY`
- Bundle ID：`com.hd838a.RemoteMicIOS`
- Scheme：`RemoteMicIOS`
- 最低系统：iOS 17.0
- 签名：Automatic Signing / Apple cloud-managed signing

macOS App 的 Bundle ID 是 `com.hd838a.RemoteMic`。两个 App 不使用同一个 Bundle ID，也不组成 App Store Universal Purchase。

## 当前范围

当前版本提供方向、确定、返回、主页、菜单、TV、关机、音量和按住说话等核心遥控交互，并为每个按键提供震动反馈。Bonjour/TLS 配对、真实按键传输和麦克风音频链路尚未接入，因此当前 TestFlight Build 只能作为界面和真机交互体验版。

## Xcode Cloud / TestFlight

Xcode Cloud 工作流使用以下固定配置：

- 工作流：`RemoteMic iOS TestFlight`
- 源码仓库：`HD838A/remote-mic-app`
- Start Condition：`Branch Changes`
- Custom Branch：`release/testflight`
- Scheme：`RemoteMicIOS`
- Action：iOS `Archive`
- Distribution：`TestFlight (Internal Testing Only)`
- Post-action：分发到 App Store Connect 内部测试组 `Internal Beta`
- Build Number：由 Xcode Cloud 自动分配，不在仓库脚本中改写

日常开发不直接在 `release/testflight` 上进行。只有经过确认的提交进入该分支并 Push 后，才会触发 TestFlight 构建。

Xcode Cloud 使用 Apple 管理的云端分发签名和描述文件。macOS 发布所使用的 Developer ID Application、Developer ID Installer、notarytool profile、Sparkle 私钥、P12 和本地临时 Keychain 均不用于此 iOS 工作流，也不得提交到仓库。

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

`Apps/RemoteMicIOS/` 中的软件代码独立采用 [Apache License 2.0](LICENSE.md)。

以下品牌资产不属于 Apache-2.0 授权范围，继续受仓库根目录的 Logo 专有许可约束：

- `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- `Resources/Assets.xcassets/AppLogo.imageset/AppLogo.png`
- 由上述文件生成或演绎的版本

未经版权所有者书面授权，不得将这些资产用作其他 App、Fork、修改版本、产品或服务的图标、Logo 或品牌标识。
