# iOS 从后台返回后不自动重连

- 时间：2026-08-03
- 状态：已修复
- 影响范围：iOS 0.8.2/0.8.3；App 后台返回
- 功能点：Bonjour 发现与前台生命周期
- 简单描述：App 回到前台时发现浏览器没有按状态正确恢复，导致断线后长期停留在查找状态。
- 原始记录：DEBUG.md，首次记录 d26a6a6

## 详细过程

## Observations

- 用户真机反馈：iOS App 与 Mac 已连接，退到后台再返回后不会自动连接；点击右上角 Mac 按钮后可立即恢复。
- `RemoteControlScreen` 只在首次 `.task` 中调用 `connection.start()`，没有监听 `scenePhase`。
- `RemoteMacConnection.start()` 在 `browser != nil` 时直接返回；连接失败会清空 `connection`，但不会清空仍存在的 `browser`。
- 右上角按钮调用 `restartDiscovery()`，会取消并清空连接、浏览器和会话状态，再重新开始发现。

## Hypotheses

### H1: App 返回前台时缺少生命周期重连入口（ROOT HYPOTHESIS）

- Supports: 页面没有 `scenePhase` 监听；用户必须手动调用与重新发现等价的右上角按钮。
- Conflicts: 如果底层连接在后台始终保持健康，则不应重启正常连接。
- Test: 仅在 App 重新进入 active 且当前未连接时调用 `restartDiscovery()`，验证是否能恢复且不打断健康连接。

### H2: 普通 `start()` 可以在前台恢复现有浏览器

- Supports: `start()` 是页面首次启动入口。
- Conflicts: `browser != nil` 时它明确提前返回，无法重置后台留下的浏览器或连接状态。
- Test: 在 `connection == nil && browser != nil` 的状态调用 `start()`，确认不会创建新浏览器。

### H3: Mac 服务端必须重新点击“连接手机”才能恢复

- Supports: 历史上曾存在 Mac 旧会话阻塞新客户端的问题。
- Conflicts: 本次点击 iOS 右上角按钮即可恢复，说明 Mac 监听和接纳流程仍可用。
- Test: 保持 Mac 端不操作，仅触发 iOS 完整重新发现；成功即排除此假设。

## Experiments

- E1：加入前台 active 状态的条件重新发现入口，并临时记录 `restartDiscovery()` 调用。模拟器进入主屏幕后重新打开 App，日志确认同一进程调用了完整重新发现。
- E2：条件限定为 `!connection.isConnected`，正常连接状态不会被前台切换打断；首次 `.task` 仍负责冷启动，不依赖场景变化。
- E3：`start()` 在旧 `browser` 仍存在时直接返回，确认普通启动入口不能修复此状态；H2 rejected。
- E4：实验期间未操作 Mac 端，iOS 端前台恢复即可触发与右上角按钮相同的重新发现路径；H3 rejected。

## Root Cause

iOS 页面没有监听从后台返回 active 的生命周期；后台期间连接失效后，仍存在的浏览器对象会让普通 `start()` 提前返回，因此只有手动点击右上角执行完整重新发现才能恢复。

## Fix

- 监听 `scenePhase`，App 回到 active 且当前未连接时调用现有 `restartDiscovery()`。
- 已连接时不重启，避免打断健康会话以及系统权限弹窗返回后的正常连接。
- 不修改发现协议、配对授权、长期信任或 Mac 服务端逻辑。
- 验证：模拟器同进程后台/前台实验确认重新发现被触发；使用截图中的真实自定义标题完成视觉复核，`Command-Tab` 完整显示，菜单与同排按钮标题基线一致；86 项 Swift Testing、36 项 Self Test、iOS Debug/Release 模拟器构建全部通过。
