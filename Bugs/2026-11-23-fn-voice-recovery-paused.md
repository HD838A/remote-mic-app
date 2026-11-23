# 睡眠唤醒后自动重连暂停，Fn 语音键必须手动连接或重启才恢复

- 时间：2026-11-23
- 状态：候选修复与自动化完成；等待真实 RC003、系统睡眠矩阵和第三方语音工具验收
- 影响范围：macOS；选中小米 RC001 / RC003；系统反复睡眠/唤醒或空闲唤醒；语音键映射为 Fn
- 功能点：遥控器有限恢复预算、系统唤醒恢复、HID 语音键意图、连接页/菜单栏暂停状态
- 简单描述：Mac 在约 40 秒周期内反复睡眠/唤醒，每次唤醒都消耗一次自动重连；十分钟内 6 次后进入“自动连接已暂停”。此后按语音键只有 HID 按键事件，没有 BLE 音频流；手动连接或重启 SayAll 才恢复。

## 原始记录

用户反馈：Fn 语音无法使用，SayAll 重启后恢复。现场提供 3 个加密 `.rmlog` session；使用私有支持工具解密，只在仓库外临时目录分析。本文只保留稳定字段和时间顺序，不记录设备标识、设备名、用户内容或第三方 App 私有状态。

## 现场证据

### 环境

- App：2.0.10，Build 431，source `40ccf2af6c21741cbcb108d956c18fb7629c6b5b`。
- 系统：macOS 14，x86_64。
- 设备：RC003；`voice_key_mode=fn`，`voice_fn_tap=false`。
- 语音工具：豆包；输入监控和辅助功能权限全程为 `true`。
- 同一现场另有 Build 430 session，出现相同模式。

### 时间线（北京时间）

| 时间 | 日志事实 |
| --- | --- |
| 11-23 01:56–02:02 | 6 次 `screen_did_sleep`/`system_will_sleep` → `screen_did_wake`/`system_did_wake`；每次唤醒 `SYSTEM AUDIO voice_link_recovery cause=no_ready_bridge`，随后 `BLE RECOVERY_WINDOW ... result=ready attempts=1`，Ready 约 40 秒后再次睡眠 |
| 02:03:11 | 第 7 次唤醒启动 `BLE RECOVERY_WINDOW` |
| 02:03:12 | `BLE RECOVERY_WINDOW ... result=paused attempts=0` |
| 02:03–08:56 | BLE 语音链路中断 6 小时 53 分；期间每次唤醒仍有 `SYSTEM AUDIO voice_link_recovery`，但没有新的 `BLE RECOVERY_WINDOW` |
| 08:55:45 / 08:55:52 | `HID VOICE_USAGE source_kind=f5 edge=down/up`，没有 `ATVV STREAM START`；按键存在，音频路径不存在 |
| 08:56:13 | 用户手动 `BLE RECOVERY_WINDOW ... manual=true` |
| 08:56:14–19 | `BLE CONNECTED` → `BLE READY` → 语音会话正常 |
| 09:09:54 | App 正常退出 |
| 09:10:19–23 | 重启后 4 秒内 `BLE READY` |
| 09:11:43 / 09:12:24 / 09:12:28 | 重启后语音会话正常，音频完整排空 |

Build 430 在 16:22–16:27 也出现 6 次睡眠/唤醒后 `result=paused attempts=0`，说明不是单次偶发。

### 失败边界

- 不是崩溃：`APP STOP` 为正常退出，无 `completion=forced`。
- 不是权限：`HID PERMISSIONS input=true accessibility=true` 全程成立。
- 不是音频丢帧：已开始的会话均 `completion=normal`，`dropped_samples=0`，尾包正常排空。
- 不是 BLE 设备自身掉线：每条 `BLE RECOVERY_WINDOW` 都在一次系统睡眠/唤醒之后；唤醒前桥为 Ready。
- 未确认：Fn 是否到达豆包。日志明确写 `native_delivery=unknown`、`target_response=unknown`、`external_capture=unknown`；本文只确认“没有 BLE 音频流”，不把第三方文字结果写成已确认。

## 根因

