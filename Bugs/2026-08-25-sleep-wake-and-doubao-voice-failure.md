# 休眠唤醒后蓝牙失效，以及豆包有电平但没有文字

- 时间：2026-08-25
- 状态：补充 HID 晚到候选修复；Fn 模式已在真机命中 `matched=0 → recovery completed`，左/右 Command 模式仍待真机验收
- 影响范围：用户反馈版本 1.9.10；回溯检查 v1.9.3 至 v1.9.10，并确认 2026-08-28 `origin/main` `10900ee2` 仍存在 HID 一次性映射窗口
- 功能点：CoreBluetooth 睡眠唤醒恢复、MiRemoteV 2ch 虚拟音频、豆包输入法文字捕获
- 简单描述：Mac 休眠后无线麦或遥控器无法继续工作，重启 App 才恢复；豆包显示电平但最终没有文字。
- 原始记录：用户反馈及共享 Bug 目录中的 `runtime 2.log`、`runtime1.log`。日志未复制语音内容；设备诊断字段只用于区分现场状态。

## 复现与范围

当前没有反馈机器的可控复现环境，因此不能声称已在原机复现。根据用户描述和代码行为，记录两个可重复的边界：

1. App 重启会重建 `CBCentralManager`、连接 generation 和扫描状态，用户反馈重启后恢复；原有唤醒路径只恢复虚拟音频，没有主动重建 BLE 连接周期。
2. 音频链路可收到并解码 PCM，因此 UI 电平会变化；如果虚拟音频播放器或引擎在会话开始前已经失效，PCM 会被拒绝或无法送入 MiRemoteV 2ch，豆包不会得到有效输入。

## 日志观察

### 1.9.10 `runtime 2.log`

- `ATVV STREAM summary trace=17` 显示已收到并解码 `samples=31920`，但 `enqueue_failures=99`。
- 同一时间段反复出现 `AUDIO WRITE rejected`，旧日志只显示 `engine_running=false`，没有说明拒绝阶段。
- 现场还有 `default_system_output` 变化，随后触发 `AUDIO RECOVERY` / `AUDIO REBIND`；重绑期间引擎停止，后续音频写入失败。
- 结论：这条会话的电平来自 BLE 解码/电平统计，不代表 PCM 已成功进入虚拟音频设备。

### 另一份 `runtime1.log`

该文件不是 1.9.10，而是 1.8.3、1.8.25 和 1.9.8 的多段运行记录，不能与本次 1.9.10 会话直接合并：

- 1.8.3/1.8.25 多次出现 `selected={none}`、`engine_running=false` 和大量入队失败，符合旧的“虚拟音频设备未选择/未就绪”路径。
- 1.9.8 的多次 `ATVV STREAM summary` 基本为 `enqueue_failures=0`，但随后出现 `initial_focus_unavailable`、`snapshot_unavailable_after_finish`；这些会导致没有文字，即使音频链路正常。
- 因此“有电平但无文字”至少包含音频未入队、虚拟设备未就绪、输入框未聚焦/文字快照不可用三类机制，不能用单一根因解释所有版本。

## 版本回溯与根因假设

从 v1.9.3 开始检查，v1.9.10 的 `Sources/RemoteMic` 没有新的业务代码变化；蓝牙重连高风险变化集中在 v1.9.9 的以下提交：

- `bce4d122`：过期 BLE 重连退避
- `ba589212`：电源恢复期间的 BLE 恢复
- `66fa6206`：隔离退避后的重连尝试
- `0af93c3b`：终态释放 BLE observer

休眠唤醒问题的高概率假设是：系统唤醒时已有 central/generation 处于退避、断开或终态，系统回调没有让连接周期重新开始；重启 App 通过重建 central 恢复。该假设尚未由反馈机的唤醒日志最终确认。

1.9.10 音频问题的高概率假设是：默认系统输出变化触发了不必要的整套音频重绑，短时间内把播放器置为不可写；旧日志没有将拒绝原因、播放器状态和完整设备绑定状态记录出来。另一份 1.9.8 日志同时证明了独立的文字焦点/快照失败路径。

## 最小修复

- `BridgeAppModel.handleSystemAudioLifecycle` 在系统唤醒完成音频恢复后，主动恢复已选蓝牙 bridge、已注册 bridge 和 discovery bridge；没有 bridge 时沿用现有启动连接逻辑。
- `XiaomiBluetoothBridge.recoverAfterSystemWake()` 只记录 central/lifecycle/generation，并调用现有 `reconnectNow()`，不改变协议、扫描或退避策略。
- `VirtualAudioRecoveryPolicy` 对“仅 `default_system_output` 变化且显式 MiRemoteV 绑定仍健康”的事件只刷新设备列表，避免无关路由变化把正常播放器重绑为不可写。
- `AudioOutput.enqueue` 对空样本、未 ready、缺少 player、缓冲创建失败分别记录拒绝原因；会话摘要追加 `audio_ready` 和完整 `audio_state`。
- `AUDIO REBIND finished`、`AUDIO HEALTH`、BLE central 状态和唤醒恢复均增加结构化诊断字段，便于下次区分“未收到唤醒回调、未触发重连、设备未枚举、引擎未启动、播放器未播放、绑定错误、文字焦点失败”等状态。

