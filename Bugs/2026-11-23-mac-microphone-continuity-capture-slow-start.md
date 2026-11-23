# Mac 麦克风选择 iPhone 连续互通麦克风后无音频

状态：代码修复完成，等待真实 iPhone 连续互通麦克风列表与文字上屏验收。

## 现象

用户选择 Mac 麦克风并在连接页点击“用<设备名>说话”后，按 Fn 多数情况下没有文字，偶发可用。重启 SayAll 后恢复。重启后的日志没有 Mac 麦克风会话，只有遥控器语音。

## 证据

现场日志会话 `B285B1BF`，2.0.10 Build 431：

- `00:59:51.720` 选择 iPhone 连续互通麦克风，系统默认输入切到 `id=837`。
- `00:59:55.501` Fn down；`00:59:55.511` 采集绑定 837。
- `00:59:58.037` Fn up，进入 stopping；按住 2.536 秒。
- `00:59:59.729` `device_started`；`startup_timing ... start_ms=3860`。
- `00:59:59.760` `samples=0 completion=no_audio`。
- `00:59:59.768` 控制器记录 `result=stopped completion=normal`。
- `01:02:06` 837 不可用，回退到内置麦克风 `id=139`。
- `01:07:36` 与 `01:09:06` 两次内置麦克风采集正常：`start_ms=233/5`、`first_pcm=740/707 ms`、`samples=48000/68800`。
- 重启后的会话 `E1FF5107` 没有 `MAC MICROPHONE` 事件；Fn 走 `ATVV STREAM` 遥控器路径，`samples=138720`。

## 根因

- [MacMicrophoneCapture.swift](../Sources/RemoteMic/MacMicrophoneCapture.swift) 只把 Bluetooth / BluetoothLE 输入交给 `AVCaptureSession`；其他输入走 `AVAudioEngine`。
- iPhone 连续互通麦克风不是 Bluetooth，因此走 `AVAudioEngine`。本次 `engine.start()` 阻塞 3.86 秒。
- 正常按键时长约 2.5 秒。松键先触发停止。`engine.start()` 返回后采集才启动，得到 0 样本。
- 停止路径只记录 `completion=no_audio`，不调用 `fail(.noAudio)`。控制器按正常停止处理，界面回到待命，没有文字也没有错误提示。
- 同类阻塞已在 AirPods 出现。AirPods 的修复是改用 AVCapture；本次按产品确认直接排除连续互通 transport，避免提供无法保证按下即录的设备。

## 修复

- 新增 `MacMicrophoneInputEligibilityPolicy`，排除 `kAudioDeviceTransportTypeContinuityCaptureWired` 和 `kAudioDeviceTransportTypeContinuityCaptureWireless`。
- [BridgeAppModel.swift](../Sources/RemoteMic/BridgeAppModel.swift) 的备用麦克风候选列表使用该策略；iPhone/iPad 连续互通麦克风不再显示。
- 已保存的连续互通设备 UID 不在候选列表，按既有回退逻辑切到内置麦克风或当前默认物理输入。
- 同步产品规范和测试手册。

## 验证

- 自动化：`swift test --disable-keychain --filter MacMicrophoneInputTests`。
- 构建：`swift build --disable-keychain`。
- 静态检查：`git diff --check`、`scripts/verify-repository-governance.sh`。
- 真实设备待验收：连接 iPhone 后，下拉框不显示连续互通麦克风；保存过 837 的配置启动后回退到内置麦克风；内置麦克风、AirPods、USB 麦克风仍可选；真实文字上屏不受影响。

## 边界

- 同一现场日志还包含遥控器 BLE 恢复暂停问题；该问题已由 [#1193](https://github.com/HD838A/remote-mic-app/pull/1193) 单独修复。本记录只覆盖 `00:59:55` 的 Mac 麦克风连续互通采集路径。
- 只改变本功能的候选列表，不改变系统默认输入、其他功能或第三方工具的麦克风选择。
- 无法只排除 iPhone 型号；同一 transport 的 iPad、有线连续互通麦克风也会一起排除。
- 本次日志没有记录 CoreAudio transport；`ccwd` / `ccwl` 判断依据是设备命名、非蓝牙采集路径和设备消失行为。下一次现场日志应补 transport 只读诊断。
- 单元测试和构建不能替代真实 iPhone、AirPods、USB 麦克风与文字上屏验收。
