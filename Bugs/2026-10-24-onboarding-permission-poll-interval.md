# 引导页权限轮询 1 Hz 过密，且 SayAll 在后台仍然查询

- 时间：2026-10-24
- 状态：候选修复已实现（周期降到 2 s、App 在后台不做周期查询）；构建、定向回归、全量回归与渲染对照通过，等待真实权限切换与续接旅程验收
- 影响范围：macOS；开机引导页（Onboarding）的权限行刷新
- 功能点：引导页权限刷新（`OnboardingView`）、周期权限查询（`Timer.publish`）
- 简单描述：引导页用一个 1 Hz 的 `Timer.publish` 在主线程上做三项同步 TCC 权限查询，即使 SayAll 已经在后台也照查不误。而引导页本来就订阅了 `NSApplication.didBecomeActiveNotification`，用户从系统设置改完权限回到 App 会立即刷新一次——1 Hz 只是兜底，2 s 已经足够。
- 原始记录：本机取证（Apple Silicon，macOS 27）。与 event tap 那次主线程阻塞调查同批产出；event tap 记录随 PR #731 交付，本记录是其中「后续」清单里的独立工作项

## 证据：App 内的定时器清单

全仓定时器只有三类来源：`Timer.publish`（1 处）、`DispatchSource.makeTimerSource`（17 处）、`Task.sleep` 循环（1 处）。另有 36 处 `asyncAfter`（一次性延迟，不是定时器），无 `Timer.scheduledTimer`、无 `CADisplayLink`。

真正「一直在跑」的只有三条 1 Hz 轮询，其余全部由具体事件触发、用完即销：

| 轮询 | 用途 | 必要性 |
| --- | --- | --- |
| 引导页权限刷新 | 让界面上的权限行显示最新状态 | **冗余**。已有 `didBecomeActive` 即时刷新兜底，可降频、可在后台跳过 |
| HID 权限撤销检测 | 授权被收回后释放 active event tap | **必要**，是安全兜底，撤销检测不能取消 |
| Siri 遥控器权限撤销检测 | 监听期间权限被收回后停止监听 | **必要**，同上 |

本记录只动第一条。后两条属于撤销检测，把周期调大会延长「授权收回后 tap 仍存活」的窗口，属于权限语义变更，不搭在这个优化里。

## 引导页这条为什么是冗余的

- `OnboardingView.swift:142` 的 `Timer.publish(every:on:in:)` 是全仓唯一的 `Timer.publish`。`in: .common` 让它在滚动、菜单跟踪期间也照常触发。
- 定时器回调（`OnboardingView.swift:217`）每次触发都会调用 `refreshPermissionStates()`（`OnboardingView.swift:3740`），后者在主线程上做三次同步 TCC 查询：
  - `CBManager.authorization` —— CoreBluetooth 到 tccd 的同步 IPC；
  - `HIDRemoteMonitor.isInputMonitoringGranted` —— `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`，同步 IPC；
  - `KeyboardInjector.isAccessibilityTrusted` —— `AXIsProcessTrusted()`，同步 IPC。
- 引导页同时订阅了 `NSApplication.didBecomeActiveNotification`，该通知的处理里**无条件**调用 `refreshPermissionStates()`。用户在系统设置改完权限回到 App 的那一刻，权限行立即刷新，不需要等定时器。
- 所以定时器只是兜底：1 Hz 与 2 s 在用户可感知的层面没有差别；App 在后台时更是完全没有用户可见的刷新需求。

## 修复

1. 新增 `OnboardingPermissionRefreshPolicy`（`OnboardingFlow.swift:471`），把周期常量 `permissionRefreshIntervalSeconds = 2` 和判定 `shouldRefreshPermissions(isApplicationActive:)` 放在一处，周期不再以字面量散落在视图里。
2. `OnboardingView.swift:142` 改为使用该常量。
3. 定时器回调（`OnboardingView.swift:217`）在调用 `refreshPermissionStates()` 前先判断 `shouldRefreshPermissionStates`（`OnboardingView.swift:3727`）：App 不在前台时跳过周期查询。其余刷新（安全输入状态、语音工具可用性、选中语音工具运行态）保持原频率不变——它们不是 TCC 查询，也不受前台状态影响。
4. 离屏截图渲染没有前台会话（`NSApplication.shared.isActive` 为 `false`），由宿主显式传入 `permissionRefreshInForegroundOverride: true`（`OnboardingScreenshotRenderer.swift:207`），渲染状态与生产一致。

**不改变的功能**：权限项本身、门禁判定、页面顺序、连接、音频、持久化、遥控器动作语义，以及「回到前台立即刷新」这条路径。

