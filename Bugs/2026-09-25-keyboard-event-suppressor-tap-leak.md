# 键盘事件抑制器停止时未 invalidate CFMachPort，event tap 随重连逐次累积

- 时间：2026-09-25
- 状态：修复已提交，本地 diff 与单文件语法已检查；本机缺少完整 Xcode，未能执行全量构建、自动化回归与真机验证，等待上游 CI 与真机验收
- 影响范围：macOS；实测环境 macOS 27.0 build 26A428（Apple Silicon，M4）+ SayAll 1.9.21 build 174；后台常驻数天、期间发生多次 HID 重连的用户场景
- 功能点：HID 按键抑制（`KeyboardEventSuppressor`）、遥控器非独占 monitored 路径
- 简单描述：`KeyboardEventSuppressor.stop()` 只 disable event tap 并摘除 RunLoop source，未对底层 `CFMachPort` 调用 `CFMachPortInvalidate`；每次 start/stop 都会在 WindowServer 的 tap 列表中残留一个 tap，长时间后台运行后累积到数千个，使每个输入事件都要遍历全部残留 tap。
- 原始记录：<https://github.com/HD838A/remote-mic-app/issues/476>；本机 `~/Library/Logs/RemoteMic/runtime.log`（覆盖 2026-09-20T01:33:50Z – 2026-09-25T04:54:49Z）

## Observations

### 上游报告的独立观测（Issue #476）

该 Issue 的环境与本机逐字一致：macOS 27.0、build 26A428、SayAll 1.9.21 build 174。报告给出的观测为：

- 初始 `CGEventTapList` 计数为 8；启动 SayAll 并触发一次 HID restart 后变为 10。
- 其中两个 tap 属于 SayAll，但只有一个处于 enabled；退出 SayAll 后计数回到 8。
- 一次长时间会话中累积了 **2,378 个** SayAll tap。
- WindowServer 最热的调用栈是 `add_event_vector_to_tap`。
- 最小实验：100 次 create/stop 循环不调用 `CFMachPortInvalidate` 时残留 100 个 tap；显式调用后残留 0 个。

### 本机独立观测

以下数据由本机只读排查取得，不依赖上述报告的 tap 计数工具：

1. **长跑实例确实存在。** `runtime.log` 中 `pid=16211` 单实例从 2026-09-20T01:36:46 连续运行到 2026-09-25T02:30:36，历时 **4.96 天**，占全部 31,807 行日志的 30,922 行。这满足「tap 在进程生命周期内累积」的前提。
2. **该实例的 start/stop 周期数约为 1,000 量级：**

   | 事件 | 次数（pid=16211） |
   | --- | --- |
   | `HID START mode=adaptive` | 1,039 |
   | `HID PERMISSIONS` | 1,039 |
   | `HID CONNECTED` | 992 |
   | `HID DISCONNECTED` | 502 |

   折合约 8.4 次/小时、201.8 次/天。
3. **与报告 tap 数对账。** 按报告中「一次 HID restart 使计数 +2」的单点实测，1,039 次 start 推算约 **2,078** 个残留 tap，与报告实测的 2,378 个偏差约 13%；反推报告对应约 1,189 个周期，与本机 1,039 个同量级。两个独立来源相互吻合。
4. **同机 WindowServer 负载异常。** 同一会话内 WindowServer 累计 CPU 时间 30:45、进程已运行 1:50:30，折合**会话均值约 28.0% CPU**；GPU 时间累计 37:16.93，折合约 **33.8% GPU 占用**。该数值远高于「文字输入常驻工具」应有的水平，且与报告指认的 `add_event_vector_to_tap` 热点一致。

### 本次排查中确认的一个非问题

日志中大量出现的 `HID CONNECTED mode=monitored seize_error_code=-536870207`（即 IOKit `kIOReturnNotPrivileged`，0xE00002C1）**不是本 Bug**，也不是新增缺陷。`HIDRemoteMonitor.swift` 在独占 seize 失败后会退回非独占 monitor 路径，成功时即以该字段记录 seize 失败码；`Bugs/2026-08-21-issue-137-missing-hid-key-up-blocks-arrows.md` 也把该组合记录为 monitored 路径的正常表现。本记录不把 seize 失败本身当作缺陷。

## Hypotheses

### H1：`stop()` 未 invalidate 底层端口，导致 tap 泄漏（ROOT CAUSE）

- Supports：`stop()` 现有的清理步骤只有 `CFRunLoopRemoveSource` 与 `CGEvent.tapEnable(enable: false)`，随后直接置空引用；全仓库检索 `CFMachPortInvalidate` 命中 0。报告的最小实验是决定性的——同一段代码在 100 次 create/stop 后残留 100 个 tap，补上 invalidate 后残留 0。本机日志给出的周期数与报告的 tap 数同量级。
- Conflicts：本机没有复现报告所用的 tap 计数手段，无法独立读取 `CGEventTapList`；「+2 tap/restart」只有报告中的一个单点实测，用它做线性外推存在误差。
- Test：由上游 CI 与维护者用真实设备完成——在同一进程内连续 start/stop N 次，比较前后 tap 数；并对比修复前后长时间会话的 WindowServer CPU 与调用栈。

