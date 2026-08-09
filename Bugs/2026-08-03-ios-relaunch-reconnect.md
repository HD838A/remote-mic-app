# iOS 重启后仍无法重新连接 Mac

- 时间：2026-08-03
- 状态：已修复
- 影响范围：iOS 0.8.1/0.8.2；已信任设备重启后
- 功能点：附近连接、长期身份与会话接管
- 简单描述：iOS 重启后旧连接和新连接的身份、会话接管状态可能冲突，造成已授权设备无法自动恢复。
- 原始记录：DEBUG.md，首次记录 af3f8b8

## 详细过程

## Observations

- 用户真机反馈：iOS 与 Mac 最初连接成功；一段时间后连接失败，重启 iOS App 仍不能恢复；重启 Mac App 并再次点击“连接手机”后立即恢复。
- 当前环境中的历史运行日志包含手机监听启动和授权成功记录，没有出现 `listener_failed`；本次用户现场无法在开发机上原样复现，因此以用户步骤和现有状态机边界作为最小复现条件。
- `PhoneRemoteServer.accept(_:)` 在已有客户端时，只允许 `canBeReplaced == true` 的客户端被替换；已授权客户端的 `canBeReplaced` 永远为 `false`，所以新的 TCP 连接会在协议握手前被直接取消。
- 旧客户端只有在 Network.framework 报告 `.failed` / `.cancelled` 或接收回调返回完成/错误时才从 `clients` 移除；服务端没有心跳，也没有允许新的已认证会话接管旧会话的路径。
- 重启 iOS 会创建新的连接，但不会改变 Mac 内存中的旧 `clients`；重启 Mac 会执行 `PhoneRemoteServer.stop()` 并清空全部客户端，和用户观察完全一致。
- iOS App 重启会重新创建 `NWBrowser`，因此“已有 Bonjour 结果没有再次触发”不能解释重启 iOS 后仍持续失败。

## Hypotheses

### H1: Mac 中残留的已授权旧客户端阻塞了所有新连接（ROOT HYPOTHESIS）

- Supports: 新连接在 `accept(_:)` 中会被已授权客户端无条件拒绝；重启 iOS 不清理 Mac 状态，重启 Mac 会清空客户端；三者与用户步骤逐项对应。
- Conflicts: 没有现场 Network.framework 状态日志能证明旧 TCP 连接当时仍被系统视为活跃。
- Test: 沿新连接接入路径验证“旧客户端已授权”时是否存在任何继续握手或认证后接管的分支。

### H2: Mac 的 `NWListener` 失败后仍被非空引用阻止重启

- Supports: `.failed` 当前只写日志，没有清空 `listener`；同一 App 生命周期内再次调用 `startOnQueue()` 会被 `listener != nil` 拦截。
- Conflicts: 现有手机连接日志没有 `listener_failed`；用户重启 iOS 时表现为连接失败，而不是明确的服务完全消失。
- Test: 检查现场日志是否存在 `listener_failed`，并确认失败后 Bonjour 服务是否消失。

### H3: iOS 断线后没有重新使用已有 Bonjour 服务结果

- Supports: `handleFailure` 会清空 `pendingEndpoint`，浏览结果不变化时当前实例不会自动重连。
- Conflicts: 用户已重启 iOS App，新的 `NWBrowser` 会重新收到服务结果；仍需重启 Mac 才恢复。
- Test: 新建 iOS 连接对象并确认首次浏览结果会调用 `connect(to:)`。

## Experiments

### E1: 验证 H1

- 接入路径检查结果：当旧客户端 `isApproved == true` 时，`canBeReplaced` 为 `false`，`accept(_:)` 立即取消新连接；后续身份校验、长期信任和授权逻辑均不会执行。
- 生命周期检查结果：iOS 重启只产生新的客户端；Mac 重启会调用 `stop()`，清空 `clients` 并取消旧客户端。
- 结论：H1 confirmed。修复点应位于 Mac 客户端接纳策略，不能要求用户重启任一 App，也不能让未授权的新连接直接踢掉正常连接。

### E2: 验证 H2

- 历史运行日志中没有手机监听失败记录，当前证据不足以把监听器失败列为本次根因。
- 结论：H2 inconclusive，本次不扩大范围修改监听器生命周期。

### E3: 验证 H3

- iOS `RemoteMacConnection` 初始化后会创建全新的浏览器；浏览器 ready 且收到服务结果时会调用 `connect(to:)`。
- 结论：H3 rejected，无法解释重启 iOS 后仍被持续拒绝。

## Root Cause

Mac 服务端把首个已授权客户端视为永远不可替换；当底层连接已经失效但 Network.framework 尚未关闭旧对象时，所有新 iOS 连接都会在认证前被取消，只有重启 Mac 清空内存会话后才能恢复。

## Fix

- 保留正常的已授权连接，同时允许新的待认证连接完成握手。
- 新连接只有在完成长期信任校验或用户授权、并成功发送 ready 后，才取消并替换旧客户端。
- 多个未授权连接仍互相替换，避免待认证客户端无限累积；未授权连接不能直接中断正常客户端。
- 验证：会话替换策略回归测试通过；Mac 86 项 Swift Testing、36 项 Self Test、macOS Release 构建、iOS Debug/Release 模拟器构建全部通过。
