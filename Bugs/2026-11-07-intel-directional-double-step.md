---
title: Intel 上方向键一次按下移动两格
subtitle: 方向键缺少事件级兜底，原生方向键与 App 注入同时生效
lang: zh
template: doc
date: 2026-11-07
status: 代码与回归已提交；本机无可编译工具链，待 CI 与 Intel 真机验收
---

## 现象

Intel Mac 上按一次遥控器方向键，文本光标移动两位；同一配置在 Apple Silicon 上只移动一位。

左右上下四颗方向键都会复现。按住时更明显：系统原生重复与 App 的重复同时生效，速度约为两倍。

## 证据

### 本机（Intel，macOS 14.2.1，x86_64）

本机就是 Intel，`ioreg` 里遥控器键盘接口在位（VID `0x2717`、PID `0x32B8`）。明文 `runtime.log` 记录：

| 记录 | 含义 |
| --- | --- |
| `HID CONNECTED mode=monitored seize_error_code=-536870207` | 独占打开返回 `0xE00002C1`（`kIOReturnNotPrivileged`），退回监控模式 |
| `HID NATIVE MAPPING phase=prepare result=verified reason=mapping_readback services=1 native_delivery=unobserved` | 设备级映射写入并回读一致；日志本身已声明原生投递未观察 |

`RemoteNativeKeyMapper` 对方向键 usage `0x4F/0x50/0x51/0x52` 写入的就是这一份零映射。

### 已归档的 Intel 现场测量

`Bugs/2026-10-29-intel-volume-native-leak-before-arm.md` 在同一类 Intel 机器上实测：

- 设备级映射 4 次 `result=verified`、`services=1`，同一时段仍拦截到 227 次原生按下。
  即**回读通过不等于系统停止投递**，结论已由音量键独立验证。
- 原生事件比主线程登记早约 200 ms（`preceding_unclaimed_ms=199`），
  而报告线程的提前登记能把这段差值抹平（build 269 按下边沿 0 泄露）。

同一份记录还排除了「平台差异来自独占失败」：Apple Silicon 上同样是
`mode=monitored`、`seize_error=-536870207`。因此两平台的差别不在是否独占，
而在**设备级映射是否真的阻断原生投递**——Intel 上回读通过但仍投递，
Apple Silicon 上没有观察到投递。方向键 usage `0x4F/0x50/0x51/0x52`
写在同一份零映射里，与音量键共用同一条 HID 报告链路。

本缺陷不是新的时序问题，而是**方向键从未被纳入事件级兜底**：

```swift
// 修复前
if button == .tv || button == .volumeUp || button == .volumeDown {
    return needsEventLevelArm(seized:activeDeviceIsSeized, neutralized: nativeKeysNeutralized)
}
return !nativeKeysNeutralized          // 方向键走这里：中和成功即不再登记
```

`Bugs/2026-10-26-tv-volume-native-race.source.md` 已写明当时的取舍：
「当前代码只恢复 TV 和音量的兜底登记。方向、电源、菜单等其它按键仍使用源头映射的普通键盘保护。」
Intel 现场已经证明这条保护不成立。

## 根因

一次物理方向键按下在 monitored 会话里产生两条独立路径：

1. 系统路径：HID → WindowServer → 原生 `keyCode 123/124/125/126` → 光标移动一格。
2. App 路径：HID 原始报告 → 主线程 → 执行 `arrowLeft/arrowRight/…` → 再注入一格。

修复前方向键两边都会登记失败，因此必然双份：

- `shouldArmNativeEvent` 对方向键返回 `!nativeKeysNeutralized`；本机中和成功，
  于是**主线程根本不登记**，原生事件直接被放行。
- `prearmManagedNativeEvents` 只枚举 TV 与音量，**报告线程也不登记**，
  即使主线程登记也追不回早到约 200 ms 的原生事件。
- 同一时刻 `shouldUseNativePassthrough` 因 `!nativeKeysNeutralized` 为假而被挡住，
  默认左右动作改由 App 执行，于是 App 注入的那一次必然发生。

Apple Silicon 上设备级映射回读之后确实停止了原生投递（本机 Intel 上无效，见上文归档证据），
系统侧不再产生方向键事件，只剩 App 注入一次，所以不表现。

## 最小修复

### 1. 方向键登记事件级兜底（默认只在 Intel 构建）

`shouldArmNativeEvent` 为方向键单独开一条分支：映射已回读生效（`neutralized`）时，
由 `directionalNativeFallback` 决定是否登记；映射未生效时保持修复前的行为（登记），
因为那条路径本来就没有源头隔离，默认左右动作走原生透传由调用点排除，
其余动作（自定义快捷键等）仍要靠登记拦住原生方向键。

`directionalNativeFallback` 是注入项，默认值按构建架构取值：

```swift
static let directionalNativeFallbackEnabled: Bool = {
    #if arch(x86_64)
    return true
    #else
    return false
    #endif
}()
```

