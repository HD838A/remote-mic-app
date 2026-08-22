# 设置窗口在失去焦点后被移出屏幕

- 时间：2026-08-22
- 状态：第二轮候选修复完成，等待可见 App 验收
- 影响范围：macOS 无线麦SayAll.app 设置窗口；尤其是关闭“在 Dock 中显示应用图标”时的菜单栏常驻使用方式
- 功能点：设置窗口生命周期、应用前后台切换
- 简单描述：用户切换到其他 App 后，设置窗口被直接移出屏幕；用户期望它仅变为非活跃窗口，且只由红色关闭按钮或 `⌘W` 关闭。
- 原始记录：2026-08-22 用户反馈与两张设置页截图。第二轮反馈确认：关闭“在 Dock 中显示应用图标”后，设置窗口失焦仍会从屏幕消失。

## 复现与日志

1. 关闭“在 Dock 中显示应用图标”，使无线麦SayAll.app 使用菜单栏常驻模式。
2. 打开无线麦SayAll.app 的设置窗口。
3. 切换到任意其他 App，使无线麦SayAll.app 失去活跃状态。
4. 用户现场观察到设置窗口直接消失；正常边界是窗口仅显示为非活跃状态，切回无线麦SayAll.app 后仍存在。

当前自动化环境没有可操作的无线麦SayAll.app 图形窗口，因此无法在本机重复第 2 步。检查 `~/Library/Logs/RemoteMic/runtime.log` 的最近记录，只包含音频重建事件；现有日志没有窗口失活、隐藏或关闭事件，不能用来确认窗口被移出屏幕的调用来源。

## 代码与根因假设

- 设置窗口是 `NSWindow`，不是默认会在应用失活时隐藏的 `NSPanel`。
- 第一轮候选已设置 `hidesOnDeactivate = false`，但用户仍能复现，说明窗口失活不是唯一需要覆盖的隐藏路径。
- 关闭 Dock 图标会把 App 设为 `.accessory`，即 `LSUIElement` 菜单栏模式；该策略应只影响 Dock 与菜单栏可见性，不应改变设置窗口的生命周期。
- `NSWindow.canHide` 默认允许应用隐藏时一并隐藏窗口；前一版没有明确覆盖此路径。
- 唯一的关闭路径是用户触发的 `NSApp.keyWindow?.performClose(nil)`，由“关闭”菜单项和 `⌘W` 调用。

AppKit 将“应用失活时隐藏窗口”与“应用隐藏时隐藏窗口”分为 `hidesOnDeactivate` 和 `canHide` 两个独立控制项。第一轮只覆盖前者；第二轮把二者都固定为 `false`。由于当前自动化会话仍不能直接操作现场图形窗口，不能把 accessory 模式实际触发了应用隐藏表述为已确认根因，但该修复覆盖了用户已经证明仍遗漏的系统隐藏边界。

## 修复

- 在设置窗口创建时设置 `window.hidesOnDeactivate = false` 和 `window.canHide = false`。
- 保留标准红色关闭按钮、`⌘W`、最小化和缩放；设置窗口打开时不再参与应用级隐藏。
- 未修改菜单栏常驻策略、Dock 图标偏好、音频、蓝牙或任何按键路径。

## 验证

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SettingsPageRegressionTests`：第二轮 23 项通过；新增门禁要求设置窗口明确禁用失活隐藏与应用级隐藏，并保留现有 `performClose` 的 `⌘W` 关闭路径。当前 SwiftPM 测试 bundle 没有自动复制 Sparkle framework，本机仅在忽略的 `.build/.../PackageFrameworks/` 中创建临时框架链接后执行测试，未改动项目源文件或测试配置。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/build-app.sh`：第二轮通过，生成 ad-hoc 本地测试 App，且 `codesign --verify --deep --strict dist/SayAll.app` 通过。
- 可见 App 验收须按 [设置窗口失焦行为测试手册](../Testing/SettingsWindowFocus.md) 执行。
- 自动化与构建只能证明配置和编译边界，不能替代在真实 macOS 图形会话中观察失焦、`⌘W` 和红色关闭按钮的验收。
