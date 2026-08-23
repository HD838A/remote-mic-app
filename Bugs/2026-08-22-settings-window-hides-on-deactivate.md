# 设置窗口在失去焦点后被移出屏幕

- 时间：2026-08-22
- 状态：第三轮候选修复完成，等待可见 App 验收
- 影响范围：macOS 无线麦SayAll.app 设置窗口；尤其是关闭“在 Dock 中显示应用图标”时的菜单栏常驻使用方式
- 功能点：设置窗口生命周期、应用前后台切换
- 简单描述：用户切换到其他 App 后，设置窗口被直接移出屏幕；用户期望它仅变为非活跃窗口，且只由红色关闭按钮或 `⌘W` 关闭。
- 原始记录：2026-08-22 用户反馈与两张设置页截图。第二轮反馈确认：关闭“在 Dock 中显示应用图标”后，设置窗口失焦仍会从屏幕消失；同时 Dock 图标在设置窗口仍打开时立即消失。

## 复现与日志

1. 打开无线麦SayAll.app 的设置窗口。
2. 关闭“在 Dock 中显示应用图标”。
3. 当前实现会立即把 App 切换到 `.accessory`，Dock 图标在设置窗口仍打开时消失。
4. 再切换到任意其他 App；用户现场观察到设置窗口直接消失。

正常边界：该偏好应保存为关闭，但设置窗口仍打开时继续显示 Dock 图标并保持普通窗口行为。只有用户点击红色关闭按钮或按 `⌘W` 关闭窗口后，Dock 图标才应按偏好消失。

当前自动化环境没有可操作的无线麦SayAll.app 图形窗口，因此无法在本机重复第 2 步。检查 `~/Library/Logs/RemoteMic/runtime.log` 的最近记录，只包含音频重建事件；现有日志没有窗口失活、隐藏或关闭事件，不能用来确认窗口被移出屏幕的调用来源。

## 代码与根因假设

- 设置窗口是 `NSWindow`，不是默认会在应用失活时隐藏的 `NSPanel`。
- 第一、二轮候选分别固定了 `hidesOnDeactivate` 和 `canHide`，但没有改变 Dock 开关立即执行 `NSApp.setActivationPolicy(.accessory)` 的时机。
- 关闭 Dock 图标时，`setDockIconVisible(false)` 会在设置窗口仍打开的情况下立刻切到 `.accessory`，即 `LSUIElement` 菜单栏模式。这既解释了 Dock 图标立即消失，也使窗口不再保持普通 App 的生命周期。
- 唯一的关闭路径是用户触发的 `NSApp.keyWindow?.performClose(nil)`，由“关闭”菜单项和 `⌘W` 调用。

设置窗口打开期间保持 `.regular` 是最小的生命周期边界：Dock 开关只代表“没有设置窗口时是否显示 Dock 图标”，而不是“立刻把正在使用的窗口降为菜单栏面板”。使用 `NSWindowDelegate.windowWillClose` 能准确对应红色按钮和 `⌘W` 的关闭完成，不会把失焦、最小化或切换 App 当成关闭。

## 修复

- 设置窗口创建时继续设置 `window.hidesOnDeactivate = false`，并接入 `windowWillClose` 生命周期回调。
- 只要设置窗口存在，App 维持 `.regular`，无论 Dock 偏好是否关闭；因此 Dock 图标和窗口会一起保留。
- 红色关闭按钮或 `⌘W` 关闭窗口后，才按保存的 Dock 偏好切换到 `.accessory` 或继续 `.regular`。
- 移除第二轮的 `window.canHide = false`，恢复标准 `⌘H` 隐藏行为；隐藏不是关闭。
- 未修改菜单栏常驻策略、Dock 图标偏好、音频、蓝牙或任何按键路径。

## 验证

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SettingsPageRegressionTests`：第三轮 23 项通过；新增门禁验证 Dock 偏好在设置窗口关闭前不能降级激活策略，且红色关闭按钮与 `⌘W` 仍走现有 `performClose` 路径。当前 SwiftPM 测试 bundle 没有自动复制 Sparkle framework，本机仅在忽略的 `.build/.../PackageFrameworks/` 中创建临时框架链接后执行测试，未改动项目源文件或测试配置。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/build-app.sh`：第三轮通过，生成 ad-hoc 本地测试 App，且 `codesign --verify --deep --strict dist/SayAll.app` 通过。
- 可见 App 验收须按 [设置窗口失焦行为测试手册](../Testing/SettingsWindowFocus.md) 执行。
- 自动化与构建只能证明配置和编译边界，不能替代在真实 macOS 图形会话中观察失焦、`⌘W` 和红色关闭按钮的验收。