为什么不在 Apple Silicon 上一起打开：方向键的原生码与实体键盘完全同码
（keyCode 123/124/125/126），登记会在每次遥控器方向键按下/松开后各开一个
0.5 s 的待匹配窗口。Intel 上这个窗口会被泄漏的原生事件立刻消费掉（实测为几十毫秒），
Apple Silicon 上没有任何原生事件来消费，窗口是实打实开着的：

- 窗口内按实体键盘方向键：keyDown 命中待匹配记录被吞，keyUp 再被
  「已认领原生配对」规则吞掉 → 丢一次按键，无副作用。
- 更窄的一段（按下后 0.5 s 已过、松开后 0.5 s 未过）：keyDown 放行、keyUp 被吞，
  系统会认为该键仍然按下并继续连发 → 光标可能持续移动。

后半段是本轮自查发现的风险，也是收窄到 Intel 的直接原因。
Apple Silicon 上没有该泄漏证据，为不存在的泄漏开窗口没有收益。

### 2. 报告线程提前登记方向键

新增 `prearmsNativeEvent(for:seized:neutralized:directionalFallback:)`，报告线程按它决定是否提前登记：

| 按键 | 提前登记条件 | 理由 |
| --- | --- | --- |
| TV、音量加、音量减 | 与外层 `needsEventLevelArm` 一致 | 始终由 App 执行，原生事件一律要拦 |
| 四颗方向键 | `directionalFallback && !seized && neutralized` | 只在「有泄漏证据的构建 + App 必定自己执行移动」时拦 |
| 其余普通键 | 不登记 | 避免吞掉实体键盘同码按键 |

提前登记是主线程登记的子集：`seized && !neutralized` 或 `monitored && !neutralized`
时主线程会登记，但报告线程不提前登记——后者的原生事件可能正是透传动作本身。

方向键**不能无条件提前登记**：monitored 且源头映射未生效时，默认左右动作故意走原生透传，
原生事件本身就是那一次移动；抢先登记会把它吞掉，按键完全没有反应。
判据取 `!seized && neutralized` 正是本次现场条件——非独占（独占失败）且映射回读一致。

### 3. 保持的行为

- 独占成功且映射回读一致的机型不登记（`needsEventLevelArm(false)`），行为不变。
- monitored 且映射未生效的默认左右透传不登记，行为不变。
- monitored 且映射未生效、动作不是默认方向键（自定义快捷键等）时仍登记，行为不变
  ——兜底开关只决定「映射回读一致」那一段，评审时发现漏掉的正是这一条。
- 松开边沿在非提前登记路径上由主线程 `arm(edge: .up)` 与「已认领原生配对」规则接管；
  提前登记路径下按下由报告线程认领，主线程登记时不再持有配对标记，若原生松开
  早于主线程 `arm(edge: .up)` 到达会被放行。按下已被吞，孤立的松开事件不改变系统按键
  状态，与音量键已验证的松开边沿残留同类。
- **Apple Silicon 构建：方向键既不登记也不提前登记，行为与修复前完全一致**
  （含日志：不会有新增的 `HID FILTER arm events=key1xx` 行）。

## 验证

新增回归（`Tests/RemoteMicTests/KeyboardEventSuppressorTests.swift`）：

- `monitoredDirectionalPressOwnsItsLeakedNativeEvent`（参数化四颗方向键）：
  非独占 + 映射回读一致 + 兜底开启时，泄漏的原生方向键必须被拦下，且动作只执行一次。修复前必失败。
- `directionalFallbackKeepsNonLeakingBuildsFreeOfSuppressionWindows`（参数化四颗方向键）：
  兜底关闭（Apple Silicon 默认）时不得开窗口，原生事件放行、动作仍执行一次。
- `unneutralizedDirectionalKeepsItsArmingWithoutTheFallback`（参数化左右键）：
  映射未生效时兜底开关不得影响原有登记，自定义快捷键仍要拦住原生方向键。
- `monitoredPassthroughKeepsTheNativeArrowAsTheOnlyMove`：
  反向边界，映射未生效的透传会话不得登记，原生事件放行且 App 不注入。
- `directionalPrearmOnlyCoversSessionsWhereTheAppOwnsTheMove`：
  报告线程提前登记范围的取值表（方向键三种状态 + 兜底开关 + TV/音量两种状态 + 普通键）。

本地限制：本机只装了 Xcode 15 / Swift 5.9，而 `Package.swift` 要求 Swift tools 6.2，
`swift test --disable-keychain` 在本机无法启动（`package is using Swift tools version 6.2.0
but the installed version is 5.9.0`）。本次只完成 `swiftc -parse` 语法检查，
**自动化结果必须由 CI 或具备 Xcode 27 的机器确认**：

```sh
SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain \
  --filter "KeyboardEventSuppressorTests|RemoteButtonsTests"
```

## Intel 真机验收