1. PR #1072（实现提交 `82bc3600`）引入 `RemoteConnectionRecovery`，把系统睡眠/唤醒后的重连也计为一次自动恢复尝试。
2. 十分钟滚动窗口最多 6 次；第 7 次唤醒时 `claimAttempt` 直接 `finish`，状态写成 `.paused`。
3. `.paused` 对自动恢复是终态：`begin(manual: false)` 只接受 `.waiting`，没有定时器把 `.paused` 改回 `.waiting`。后续每次唤醒仍会打印 `voice_link_recovery`，但 `begin` 静默失败，没有 `BLE RECOVERY_WINDOW`。
4. 语音键只写 `HID VOICE_USAGE` 诊断，没有把按下当作恢复意图；因此链路未就绪时按键不会触发重连。
5. 重启 App 创建新的 `RemoteConnectionRecovery`（`.waiting`）并重新连接，所以用户看到“重启就好了”。

对应代码：

- `Sources/RemoteMic/RemoteConnectionRecovery.swift`：`begin(manual:)` 的 `.waiting` 门禁、`.paused` 终态和十分钟滚动计数。
- `Sources/RemoteMic/XiaomiBluetoothBridge.swift`：系统唤醒进入 `reconnectNow()`，与普通失败共用预算。
- `Sources/RemoteMic/BridgeAppModel.swift`：`system_wake` 触发对所有桥的恢复；语音键没有恢复回调。
- `Tests/RemoteMicTests/RemoteConnectionRecoveryTests.swift`：旧测试明确断言暂停后 900 秒仍不能自动恢复。

## 修复

- `RemoteConnectionRecovery` 新增 `automatic` / `systemWake` / `voiceKey` / `manual` 触发器。只有 `automatic` 计入十分钟失败窗口；系统唤醒和语音键各自一轮，不写失败计数。
- 选中设备在睡眠前 Ready 时，每次真实唤醒允许一次免预算恢复；失败后锁存，不再让后续 40 秒睡眠周期反复握手，直到真实设备出现、语音键或手动操作解除。
- 语音键下沿在选中设备语音链路未就绪时触发一次 `voice_key` 恢复；只处理按下边沿，受 5 秒冷却约束，按键重复和上沿不重复触发。HID 事件不被消费。
- 新增稳定日志：`recovery_trigger`、`BLE RECOVERY phase=skipped reason=wake_not_eligible|budget_paused|cooldown`、`VOICE KEY reconnect_requested|reconnect_skipped`。
- 保留真实握手失败的三次/60 秒和十分钟六次上限，避免重新引入离线历史设备的盲连风暴。
- 连接页和菜单栏已有“自动连接已暂停”与“重新连接”入口；修复后管理员请求不再依赖重启。

## 验证

自动化：

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteConnectionRecoveryTests|VoiceKeyDiagnosticTests|BluetoothLifecycleTests'`：71 项通过。
- `RemoteConnectionRecoveryTests` 新增：暂停后系统唤醒启动一次性恢复、暂停后语音键启动一次性恢复及 5 秒冷却、唤醒资格要求睡眠前 Ready 且每次唤醒只一次。
- `VoiceKeyDiagnosticTests` 新增：语音键下沿每个边沿只触发一次恢复意图，重复报告和上沿不触发。
- `BluetoothLifecycleTests` 新增：`system_wake` 使用 `.systemWake` 触发器，语音键接线和日志 token 存在。

待真机：

- RC003 + 豆包，连续 7 次系统睡眠/唤醒后直接按语音键，不手动连接、不重启；验证首个 PCM、首字和尾字。
- 链路未就绪时按语音键，日志出现 `VOICE KEY reconnect_requested` 并最终恢复。
- 遥控器不可达时连续 6 次真实握手失败，后台仍暂停，不无限重试。
- 历史 RC001 离线时不因 RC003 的睡眠/唤醒被唤醒。
- 菜单栏“自动连接已暂停”和一键“重新连接”。

## 验证边界

- 自动化使用虚拟时间验证预算和接线，不能证明 CoreBluetooth 真实回调、睡眠唤醒时序或蓝牙固件行为。
- 语音键按下后再重连可能需要 1–6 秒，无法保证已经开口的首字；满足首字契约的主路径是选中设备唤醒后及时恢复链路，语音键是兜底。
- 未取得豆包侧录音/文字日志；不能把 `BLE READY` 或音频入队写成第三方文字上屏成功。
- 本修复只改 macOS 遥控器恢复；不修改 ATVV 音频格式、语音键手势、普通按键映射、Apple/Chromecast 适配器或发布流程。
