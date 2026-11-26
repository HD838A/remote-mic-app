# Session event tap 超时导致登录会话输入失效

- 时间：2026-11-26
- 状态：候选修复已实现；自动化待验证，真实长时间运行待验收
- 影响范围：macOS；启用 HID 原生按键抑制的用户
- 原始证据：本机 `runtime.log` 与 WindowServer 统一日志

## 现象与证据

北京时间 12:02 左右，鼠标和键盘输入失效，但 shell、网络和内核仍可用。RemoteMic 2.0.10 build 442 的日志从 `2026-11-26T04:02:44Z` 开始记录七次
`HID FILTER phase=disabled reason=timeout tap=session`，每次之后都立即记录
`phase=reenable_requested result=submitted`。退出 SayAll 后输入恢复。

`KeyboardEventSuppressor` 使用 `.cgSessionEventTap` 和 `.headInsertEventTap`。事件回调与 HID 报告路径共享同一把 `NSLock`；报告路径的 `arm` 在锁内维护多个有界数组和字典。现有日志可以确认 tap 超时和反复重新启用，源码可以确认回调存在锁等待路径；现场没有线程采样，因此不能进一步断言某一次超时具体阻塞在哪条集合操作上。

## 根因

session 级 active event tap 位于 WindowServer 输入投递路径。回调使用阻塞式 `lock.lock()` 等待 HID 报告线程维护共享账本；系统判定回调超时后，旧实现又立即启用同一个 tap，形成“超时、启用、再次超时”的循环。内存压力和 WindowServer 客户端队列积压会放大延迟，但不能解释 RemoteMic 自身连续的 tap timeout。

## 修复

1. 事件回调改用 `NSLock.try()`。共享账本正忙时直接放行当前事件，不等待 HID 报告线程。
2. 收到 `tapDisabledByTimeout` 或 `tapDisabledByUserInput` 后保持 fail-open，不再立即重新启用。功能在 App 重启后恢复，整机输入优先于一次按键抑制。
3. 保留脱敏日志，明确记录 `result=fail_open recovery=app_restart`，便于区分系统禁用与正常停止。

## 验证

- 已新增自动化断言：timeout 回调返回放行且不再产生 `reenable_requested`；账本锁被占用时 tap 回调立即放行。
- `swift test --disable-keychain --filter KeyboardEventSuppressorTests` 未执行成功：本机工具链在编译既有测试目标时统一报 `no such module 'Testing'`。
- 公开模式本地打包、App 校验、安装和启动通过；本地包为 ad-hoc 签名的开发自用构建，不是发布候选。

## 未验证项

- 尚未用真实遥控器和持续内存压力复现原始故障。
- 尚未获得超时瞬间的线程采样；锁竞争是由代码路径与超时行为支持的根因判断，不是逐帧栈证据。
- Productivity Pet 具有相似的 session tap 自动重启结构，但本次日志没有证明它参与故障。
