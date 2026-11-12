# 蓝牙语音停止前等待虚拟麦克风尾音排空

- 时间：2026-11-13
- 状态：候选修复完成；自动化通过，真实 RC003 复测待完成
- 影响范围：RC003 正常松键、软件语音键、虚拟麦克风尾音、目标语音工具最后文字
- 功能点：bluetooth_remote、virtual_audio、voice key release

## 问题

蓝牙语音正常停止时，`bluetoothBridgeDidStopVoice` 在播放队列仍有待播放缓冲时立即调用 `releaseVoiceKeyIfNeeded`。如果目标语音工具依赖语音键按住状态，最后一批音频可能已经在本地入队，却在语音键抬起后才到达目标，表现为尾字缺失。

历史记录 `Bugs/2026-08-24-final-word-tail-loss/DEBUG.md` 的 H1 已记录该时序风险；现有采集已提供 `pending_buffers`、`AUDIO PLAYBACK drained` 和末尾 300ms 信号统计。

## 修复

- 正常蓝牙停止不再立即释放蓝牙语音键。
- 使用 `AudioOutput.endSessionAfterDraining` 等待已入队音频自然排空；`maximumDelay` 为 `nil`，不触发 flush，不丢弃在途样本。
- 排空完成后才释放语音键，并记录 `VOICE KEY tail_release`。
- 新蓝牙会话开始时，如果上一次排空仍在等待，先释放上一段遗留的软件按键保持，再开始新按下，避免连续语音被旧会话卡住。
- 正常停止仍保持 `flush=false`；录音、解码和路由行为不变。

## 验证

- `swift test --disable-keychain`：1399 项 / 103 suites 通过。
- 定向 `TranscriptCaptureCoordinatorTests`、`BluetoothVoiceStopPolicyTests`、`VirtualAudioConnectionLifecycleTests` 通过。
- `git diff --check` 通过。
- 待完成：真实 RC003 正常松键尾字、连续快速会话、60 秒远端停止；没有真机结果前不标记为已验收。

## 边界

自动化只能证明排空等待和按键释放顺序。真实 CoreBluetooth、RC003 固件、豆包最终文字仍须真机复测。
