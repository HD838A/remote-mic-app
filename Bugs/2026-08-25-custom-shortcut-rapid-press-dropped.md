# 自定义快捷键连续快速按只有第一次生效

- 时间：2026-08-25
- 状态：候选修复完成；自动化与项目自检通过，等待 RC001 / RC003 真机连按验收
- 影响范围：macOS 全部已发布版本（现场证据来自 1.8.3 与 1.9.10 build 136）；单击绑定为不支持按住连发的动作，且该按键没有配置双击或长按
- 功能点：按键映射、非重复动作的原始按下闸门（`HIDRemoteMonitor.shouldAcceptRawPress`）
- 简单描述：把按键绑定为自定义快捷键后连续快按，只有第一次执行，之后的按下被静默丢弃，需要间隔约一秒才能再次触发。
- 原始记录：用户现场 `runtime.log`（1.9.10 build 136）；社区反馈 [Issue #205](https://github.com/HD838A/remote-mic-app/issues/205) 第 2 条

## 触发条件

1. 启用「自定义按键映射」。
2. 把某个按键的**单击**绑定为不支持按住连发的动作（`ButtonAction.allowsRepeat == false`），例如自定义快捷键、`Command + Return`、`Command + Q` 或打开自定义 App。
3. 该按键**没有**配置双击或长按（否则走手势识别路径，不经过本闸门）。
4. 连续快速按该按键。

正常行为边界：间隔约 1 秒以上按下时每次都生效；配置了双击或长按的按键不受影响；方向键、音量键、退格键在非无线麦前台时不受影响。

## 复现证据

用户现场 1.9.10 build 136 的 `runtime.log`。1.9.0 新增的 `HID EDGE` 使按下边沿可见，被丢弃的按下表现为有 `HID EDGE pressed=...` 但后面没有对应的 `HID GESTURE` / `HID BUTTON`：

```
06:57:27.065  pressed   → GESTURE → BUTTON        生效
06:57:27.290  released                             解锁定时器排到 27.890
06:57:27.605  pressed   → 无后续                   丢弃（距松开 315ms），定时器被取消
06:57:27.800  released                             新定时器排到 28.400
06:57:27.950  pressed   → 无后续                   丢弃
06:57:28.115  released                             新定时器排到 28.715
06:57:28.190  pressed   → 无后续                   丢弃
06:57:28.370  released
06:57:28.390  pressed   → 无后续                   丢弃
06:57:28.477  released
06:57:28.568  pressed   → 无后续                   丢弃
06:57:28.642  released
06:57:28.715  pressed   → 无后续                   丢弃
06:57:28.820  released
06:57:28.881  pressed   → 无后续                   丢弃
06:57:28.971  released                             此后没有新按下，定时器执行
06:58:25.179  pressed   → GESTURE → BUTTON        生效
```

同一段日志里连续 8 次按下全部被丢弃；三次成功的按下间隔为 1.53 秒和 1.20 秒。

对照实验（同一按键、同一监听路径）：把该按键改绑为 `appSwitcher`（`Command-Tab`，`allowsRepeat == true`）后连按全部生效，同一秒内可记录 6–7 条。说明失效与动作类型相关，与目标 App 无关。

社区独立复现，[Issue #205](https://github.com/HD838A/remote-mic-app/issues/205) 第 2 条：

> 未开启双击｜长按模式时，按键映射单击快速点选没反应，会卡住：比如快捷键打开终端，再次执行快捷键会收回终端。在本程序下，连续按键无反应。

该反馈与本记录的触发条件完全一致（无双击/长按 + 单击绑定不可连发动作），此前未定位到机制。

## 日志结论

被丢弃的按下在修复前不产生任何日志。`HIDRemoteMonitor.process(usages:)` 的 `guard shouldAcceptRawPress(...) else { continue }` 位于 `diagnosticLogger("HID GESTURE ...")` 之前，因此只能通过「有 `HID EDGE pressed` 但没有后续 `HID GESTURE`」间接推断，排查成本高。`HID EDGE` 是 1.9.0 才加入的，1.8.x 现场完全无法区分「按键被丢弃」和「按键根本没收到」。

## 根因

`ButtonAction.allowsRepeat` 同时控制两处语义不同的判断：

| 位置 | 语义 | 排除不可连发动作是否正确 |
| --- | --- | --- |
| `startRepeatIfNeeded`（`HIDRemoteMonitor.swift`） | 按住不放时是否启动 App 自己的重复定时器 | 正确，是 `Bugs/2026-08-09-custom-shortcut-repeat-and-sidebar-focus.md` 的修复目标，必须保留 |
| `shouldAcceptRawPress`（`HIDRemoteMonitor.swift`） | 一次新的按下边沿是否被接受 | 这是本 Bug 的来源 |

第二处的闸门来自 `Bugs/2026-08-09-post-fix-multi-remote-hid-routing.md`：`customShortcut.allowsRepeat` 置为 false 之后，一次按住仍产生约 18 条执行记录，因此追加了 `nonRepeatablePressedButtons` 闸门，并规定「松开必须稳定 `600ms` 才解锁」。该记录同时说明了为什么不能用更短的按下到按下冷却时间：

> A 5-second physical hold captured the exact lifecycle: initial press, a false release after `2714ms`, another press `449ms` later, and the final real release after the user let go. This rejects a fixed press-to-press cooldown and confirms that non-repeatable actions need release stabilization.

也就是说，一次真实按住过程中出现的虚假松开间隔可达 449ms，而人手有意连按的间隔通常短于这个值。**从按下边沿的时序上无法区分「按住时的重复上报」和「用户真实的第二次快按」**，缩短阈值不能解决问题，只会把按住保护一起放掉。

同时确认闸门的「续期」不是缺陷：被丢弃的按下取消待执行的解锁定时器，正是按住保护得以成立的机制。去掉续期后按住 3 秒会按每 600ms 放行一次，对 `Command + Q` 这类绑定比现状更糟。

结论：两个决定各自成立，组合后产生了没被考虑到的结果——用户无法连续快速触发一个不可连发的动作，而这在「快捷键打开/收起面板」「切换会话」这类绑定上是正常用法。这不是可以由代码单独判定的取舍，需要用户按按键表达意图。

## 修复

最小改动，默认行为与修复前完全一致：

- `RemoteDeviceProfile.swift`：`RemoteDeviceMappings` 新增可选字段 `buttonRapidPressEnabled: [String: Bool]?`，沿用 `buttonApplicationProfileIDs` 的可选字段兼容方式；值为空时存 `nil`，旧配置无需迁移。
- `AppSettings.swift`：新增按按键的 `buttonRapidPressEnabled`，随所选遥控器配置、`UserDefaults`、导出/导入配置一起保存；`allowsRapidPress(for:)`、`allowsRapidPress(for:profileID:)`、`setAllowsRapidPress(_:for:)`；「恢复默认」会一并清除。导入旧配置文件（没有该字段）时按关闭处理。
- `HIDRemoteMonitor.swift`：`shouldAcceptRawPress` 新增 `allowsRapidPress` 参数，默认 `false`。为 `true` 时清除该按键已有的闸门状态并直接接受本次按下，**不改动 `startRepeatIfNeeded`**，因此 App 自己的连发定时器对这些动作依然不启动。
- `HIDRemoteMonitor.swift`：按下被闸门丢弃时写日志 `HID PRESS rejected button=... action=... reason=awaiting_stable_release stable_release_ms=600`，不再静默。这一条与开关无关，默认生效。
- `SettingsView.swift`：单击动作不支持按住连发时，在该按键的单击编辑区内显示「允许连续快速按」开关，并说明打开后按住可能重复执行。页面内联，不使用弹窗。
- 本地化：`button_mapping.rapid_press`、`button_mapping.rapid_press_hint_short`、`button_mapping.rapid_press_help`，中英文同时新增。

未改动：`ButtonAction.allowsRepeat`、`HIDRemoteTiming.stableReleaseMilliseconds`、闸门续期逻辑、手势识别路径、`KeyboardEventSuppressor`。

## 验证

在 `codex/allow-repeated-custom-shortcut-presses` 分支（基线 `6e809dc`）执行：

- `swift build`：Build complete，无新增警告。
- `swift test`：393 项通过，0 失败（含 `rawHardwareRepeatStaysLatchedUntilAStableRelease`、`navigationRepeatStopsOnlyWhileRemoteMicIsFrontmost` 与本地化键完整性）。
- `scripts/test.sh`：项目自检 43 项通过，0 失败。
- 新增回归：
  - `rapidPressOptInLetsNonRepeatableActionsFireOnEveryRawPress`：开关关闭时第二次按下仍被丢弃；打开后连续 5 次按下全部接受；另一按键不受影响；重新关闭后立即恢复闸门；`commandQuit` 等其他不可连发动作行为一致。
  - `rapidPressOptInDefaultsOffAndPersistsWithMappings`：默认关闭、按按键独立、写入所选遥控器配置、重新读取 `UserDefaults` 后保持、关闭后不留残值、「恢复默认」清除。
  - `rapidPressOptInTravelsWithExportedConfigurationAndToleratesOlderFiles`：导出/导入携带该开关；删除该字段的旧配置文件仍能导入并按关闭处理。

## 验证边界

- 未执行真机验收。上述现场日志由用户在 1.9.10 build 136 上采集，修复本身只经过自动化、项目自检和本地构建验证。
- 本机没有可选的 `REMOTE_MIC_HARDWARE_SIMULATION_PATH`，`HardwareSimulationIntegrationTests` 匹配 0 项，600ms 定时器的真实到期路径未在自动化中驱动。
- 开关打开后「按住该按键是否会重复执行」取决于遥控器在按住期间是否继续产生按下边沿。`Bugs/2026-08-09-post-fix-multi-remote-hid-routing.md` 记录了会产生（约 18 条 / 3 秒），但没有 HID 层抓包或固件版本，界面说明因此写为「可能会重复执行」。这一点需要真机在 1.9.x 的 `HID EDGE` 日志下确认：按住 4 秒，若只出现一对 `pressed` / `released` 则按住不会重复。
- 本机工具链 Swift 6.3.3，仓库要求 6.2；CI 上的完整检查以 PR 为准。
