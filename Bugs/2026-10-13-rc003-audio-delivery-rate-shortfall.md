# RC003 长会话音频到达率不足导致尾部缺失

- 时间：2026-10-13
- 状态：现场结论已确认；修复方案待真机验证，本轮只补账目未改业务行为
- 影响范围：macOS 1.9.21；RC003 物理语音键 + 虚拟麦克风路线；会话越长越明显
- 功能点：ATVV 音频接收、虚拟麦克风输出、本地录音、第三方语音工具上屏
- 简单描述：每次会话实际收到的音频只覆盖会话时长的 84%～96%，缺口随会话长度累积；音频内容因此始终落后于说话进度，松手时最后约 5%～16% 的话还没送到，遥控器已停流，表现为尾部截断，且本地录音同步变短。
- 原始记录：用户提供的 `runtime.log`（`1.9.21 build=174`，2026-10-12T07:27Z–2026-10-13T03:26Z，29 次 rc003 会话）

## 现场

- 遥控器 RC003，Mac 为 M2 Air，macOS 26.6.2，SayAll 1.9.21，第三方工具 Vokie 1.6.1 / 豆包输入法。
- 用户口述：单开 Voki（SayAll 关闭）体验正常；打开 SayAll 搭配 Voki 时尾部截断明显；豆包比 Voki 略好；**说得越长越明显**；SayAll 自己的回眸录音**也是截断的**；短句几乎感觉不到。
- 日志中该用户的 `VOICE INPUT` 记录显示配置工具为微信输入法，与口述的 Voki/豆包不一致，复访时需确认。

## Observations

- 29 次会话**全部**满足：`enqueue_failures=0`、`partial_frame_bytes=0`、`flush=false`、各 1 条 `AUDIO PLAYBACK drained`、**0 条 `AUDIO PLAYBACK interrupted`**、29 条 `RECORDING ASSET saved`。
- **0 条** `ATVV AUDIO ignored_after_stop`、`ATVV AUDIO ignored_not_ready`、`ATVV FRAME discarded`、`ATVV STREAM implicit_audio_race`。→ 旧实现「停止后 300 ms 内音频被丢弃」在本次现场**一次都没有发生**。
- 会话窗口内 **0 次** `BLE SCANNING`、`BLE CENTRAL state=`、`AUDIO REBIND`、`AUDIO CONFIGURE`。→ 不是被自身蓝牙活动或音频重配打断。
- `ATVV CAPS version=256 codec=2 frame=120`：每帧 120 字节 = 240 个 16 kHz 样本 = **15.0 ms/帧**，实时需要 66.7 帧/秒。
- 实测帧到达节奏为 **15.0～17.9 ms/帧（56.4～63.9 帧/秒）**，即每次会话的实际音频时长为会话时长的 **83.9%～95.8%**：

| 会话 | 时长 | 音频 | 覆盖 | 缺口 |
| --- | --- | --- | --- | --- |
| 853/9 | 2.1 s | 1.78 s | 83.5% | 0.35 s |
| 853/4 | 4.4 s | 4.14 s | 95.0% | 0.22 s |
| 15682/3 | 13.5 s | 11.60 s | 86.1% | 1.87 s |
| 15682/5 | 15.0 s | 12.66 s | 84.6% | 2.30 s |
| 19284/2 | 24.7 s | 20.86 s | 84.4% | 3.85 s |
| 19284/6 | 37.2 s | 35.62 s | 95.8% | 1.56 s |

- 缺口与主线程在做什么**无关**：完全没有触发转写捕获（`TRANSCRIPT CAPTURE`）的 3 次会话覆盖率仍是 88.1%～91.2%。按捕获结果分组：`canceled` 均值 86.7%（n=5）、`saved` 均值 91.2%（n=21）、无捕获均值 90.1%（n=3）——差异不足以支持「辅助功能轮询拖垮主线程」。
- 尾部指标显示**最后一帧就在停止前 7～28 ms**（`last_audio_age_ms`），末 300 ms 几乎全为有声样本（`tail_nonzero` 4648～4797 / 4800）。→ 音频流一直送到停流为止，缺失的部分不在末端一次性发生。
- 停播延迟 5～44 ms，与停止时的 `pending_buffers`（1～3）× 15 ms 吻合；`HID EDGE` 的 Fn 释放处理发生在停流后 71～135 ms，**晚于**音频排空。→ 不是「松手时队列被清空」或「输入法比音频先结束听写」。
- `VOICE FN MAPPING applied=true neutralized=false`：Fn 模式走遥控器硬件 Fn，SayAll 不注入也不接管，输入法何时结束听写不由 SayAll 控制。

