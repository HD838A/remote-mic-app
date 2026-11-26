# 多次短唤醒后自动连接暂停，系统已连上遥控器 App 仍显示未连接

- 时间：2026-11-26
- 状态：候选修复与自动化完成；等待真实 RC003 睡眠矩阵、系统 HID 重连和第三方语音工具验收
- 影响范围：macOS；小米 RC001 / RC003；笔记本合盖或闲置自然睡眠，每次只短暂唤醒；最新 `main`（`a8c238bc`）同样存在
- 功能点：遥控器有限恢复预算、系统唤醒恢复、HID 设备在场恢复
- 简单描述：长时间不用遥控器（例如从家到公司），Mac 期间多次短暂唤醒后，连接页变成「自动连接已暂停」。到达后系统蓝牙已经自动连上遥控器，按键在 SayAll 界面有响应动画，但语音链路不恢复，必须手动点「重新连接」。

## 现场证据

来源为维护者本机公开构建（2.0.8 Build 256，source `95b27a43`，未包含 #1193/#1195）的脱敏 `runtime.log`。日志只用于确认事件顺序，本文不记录设备身份或语音内容。时间为北京时间。

| 时间 | 日志事实 |
| --- | --- |
| 11-25 11:11–12:04 | 6 次 `system_did_wake` → `screen_did_wake`；每次 `BLE RECOVERY phase=begin trigger=session_activated`，`RECOVERY_WINDOW result=ready attempts=1`，Ready 后约 60–100 秒再睡眠 |
| 11-25 12:20:25 | 第 7 次唤醒同一路径，`RECOVERY_WINDOW phase=completed result=paused attempts=0`，卡片状态 `paused` |
| 11-26 10:40:31 | 系统 HID 重连遥控器：`HID NATIVE MAPPING ... result=verified`、`HID CONNECTED` |
| 10:40:31–46 | 多次 `HID EDGE`、`HID BUTTON ... action=arrowDown`、`HID VOICE_USAGE source_kind=f5`；同期没有 `BLE CONNECTING` |
| 10:58:09 | 用户手动 `RECOVERY_WINDOW ... manual=true`，0.45 秒后 `BLE READY` |

同机 11-23、11-24 日志重复出现同样模式（各 6 次成功唤醒后第 7 次 `result=paused attempts=0`）。

补充事实：现场 Mac 的 `kern.boottime` 到当前为 27.0 小时，而 `ProcessInfo.systemUptime` 仅 14.3 小时；睡眠期间 uptime 不前进。

## 根因

1. **成功的唤醒重连被计入失败窗口。** `RemoteConnectionRecovery.claimAttempt` 对 `.automatic` 每次尝试都写入十分钟滚动窗口，连接成功后不清除；窗口按 `systemUptime` 计时。跨数小时的 6 次短唤醒在 uptime 上只相隔几分钟，第 7 次 `automaticAttempts.count < 6` 不成立，直接 `finish` 为 `.paused`。
2. **#1193 的系统唤醒豁免没有覆盖「屏幕后醒」的顺序。** 现场 `system_did_wake` 到达时屏幕仍在睡眠，记录 `resume_deferred`；真正完成恢复的是随后的 `screen_did_wake`。`BluetoothWakeRecoveryPolicy.shouldForceReconnect` 只认 `event == .systemDidWake`，于是走 `session_activated` 的 `.automatic` 恢复，继续消耗失败预算。#1193 Bug 文档的现场也是这条 `voice_link_recovery` 路径。
3. **系统 HID 重连不能解除暂停。** `BridgeAppModel` 在已绑定遥控器 `HID CONNECTED` 时调用 `connectBluetoothIdentifier(manual: false)`，已有桥走 `bridge.start()`，以 `.automatic` 进入 `begin`，暂停状态返回 `budget_paused`。注释明确不允许 HID 出现重置预算，而 #1193 的设计说明是「失败后锁存，直到真实设备出现、语音键或手动操作解除」，两者不一致。普通按键也没有恢复入口。
4. 现场构建不含 #1193，因此语音键也不会补连；最新 `main` 的语音键补连只是兜底，第 1–3 点仍会让 UI 长期停在暂停。