前置：Intel Mac、遥控器独占打开失败（`HID CONNECTED mode=monitored`）、
自定义映射开启、映射回读 `result=verified`。

1. 在微信或备忘录输入框中连续短按左方向键 10 次，每次间隔至少 1 秒。
2. 每次光标只移动**一格**；不得出现两格或偶发两格。
3. 右、上、下三颗方向键各重复 10 次，判定同上。
4. 按住左方向键 2 秒后松开：按下期间按配置的重复策略移动，松开立即停止，速度不得翻倍。
5. 每次遥控器方向键操作后立刻按一次电脑键盘的方向键：键盘必须正常生效
   （窗口期内被吞一次属已知取舍，连续两次仍被吞即判失败）。
6. 触发 Command-Tab 会话后按左右键：高亮每次只移动一格（与 #485 同一判据）。

日志判读：

- 每次方向键按下后应出现 `HID FILTER arm events=key123 edge=down`，
  随后泄漏的原生按下应是 `HID FILTER suppressed event=key123 … armed_by=prearm|arm`。
- 若出现 `HID FILTER phase=arm_order … result=already_passed_through`，
  说明原生事件仍跑在登记之前，本次修复对这台机器无效，需回读现场日志再定位。
- 若完全没有 `HID FILTER suppressed`，说明这台机器上映射确实阻断了原生投递，
  双跳另有原因，不能按本结论关闭。

## 剩余边界

- **Apple Silicon 不接受本次兜底**。默认只在 Intel 构建启用（`#if arch(x86_64)`）。
  若将来在 Apple Silicon 上拿到 `HID FILTER miss event=key123` 一类证据，
  把 `directionalNativeFallbackEnabled` 改为 `true` 即可，回归已按开关参数化。
- 用 Intel 包在 Apple Silicon 上以 Rosetta 运行时，`#if arch(x86_64)` 仍为真，
  会按 Intel 处理；这是非支持组合，未做额外判定。
- `ok`、`home`、`menu`、`power` 等普通键仍按「源头映射优先」处理，未纳入本次兜底。
  这些键的原生码与实体键盘同码（回车、Esc 等），无差别登记会吞掉正常打字输入；
  是否需要类似兜底应单独评估，不能顺手扩大。
- Intel 构建里，实体键盘的方向键与遥控器方向键同码，登记窗口（0.5 s）内按下的
  键盘方向键可能被吞一次；窗口内的 keyUp 被吞会让系统认为键仍按下。
  验收步骤第 5 条专门检查它，出现「吞掉后仍在连发」即判失败。
- 若 macOS 在用户态投递 HID 报告之前就生成原生事件，仍可能漏一次；
  这是概率性保障，不是结构性保证。
- 本轮未改动源头映射、恢复记录、语音、音频、共享协议与设置存储。
- 未打包、未替换安装目录。

## 基线与合入

分析基线为 `64c382ac`（PR #901，2026-11-06 09:24）。核对时父项目 main 已到
`91f27056`（PR #916，2026-11-07 17:28），本分支落后 16 个提交。用 blob 哈希逐字节核对：

| 文件 | 基线 blob | main blob | 结论 |
| --- | --- | --- | --- |
| `Sources/RemoteMic/HIDRemoteMonitor.swift` | `77557bd4` | `77557bd4` | 一致 |
| `Sources/RemoteMic/RemoteButtons.swift` | `384e913a` | `384e913a` | 一致 |
| `Sources/RemoteMic/KeyboardEventSuppressor.swift` | `9e67f4d5` | `9e67f4d5` | 一致 |
| `Sources/RemoteMic/RemoteNativeKeyMapper.swift` | `4d6fed1f` | `4d6fed1f` | 一致 |
| `Sources/RemoteMic/BridgeAppModel.swift` | `edf95065` | `edf95065` | 一致 |
| `Tests/RemoteMicTests/KeyboardEventSuppressorTests.swift` | `13e3e663` | `13e3e663` | 一致 |
| `Testing/HIDIntermittentButtonDiagnostics.md` | `c912d471` | `c912d471` | 一致 |
| `Bugs/README.md` | `80683308` | `1c2110d9` | **已变化**（#902–#916 增加索引表） |

即本次分析与补丁针对的代码就是最新 main 上的代码，补丁可直接套用；
唯一需要人工处理的是 `Bugs/README.md`：rebase 后除了顶部 bullet，还要在
「## 索引」表中补一行（该表在 #902–#916 之间新增，基线里没有）。

- bullet：`- [Intel 上方向键一次按下移动两格](./2026-11-07-intel-directional-double-step.md)`
- 索引行：`| 2026-11-07 | Intel 上方向键一次按下移动两格 | 代码与回归已提交；本机无 Swift 6.2 工具链，待 CI 与 Intel 真机验收 |`

本机 `git fetch upstream` 走代理返回 `CONNECT tunnel failed, response 502`，
无法直接 rebase 到 `91f27056`，因此本地分支仍停在 #901 基线。
