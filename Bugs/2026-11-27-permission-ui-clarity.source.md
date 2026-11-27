---
title: 设置页蓝牙入口与教程浮层的文案和关闭按钮
subtitle: 2026-11-27 修复记录
template: doc
---
Lead: 三处用户可见问题已修复：抖音扫码提示、教程浮层关闭按钮、蓝牙连接与权限入口。

## 现象

- 教程浮层抖音卡片写「保存图片后，用抖音扫一扫」。用户要求直接写「用抖音扫一扫」。
- 教程浮层底部是主题色「关闭」按钮。用户要求去掉，改为右上角弱化 x，与项目已有通知气泡样式一致。
- 设置页蓝牙行只有一个「打开蓝牙设置」按钮，点击进入蓝牙硬件设置。用户需要同时看到「打开蓝牙连接」和「打开蓝牙权限」；后者进入 `Privacy_Bluetooth` 权限页。
- Onboarding 遥控器配对区的「打开蓝牙设置」同样容易和权限页混淆。
- 教程浮层底部教程入口获得键盘焦点时显示主题色焦点圈。
- 教程浮层四周可见外边距小于两张二维码卡片之间的间距。
- 教程浮层整体带投影，用户看到二维码周围有阴影，希望去掉。
- 二维码卡片间距比用户期望的大。

## 根因

- 抖音提示在 `Resources/zh-Hans.lproj/Localizable.strings` 的 `community.help.douyin_hint`，文案沿用了旧版「保存图片后」的引导。
- `CommunityHelpSheet` 使用底部 `Button(localization.text("common.action.close"))`，默认按钮样式显示主题色；项目内 `NoticeBubble` 已有 12pt xmark、24pt 命中区、次级色的弱化关闭按钮。
- `SettingsView.inlinePermissionsSection` 的蓝牙行只渲染一个按钮；`SettingsPageBehavior.permissionAction(for: .bluetooth)` 固定返回 `com.apple.BluetoothSettings`，即硬件设置 URL，不是权限页。
- `OnboardingView.openBluetoothSettingsButton` 使用文案键 `onboarding.remote.open_bluetooth`，当前写「打开蓝牙设置」。按钮实际打开配对所需的硬件设置。Onboarding 权限行本身已在授权后打开 `Privacy_Bluetooth`。
- 教程入口使用 `.buttonStyle(.plain)`，获得键盘焦点时仍显示系统主题色焦点圈。
- 教程浮层使用 `.padding(22)` 和卡片间距 18pt，卡片内二维码居中后，外侧可见间距约 29pt，小于卡片之间约 32pt。
- `CommunityHelpOverlay` 对整张浮层使用 `.shadow(color: .black.opacity(0.28), radius: 30, y: 14)`，用户看到二维码周围有阴影。描边是另一层样式，用户希望保留。
- 卡片间距沿用旧值，用户希望中间间距为 30pt、四侧外边距为 38pt。

## 修复

- 抖音提示改为「用抖音扫一扫」，英文改为「Scan with Douyin」；README 同步。
- 教程浮层移除底部关闭按钮，右上角增加 x。样式与 `NoticeBubble` 一致：12pt、semibold、次级色、24pt 命中区、`.buttonStyle(.plain)`，保留 Esc 和点击遮罩关闭。
- 设置页蓝牙行保留「打开蓝牙连接」打开硬件设置，并新增「打开蓝牙权限」打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth`。两个按钮使用相同的标准按钮样式。
- Onboarding 遥控器配对按钮改为「打开蓝牙连接」；权限行保持打开权限页，不重复增加第二个权限按钮。
- 两张教程入口按钮增加 `.focusable(false)`，保留点击和无障碍标签，不再显示主题色焦点圈。
- 教程浮层改为四侧 38pt 内边距，浮层宽 516pt；二维码卡片之间 30pt。
- 去掉 `CommunityHelpOverlay` 的整层投影；恢复二维码卡片 1pt 描边。
- 新增和更新文案、回归测试：`CommunityHelpSheetTests`、`LocalizationTests`、`SettingsPageRegressionTests`。

## 验证

- 公开模式 `swift build --disable-keychain` 通过。
- 定向测试 105 项 / 4 套件通过。
- 完整测试结果见 PR；真实窗口截图覆盖浅色/深色、中英文、教程浮层 x、设置页两个蓝牙按钮和 Onboarding 配对按钮。
- 真实系统设置需要点击确认，PR 附真实窗口截图；不冒充已完成的真实点击。

## 边界

- 本修复不读取第三方 App 私有数据，不改变蓝牙连接、权限授予或 TCC 状态。
- 设置页的「打开蓝牙权限」只打开系统权限页，不自动授予权限。
- 正式签名 App 首次授权的 TCC 连续性仍按发布流程单独验证。