## 验证

- **构建**：`swift build --build-tests --disable-keychain --disable-sandbox` 通过；Apple Silicon Release（`--triple arm64-apple-macosx14.0`）与 Intel Release（`RELEASE_VARIANT=intel ... --triple x86_64-apple-macosx13.0`）均通过。
- **定向回归**：`swift test --disable-keychain --disable-sandbox --filter OnboardingFlowTests` → 78 项通过，其中 2 项为本次新增：
  - `permissionRefreshIntervalIsReducedAndBackgroundQueriesAreSkipped()` —— 断言周期常量为 2、后台不刷新、前台刷新；
  - `onboardingPermissionRefreshUsesThePolicyIntervalAndSkipsBackgroundQueries()` —— 断言视图走策略常量而不是硬编码 1 Hz、周期刷新被前台判定包住、渲染器显式开启，并且 `didBecomeActive` 处理里仍然无条件刷新。
- **修复前对照**：把 `OnboardingView.swift` 与 `OnboardingScreenshotRenderer.swift` 临时回退到修复前版本后重跑，新用例在旧实现下失败 5 条断言（周期仍是 1 Hz、没有前台判定、渲染器没有显式开启）；恢复修复版后 78 项全部通过。
- **全量套件**：`swift test --disable-keychain --disable-sandbox` → **950 个用例、74 个套件，949 通过，1 失败**。失败项是 `releaseControlPlaneFixtureHasExecutableRegressionCoverage()`，报错 `Missing required command: rg`——本机 PATH 里没有 `rg`（`command -v rg` 无输出、`/opt/homebrew/bin/rg` 不存在），发布流程脚本自带的守卫直接退出 1。该脚本与本次改动零重叠（`git diff --name-only origin/main..HEAD | grep '^scripts/'` 无输出，本次只改 Swift 源码、测试与文档），属环境缺件，非回归。
- **渲染对照**：本分支渲染出的引导页 9 页与 `origin/main` 基线代码渲染出的 9 页**逐字节一致**（差异 0 张）。同一份代码连续两次渲染也逐字节一致，说明渲染本身是确定的。

## 验证边界

- **没有真机权限撤销/恢复验收**：本轮只在离屏渲染与自动化层面验证。真实用户在系统设置改权限、回到 App 观察权限行刷新的场景未做人工验收。
- **没有完整续接旅程验收**：退出续接与关于页重跑未在真实安装包上走一遍。
- **离屏渲染机的蓝牙状态是环境产物**：裸调试可执行文件没有 app bundle identifier，系统无法为它解析蓝牙授权，因此权限页的蓝牙行显示为未授权、页面据此禁用「继续」。这是渲染环境的状态，不是渲染缺陷，也不代表正式包的行为；本轮不证明正式包的蓝牙行状态。
- **权限感知延迟上限变大**：周期从 1 s 变成 2 s，用户可见的权限状态感知延迟上限相应变大。引导页已有 `didBecomeActive` 即时刷新，实际场景不受影响；但「停留在引导页不动、也不切换 App」时，权限行的最坏延迟是 2 s。

## 后续

1. 与 event tap 那条记录的「后续」清单一起收口：`SettingsView` 的权限查询改异步、`RemoteMicApp` 启动时 6 次同步读取复用同一探针、`HIDRemoteMonitor` 按键路径上的同步权限判定单独立项。三者都需要各自的语义评估，不搭在这个优化里。
2. HID 与 Siri 两条 1 Hz 撤销检测轮询的频率评估另立工作项；本记录没有改动它们的周期。


## 2026-10-24 二次审查：保留非权限检查周期

- 错误证据：原改动把共用定时器整体改成 2 秒，因此安全输入、Fn 配置和语音工具运行态检查也变成 2 秒。上文“其余刷新保持原频率不变”在原提交中不成立。
- 失败对照：新增接线回归在原实现出现 5 条断言失败，确认非权限检查仍绑定在权限 timer 上。
- 修复：权限 timer 继续每 2 秒触发并检查前台状态；运行状态另用 1 秒 timer。回到前台仍立即刷新权限。生产权限 IPC 查询次数不增加。
- 验证：`swift test --disable-keychain`：950 项全部通过，包含原发布流程 fixture；Apple Silicon macOS 14 与 Intel macOS 13 Release 均通过。
- 日志与边界：沿用安全输入状态变化日志，不逐 tick 增加日志。页面清单与布局未改，本轮未重做截图、真实权限切换和完整用户旅程；PR 保持 Draft 候选。
