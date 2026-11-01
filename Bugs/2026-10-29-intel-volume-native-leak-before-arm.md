---
title: Intel 音量键原生泄露（原生事件早于拦截登记）
subtitle: 专用报告线程提前登记
lang: zh
template: doc
date: 2026-10-29
status: build 269 已验证；本轮收紧门禁后待 Intel 复验
---

## 现象

用户在 Intel Mac 上把音量加配置为逗号、音量减配置为句号。
按下音量加时既输入逗号，又调高系统音量；按下音量减时既输入句号，又调低系统音量。
同一配置在 Apple Silicon 上不出现该现象。

这是「自定义动作与系统原生动作同时生效」，不是自定义动作映射错误。

## 证据

### 现场日志（本次已解密，可读）

`sayall.app-2026-10-28-session-FD108763.rmlog` 已用受控脚本解密为 7901 条记录，
`build=268`、`cpu_architecture=x86_64`，会话时长约 69 分钟。整个会话里遥控器音量键
只被按了 2 次（`volume_down` 0 次），两次的时间线如下。

| 时刻 | 来源 | 记录 |
| --- | --- | --- |
| 16:02:35.204 | tap 线程 | `HID FILTER miss type=14 event=sys0 edge=down armed=false pending=0` |
| 16:02:35.338 | tap 线程 | `HID FILTER passed_through event=sys0 edge=up reason=escaped_native_pair` |
| 16:02:35.403 | 主线程 | `HID REPORT rejected reason=target_fingerprint_mismatch`（2 条） |
| 16:02:35.404 | 主线程 | `HID FILTER arm events=sys0 edge=down` |
| 16:02:35.404 | 主线程 | `HID FILTER phase=arm_order event=sys0 edge=down preceding_unclaimed_ms=199 source_correlation=timing_only result=already_passed_through` |
| 16:02:35.404 | 主线程 | `HID REPORT accepted source=device id=1 bytes=7 usage_count=1 buttons=volume_up` |
| 16:02:35.412 | 主线程 | `HID BUTTON button=volume_up trigger=singleClick action=customShortcut` |
| 16:02:36.047 | 主线程 | `HID FILTER arm events=sys0 edge=down` |
| 16:02:36.048 | 主线程 | `HID REPORT accepted ... buttons=volume_up` |
| 16:02:36.050 | tap 线程 | `HID FILTER suppressed event=sys0 edge=down type=14 latency_ms=2` |

判读：

- 第 1 次按下：原生按下 35.204 先到，App 的 `arm` 到 35.404 才执行，差 **200 ms**，
  `preceding_unclaimed_ms=199` 与现场测量完全一致。原生按下被放行，系统音量改变；
  随后自定义动作照常执行，逗号和音量同时发生。
- 第 2 次按下：`arm` 36.047 早于原生 36.050，`latency_ms=2`，被正常吞掉。
  说明泄露不是「每次必现」，而是**首次按下、主线程有空档时才发生**。
- 关键不在 `arm` 调用本身慢，而在**报告投递慢**：35.020 之后主线程再无任何日志，
  直到 35.403 才一次性吐出 4 条报告回调（2 条拒绝 + 1 条 arm + 1 条接受）。
  同一时段 tap 线程在 35.204、35.338 都正常写日志。即主线程被阻塞约 383 ms，
  tap 线程没有阻塞。
- 那 383 ms 里主线程处理的是 BLE 重连与音频健康检查：35.019/35.020 连续
  `PUBLIC_EVENT connection`、`AUDIO HEALTH`、`BLE SCANNING`。全场 43 次
  `HID FILTER stopped/started` 也来自这种重连抖动。
- 设备级映射当场为 `HID NATIVE MAPPING phase=prepare result=verified
  reason=mapping_readback services=1 native_delivery=unobserved`，即回读通过，
  但原生事件照旧产生。

结论：报告回调挂在主线程 RunLoop 上，主线程一忙，先前的「按报告登记」就不可能
早于系统原生事件。仅把 `arm` 提前到别的时机无效，必须让报告投递本身离开主线程。

### 旧证据：本机 Apple Silicon 对照与归档测量

