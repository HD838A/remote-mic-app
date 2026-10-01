# 设置页右侧背景比侧栏明显更灰

- 时间：2026-10-01
- 状态：候选修复完成，自动化与离屏截图验证通过；待真实生产窗口人工确认
- 影响范围：macOS 设置窗口全部页面，macOS 27 浅色外观最明显
- 功能点：设置页共享容器背景

## 复现证据

在 macOS 27 浅色外观打开设置窗口并依次切换侧边栏页面。左侧栏保持较亮背景，右侧所有页面呈现明显灰色遮罩感；页面内容、滚动和控件仍可操作。用户提供的原始 PNG 为 `2040 × 1552`，本地校验 SHA-256 为 `94678c23f89d0b2f1fd73d5e03eb3f4fca576451498c084339bc6f3ea19436ea`。原图含设备标识，只作为本地复现证据，不提交仓库。

正常边界是：侧栏与右侧页面使用同一设置窗口基础背景，分区只通过分隔线、卡片和语义层级区分，不应让整块页面看起来被灰色遮罩覆盖。

## 日志结论

该现象在设置窗口首次渲染后稳定存在，切换页面不会改变；运行时日志没有权限、连接或页面失败事件。问题属于静态 SwiftUI 背景取色，不涉及设备状态机或异步数据结果。

## 根因

`Sources/RemoteMic/SettingsView.swift` 的根容器使用 `NSColor.windowBackgroundColor`，侧栏单独使用 `NSColor.controlBackgroundColor`。macOS 27 浅色外观下两种系统色差异明显，因此右侧共享页面区域整体更灰。

## 修复

设置窗口根容器改用与侧栏一致的 `controlBackgroundColor`。不修改页面内部卡片、分隔线、材质、深色模式或窗口尺寸。

## 验证

- 修复前新增回归测试 `settingsSidebarAndPageUseTheSameBackgroundColor`，在主线代码上按预期失败。
- 修复后定向测试与完整 `SettingsPageRegressionTests` 通过。
- 使用生产 `SettingsView` 离屏入口生成 `1020 × 772` 中文浅色和深色截图，核对侧栏、右侧页面、分隔线、页头和滚动区域无整块色差与裁切。
  - `Screenshots/bug-fixes/settings-background/mapping-light-1020x772.png`，Retina PNG `2040 × 1544`，SHA-256 `221d27d978fb85523b8be7c61e26ca7f01734f1d1921787cc107944f1f4c3c21`
  - `Screenshots/bug-fixes/settings-background/mapping-dark-1020x772.png`，Retina PNG `2040 × 1544`，SHA-256 `b2e18ff9396cbecf5adf9213159489a1bb786192ff444c3ed4956b6f503735db`
- `swift build --disable-keychain -c release`、`git diff --check` 通过。

## 自动化与真实界面边界

源码回归测试可以防止共享根背景再次改回不同系统色；离屏截图可以验证当前系统的静态取色和布局。仍需在用户实际 macOS 27、生产窗口与显示器色彩设置下人工确认主观灰度观感。