### H2：WindowServer 负载主要由屏幕上的其他重绘来源造成

- Supports：本次排查的同一台机器上还有两个 WKWebView 进程在活跃刷新，瞬时合计可达 30% CPU 以上。
- Conflicts：报告给出的 WindowServer 热点栈是 `add_event_vector_to_tap`，属于 tap 遍历路径，网页合成本身不会产生该栈；且本机测得 WindowServer 的**会话均值**（28.0%，跨 1:50:30）明显高于网页活动的波动区间。
- Test：退出 RemoteMic 后对比 WindowServer CPU/GPU 占用。本机未执行该 A/B，理由见「未覆盖边界」。

## Experiments

1. 只读解析 `~/Library/Logs/RemoteMic/runtime.log`，按 PID 统计实例生命周期与 `HID START` / `HID CONNECTED` / `HID DISCONNECTED` / `HID PERMISSIONS` 次数（结果见 Observations 第 1、2 点）。
2. 用报告给出的单点系数把本机周期数换算为 tap 数，并与报告实测值对账（见 Observations 第 3 点）。
3. 通过 `pmset -g assertions`、`ps -o time`、`top -o power` 采集 WindowServer 在同会话内的累计与瞬时占用（见 Observations 第 4 点）。
4. 阅读 `HIDRemoteMonitor.swift` 第 352–442 行，确认 `mode=monitored` 与 `seize_error` 是正常回退记录，排除该线索。
5. 全仓库检索 `CFMachPortInvalidate` 与全部历史 PR，确认主线未修复且无重叠 PR。

## Root Cause

`KeyboardEventSuppressor` 的 tap 生命周期包含创建（`CGEvent.tapCreate` + `CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource`）与销毁（`stop()`）两端。销毁端只做 disable 与摘除 RunLoop source，**未 invalidate 底层 `CFMachPort`**，因此端口在 WindowServer 侧保持登记状态直到进程退出。遥控器每次重连都会重新走一遍 start/stop，于是残留 tap 随重连次数单调增长；本机 4.96 天的单实例累计约 1,039 次 start，与报告实测的 2,378 个 tap 同量级。每个键盘事件到达 `cgSessionEventTap` 时都要流经这些残留 tap，正是 `add_event_vector_to_tap` 成为 WindowServer 热点的原因。

根因置信度：高。代码缺陷明确且可静态确认，报告的最小实验给出了因果隔离，本机日志与报告 tap 数在数量级上互证。缺口在于本机无法独立读取 tap 列表，因此「精确 tap 数」仍以报告数据为准。

## Fix

`Sources/RemoteMic/KeyboardEventSuppressor.swift` 的 `stop()` 中，在 disable 之后、清空引用之前调用 `CFMachPortInvalidate(eventTap)`：

```swift
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            // 只 disable 不会把 event tap 从 WindowServer 的 tap 列表中摘除，必须
            // invalidate 底层 CFMachPort。否则每次 start/stop 都会残留一个 tap，
            // 长时间后台运行后累积到数千个，使 WindowServer 在每个输入事件上付出
            // 遍历全部残留 tap 的代价。
            CFMachPortInvalidate(eventTap)
        }
```

该改动与 Issue #476 的 Proposed fix 完全一致（「after disabling the tap and removing its RunLoop source, before clearing the references」），也是报告作者已在本地验证过 `swift build` 通过的最小改动。

## 验证

已执行：

- `git diff --check`：无空白或行尾问题。
- `swiftc -parse Sources/RemoteMic/KeyboardEventSuppressor.swift`：退出码 0。
- 改动仅涉及 1 个文件、5 行新增，未触碰其他文件。

未执行（受本机环境限制，须由上游 CI 或维护者补足）：

- `swift build --disable-keychain` / `swift test --disable-keychain`：本机只安装了 Command Line Tools（`/Library/Developer/CommandLineTools`），未安装完整 Xcode。构建在 `Sources/RemoteMic/KeyboardShortcutPicker.swift` 处失败，报错为 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'`——SwiftUI 宏插件随完整 Xcode 提供，与本次改动无关。已通过 `git stash` 在纯净 `upstream/main`（`41167180f18c07758e6732c5e366018ad4d958a4`）上复现同一失败，确认是既有环境问题而非本修复引入。仓库 CI 使用 `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`，不受此限制。
- tap 数复现：本机没有报告中使用的 `CGEventTapList` 计数手段。
- 真机长跑 A/B：需连续运行数天后对比 WindowServer 占用。

## 未覆盖边界

- 本修复只消除 tap 泄漏，**不改变重连频率本身**。本机日志显示约 8.4 次/小时的重连会持续触发 start/stop；泄漏被堵住后不再累积，但重连为何如此频繁属于独立工作项，不在本记录范围。
- 本机在 2026-09-25T02:33 之后出现单实例生命周期骤降（2.5 小时内先后出现 `pid=680`、`3220`、`6009`、`7624`、`8299`，均仅存活约 30–45 分钟），与前述 4.96 天长跑实例形成对比。该变化与本 Bug 无关，是否属于另一问题需另行定位。
- 未在真实遥控器上验证修复后的按键映射、长按与手势行为是否与修复前一致。