- 本机（Apple Silicon）明文 `runtime.log` 读到 `HID CONNECTED mode=monitored
  seize_error=-536870207`，即 `0xE00002C1`（`kIOReturnNotPrivileged`）。
  本次 Intel 日志同样是 `seize_error_code=-536870207` 且 `mode=monitored`，
  两侧一致。**独占失败不是平台差异的原因**，此前怀疑已排除。

### 已归档的 Intel 现场测量

`Bugs/2026-10-26-tv-volume-native-race.source.md` 在另一台 Intel Mac 上测得：

| 观察 | 原生按下 | HID 登记 | 差值 |
| --- | --- | --- | --- |
| 音量减 sys1 | 52.762 | 52.964 | 约 200 ms |
| TV key50 | 17.828 | 18.075 | 约 246 ms |

同一记录已说明：`UserKeyMapping` 回读为 `verified` 时，系统仍会出现 `sys0` 和 `sys1`。
回读只证明属性写入成功，不证明系统停止投递原生事件。

## 根因

一个物理音量键产生两条独立路径：

1. 系统路径：HID → WindowServer → `NX_KEYTYPE_SOUND_UP/DOWN` → 立即改变系统音量。
2. App 路径：HID 原始报告 → 主线程 RunLoop → 登记拦截 → 执行自定义动作。

`KeyboardEventSuppressor` 是「先登记、后吞掉」模型，只吞已经登记过的原生事件。
主线程在界面渲染、设置窗口、BLE 重连或音频工作时可能排队 200 ms 以上，
登记因此晚于系统路径。原生按下被放行、系统音量改变，
随后 App 仍按原始报告执行自定义动作，两者同时发生。

本次日志把「登记晚」进一步定位为「报告投递晚」：主线程停了 383 ms 期间，
tap 线程仍在按时处理事件。所以任何仍以主线程回调为起点的登记都不可靠，
必须让报告投递本身离开主线程，登记才有机会早于系统路径。

Apple Silicon 上主线程通常能在原生事件之前完成登记，所以同一缺陷表现为平台差异而非逻辑分支差异。
该缺口在 `2026-10-24`（原生事件晚到）与 `2026-10-26`（放行按下忽略松开）两次修复后仍然存在，
两份记录都已把「初次原生事件早于解析报告」写成已知残留。

## 最小修复

### 报告线程提前登记

- 新增 `HIDReportRunLoop`，把 `IOHIDManager` 调度到专用线程 RunLoop；
  线程无法就绪时退回主线程，保持原有可用性。
- 设备匹配、移除与报告处理仍回到主线程，设置、界面和动作执行语义不变。
- 报告线程只做三件事：解析报告字节、读取一份线程安全的路由快照、
  调用 `KeyboardEventSuppressor.prearm`。它不读设置对象、不碰界面、不执行动作。
- 路由快照由主线程在启用状态、允许位置、目标设备或排除列表变化时刷新，
  其中包含 `enabled`、`activeFingerprint`、`targetFingerprint`、
  `excludedFingerprints`、`allowedLocationIDs`，以及 `deviceSeized`、
  `nativeKeysNeutralized`、`permissionsGranted` 三项。报告线程用与主线程完全相同的
  `reportRoutingDecision`、`isLocationAllowed`、`needsEventLevelArm` 做判定。
- `needsEventLevelArm` 由主线程的 `shouldArmNativeEvent` 与报告线程共用，
  判据是 `!seized || !neutralized`。两处各写一遍时，独占成功且映射回读通过的
  机型上报告线程仍会登记，留下过期待匹配记录，把真实键盘音量键吞掉一次。
- 权限不查 TCC：`IOHIDCheckAccess` 与 `AXIsProcessTrusted` 都是同步 IPC，
  在报告线程上执行等于把本次要消除的阻塞搬到了热路径。改为读取主线程记录的
  快照，之后由权限轮询线程更新。
- `prearm` 在同一把锁内再次确认会话仍处于启用状态。调用方的 `acceptsPrearm`
  检查与真正的写入之间可能插入 `stop()`，否则停止后仍会写入陈旧记录。