本次没有修改 ATVV 协议、音频驱动、豆包进程、输入法快捷键或重连退避参数，也没有加入持续轮询或强制重启第三方 App。

## 自动化验证

- `swift test --filter 'BluetoothLifecycleTests|VirtualAudioConnectionLifecycleTests'`：32 个聚焦测试通过。
- `swift test`：35 个测试套件、365 个测试全部通过。
- 新增测试覆盖：只有 `systemDidWake` 且 App 已启动才触发 BLE 唤醒恢复；显式音频配置健康时忽略仅默认系统输出变化。
- `xcrun swift build --skip-update --scratch-path /private/tmp/remote-mic-swiftpm/1.9.10-136/apple-silicon-sayall-ai --cache-path /private/tmp/remote-mic-swiftpm-cache/1.9.8-132 -c release --triple arm64-apple-macosx14.0`：Release 编译通过；仅有修改前已存在的 macOS 14 `onChange` 弃用警告。
- `./scripts/build-app.sh` 首次尝试在 SwiftPM 下载 Sparkle 二进制工件/系统钥匙串阶段等待约 5 分钟后主动停止；未进入源码编译，属于构建环境依赖获取阻塞，不判定为代码失败。未对现有历史 App 运行 `verify-app.sh`，避免把旧包误当成本次候选包。
- `git diff --check`：通过。

## 验证边界与下一步

- 尚未在真实反馈 Mac 上执行睡眠→唤醒→首次按键/首次语音，也尚未用真实 RC001/RC003 和豆包输入法验收。
- 自动化测试不能证明 CoreBluetooth、macOS 电源唤醒时序、MiRemoteV 2ch HAL 或豆包最终文字提交。
- 下一次现场日志应重点收集 `BLE WAKE`、`BLE CENTRAL`、`AUDIO RECOVERY`、`AUDIO REBIND`、`AUDIO WRITE rejected reason=...`、`ATVV STREAM summary ... audio_state=...` 以及 `TRANSCRIPT CAPTURE` 的同一 trace/时间段。

## 2026-08-28 现场复现：BLE Ready 时 HID service 尚未出现

本轮在同一台 Mac、同一只 RC003 和北京时间 2026-08-28 13:43 至 14:20 的现场中复现了一个更精确的独立失败窗口：

- 13:43:29 Mac 进入系统休眠；13:43:35 BLE 从 Ready 断开。
- 14:12:11 RC003 重新进入 `BLE READY`，但该次 Ready 回调中的唯一一次映射得到 `VOICE FN MAPPING applied=false ... matched=0`，紧接着两次 HID monitor 均因 `power_suppressed=false` 拒绝启动。
- 14:12 至 14:20 的六次语音会话均收到完整 `STREAM_START → AUDIO → STREAM_STOP`；最后一次解码 44,640 个样本、`enqueue_failures=0`、`route=virtual_audio`，证明 BLE 音频和虚拟麦克风仍在工作。
- 14:20 另用公开音频采集工具直接录制 `MiRemoteV 2ch`，约 4.8 至 7.3 秒存在清晰非静音信号；该实验只验证虚拟音频输出，不读取或依赖第三方 App 内部数据。
- 从 14:12 的 `matched=0` 到 14:20 没有第二次 `VOICE FN MAPPING`。方向键仍可控制系统，但 RC003 F5 没有被重新映射为 Fn，因此第三方语音输入没有收到启动键；点击“立即重新连接”会制造新的 Ready 转换并再次调用映射，所以能够恢复。

### 根因

蓝牙 bridge 的 Ready 与 macOS `IOHIDEventSystemClient` 枚举出 RC003 service 不是同一时刻。现有代码只在 bridge 从非 Ready 进入 Ready 时调用一次 `applyHIDSettings()`；如果那一刻 `matched=0`，既没有 HID service 到达通知，也没有延迟重试，因此用户当前选择的语音键模式无法恢复。HID monitor 又要求电源键映射已经安全生效才能启动，无法反向触发恢复。

