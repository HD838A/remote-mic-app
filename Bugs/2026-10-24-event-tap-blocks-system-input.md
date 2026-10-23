# 主线程同步查权限 + event tap 挂在主 RunLoop，导致整机输入停摆

- 时间：2026-10-24
- 状态：根治已实现（事件 tap 迁到专用线程、权限查询移出主线程、权限撤销时释放 tap）；构建、定向回归与三组修复前后对照通过，等待真机按键链路与真实权限切换场景验收
- 影响范围：macOS；所有把自定义映射（`customMappingEnabled`）或 `ShortcutCaptureMonitor` 开启的用户；触发条件是「主线程出现秒级阻塞」×「阻塞期间有输入事件到达」。用户在系统设置里改本 app 权限、或 tccd 抖动时最容易命中
- 功能点：HID 按键抑制（`KeyboardEventSuppressor`）、自定义快捷键录入（`ShortcutCaptureMonitor`）、event tap 接入点（`EventTapPort`）、开机引导页权限刷新（`OnboardingView`）、权限撤销释放路径（`HIDRemoteMonitor`）
- 简单描述：两处 **active tap**（`.defaultTap`）的 RunLoop source 被挂在主 RunLoop 上，同时引导页用 1 Hz 定时器在主线程同步查询三项 TCC 权限。主线程一旦被 tccd 的同步 IPC 钉住，尚未返回的 tap 回调就会把整条系统输入队列一起卡住——光标能动、所有 app 不响应、进程不崩不重启，直到进程被杀
- 原始记录：本机实测（Apple Silicon，macOS 27）；用户当场反馈，无 Issue

## 观察

### 用户现场（2026-10-24 02:1x）

- 操作序列：在开机引导页（onboarding）**打开系统蓝牙**，随后**关闭本 app 的蓝牙权限** → 整机失去响应。
- 症状：**鼠标指针仍能移动**，但无法操作任何软件（点击、键盘输入均无反应）。
- 该状态持续到用户手动干预，**不是**几秒后自愈。
- 处置：结束本 app 的进程后，用户当场确认「干掉后立刻就恢复了！」。
- 关键点：恢复**不需要**重启、不需要登出、不需要重启 WindowServer，只需要杀掉本 app。

### 解密日志取证（`.rmlog` 经 `sayall-rmlog-decrypt` 解密）

会话日志 `sayall.app-2026-10-23-session-8FBF7B8D.rmlog`（`pid=85253`，638 条记录）解密成功。下文时间为日志原始 UTC，括号内为北京时间（UTC+8）。

| 时间 | 事件 |
| --- | --- |
| 17:27:20（01:27:20） | 应用启动；`HID PERMISSIONS input=true accessibility=true`；`HID START mode=adaptive` ×2；`HID FILTER ready=true` |
| 17:27:21（01:27:21） | `ONBOARDING STEP entered=remote`，随后 `ONBOARDING EVENT kind=blocked step=remote failure=remote.not_found` |
| 17:46:55（01:46:55） | `UI ENTRY_POINT source=application_reopen decision=open_settings`（用户第一次进系统设置） |
| 17:47:04（01:47:04） | `ONBOARDING STEP entered=permissions` —— **应用此后一直停在权限页** |
| 17:49:35 / 17:56:12（01:49:35 / 01:56:12） | 两次 `application_reopen → open_settings` |
| 17:56:24（01:56:24） | `ONBOARDING EVENT kind=blocked step=permissions failure=permission.accessibility_denied`；`HID PERMISSION POLL phase=unsubscribed` ×2（订阅数归零、轮询停止）；`HID RELEASED permission_revoked` ×2 |
| 17:57:13（01:57:13） | `HID FILTER miss type=14 event=sys4 edge=down/up` —— **权限撤销 49 秒后，event tap 回调仍在执行** |
| 18:02:13–18:02:24（02:02:13–02:02:24） | 蓝牙耳机接入引发音频设备变化 → 两轮 `AUDIO RECOVERY`（`reason=hardware_change`），最终 `AUDIO RECOVERY phase=completed result=ready` |
| 18:02:24 之后（02:02:24 之后） | **应用完全静默 12 分钟**：除后台会员权益轮询外没有任何业务日志 |
| 18:14:30（02:14:30） | 最后一条记录：会员权益 `refresh phase=requested`，**没有配对的 `phase=failed`**（此前每次都在 230–340 ms 后落地）。此即进程被 SIGKILL 的时刻 |

这份日志把三件事钉死了：