- 这道门禁不是可选优化：主线程会拒绝其他 HID 设备的报告，本次日志中就有
  20 条 `target_fingerprint_mismatch` 与 10 条 `excluded_fingerprint` 被拒。
  若无条件提前登记，这些设备上的音量键也会被登记并吞掉，
  用户真实键盘的音量键将失效。
- `prearm` 只追加一条「按下」待匹配记录，不修改按住计数、已放行配对和提前松开状态。
- 提前登记一旦被原生按下认领，主线程随后登记同一次按下时不再追加记录，
  避免留下会吞掉下一次实体键盘按键的陈旧窗口。

### 代码评审补上的三处

收窄范围后自查发现的三处，都在同一条「提前登记」链路上：

- **同一次按下只能留一条待匹配记录。** 现场不只有「原生事件早于主线程 arm」
  这一种顺序：原生事件也可能落在 `prearm` 之后、主线程 `arm` 之前。此时
  `prearm` 那条记录还没被消费，主线程再追加一条，同一次按下就占住两个待匹配
  窗口；其中一条被遥控器消耗，另一条留到过期，期间用户按实体键盘音量键会被
  吞掉一次。`arm` 现在只跳过报告线程留下的那条并把它降级为主线程记录，
  重叠点击的第二次按下仍各占一条（既有用例
  `overlappingClicksConsumeOnlyTheirExpectedEdges` 守的就是这一点）。
- **认领记录带过期时刻。** 认领原先是不带时间的计数：主线程若因权限撤销、
  设备移除等路径没有为该按下执行 `arm`，认领会一直留着，下一次真实按下被
  误判成重复登记而漏拦。现在过期时间与待匹配窗口一致，按 `arm` 时顺带清理。
  认领按按下顺序排队，每条只抵掉一次按下（配对方式见下方评审修复）。
- **专用线程的可观测性与退出。** 就绪超时原先被忽略：超时后调用方退回主线程，
  而那条线程仍会在空转 source 上驻留，日志里也看不出走的哪条路径。现在超时
  直接撤销工作线程并返回失败，`deinit` 兜住未显式 `stop()` 的释放路径，启动时
  补一条 `HID REPORT runloop mode=dedicated|main`；命中日志补
  `armed_by=prearm|arm`，让「提前登记是否真的生效」可以从日志直接读出来。

### PR 评审提出的三个阻塞项

首轮评审在行内提出三条阻塞意见，本轮逐条修复，各补一条回归：

- **[P1] 松键会清空全部提前登记认领。** 认领原先按事件计数、松键时整条删除：
  快速连按时 `up 1` 会把 `down 2` 仍需的认领一起删掉，主线程随后为 `down 2`
  追加一条错误的待匹配记录，窗口期内吞掉实体键盘的音量键。现在认领改成按
  按下顺序排列的队列，每条认领只抵掉一次 `arm(.down)`；松键不再改动认领，
  只按过期时间清理。回归用例
  `twoNativeDownsBeforeMainThreadArmsKeepTheirOwnClaims` 覆盖「两次原生按下都
  先于主线程处理」的现场顺序，修复前必失败。
- **[P1] 在途回调能在监视器 `stop()` 之后写入共享拦截器。** 生产结构里
  `KeyboardEventSuppressor` 由多个监视器共享（`ownsEventSuppressor: false`），
  `stop()` 不会关闭它；只刷新路由快照也无法让已经读到旧快照的在途回调失效。
  现在提前登记由 `HIDPrearmSession` 的会话代数把关：监视器 `start()` 开启会话，
  `stop()` 先结束会话，报告线程带快照回来时在同一个临界区内校验代数再调用
  `prearm(...)`。回归用例
  `staleSnapshotFromASharedMonitorCannotPrearmAfterStop` 按生产结构（共享
  suppressor + 监视器级 `stop()`）复现；源码回归同时锁住「校验与写入必须是
  同一次调用」和「`stop()` 先结束会话再释放资源」。
