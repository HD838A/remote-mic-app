# 菜单栏图标无法关闭与入口恢复

## 范围

- 关联 PR：#379
- 影响：用户无法隐藏无线麦SayAll.app 的菜单栏图标；如果同时隐藏 Dock 与菜单栏入口，必须仍能通过再次启动 App 恢复设置窗口。
- 不涉及：连接状态、蓝牙、HID、音频、语音键、Onboarding 页面或第三方 App 数据。

## 复现

1. 在当前 `origin/main` 启动 App 并完成 Onboarding。
2. 打开“设置 → 通用”。
3. 尝试隐藏菜单栏图标。

修复前结果：页面只有 Dock 图标开关，`applicationDidFinishLaunching` 每次都会无条件创建 `NSStatusItem`，用户无法关闭菜单栏图标。

正常边界：菜单栏图标关闭后，运行时服务继续工作；Dock 图标仍可独立保留。两个入口都关闭时，正在显示的设置窗口不应被强制关闭，再次从 Finder、Launchpad 或 Spotlight 启动 App 应重新打开设置。

## 日志结论

修复前没有菜单栏显隐请求，因此也没有对应运行日志。已有 `UI STATUS_ITEM` 日志只记录状态图标的连接展示变化，不能表示用户请求创建或移除菜单栏入口。

## 根因

菜单栏状态项生命周期固定绑定到 App 启动：`RemoteMicAppDelegate` 无条件调用 `configureStatusItem()`，`AppSettings` 没有菜单栏显隐偏好，配置导入后也只同步 Dock 激活策略。入口全部隐藏后的冷启动恢复没有独立判断。

## 修复

- 新增默认开启的菜单栏图标偏好，并以可选配置字段保持旧导出文件兼容。
- 状态项创建和移除保持幂等；隐藏时只移除 `NSStatusItem`，不停止后台运行时。
- 配置导入后同步 Dock 与菜单栏入口。
- Dock 与菜单栏都隐藏时，冷启动打开设置；已运行实例再次被启动时沿用系统 reopen 路径打开设置。
- 使用脱敏日志记录请求来源、操作编号、目标显隐状态、是否真正发生创建或移除，以及是否两个入口都已隐藏。

## 验证

- 自动化覆盖默认值、持久化、配置导入导出、旧配置兼容、入口恢复策略和状态项幂等实现门禁。
- 使用生产 `SettingsView` 离屏入口生成中文浅色与深色实际截图，检查 12pt 帮助文字、开关布局和裁切。
- 使用 `swift test --disable-keychain`、Release build、仓库边界检查和 `git diff --check` 验证。

## 验证边界

自动化和离屏截图不能证明真实 macOS 菜单栏项目已经出现或消失，也不能替代 Finder、Launchpad、Spotlight、登录项启动和多显示器菜单栏的人工验收。人工步骤见 `Testing/MenuBarVisibility.md`。
