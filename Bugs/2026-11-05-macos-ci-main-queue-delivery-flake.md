# macOS CI 上主队列投递延迟导致自聚焦用例误报

- 时间：2026-11-05
- 状态：**已修复**（等待预算改为墙钟；生产端 10 秒超时契约不变）
- 影响范围：`macOS CI` 的必需检查（`Public Swift tests and dual-architecture build`），阻塞所有 PR 合并
- 功能点：宏宿主自聚焦请求、CI 测试稳定性
- 简单描述：`ComposerFocusRequest.perform` 把聚焦动作经 `DispatchQueue.main.async` 投递到主队列。同一个测试进程里上千个用例共用主队列，主队列被占住时这次投递会被推迟到几十秒；用例里的等待预算按「轮询次数」或 10 秒内部超时计算，于是被误判成失败。

## Observations

- 2026-11-04 11:00，`main`（`96b9df005`，PR #868 的合并提交）自己的 CI 就以同一形态失败：`ComposerFocusRequestTests` 报 5 个 issue，`Test run with 1186 tests in 85 suites failed after 32.333 seconds`。**该失败发生在本次 ⌘F / ⌘1–⌘9 功能合入之前**，因此不是新功能引入的。
- 2026-11-04 17:16，PR #880 的 CI 失败：`ComposerFocusRequestTests` 5 个 issue（`acceptedRequestWaitsForFinalCallback` 两个参数化用例与 `cancellationInvalidatesFocusAndIgnoresLateCallback` 报 `callback → nil`；`macroSelfFocusCompletesInsteadOfTimingOut` 与 `rejectedRequestReturnsFailure` 报 `Caught error: .timedOut`），`Test run with 1210 tests in 87 suites failed after 27.346 seconds`。
- 2026-11-04 17:51 重跑同一提交，仍然失败在同一个 Suite（这次 2 个 issue，都是 `.timedOut`），整轮 21.569 秒。
- 失败窗口内的 CI 时序（run 41875979953，attempt 2）显示：失败期间同一进程里 `HID permission poll` 的 `sharedPollCallsActualPermissionAPIsOncePerTick` 用了 21.334 秒，且有大批用例在同一时刻（约 6.18 秒）集体结束——典型的「主线程被排队任务占满」形态。
- 本机 7 次全量测试（其中 6 次在并发 release 编译压力下）全部通过，耗时 8.9–9.6 秒；CI 上同一批用例要 21–32 秒。**本机跑不出该失败**，因此必须靠复现夹具定位。

## Root Cause

`ComposerFocusRequest.perform` 的实现是：安装 continuation 后，用 `DispatchQueue.main.async { … start(…) }` 把真正的聚焦动作投递到主队列，再用一个 10 秒的内部超时兜底。

用例侧的两处等待预算都短于 CI 上这次投递的真实延迟：

1. `macroSelfFocusCompletesInsteadOfTimingOut` / `rejectedRequestReturnsFailure` 直接用 `perform` 的默认 10 秒超时。主队列被占住超过 10 秒时，超时任务先到期 → `Caught error: .timedOut`。
2. `acceptedRequestWaitsForFinalCallback` / `cancellationInvalidatesFocusAndIgnoresLateCallback` 用「轮询 1000 次 × `Task.sleep(1ms)`」等回调。慢机器上每次 sleep 会被拉长到十几毫秒，1000 次其实已经过了二十多秒；主队列迟迟不投递时，回调始终是 `nil` → `Expectation failed: callback`。

主队列投递为什么会被推迟：`DispatchQueue.main.async` 的块要等主线程空闲才会执行。同进程内上千个 `@MainActor` 用例把主线程排满时，主队列上的投递就会排到后面。实测（独立最小程序）排除掉了另外两种猜测——**不是** QoS 饿死（主队列积压 2 万个 MainActor 任务时，GCD 块与 MainActor 任务的延迟相同，均约 0.12 秒），**也不是**执行器继承问题（本工具链的 Swift 6 模式下，非隔离 async 函数从 `@MainActor` 调用者进来时仍跑在通用执行器上）。

仓库里已有同一问题的处理范式：`PermissionStatusProbeTests.waitUntil` 的注释明确写着「CI 上会同时跑几百个测试，主队列可能被别人的工作占住数秒」，2026-10-23 就因为 5 秒超时误报过一次，当时把预算提到 20 秒。**2026-11-04 实测到 27 秒后，20 秒也不够了。**

## 复现（决定性证据）

在测试进程里临时加一个占用主线程 30 秒的夹具，其余代码不变：

- **修复前**：整轮 1211 项失败，3 个 issue——
  `ComposerFocusRequestTests.macroSelfFocusCompletesInsteadOfTimingOut`（`.timedOut`）、
  `ComposerFocusRequestTests.rejectedRequestReturnsFailure`（`.timedOut`）、
  `PermissionStatusProbeTests.requestsDuringAnInFlightQueryCoalesceIntoOneRerun`（超时）。
  失败形态与 CI 上一致。
- **修复后**：同样的夹具下整轮 1212 项 / 88 套件全部通过（38.689 秒）。

夹具只用于定位，验证完成后已删除，不入库。

## 修复

1. `ComposerFocusRequestTests`：
   - 等待一律改成**墙钟预算**（`waitUntil(timeout:_:_:)`，60 秒），与 `PermissionStatusProbeTests` 已有范式一致，不再用「轮询次数」推算时间。
   - 需要等回调的用例把 `perform` 的超时显式放宽到 60 秒。
   - 新增 `productionTimeoutRemainsTenSeconds`，按仓库既有的源码守卫范式锁定生产端默认仍是 `timeout: Duration = .seconds(10)`——放宽的是测试预算，不是产品契约。
   - Suite 加 `.timeLimit(.minutes(5))`。
2. `PermissionStatusProbeTests.waitUntil`：预算 20 秒 → 60 秒，并补记 2026-11-04 的 27 秒实测。

## 遗留（不在本次范围）

- **产品侧风险未改**：真实用户按下「聚焦输入框」时，如果主线程正忙（例如正在做虚拟音频重配），这次主队列投递同样可能被推迟到 10 秒之后，`perform` 会按产品契约超时并放弃聚焦。本次只修了测试的误报，没有改生产端的 10 秒超时，也没有改投递方式（改成同步投递会改变「先返回再聚焦」的语义，且 `start` 闭包不是 `Sendable`，需要连带调整 API 与隔离标注）。若要处理，应单独立项。
- CI 上主线程为何会被占住二十多秒尚未定位到具体用例；本记录只覆盖「投递延迟会让这两处用例误报」这一层。