- **[P2] 就绪超时没有撤销工作线程。** `start()` 超时原先只返回 `nil`，工作线程
  在进入 `CFRunLoopRun()` 前把 weak self 提成强引用并长期持有，`deinit { stop() }`
  永远轮不到。现在线程进入 `CFRunLoopRun()` 后不再强持有实例，超时走统一的
  撤销路径（取消标志 + 只停本线程的 run loop + 有界等待退出）；
  `stop(waitTimeout:)` 返回线程是否真的退出，并用每次启动的代数防止迟到的旧
  线程清掉新会话状态或误报新线程已退出。回归用例
  `readyTimeoutCancelsTheWorkerSoRestartStillWorks` 与
  `stoppingAnIdleRunLoopIsSafe` 覆盖超时撤销、重启和重复停止。

### 已移出本修复的两项

早期版本同时改了设备级映射（Consumer 页 `0xE9`/`0xEA`/`0xE2` 中和、重复
Registry ID 去重），并加了一条 `native_delivery=observed` 观察日志。真机复核后
两项都已从本修复移除：

- 设备级映射在这台 Intel 上无效。`phase=prepare` 4 次全部 `result=verified`、
  `services=1`，同一时段仍拦截到 227 次原生按下——回读通过并没有阻止系统投递。
  它既不能证明与本问题有关，也就没有理由和本修复捆在一起。
- 观察日志一行都没打印。原因不是判定条件，而是生命周期：`KeyboardEventSuppressor`
  由 `BridgeAppModel` 的 `hidMonitors` 与 `hidDiscoveryMonitor` 共享，
  每个 monitor 的 `start()` 都直接覆盖 `onVolumeNativeObservation`，
  每个 `stop()` 又把它清空。只有真正持有设备的那个 monitor 会把
  `nativeKeysNeutralized` 置为 true，观察回调却常常属于别的实例。
  这段链路要连同「共享观察器」一起重新设计，单独立项。

## 验证

- 新增回归覆盖：原生事件早于主线程登记的现场顺序、提前登记未被认领时自然过期、
  正常顺序仍被拦截、主线程重复登记不再留下陈旧窗口。
- 新增回归覆盖：报告线程先登记、主线程在原位事件之前完成 `arm` 时，同一次按下
  只留一条记录，随后按下的实体键盘音量键必须放行（修复前被吞一次，见上）。
- 新增回归覆盖：命中日志的 `armed_by=prearm|arm` 能区分两条路径。
- 新增回归覆盖：`stop()` 之后才到达的提前登记必须被忽略；未处于活动会话时的
  提前登记必须被忽略。
- 新增回归覆盖（评审 P1）：两次原生按下都先于主线程处理时，两次按下各自保留认领；
  第一次松键不得清掉第二次按下的认领，随后按下的实体键盘音量键必须放行。
- 新增回归覆盖（评审 P1）：按生产结构（共享 suppressor + 监视器级 `stop()`）复现，
  会话结束后带旧快照的在途回调不能再写入提前登记；重启会话会让旧快照失效。
- 新增回归覆盖（评审 P2）：就绪超时撤销工作线程后仍能重新启动；`stop(waitTimeout:)`
  报告线程确实退出；重复停止与未启动状态停止都安全。
- 新增源码回归：提前登记必须复用主线程的 `reportRoutingDecision`、
  `isLocationAllowed`、`needsEventLevelArm` 与权限快照，且调用 `prearm`
  之前必须已完成路由判定；报告线程不得调用 `runtimePermissionsAreValid()`
  或 `IOHIDCheckAccess`；会话代数校验与 `prearm` 写入必须是同一次调用；
  `stop()` 必须先结束会话再释放资源。
- 新增源码回归：`shouldArmNativeEvent` 必须与报告线程共用 `needsEventLevelArm`，
  防止两条路径的判据再次分叉。
- 既有 `KeyboardEventSuppressorTests` 与 `RemoteNativeKeyMapperTests` 全部保留。
- 构建与测试命令均带 `--disable-keychain`。
- 分支已 rebase 到 `origin/main`（`9190672d`，2026-11-01），
  `Bugs/README.md` 的顶部链接与索引表格冲突按主线顺序解决。