## Root Cause

远端音频的**到达速率长期低于实时**（本次现场 56.4～63.9 帧/秒 vs 需要 66.7 帧/秒）。由于内容始终以该速率落后，松手时最后的那一段话还没有到达 Mac，遥控器随即停流，这部分音频永久丢失。因此：

- 缺口与说的时间成比例 → 「越长越明显」；
- 本地录音是接收流的副本（`recordingAssetCoordinator.append` 在解码处复制），同步变短 → 「录音也截断」；
- 音频流一直送到停流为止、且播放队列只落后十几到几十毫秒 → 所有「松手时被 flush / 队列被清空」的假设都不成立；
- SayAll 侧丢弃计数全为 0 → 缺口不是本地策略丢弃造成的。

**未确认（证据缺口）**：无法区分「遥控器固件与 BLE 发送队列本身达不到实时」与「通知在链路/控制器层面被静默丢弃」。现有日志**没有逐帧到达时间**，两者只能靠空口抓包区分。相同连接内的不同会话节奏在 15.0～17.9 ms 间波动，说明不是单一固定连接参数。

## 本轮改动（只补账目，不改业务行为）

- `ATVVProtocol`：新增 `expectedFrameCount` 与 `audioCoveragePercent`，把「按实时应有」与「实际收到」变成可计算的量。
- `XiaomiBluetoothBridge`：新增 `ATVVAudioReceiveStats`，会话开始时重置，覆盖四个方面：
  - **到达量**：帧数、通知次数、字节数；一次通知可能携带多帧，两者分开记。
  - **时间维度**：`max_gap_ms` 与 `max_gap_at_ms`（最大缺口出现在会话的第几毫秒）、`gaps_ge_20/50/100/250ms` 直方图。**均匀低速率**（间隔稳定略大于 15 ms、无大缺口）与**成段停顿**（少数几次上百毫秒的缺口）必须能区分开，这是「远端发不满」与「突发丢包」的分水岭。
  - **分包异常**：`notify_bytes` 最小/最大值与 `not_frame_multiple`（通知字节数不是声明帧长整数倍），用于发现重组错位。
  - **本地丢弃**：`gate_drops`（生命周期门）、`late_stop_drops`（停流后丢弃）。
- 每 5 秒输出 `ATVV STREAM progress`，除累计值外**额外给出本区间**的 `interval_frames` 与 `interval_coverage_pct`。只在会话结束时汇总，永远分不清缺口落在开头、中段还是结尾。
- 停流时输出 `ATVV AUDIO receive` 两会话总账，并写明 `stream_origin=remote_initiated|host_requested`：本次现场是 `remote_initiated`，说明流由遥控器发起、由遥控器结束，**宿主既没有写任何控制命令、也没有能力延长它**。
- 补齐三处此前的静默丢弃：`handleCharacteristicValue` 的 `acceptsProtocolData` 门、`ATVV AUDIO ignored_after_stop`、`BridgeAppModel` 里 identifier 不匹配的音频批次（`identifier_drops`）。
- `ATVV STREAM summary` 增加 `expected_batches`、`coverage_pct`、`max_gap_ms`、`gate_drops`、`late_stop_drops`、`identifier_drops`。
- `RecordingAssetStore`：`RECORDING ASSET saved` 增加 `audio_ms` 与 `audio_samples`。清单里的 `duration_ms` 是墙上时间，**不能**证明录音内容长度；用户「录音也截断」的说法此前无法在日志里验证，补上后每次会话都能直接对比「会话时长 vs 录音音频时长」。
- 新增 8 项自动化断言覆盖实时帧预算、覆盖率计算、账目结构、低速率与停顿的区分、分包异常计数、区间进度字段、流归属字段和录音音频长度。

## 修复方向