1. **冻结窗口 = 02:02:24 → 02:14:30**，共约 12 分钟。02:02:13 的音频设备变化正是「打开系统蓝牙 → 蓝牙耳机接入」造成的，与用户描述的操作序列完全吻合；应用在此之后立刻停止一切业务动作。
2. **1 Hz 同步 TCC 查询当时确实在跑**：应用从 01:47:04 起就停在 onboarding 的 `permissions` 页，`OnboardingView` 的权限刷新定时器一直在该页生效，直到进程被杀。
3. **event tap 在冻结时确实活着**：`HID FILTER` 只由 `KeyboardEventSuppressor.handle()` 输出，它最后一次出现在 01:57:13；此后没有任何 `HID START`（即 `startHIDMonitors()` 没有再被调用），也没有任何 `stopHIDMonitors()` 路径被触发——所以那条 active tap 一直挂到进程被杀。

### 本机取证（2026-10-24 02:20–02:24）

- **不是断电/重启造成的错觉**：`uptime` → `up 4 days, 5:09`，机器当次开机已连续运行超过 4 天。
- **不是内核 panic**：`~/Library/Logs/DiagnosticReports/` 中 2026-10-23 22:40 之后无任何新增报告；`/Library/Logs/DiagnosticReports/` 中 02:1x 也没有 RemoteMic 相关条目。系统没有判定为 hang 并落盘 spindump。
- **进程没有崩溃**：App 是「活着但不响应」，用户是通过 SIGKILL 结束的，不是它自己退出。

### 当前代码（修复前）

- `Sources/RemoteMic/EventTapPort.swift:15-18`（`activate`）：

  ```swift
  CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  CGEvent.tapEnable(tap: port, enable: true)
  ```

  两处 tap 创建点共用这一行，于是 `KeyboardEventSuppressor`（`options: .defaultTap`，`KeyboardEventSuppressor.swift:57`）与 `ShortcutCaptureMonitor`（`options: .defaultTap`，`ShortcutCaptureMonitor.swift:69`）的回调**全部在主线程上执行**。
- `Sources/RemoteMic/OnboardingView.swift:139-143` / `:212-221` / `:3714-3718`：引导页用一个 1 Hz 的 `Timer.publish(every: 1, on: .main, in: .common)` 在主线程上每秒执行一次

  ```swift
  bluetoothAuthorization = CBManager.authorization
  inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
  accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
  ```

  这三项分别是 `CBManager.authorization`（CoreBluetooth → tccd）、`IOHIDCheckAccess`（IOKit → tccd）、`AXIsProcessTrusted`（AX → tccd），**都是同步 IPC**。
- `Sources/RemoteMic/HIDRemoteMonitor.swift`（`releaseForRevokedPermissions`）：权限撤销时只释放 HID 设备监听。`stop()` 里的 `if ownsEventSuppressor { eventSuppressor.stop() }` 因 `BridgeAppModel` 传入 `ownsEventSuppressor: false` 而不成立——**共享的 active tap 因此在权限撤销后继续存活**，这正是 01:57:13 仍有 `HID FILTER` 的原因。
- `Sources/RemoteMic/SettingsView.swift:4911-4915` 是同一组查询，但只在 `.onAppear` 与 `didBecomeActive` 触发，不是定时器；`setCustomMappingEnabled` 还需要它的**同步**结果来决定是否弹授权提示，本次未改（见「后续」）。

## 假设

### H1：active tap 的回调未返回会阻塞系统输入派发

active（非 listen-only）tap 的语义是「先给我看，我说放行才继续」。回调不返回，事件就不会继续派发给下游 app。既然是**全系统**的 session tap，被卡住的就是所有 app 的输入。光标由 WindowServer 独立绘制，不经过这条链路，所以「鼠标能动、别的都不动」。置信度：高（机制本身是 CGEventTap 的既定语义）。

### H2：回调挂在主 RunLoop 上，把「本 app 主线程慢」放大成「整机输入停摆」

主线程被同步 IPC 钉住 → 主 RunLoop 不再服务 tap 的 mach port source → 已经进入或正在排队的回调无法返回 → 输入队列整体停在原地。置信度：中高。代码事实明确（`CFRunLoopGetMain()`），解密日志确认冻结时那条 tap 仍在运行，但缺少主线程栈来指认具体是哪一次查询、卡在哪一帧。

### H3：为什么没有在 1 秒后自愈

