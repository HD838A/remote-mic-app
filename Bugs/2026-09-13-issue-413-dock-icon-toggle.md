# Issue #413：Dock 图标开关无效

## 复现与日志

在设置中关闭“在 Dock 中显示应用图标”后打开设置窗口，原实现仍因窗口可见而保持 `.regular`，因此 Dock 图标不会隐藏。该路径没有外部 App 私有数据依赖。

## 根因与修复

Dock 激活策略错误地把设置窗口状态作为强制显示条件。现改为只遵循 `showDockIcon` 用户偏好；设置窗口仍可通过菜单栏打开。

## 验证边界

`SettingsPageRegressionTests` 与完整 Swift 测试通过；尚未替代真实 macOS Dock 缓存和多显示器验收。
