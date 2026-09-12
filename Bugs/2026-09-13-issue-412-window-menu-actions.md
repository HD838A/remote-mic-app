# Issue #412：恢复窗口菜单项与快捷键

## 复现与日志

应用菜单缺少隐藏应用、隐藏其他和显示全部，文件菜单缺少最小化，导致标准 macOS 快捷键不可见。

## 根因与修复

当前 `configureApplicationMenu()` 只注册退出、关闭和编辑菜单项。现补回 AppKit responder action：`hide:`、`hideOtherApplications:`、`unhideAllApplications:`、`performMiniaturize:`。

## 验证边界

菜单源码回归断言和完整 Swift 测试通过；尚未替代不同 macOS 版本的菜单栏人工点击验收。