系统对 event tap 有 `tapDisabledByTimeout` 看门狗：回调超时会禁用该 tap 并把事件放行。`KeyboardEventSuppressor.swift:148-153` 与 `ShortcutCaptureMonitor.swift:101-106` 都实现了「收到该类型就重新 enable」。但看门狗要生效，仍需要 tap 所在线程**能跑起来**去接收这个通知。当这条线程就是被钉住的主线程时，看门狗既叫不动回调、也无法让 tap 恢复。置信度：中。这解释了「不是短暂卡顿，而是停摆 12 分钟」，但同样缺栈佐证。

### H4（已排除）：tccd / 蓝牙子系统整体卡死

如果只是 tccd 或 `bluetoothd` 自己卡住，结束本 app 的进程不会让整机恢复——它只会让本 app 自己不再查权限。反向证据（用户当场确认杀掉即恢复）足以排除这一解释，也把责任收敛到本进程持有的机制上；本进程能阻塞系统输入的机制只有那两处 active tap。

### H5（已排除）：崩溃或内核级卡死

解密日志显示进程存活到 02:14:30 且仍在写日志；系统没有生成 panic 或 hang 报告。进程是「活着但不响应」。

## 实验

1. **静态确认挂载点**：`grep -rn "CFRunLoopGetMain" Sources/` 只命中 `EventTapPort.activate/release` 两处，两处 tap 创建点都走它，没有第三条旁路。两处 `CGEvent.tapCreate` 的 `options` 都是 `.defaultTap`（active），不是 `.listenOnly`。
2. **解密日志确认现场前提**：见「解密日志取证」的三条结论——引导页停在 `permissions`、1 Hz 刷新在跑、冻结时 active tap 仍在。
3. **新增回归断言（接入点）**（`Tests/RemoteMicTests/EventTapPortTests.swift`）：

   ```swift
   #expect(CFRunLoopContainsSource(tapRunLoop, source, .commonModes))
   #expect(!CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
   ```

   直接断言「source 落点不是主 RunLoop」。
4. **修复前后对照（接入点）**：把 `EventTapPort.activate` 临时改回 `CFRunLoopAddSource(CFRunLoopGetMain(), ...)` 后跑同一组用例，`tapSourceLandsOnTheDedicatedRunLoopInsteadOfMain()` 立刻失败：

   ```
   Expectation failed: CFRunLoopContainsSource(tapRunLoop, source, .commonModes)
   Expectation failed: !CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes)
   ```

   恢复修复版后通过。同一用例从失败变为通过。
5. **证明新 RunLoop 真的在派发**：event tap 的投递本质是「mach port source 被 RunLoop 服务」。用 `CFMessagePort`（同为 mach port source，且只在本进程内发一条消息、不注入任何真实输入）搭一条安全替代链路，断言回调在 3 秒内到达且**不在主线程**：

   ```
   Test tapRunLoopServicesMachPortSourcesOffTheMainThread() passed after 0.006 seconds.
   ```

   这一步排除了「端口在、回调不来」这种表面修复。
6. **新增回归断言（权限撤销释放 tap）**（`Tests/RemoteMicTests/HIDPermissionRevocationTests.swift`）：共享 suppressor + `ownsEventSuppressor: false` 的监视器在权限撤销后，suppressor 必须停止运行。
7. **修复前后对照（权限撤销释放 tap）**：去掉 `releaseForRevokedPermissions()` 里新增的 `eventSuppressor.stop()` 后，`revokedPermissionsReleaseTheSharedEventTap()` 失败：

   ```
   Expectation failed: !suppressor.isRunning
   ```

   恢复修复版后通过。同一用例从失败变为通过。
8. **本机没有复现卡死**：见「当前验证边界」第 1 条。

## 根因

三条独立的缺陷叠在一起才构成整机停摆：

1. **接入点选错**（`EventTapPort.activate`）：两处全系统 active tap 的回调被挂到 `CFRunLoopGetMain()`。active tap 的「回调不返回就不放行」语义是全系统范围的，而主线程恰恰是本 app 最容易出现秒级阻塞的地方（同步 TCC、磁盘、任何同步等待）。这等于把本 app 的局部卡顿接成了整机的输入阀门。
2. **阻塞源就在主线程上**（`OnboardingView` 的 1 Hz 刷新）：每秒 3 次同步 TCC 查询。平时每次几百微秒、无感；用户在系统设置里改本 app 权限的那一瞬间，tccd 正在结算授权，往返被拉长到「秒」级，主线程被钉住，第 1 条随即生效。
3. **权限撤销没有连带释放 tap**（`HIDRemoteMonitor.releaseForRevokedPermissions`）：共享 suppressor 的生命周期只跟随 `applyHIDSettings()`，权限被撤销时 tap 继续挂在系统输入路径上——授权已经收回却仍在拦截按键，也让第 1 条的前提条件在权限变更窗口内始终成立。

