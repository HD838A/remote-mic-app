# HID 权限按实例重复轮询

## 状态与范围

- 状态：二次候选修复；自动化确认每个 Tick 只求值一次，真实 TCC 速率与权限撤销仍需真机验收
- 基线：`db9785260249fdb86df08e9edf7a390f43606486`
- 关联：[Issue #494](https://github.com/HD838A/remote-mic-app/issues/494)、[PR #495](https://github.com/HD838A/remote-mic-app/pull/495)
- 影响：启用实体 HID 遥控器监控后，每个存活的 `HIDRemoteMonitor` 都创建独立 1Hz 权限轮询，使 `IOHIDCheckAccess` 的 TCC IPC 次数随 monitor 数量增长

## 复现

Issue #494 在 macOS 27.0 build 26A428、SayAll 1.9.21 build 174、实体小米遥控器保持连接时记录到：

```text
静默窗口 180 秒：360 次 TCCAccessRequest = 2.00 次/秒
每约 998 ms 连发 2 次，两次相隔 2–3 ms
全部来自同一主线程
```

独立探针确认每次 `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` 都会产生一次 TCC 活动；`CGPreflightListenEventAccess` 同样没有减少调用。当前代码同时存在按设备保存的 `hidMonitors` 和独立 `discoveryHIDMonitor`，且每个实例的 `startPermissionMonitor()` 都通过自己的 scheduler 建立 1Hz 重复任务，因此现场节律与代码结构一致。

本次没有重新读取用户机器统一日志，也不把「现场恰有两个 monitor 实例」写成直接观测事实；2 个实例是由两处容器、同线程节律和每秒 2 次活动共同支持的高置信度结论。

## 日志与代码结论

修复前 App 运行日志只记录启动权限结果和最终 `HID RELEASED permission_revoked`，没有共享轮询的订阅数和定时器启停，因此无法仅靠 App 日志判断是否仍为 N 个定时器。

根因位于：

- `HIDRemoteMonitor.startPermissionMonitor()`：每个实例各自调用 `scheduler.schedule(... repeatingEveryMilliseconds: 1_000)`；
- 默认 `runtimePermissions`：每次调用静态 `HIDRemoteMonitor.isInputMonitoringGranted`，最终进入 `IOHIDCheckAccess`；
- `BridgeAppModel`：按设备持有 `hidMonitors`，另有 `discoveryHIDMonitor`。

输入监控与辅助功能权限是进程级状态，因此实例级重复检查没有额外信息，只增加 TCC IPC 和唤醒。

## 最小修复

- 新增进程级 `HIDPermissionPoll`，所有 monitor 共享一个保持原 1Hz 频率的重复任务和一次权限求值。
- 2026-09-30 合入 #532 后复查发现，当时只共享了 timer，仍由每个订阅回调分别调用 `runtimePermissions`，因此 N 个 monitor 仍可能产生 N 次 TCC IPC。定向复现中两个订阅者的一次 Tick 得到 2 次权限求值。
- 二次修复把进程级权限求值移入 `HIDPermissionPoll`，每个 Tick 只求值一次，再把同一个布尔结果广播给所有 monitor。
- 订阅对象支持显式 `cancel()`，析构时自动退订；最后一个订阅离开后停止定时器，避免原 #495 中依赖 `stop()` 导致的残留空回调。
- 用锁保护订阅表和任务状态；执行回调前只在锁内取快照，实际 handler 在锁外运行，允许 handler 安全触发停止流程。
- `HIDRemoteMonitor` 只把原有权限撤销回调接到共享 poll；权限判定、撤销后的 `stop()`、用户状态和 1 秒检测上限不变。
- 新增脱敏生命周期日志，只记录 `subscriber_count` 与 timer 是否启停，不记录设备身份、按键或用户内容。

没有修改 Siri Remote adapter、权限 API、轮询频率、HID 报告处理、按键映射、语音或音频路径。

## 验证与边界

- 定向自动化覆盖：多订阅仅一个 timer、部分取消、最后取消、重新订阅、析构自动退订、重复取消幂等、回调锁外执行和脱敏日志。
- 二次定向用例覆盖两个订阅者时每个 Tick 只执行一次权限求值，并向两个订阅者广播同一个结果；修复前该用例稳定得到 2 次，修复后为 1 次。
- `swift test --disable-keychain`：768 tests / 59 suites 全部通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：48 passed / 0 failed。
- `swift build -c release --disable-keychain`：通过。
- 双架构 CI 结果在 PR 合入前补充。
- 自动化只证明共享调度与生命周期，不会调用真实 `IOHIDCheckAccess`。仍需在签名候选包连接实体遥控器后确认 TCC 活动不随 monitor 数增长，并实际撤销输入监控权限确认 1 秒内释放按键状态。

二次修复验证：`swift test --disable-keychain` 为 770 tests / 59 suites，项目 Self Test 为 48/48，Release build、仓库边界和治理检查均通过。真实 TCC 速率和权限撤销仍属于签名候选包验收边界。

## 原作者

现场复现、TCC 探针、根因方向和原始共享轮询实现由 [@btiger](https://github.com/btiger) 在 Issue #494 / PR #495 提交；本次重做保留其作者署名，并修复订阅生命周期与并发安全缺口。