1. **本轮已实施（候选修复，待真机验收）：把 ATVV 音频的接收与主线程解耦。**

   现场证据把范围压到了无线麦自己这一侧：同一个 RC003、同一个链路，单用第三方工具驱动遥控器时没有这个现象，只有开着无线麦才会出现；而无线麦的 29 次会话里，所有显式丢弃计数都为 0、音频一直送到停流为止 —— 说明帧是在**到达本地前**就没的。

   代码侧只剩一条解释：`XiaomiBluetoothBridge` 用 `CBCentralManager(delegate: self, queue: .main)`，会话中约 **66.7 个通知/秒全部投到主线程**。蓝牙栈只有在回调队列被及时排空时才释放接收缓冲；主线程忙着 SwiftUI、HID 事件、辅助功能查询时缓冲排不空，通知就在控制器/系统侧被丢掉，**丢多少与忙碌时长成正比**，于是「说的时间越长、尾部缺得越多」。该写法自最早版本就存在，`1.9.21` 同样受影响。

   改动：
   - `CBCentralManager` 改用专用串行队列 `RemoteMic.bluetooth`，回调队列不再受主线程负载影响；
   - 新增 `onMain` 帮助函数，代理与中央回调都在拿到回调后立刻切回主线程，**业务状态仍然只在主线程变更**（保持原有线程模型与顺序）；
   - `CBCharacteristic.value` 是可变的「最新值」属性，必须在回调线程上先把本次字节取出来再切线程，因此 `handleCharacteristicValue` 改为显式接收 `value: Data?`；否则排队期间会被后续回调覆盖，反而把音频吃掉。
   - 新增源级回归断言：队列不得回到 `.main`、`onMain` 必须存在、取值必须先于切线程。

   **边界（未验证）**：这是候选修复。本机没有真实 RC003 与目标第三方工具，无法验证是否真正消除尾部缺失；按 `Testing/HardwareVoiceAudioContract.md` 的「首字快、尾字全、正常不 flush」门禁，必须在真实设备上完成首字延迟、尾字完整、连续会话和断连/异常恢复验收后才能交付。

   如果真机验证后缺口仍然存在，说明帧确实没离开遥控器或没被系统投递到进程，则需要走第 2 条。

2. **若上述修复无效**：用 PacketLogger 空口抓包一次长会话，数每秒音频通知数。约 66/秒 → 帧到了 Mac 却被丢，继续查本地接收路径；约 60/秒 → 遥控器本身发不满，需要由宿主持有麦克风流（有界 `MIC_OPEN` / `MIC_EXTEND` / `MIC_CLOSE`）让遥控器把积压的尾部推完再关流。注意 `2026-08-10-rc003-one-minute-voice-session-timeout.md` 已撤回一次物理流 `MIC_EXTEND` 尝试，且 Chromecast 曾出现「未关远端流导致麦克风长期开启」的事故，必须配硬上限。

## Validation

- `swift build --disable-keychain --disable-sandbox`：通过。
- `swift test --disable-keychain --disable-sandbox --filter 'ATVVProtocolTests|BluetoothVoiceTailDiagnosticsTests|RecordingAsset'`：35 项 / 3 套通过，其中 9 项为本轮新增。
- `scripts/verify-repository-governance.sh origin/main`：通过。
- 本轮不改变蓝牙控制时序、Fn、输入法切换、排空策略或文字上屏行为；线程模型仍然「业务状态只在主线程」。
- **未验证**：真实 RC003 上的尾部完整性、首字延迟与连续会话。候选修复必须真机验收后才能交付。

## 现场复现所需

用户下一次反馈只需要带一份新的 `runtime.log`，无需任何额外操作，以下四组数字即可直接定性：

1. `ATVV STREAM progress` 每 5 秒的 `interval_coverage_pct` —— 缺口是全程均匀还是中途突然变差；
2. `gaps_ge_100ms` / `gaps_ge_250ms` —— 均匀低速率还是成段停顿；
3. `gate_drops` / `late_stop_drops` / `identifier_drops` —— 本地是否仍有静默丢弃；
4. `RECORDING ASSET saved` 的 `audio_ms` 与同一会话 `summary` 的 `duration_ms` —— 录音是否与接收流同步变短。

## Validation Boundary

- 尚未用 PacketLogger 确认缺口发生在远端发送侧还是 Mac 接收侧。
- 尚未在真实 RC003 上验证修复后尾部是否恢复完整。
- 本机没有用户现场那台 M2 Air 的真实设备与第三方工具，本轮结论全部来自用户提供的 `runtime.log`（29 次会话）与源码交叉核对。
