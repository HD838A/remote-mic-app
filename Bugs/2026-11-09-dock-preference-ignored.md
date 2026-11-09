# Dock 开关消失且旧偏好失效

- 状态：本地修复候选。屏幕显隐以实机记录为准。
- 影响：#938 合入后，旧配置中的 `showDockIcon=false` 仍能读取，但启动总是使用 `.regular`，设置页也没有 Dock 开关。

## 证据与根因

在 #938 之后的基线上，启动日志显示 `target_policy=regular` 和 `result=applied`。该日志只证明 AppKit 策略生效。检查默认值和配置恢复路径，确认偏好字段仍在。对基线运行最小源码接线检查时，启动未调用偏好策略，设置页也没有偏好绑定。修复后同一检查通过。此前按窗口状态降级的历史问题见 [设置窗口失焦记录](2026-08-22-settings-window-hides-on-deactivate.md)。

## 修复与验证

启动、开关切换、开窗、关窗和配置导入共用同一策略。设置窗口打开或 Dock 偏好开启时使用 `.regular`，其他情况使用 `.accessory`。两个入口都关闭时启动打开主窗口。AppKit 成功切换策略后刷新图标。

公开构建和测试使用 `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain` 与 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain`。策略组合和调用点由自动化覆盖。真实 Dock 图标、原窗口恢复和 Intel 圆角按 [设置窗口测试手册](../Testing/SettingsWindowFocus.md) 验收。