- 本地结果：`swift build` 通过；受影响四个套件 175 项全部通过；
  `swift test` 全量 1153 项中 1151 项通过，2 项 `BuildSigningTests` 失败
  （`binaryArtifactsEnableUnifiedButtonConfiguration`、
  `releaseControlPlaneFixtureHasExecutableRegressionCoverage`），原因是本机沙箱
  禁止嵌套 `sandbox-exec`：`swift package dump-package` 报
  `sandbox-exec: sandbox_apply: Operation not permitted`，
  `git init --bare` 报 `mkdir '/Users/andy/.Trash': File exists`，与本改动无关。

## Intel 真机验收（build 269）

> 这一轮跑的是**收窄范围之前**的包：里面还带着后来被移除的设备级映射改动和
> 观察日志。两处移除都不改变拦截行为（映射在本机未生效、观察只写日志），
> 但按仓库规矩不能拿旧包当新代码的结论，**收紧门禁后需要在 Intel 上复验一次**。

`runtime.log` 里 `build=269`、单进程 `pid=18235`，时间窗 00:10:04–00:26:21（约 16 分钟），
`cpu_architecture=x86_64`。音量加配置为逗号、音量减配置为句号，双击与长按关闭。

| 指标 | 数值 |
| --- | --- |
| 音量键自定义动作 | 223 次（加 114 / 减 109），全部 `customShortcut` |
| `HID FILTER arm` | 按下 226 / 松开 226 |
| `HID FILTER suppressed` | 按下 227、松开 203（其中 85 条 `via=owned_native_pair`） |
| `passed_through` | 0 |
| `arm_order … result=already_passed_through` | 0 |
| `HID FILTER miss` | 23 条，全部 `edge=up`（`edge=down` 0 条） |
| 按下命中延迟 | p50 5 ms / p90 324 ms / max 472 ms |

判读：

- build 268 那条失败链路（`miss armed=false` → `passed_through` →
  `arm_order preceding_unclaimed_ms=199`）在 build 269 上一次都没复现，
  **按下边沿 0 泄露**，与用户「只出逗号、音量不动」的观察一致。
- 延迟数值反而印证根因：日志中有按下在登记后 418 ms 才被吞，系统侧事件延迟一直存在；
  现在登记在报告线程上完成，始终跑在原生事件之前，所以延迟再大也不会被反超。
- 23 条 `miss` 全部是松开边沿，音量动作只在按下触发，不影响功能，属已知残留。
- 音量减本次有 109 次实测，此前「句号那一半无现场数据」的缺口已补齐。
- 安装后 00:10:04–00:10:12 有 2 条 `start_failed reason=tap_create_failed`
  （同期 `accessibility=false`），授权后立刻 `started result=active`。
  即新包刚装好、权限尚未授予的那几秒按音量键一定会漏，不是修复失效。

## 剩余边界

- 松开边沿约 10%（23/226）出现 `miss`：系统松开事件先到、没有待匹配记录，遂放行。
  音量与自定义动作都不受影响，只多一条诊断日志，可留待后续收窄。
- A 不承诺零窗口：若 macOS 在用户态投递原始报告之前就生成原生事件，仍会泄露一次。
  本次 226 次按下实测为 0，但这是概率性保障，不是结构性保证。
- A 只在主线程完成启用与设备判定后才允许提前登记，因此设备刚被重新枚举、
  路由快照仍为旧值的那一瞬间，仍退回主线程登记的旧行为。
- 快速连按两次时，第一次放行的原生按下仍在 `passedVolumeDowns` 保护期内，
  该期间不新增提前登记，必要时靠主线程登记兜底。
- 设备级映射在这台 Intel 上回读通过却不阻断投递，相关改动已移出本修复。
  「回读通过 ≠ 系统停止投递」这个结论保留，供后续单独评估映射方案时参考。
- 共享 `KeyboardEventSuppressor` 的观察回调会被后启动的 monitor 覆盖，
  这个生命周期缺陷仍未修；本轮把观察链路整体移除，范围缩到只有拦截本身。
  要恢复「源头映射是否生效」的日志判据，需要先设计共享观察器，单独立项。
- 本轮改动收窄了门禁（新增 `needsEventLevelArm` 与权限快照、`prearm` 锁内复检），
  build 269 的验收结论不能直接沿用，需要在 Intel 上复验。
- 验收基于日志与手工观察：未做第三方语音工具、系统音量最终状态与长按组合的回归。
