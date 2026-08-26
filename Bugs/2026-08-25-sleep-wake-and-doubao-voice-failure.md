# 休眠唤醒后蓝牙失效，以及豆包有电平但没有文字

- 时间：2026-08-25
- 状态：候选修复完成，等待真实 Mac 休眠唤醒、遥控器和豆包输入验收
- 影响范围：用户反馈版本 1.9.10；回溯检查 v1.9.3 至 v1.9.10
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

## 检查过的代码位置

- `Sources/RemoteMic/BluetoothLifecycle.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Sources/RemoteMic/XiaomiBluetoothBridge.swift`
- `Sources/RemoteMic/AudioOutput.swift`
- `Tests/RemoteMicTests/BluetoothLifecycleTests.swift`
- `Tests/RemoteMicTests/VirtualAudioConnectionLifecycleTests.swift`