该时序问题不只影响 Fn：Fn/地球键模式需要把 RC003 F5 映射为 Fn；Fn 点按、左 Command 和右 Command 模式都需要先把实体 F5 中和，再由软件发送所选按键。四条路径共享同一次 HID service 枚举，因此 `matched=0` 会阻断当前所选模式，而不是只丢失固定的 Fn 映射。

### 补充修复

- 仅当 App 已启动、至少一个蓝牙 bridge 为 Ready 且映射仍为 `matched=0` 时，按 0.5、1、2、4、8 秒最多重试五次现有 `applyHIDSettings()`；该方法读取当前 `voiceKeyMode`，不会强制切回 Fn。
- 任一重试枚举到目标 HID service 后立即结束；所有 bridge 不再 Ready 或 App 停止时取消；五次耗尽后停止，不持续轮询。
- 增加 `scheduled`、`applying`、`completed`、`cancelled` 和 `exhausted` 日志，下一次现场可直接确认恢复结果。
- 不修改 ATVV、虚拟音频、输入法协议、语音键按下/释放时序或手势定义。

### 补充验证边界

- `swift test --filter 'BluetoothLifecycleTests|VoiceKeyModeTests|RemoteVoiceFunctionMapperTests'`：3 个测试套件、44 个测试通过；覆盖有限退避序列、Ready 回调接线、断连取消接线、当前模式读取，以及 Fn/左右 Command 的映射与中和边界。
- `swift test`：37 个测试套件、421 个测试全部通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：Self Test 44 项全部通过。
- `./scripts/check-repository-boundaries.sh`：公开仓库边界检查通过。
- 自动化验证 App 未启动、无 Ready bridge、已经枚举到 HID service 时不再安排恢复；同时验证恢复重试重新进入读取当前 `voiceKeyMode` 的完整映射流程，没有把模式写死为 `.function`。
- 仍必须用本轮代码构建同一 App，在真实 RC003 上重放“久置或休眠 → 电源键唤醒 → 方向键可用 → 不点击立即重新连接 → 第一次语音”。只有首次语音成功并看到 `HID MAPPING RECOVERY completed`，才能确认现场问题修复。

### 测试包真实休眠唤醒结果

北京时间 2026-08-28 15:49 至 15:51，用户在同一台 Mac、同一只 RC003 上运行本分支构建的 `1.9.18 (171)` 测试 App，并在不点击“立即重新连接”的情况下完成一次合盖休眠唤醒：

- `pmset` 记录 15:49:24 因 `Clamshell Sleep` 进入休眠，15:50:04 从 Deep Idle 完整唤醒；`kern.boottime` 仍为 2026-08-26 11:39:18，因此本次不是关机重启或冷启动。
- App 在 15:50:05 重新进入 `BLE READY`，HID 映射直接得到 `matched=1 applied=1`，音频恢复到 `MiRemoteV 2ch`。
- 唤醒后第一次语音于 15:50:41 开始，Fn down/up 完整，23,280 个样本全部通过虚拟音频路由，`enqueue_failures=0`；随后两次语音分别通过 30,000 和 128,640 个样本。
- 用户确认唤醒后遥控器正常，证明本候选包的真实休眠唤醒基础路径、Fn 触发和虚拟音频路径通过。
- 本次 HID service 已及时出现，没有复现原故障的 `matched=0`，日志中也不会出现 `HID MAPPING RECOVERY completed`。因此有限重试分支仍只有自动化覆盖，尚不能表述为已完成该分支的真机验收。

### 测试包命中有限重试分支

随后同一台 Mac、同一只 RC003 再次复现原问题时序：首次映射记录 `matched=0`，新逻辑在 500ms 后执行第一次重试，得到 `matched=1 applied=1`，并记录 `HID MAPPING RECOVERY completed attempts=1`。整个过程没有点击“立即重新连接”；恢复后的下一次语音成功触发豆包，传输 31,920 个音频样本且 `enqueue_failures=0`，后续四次语音也均正常。

现场同时确认：BLE Ready 后约 0.2 秒立即按下的第一次语音发生在 500ms 重试前，因此仍可能漏掉；恢复完成后不会持续失效。该结果验证了 Fn/地球键与豆包路径，但没有验证左 Command、右 Command 或 Fn 点按模式的真实 RC003 按键侧别、权限和第三方 App 行为，这三项仍需按 `Testing/VoiceKeyModes.md` 完成真机验收。

## 检查过的代码位置

- `Sources/RemoteMic/BluetoothLifecycle.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Sources/RemoteMic/XiaomiBluetoothBridge.swift`
- `Sources/RemoteMic/AudioOutput.swift`
- `Tests/RemoteMicTests/BluetoothLifecycleTests.swift`
- `Tests/RemoteMicTests/VoiceKeyModeTests.swift`
- `Tests/RemoteMicTests/VirtualAudioConnectionLifecycleTests.swift`
