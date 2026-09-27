# 后台长时间运行后累积大量 event tap，导致全系统界面卡顿

- 时间：2026-09-27
- 状态：修复完成；本机构建、定向回归与修复前后对照通过，等待真机长时间运行与遥控器反复重连验收
- 影响范围：macOS；`1.9.21` 及更早；开启自定义映射、后台常驻数天且期间遥控器发生过多次重连的用户。表现为 Dock 悬停、窗口动画与触发角动画严重卡顿，同时整机 CPU 仍有约 80–90% 空闲、无内存交换
- 功能点：HID 按键抑制（`KeyboardEventSuppressor`）、自定义快捷键录入（`ShortcutCaptureMonitor`）、HID 监听重建（`BridgeAppModel.startHIDMonitors`）
- 简单描述：两处 event tap 的释放路径都只 disable 并摘除 RunLoop source，缺少 `CFMachPortInvalidate`，端口无法从 WindowServer 的 tap 列表注销；遥控器每次重连都会重建监听，残留量因此随重连次数单调累积，最终使每个输入事件都要流经上千个已禁用 tap
- 原始记录：[Issue #476](https://github.com/HD838A/remote-mic-app/issues/476)、[Issue #446](https://github.com/HD838A/remote-mic-app/issues/446)、[Issue #337](https://github.com/HD838A/remote-mic-app/issues/337)；2026-09-24 用户反馈（macOS 27.0 build 26A428、Mac mini M2 Pro、`1.9.21`、小米蓝牙遥控器 2 Pro，附 11 MB `runtime.log` 与 WindowServer 采样）

## 观察

### 用户现场

- 运行约两天后，Dock 悬停提示、窗口动画、触发角动画严重卡顿；CPU 仍有约 80–90% 空闲、无交换内存，排除算力与内存压力。
- `CGGetEventTapList` 列出 1238 个 Event Tap，其中 1229 个属于本 App 进程。
- WindowServer 采样调用栈反复出现 `add_event_vector_to_tap` 与 `post_event_vector_after_tap_id`。
- 正常退出 App 后 Event Tap 总数立即降到 12，界面同步恢复；重启 App 时最初只有约 2 个。
- 用户另有一个自建虚拟音频输出软件（把音频送到外接电视），并据此怀疑是自己环境所致。该混淆项不解释本现象：Event Tap 位于输入路径，与音频路由无因果关系；且退出 App 后 tap 数回落，归属明确。

### 上游报告的独立观测

- Issue #476 给出同一根因与最小实验：**100 次 create/stop 循环不调用 `CFMachPortInvalidate` 时残留 100 个 tap；显式调用后残留 0 个**；同一会话实测累积 2,378 个本 App tap。
- Issue #446 及 2026-09-24 评论：另一位用户在 **macOS 26.6.2**、`1.9.21 (174)` 上实测 1872 个已禁用 tap，重启后只剩 1 个。
- Issue #337（2026-09-03）是最早的同类描述。
- 三处目前未串联。#446 的 macOS 26.6.2 实测说明该现象**不限于 macOS 27**，因此本次反馈把它归因于 9/19 系统升级不构成回归判定依据。

### 当前代码（修复前）

- `Sources/RemoteMic/KeyboardEventSuppressor.swift`：`start()` 用 `CGEvent.tapCreate` 创建端口；`stop()` 只做 `CFRunLoopRemoveSource`、`CGEvent.tapEnable(enable: false)` 并清空引用，**没有 `CFMachPortInvalidate`**。
- `Sources/RemoteMic/ShortcutCaptureMonitor.swift`：同一个缺陷模式，`stop()` 同样只移除 source + disable。
- 全仓库检索 `CGEvent.tapCreate` 只有上述两处，`CFMachPortInvalidate` 命中 0。
- 放大路径：`BridgeAppModel.startHIDMonitors()` 首行即 `stopHIDMonitors()`（其中调用 `hidEventSuppressor.stop()`），随后再 `start()`，因此**每次调用都是一次 stop+start 配对**；`shouldReapplyHIDSettings` 在蓝牙桥 `previousState == nil` 或从非 ready 进入 ready 时返回 true，而 `applyHIDSettings()` 在 `BridgeAppModel`、`OnboardingView`、`SettingsView` 中共有 21 处调用点。即**遥控器每次重连泄漏一个 tap**。
- 同一缺陷的第二种形态：两处 `start()` 在 `CFMachPortCreateRunLoopSource` 返回 nil 时直接返回失败，而 `tapCreate` 已经成功登记的端口没有被释放。

### 本机日志统计（2026-09-25 排查）

只读解析本机 `~/Library/Logs/RemoteMic/runtime.log`（覆盖 2026-09-20T01:33:50Z – 2026-09-25T04:54:49Z，共 31,807 行），不依赖任何 tap 计数工具：

- **长跑实例存在**：`pid=16211` 自 2026-09-20T01:36:46 连续运行到 2026-09-25T02:30:36，历时 **4.96 天**，占全部日志的 30,922 行。这是「tap 在进程生命周期内累积」的前提。
- **该实例的 start/stop 周期为千次量级**：

  | 事件 | 次数（pid=16211） |
  | --- | --- |
  | `HID START mode=adaptive` | 1,039 |
  | `HID PERMISSIONS` | 1,039 |
  | `HID CONNECTED` | 992 |
  | `HID DISCONNECTED` | 502 |

  折合约 **8.4 次/小时、201.8 次/天**。
- **与 #476 实测对账**：按 #476「一次 HID restart 使计数 +2」的单点实测外推，1,039 次 start 约为 **2,078** 个残留 tap，与 #476 实测的 2,378 个偏差约 13%；反推 #476 对应约 1,189 个周期。两个独立来源同量级。
- **同机 WindowServer 负载异常**：同一会话内 WindowServer 累计 CPU 30:45、进程已运行 1:50:30，**会话均值约 28.0% CPU**；GPU 累计 37:16.93，折合约 **33.8%**。远高于「文字输入常驻工具」应有水平，且与 #476 指认的 `add_event_vector_to_tap` 热点一致。
- **已排除的混淆项**：日志中大量 `HID CONNECTED mode=monitored seize_error_code=-536870207`（IOKit `kIOReturnNotPrivileged`，`0xE00002C1`）**不是缺陷**。`HIDRemoteMonitor.swift` 在独占 seize 失败后回退非独占 monitor 路径，成功时即以该字段记录 seize 失败码；`Bugs/2026-08-21-issue-137-missing-hid-key-up-blocks-arrows.md` 也把该组合记为 monitored 路径的正常表现。

## 假设

### H1：两处 `stop()` 未 invalidate 底层端口导致 tap 泄漏（根因）

已由 #476 的最小实验证实「不 invalidate 则残留、invalidate 则清零」，且本仓库两个类的代码与该描述完全一致。置信度高。

### H2：泄漏速率由遥控器重连次数驱动

`startHIDMonitors` 必为 stop+start 配对，而 `shouldReapplyHIDSettings` 在每次重连后触发重建。本机日志统计（见「本机日志统计」）给出单实例 4.96 天内 `HID START` 1,039 次、折合约 8.4 次/小时，与 #476 实测的 2,378 个 tap 同量级。本记录未独立复核该计数，置信度中等。

### H3：用户的 11 MB 运行日志是同源症状而非独立问题

需要日志本体核对才能确认，本次仍未取得文件，不作独立条目。

## 实验

1. **独立探针对照实验（本机执行）**：在进程内连续 100 次创建 listen-only tap，按生产顺序接入主 RunLoop、摘除 source 并 disable 后，分别在不调用与调用 `CFMachPortInvalidate` 两种情况下用 `CGGetEventTapList` 统计本进程残留端口：

   | 条件 | 创建 | 残留 |
   | --- | --- | --- |
   | 不调用 `CFMachPortInvalidate` | 100 | **100** |
   | 调用 `CFMachPortInvalidate` | 100 | **0** |

   与 #476 的最小实验结论一致，复现成立。
2. **新增自动化** `Tests/RemoteMicTests/EventTapPortTests.swift`：4 个用例，覆盖共用释放契约（无辅助功能权限也执行）、100 次循环不累积端口，并直接驱动 `KeyboardEventSuppressor` 与 `ShortcutCaptureMonitor` 各 100 次 start/stop。
3. **修复前后对照**：把两个监听器回退到修复前版本后运行同一组用例，结果见「验证」。

## 根因

event tap 的生命周期包含创建（`CGEvent.tapCreate` + `CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource`）与释放两端。释放端只 disable 并摘除 RunLoop source，**未 invalidate 底层 `CFMachPort`**；端口在 WindowServer 侧保持登记状态直到进程退出。遥控器每次重连都会重新走一遍 start/stop，于是残留 tap 随重连次数单调增长。每个键盘事件到达 `cgSessionEventTap` 时都要流经这些残留 tap，正是 `add_event_vector_to_tap` 成为 WindowServer 热点的原因。

根因置信度：高。代码缺陷可静态确认，#476 的最小实验给出因果隔离，本机独立探针复现了同一对照结果。

## 修复

1. 新增 `Sources/RemoteMic/EventTapPort.swift`：把端口的接入与释放收敛为两处 tap 创建点共用的实现，`release` 固定顺序为「摘除 RunLoop source → disable → `CFMachPortInvalidate`」。
2. `KeyboardEventSuppressor` 与 `ShortcutCaptureMonitor` 的 `stop()` 改为调用 `EventTapPort.release(port:source:)`；两处 `start()` 的 runloop source 失败分支改为 `EventTapPort.release(port: port, source: nil)`；两处成功分支改为 `EventTapPort.activate(port:source:)`。

收敛为共用类型的原因：同一段释放逻辑此前被分别实现，结果是**两处同时缺少同一行**。共用后该释放契约只需维护一次，也才能在不需要辅助功能权限的条件下被自动化断言覆盖。

## 验证

- **构建**：`swift build --build-tests --disable-keychain --disable-sandbox`（Xcode 27.0 / 27A266a）→ `Build complete! (46.94秒)`，含测试目标。
- **定向回归**：`swift test --filter EventTapPortTests` → 4 个用例全部通过（0.054 秒）。
- **修复前对照**：回退两个监听器到修复前版本后运行同一组用例 → `keyboardEventSuppressorDoesNotAccumulateTaps` 失败（100 次循环后残留 100 个），`shortcutCaptureMonitorDoesNotAccumulateTaps` 失败（再累积 100 个，共 200 个）；恢复修复后两者通过。同一用例从失败变为通过。
- **完整套件**：`swift test --disable-keychain --disable-sandbox` → **714 个用例、55 个套件全部通过（6.550 秒）**，无回归。

## 当前验证边界

- **未做真机长时间运行验收**：真实的长时间常驻、蓝牙重连节奏、睡眠唤醒需要在实体遥控器与正式安装包上验证；自动化只能证明端口在进程内按 start/stop 次数正确释放。
- **未取得用户现场文件**：`runtime.log`（约 11 MB）、`windowserver.sample.txt` 与截图仍未拿到，H3 未验证；H2 的重连速率引自本机 `runtime.log` 统计（见「本机日志统计」），未独立复核。
- **未做 WindowServer 负载 A/B**：修复前后 WindowServer CPU/GPU 占用没有实测对照。
- **未处理重连频率本身**：泄漏堵住后残留不再累积，但「为何约 8.4 次/小时重建 HID 监听」属独立工作项，关联 Issue #441 与 `Bugs/2026-08-24-ble-cached-reconnect-storm.md`。
- `releaseInvalidatesThePort` 与 `repeatedActivateReleaseCyclesDoNotAccumulateTaps` 守护的是本次新增的共用释放路径，**不是**本 Bug「失败 → 通过」的例证；承担修复前后对照的是那两个直接驱动生产监听器的用例。
- 本机测试进程在运行时具备创建 active event tap 的条件，因此两个生产监听器用例实际执行而非跳过；在缺少辅助功能权限的环境（如无 GUI 的 CI）中这两个用例会跳过，仅前两个用例提供保护。

## 与 PR #493 的关系

[PR #493](https://github.com/HD838A/remote-mic-app/pull/493)（`fix/keyboard-event-suppressor-tap-leak`，Draft）曾针对同一 Bug 提出部分修复：只改 `KeyboardEventSuppressor.stop()` 一处，未覆盖 `ShortcutCaptureMonitor` 与两处 `start()` 失败分支，也没有任何自动化断言；即便合并，`ShortcutCaptureMonitor` 仍会继续泄漏。

该 PR 的原始排查记录（当时计划新增的 `Bugs/2026-09-25-keyboard-event-suppressor-tap-leak.md`）没有合入主线，因此仓库中不保留第二份同 Bug 文档——两份并存容易留下「已修复」的错误印象。其中有独立价值的本机日志统计已并入本记录的「本机日志统计」。本记录对应的修复分支是完整范围版本，同时关闭 #493 以避免两个 PR 各说各话。
