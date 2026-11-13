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

## 2026-11-13 会话补充记录

### 历史调试原因

- `Bugs/2026-08-24-final-word-tail-loss/DEBUG.md` 的 H1 记录过：22 次真实 RC003 会话中有 20 次在 `STREAM_STOP` 时仍有待播放缓冲，单次最多 4 个；秒级日志不能证明 Fn 抬起与播放器排空谁先发生。结论是“音频已入队/最终排空”不等于“目标工具在 Fn 抬起前收到最后一批音频”。
- #177 补过尾音诊断；#680 补过 RC003 有界音频缺口诊断；#320 曾尝试“Bluetooth voice playback before key release”但已关闭；#358 修复过 drain 超时后一直等待的问题；#523 合并过避免 drain deadlock 的实现。本次没有重做这些历史修复，只补正常停止的 release 时序。
- #793 是更早的 Draft“drain Bluetooth playback before releasing software PTT”，当前与 main 冲突；本 PR #1029 是当前干净实现。两者只能保留一个，不能同时合入。
- #1028 的独立蓝牙回调队列在 build 346 造成了音频交付回归：同长度会话覆盖率从 build 345 的 96.4% 降到 94.3%，录音少 1.681 秒，目标文字从 93 字变成 0 字。该队列改动已关闭；本 PR 不使用独立回调队列，也不改变主队列基线。

### 本次现场与自动化记录

- build 345（29.760 秒）：1912 / 1984 通知，覆盖率 96.4%，录音 28.680 秒，目标文字 93 字。
- build 346（29.625 秒）：1863 / 1975 通知，覆盖率 94.3%，录音 27.945 秒，目标文字 0 字；`gaps_ge_20ms=96`、`gaps_ge_100ms=1`，App 侧 `dropped_samples=0`、`interrupted_samples=0`。
- build 346 的缺失是通知到达前的交付缺口，不是本 PR 的 flush 或按键释放逻辑造成的；本 PR 解决的是“尾包已入队但语音键先释放”的独立时序。
- 本 PR 定向测试：`Core voice input journeys` + `Virtual audio connection lifecycle` 51 项 / 2 suites 通过；`git diff --check` 通过。
- 本地组合包 build 348（#1026 + #1029 + #1030，基于 main）完成 release 构建、签名、资源/本地化校验，并实际启动；组合 `swift test --disable-keychain` 为 1399 项 / 103 suites 通过。该组合结果不能替代逐 PR 合并后的真机结果。
- 待完成：真实 RC003 正常松键最后词、连续快速会话、60 秒超时停止、异常断开恢复；没有真机结果前保持 Draft。

### 合入边界

- 不合入 #1028；不与 #793 同时合入。
- 本 PR 只改正常蓝牙停止后的语音键释放时序，不改变解码、路由、录音或目标工具。

- 关联边界：#1026 负责远端 60 秒超时后的 Fn 提交，#1030 负责本地转写候选保留，#1024 删除不可用的 RC003 续流实验入口；本 PR 只负责正常停止的尾音排空与按键释放。