只修 1：主线程仍会卡，只是不再拖累系统，表现为「引导页卡几秒」。
只修 1+2：卡死不再发生，但授权收回后仍留着一条 active tap。
三条都修：接入点不再依赖主线程、阻塞源离开主线程、授权收回即刻释放 tap。

根因置信度：**中高**。代码事实（1、2、3）可静态确认，解密日志确认了现场前提（引导页停留位置、tap 存活、冻结窗口），反向证据（杀进程即恢复）把责任收敛到本进程；缺的是主线程栈——因此「哪一次 TCC 查询卡在哪一帧」仍未确定。

## 修复

### A. 事件 tap 迁到专用线程

- 新增 `Sources/RemoteMic/EventTapRunLoop.swift`：一个专用 `Thread` + 自有 `CFRunLoop`，用 100 年后的定时器保活（RunLoop 只有持有 source/timer 时才会停在 `CFRunLoopRun()` 里）。提供 `performAndWait`，在 tap 线程上同步执行代码块；已经在 tap 线程上时直接就地执行，避免自锁。
- `EventTapPort.activate` / `release` 改为经 `performAndWait` 在 tap 线程上完成「加/摘 source + enable/disable + invalidate」：
  - 加 source 先于 enable。`activate` 返回 `Bool`；**接不住 source 时绝不 enable**——一个已 enable 却无人承接的 tap 只会让事件堆在端口里，比不使用 tap 严重得多。
  - `release` 的 invalidate 与正在执行的回调天然串行，避免端口在回调还在栈上时被另一条线程作废。
- `KeyboardEventSuppressor` / `ShortcutCaptureMonitor`：
  - `start()` 尊重 `activate` 的返回值，失败时走同一条 `release` 清理路径并返回启动失败；
  - `eventTap` / `runLoopSource` 的读写改为持 `lock` 交接——回调已经跨线程，原来的无锁读写会变成真实数据竞争。

### B. 权限查询移出主线程

- 新增 `Sources/RemoteMic/PermissionStatusProbe.swift`：三项查询固定跑在一条串行队列上，结果回主线程交付；同一时刻只允许一次查询在飞，飞行期间到达的请求**合并成一次重跑**（否则 tccd 卡住时 1 Hz 定时器会堆出无限多个排队查询，恢复后还要逐条补跑）。
- `OnboardingView.refreshPermissionStates()` 改为调用它，并且只在值真的变化时才写 `@State`，避免每秒无谓的视图失效。

### C. 权限撤销时释放 active tap

- `HIDRemoteMonitor.releaseForRevokedPermissions()` 增加 `eventSuppressor.stop()`。这一处**不受 `ownsEventSuppressor` 约束**：那个标记针对的是「本监视器因设备移除等局部原因停止」，而权限撤销是全局的，用户已经收回授权。
- 释放后由既有的 `applyHIDSettings()` → `startHIDMonitors()` 路径重建，与 HID 设备监听的恢复时机完全一致，**不会多出新的恢复要求**（两者本来就在同一条路径上启停）。

### 为什么 `activate` 要改成返回 `Bool`

原实现是「加 source → 直接 enable」，没有任何失败分支。把 source 挪到另一条线程后，就多了一种「source 没接上」的可能。此时若仍然 enable，系统会把所有输入事件投进一个没人读的端口——**比本 Bug 的后果更严重**（本 Bug 还能靠杀进程恢复，那样会连恢复都很困难）。所以失败必须显式向上传，让两处 `start()` 按启动失败处理。

## 验证