### 根因实验

仓库外把 `main` 的 `RemoteConnectionRecovery.swift` 原样编译，回放「6 次唤醒均 Ready、每次醒约 70 秒 uptime」：

```text
wake=1..6 claimed=true status=ready
wake=7 claimed=false status=paused
hid_connected_start admission=paused
voice_key admission=started
```

与现场第 7 次 `attempts=0`、HID 重连后无 `BLE CONNECTING`、手动恢复立即成功一致。

## 修复

- `RemoteConnectionRecovery.resume(...)`：设备在睡眠前稳定 Ready ≥ 30 秒时，睡眠只是生命周期中断，清空十分钟失败窗口历史。短暂 Ready（< 30 秒）仍延续原恢复轮次与三次上限；离线设备真实握手失败仍受三次/60 秒和十分钟六次限制。
- 新增 `DeferredSystemWakeTracker`：挂起中收到的 `system_did_wake` 被记住，由最终恢复事件（通常 `screen_did_wake`）以 `.systemWake` 承接，不再落入 `.automatic`。纯屏幕睡眠不受影响。
- 新增恢复触发器 `.devicePresence`：已绑定遥控器 HID 重新连接时，若该桥处于 `paused` / `not_found`，允许一次有界恢复（30 秒手动窗口、一次握手、30 秒冷却），不重置失败历史，用户「取消」结果保持最终。空闲状态仍走原自动启动。
- 日志：`BLE RECOVERY_WINDOW ... recovery_trigger=<trigger> automatic_attempt_history=<n>`、`SYSTEM AUDIO resume_deferred ... deferred_system_wake=true|false`、`SYSTEM AUDIO wake_recovery event=<event> cause=deferred_system_wake`、`BLE RECOVERY phase=requested|skipped trigger=device_presence previous_status=<status> source=hid_connected`。

## 验证

自动化（公开模式，`--disable-keychain`）：

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteConnectionRecoveryTests|BluetoothLifecycleTests|VoiceKeyDiagnosticTests|VirtualAudioConnectionLifecycleTests'`：133 项通过。
- 新增 `stableReadyBeforeSleepDoesNotChargeLaterWakeReconnects`（回放 12 次短唤醒）、`briefReadyBeforeSleepStillCountsAgainstTheRollingLimit`、`devicePresenceLiftsPausedBudgetOnceWithCooldown`、`devicePresenceNeverOverridesUserCancellation`、`deferredSystemWakeIsOwnedByTheFinalResume`；`sessionResumeRecoveryIsWiredIntoTheSystemAudioLifecycle` 追加延迟唤醒与 HID 在场接线检查。
- 反向实验：去掉稳定清理后回放测试在第 7 次唤醒起失败（30 处断言）；去掉 `.devicePresence` 准入后在场与取消用例失败。恢复实现后全部通过。

待真机（见 `Testing/RemoteConnectionRecovery.md` 用例 12）：

- RC003 合盖短唤醒 ≥ 7 次不进入暂停。
- 遥控器离线至暂停后返回，系统 HID 重连即自动恢复，第一次语音首字和尾字完整。
- 取消后 HID 重连不自动恢复；HID 抖动 30 秒内只一次握手。
- 历史未选中 RC001 离线时不被反复唤醒。

## 验证边界

- 自动化使用虚拟时间与事件回放，不能证明真实 CoreBluetooth 回调、睡眠唤醒顺序或固件行为。
- 「稳定 30 秒」沿用既有 `stableConnection` 阈值；在 30 秒内反复睡眠/掉线的设备仍会进入暂停，此时依靠 HID 在场、语音键或手动恢复。
- HID 在场恢复仅覆盖已绑定、非私有适配器的遥控器；Apple / Chromecast 未修改。
- 未取得第三方语音工具文字上屏结果前，不把 `BLE READY` 视为最终成功。
- 本修复不改 ATVV 音频、语音键手势、普通按键映射或发布流程；Windows 未修改。