- **构建**：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests --disable-keychain --disable-sandbox` → `Build complete!`，无新增 warning（只有既有的 `onChange(of:perform:)` / `allowedFileTypes` 弃用警告）。
- **定向回归**：`swift test --filter "EventTapPortTests|PermissionStatusProbeTests|HIDPermissionRevocationTests|OnboardingFlowTests"` → 全部通过（含 7 条 event tap、2 条权限探针、2 条权限撤销、76 条 onboarding）。
- **修复前对照**：见「实验」第 4、7 条，两条新断言都在旧实现下失败、修复后通过。
- **完整套件**：`swift test --disable-keychain --disable-sandbox` → **955 个用例、76 个套件，954 通过，1 个失败**。失败项是 `releaseControlPlaneFixtureHasExecutableRegressionCoverage()`，原因是本机 PATH 里没有 `rg`，`scripts/test-macos-release-flow.sh` 自带的守卫直接 `Missing required command: rg` 并退出 1。该脚本与本次改动零重叠（本次只改 Swift 源码与测试），属环境缺件，非回归。

## 当前验证边界

- **没有真机复现卡死**：复现等于再冻一次整机，不能做。因此「修复后不会再整机停摆」是**基于机制 + 解密日志**的结论（tap 不再依赖主线程），不是现场验证。
- **没有主线程栈**：没有 spindump / hang 报告，进程已被 SIGKILL，无法事后取栈。所以「哪一次 TCC 查询卡在哪一帧」未确定；能确定的是阻塞发生在主线程（推理依据见「实验」第 2、3 条），且本进程是唯一的解除条件。
- **真机按键链路未验收**：tap 回调现在跑在非主线程上，`KeyboardEventSuppressor.descriptor()` 与 `ShortcutCaptureMonitor.handle()` 里的 `NSEvent(cgEvent:)` 也随之在非主线程执行（这是 AppKit 的既有公开用法，但本次只做了进程内验证，没有拿实体遥控器连续按键长跑）。**需要真机验收**：自定义映射吞键、遥控器语音键、以及「打开系统设置改本 app 权限」这个原始触发场景。
- **`HIDPermissionPoll` 的同类查询未改**：`DispatchHIDRemoteScheduler` 默认队列是 `.main`，所以「每 1 秒查一次 `isInputMonitoringGranted && isAccessibilityTrusted`」也跑在主线程上（订阅存在时）。**但它不是本次冻结的原因**：解密日志显示两个订阅在 01:56:24 就全部退订、轮询定时器随之停止（`timer_stopped=true`），比冻结窗口（02:02:24 起）早 6 分钟。修好 A 之后，主线程上的任何阻塞都只能让本 app 自己卡一下，不会再影响系统输入，因此它现在属于延迟/体验债而不是安全债。彻底修需要改这个轮询的线程模型与 `HIDRemoteMonitor` 回调的线程归属（HID 生命周期敏感、回归面大），建议单独立项。
- **`RemoteMicApp` 的同类查询未改**：`applicationDidFinishLaunching` 里一次读 6 次同步 TCC 权限（策略实参 3 次 + 日志 3 次）。它只在启动时跑一次，本次会话的启动（01:27:20）正常完成，不是冻结原因；仍属同类隐患。
- **`SettingsView` 的同类查询未改**：`refreshPermissionStates()` 仍是同步版，但只在 `.onAppear` / `didBecomeActive` 触发（不是 1 Hz）；`setCustomMappingEnabled` 需要它的同步结果来决定是否弹授权提示。修掉 A 之后它已经不会拖累系统，只会让设置窗口自己卡一下。
- **`OnboardingView` 的 `@State` 初始值仍会同步查询**：`OnboardingView.swift:95-97` 的三个属性初始值在**每次构造**时都会同步调一次 TCC。本次未改，因为截图渲染器（`OnboardingScreenshotRenderer`）依赖首帧就拿到真实值，改动需要先复核那条链路。

## 附带发现（不属于本 Bug，单独跟进）

- 同一段日志里，**会员权益刷新在持续失败**：355 条 `MEMBERSHIP_ENTITLEMENT` 事件中 248 条 `phase=failed`，其中 245 条 `reason_code=internal_error` + `http_status_class=5xx` + `support_code=-1900`，失败间隔 5–65 秒不等。这与本次冻结无关（冻结期间它还在继续失败并写日志），但是一个独立的服务连通性问题，应单独排查。

## 后续

1. 真机验收：实体遥控器连续按键 + 原始触发场景（引导页开关蓝牙权限）。
2. **单独立项**：把 `HIDPermissionPoll` 的权限评估移出主线程（连带调整 `HIDRemoteMonitor` 轮询回调的线程归属）。它不是本次冻结的原因，但与 B 是同一类问题。
3. 把 `SettingsView` 的权限查询也改成异步，并让 `setCustomMappingEnabled` 走「先查、再决定」的异步流程。
4. 复核 `OnboardingScreenshotRenderer` 的首帧依赖后，把 `OnboardingView.swift:95-97` 的 `@State` 初始值改为常量，去掉「每次构造都同步查 TCC」的隐藏开销。
5. 单独跟进上面「附带发现」里的会员权益 5xx 失败。
6. 与 `Bugs/2026-09-27-event-tap-port-not-invalidated.md` 一并考虑：那条记录解决了「端口泄漏」，本条解决了「回调阻塞主线程导致系统输入停摆」，第三条（本记录 C）解决了「授权收回后 tap 仍存活」。三条都出在 `EventTapPort` / suppressor 生命周期这一带上，说明该职责边界值得再收一遍。
