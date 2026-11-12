# 语音键与豆包绑定不是同一个键时只有电平、没有文字

- 时间：2026-11-11
- 状态：用户改回标准配法（SayAll 语音触发键 = Fn，豆包长按模式 = fn，免按模式留空）后自述恢复；未在本机复现。提示形态已由 PR #1010 改为可执行内联条，见下方「后续处理」。
- 影响范围：SayAll 1.9.21（build 174），小米蓝牙遥控器 2 Pro（rc003），豆包输入法
- 功能点：语音触发键模式、豆包输入法「长按模式／免按模式」、虚拟音频 `MiRemoteV 2ch`
- 简单描述：按住语音键时 App 内电平正常、回眸录音可回放，豆包侧也有收音提示，但输入框始终没有文字。原因是 SayAll 发出的语音键与豆包「长按模式」所绑定的键不是同一个。
- 原始记录：微信群反馈中的 runtime.log 截图与三张设置截图；日志未复制语音内容。

## 现场配置

- SayAll 语音触发键：**右 Command**，日志中每一段会话均为 `VOICE KEY mode=right_command`。
- 豆包「语音输入」：长按模式 = `fn`；免按模式原为 `右⌘`，反馈过程中已清空；麦克风选择 = `MiRemoteV 2ch`。
- 权限：蓝牙、输入监控、辅助功能三项全部已开启。
- 未安装 Karabiner 等改键工具；系统「修饰键 → 选择键盘：小米蓝牙语音遥控器」五项均为默认映射。
- 现象：15:35 至 15:43 之间多段会话，豆包有收音提示、输入框无文字，App 内录音可正常回放。

## 日志观察

以 15:43 那段（session=127，目标为微信 `com.tencent.xinWeChat`）为例，逐条为原始字段：

```
VOICE INPUT source_prepare tool=doubao result=selected managed=false
VOICE KEY mode=right_command edge=down result=event_submitted target_response=unknown
ATVV STREAM accepted trace=3 model=rc003
ATVV AUDIO routed trace=3 model=rc003 route=virtual_audio accepted=true first_batch_samples=240 pending_buffers=1
ATVV STREAM STOP session=127 partial_frame_bytes=0
ATVV STREAM summary trace=3 model=rc003 duration_ms=3213 batches=193 samples=46320 enqueue_failures=0 route=virtual_audio pending_buffers=2 flush=false audio_ready=true audio_state={engine_running=true player_playing=true selected={name=MiRemoteV 2ch id=90} actual_output={name=MiRemoteV 2ch id=90} bound_to_selected=true default_input={name=MacBook Pro麦克风 id=126}}
```

会话起止完整、`enqueue_failures=0`、虚拟设备已绑定且播放器在播放，说明按键触发、音频入队、设备路由三段都正常。`target_response=unknown` 表示 SayAll 无法观测目标工具是否真的收到按键，因此日志本身不能证明豆包收到了右 Command。

同一时段另外三项观察：

- `TRANSCRIPT CAPTURE waiting/skipped reason=initial_focus_unavailable`：回眸读不到微信输入框的聚焦元素。三项权限均已开启，因此不是权限缺失，是 AX 取不到该输入框，需另立工作项。
- `HID CONNECTED mode=monitored seize_error_domain=io_return seize_error_code=-536870207`（kIOReturnExclusiveAccess）：现场没有第三方改键工具，判断为 macOS 不允许对蓝牙 HID 键盘独占，走既有监听降级路径；同段 `HID REPORT accepted ... buttons=none` 与会话正常起止说明按键链路可用。
- `HID DEVICE/REPORT rejected reason=excluded_fingerprint`：发现用监听器排除已归属某个键位方案的设备，属正常日志，不是故障。

## 根因

豆包「语音输入」只有长按模式和免按模式两种绑定，没有「右 Command 长按」这一类。用户把 SayAll 设为右 Command 之后：

1. 豆包长按模式绑的是 `fn`，收到的是右 Command，不会进入长按收音；
2. 右⌘ 当时被设为免按模式（按下开始、再按任意键结束），SayAll 按下时被它接住，所以出现收音提示；
3. 小米遥控器松手即停麦（固件行为），SayAll 松开时发出的 up 不被免按模式当作结束键，收音无法收尾，文字也就不会上屏。

用户按标准配法改回后自述恢复，与该解释一致。

## 产品缺口（2026-11-11 复核后下调）

- 设置页并不缺提示：`connection.voice_key_mode.help` 与 `connection.voice_key_mode.unverified_detail` 自 `ea7400e9`（2026-08-31）起就渲染在「语音触发键」选择器下方，选择非 Fn 模式时会显示「请在目标语音工具中同步配置相同的触发键……如果没有文字，请改回 Fn/地球键」。承载它们的 `mappingVoiceKeyModeControl` 自 `991b5283`（2026-08-24）起存在，1.9.21 已包含。因此本次事故不能归因于提示缺失。
- `onboarding.voice_tool.voice_key_help` 是 `935cfd35`（2026-08-27）引入、2026-08-31 的 Fn-only 策略调整后被取代的死键：中英文各一条，`Sources/` 下无任何引用。正确处理是删除，不是接线到设置页。
- 唯一仍然成立的诊断性缺口：按键映射页的语音键卡片 `button_mapping.voice_button.detail` 是静态文案，右侧胶囊固定为「语音触发键」，不显示当前实际是哪一种触发键；用户要先点开语音键面板，才能从分段选择器的选中项看出来。

## 后续处理（PR #1010，2026-11-11 已合入）

把上面第一条的「提示存在但被当成介绍跳过」落到具体改动，不改语音链路：

- 「语音触发键」面板在非 Fn 模式下的一行 12px 灰字换成 `NoticeInline`（warning）：标题点名当前键，例如「在语音工具中快捷键也要配置为“右 Command（⌘）”」；右侧动作「改回 Fn」直接调 `setVoiceKeyMode(.function)`。
- 四种修饰键（左/右 Command、左/右 Option）统一同一语气与文案。它们在这件事上完全等价：`requiresAccessibility` 是同一实现、`usesHardwareMapping` 只对 Fn 生效、注入走同一条 `setVoiceKeyPressed` 路径，没有按 Command/Option 分档的依据。
- `connection.voice_key_mode.help` 删掉与提示条重复的一句；`unverified_detail` 改写为配置步骤，不再用看不出配哪个键的「同一个」。
- 截图夹具新增 `REMOTE_MIC_SETTINGS_SCREENSHOT_VOICE_KEY_MODE`，否则夹具固定 Fn，产不出这条提示的运行截图。
- 回归 `SettingsPageRegressionTests` 锁定：提示存在、标题注入当前键名、动作为改回 Fn。

合入提交 `7f1c53de`；验证为公开模式全量 `swift test` 1343 项 / 96 套件，CI 双架构构建通过。

仍未处理：

- 语音键卡片不显示当前触发键（本段第三条），需要改 `RemoteMappingCanvas` 的卡片形态，涉及与私有包 Siri / Chromecast 画布的共享视觉合同，单独排期；
- `onboarding.voice_tool.voice_key_help` 死键清理，纯整洁项；
- 回眸读不到微信 / ChatGPT 输入框（`initial_focus_unavailable`），权限已全部开启，属独立的 AX 读取问题。

## 边界

- 未在本机复现；现场日志只能证明 SayAll 侧正常，不能证明豆包侧的按键接收与文字提交（`target_response=unknown`）。
- 「改回后恢复」是用户自述，尚未回收改后日志做前后对照。
- 与 2026-11-06 的 `i` 泄漏、2026-11-10 的 build 320 语音回归不是同一现象：本次音频与按键链路均正常，差异只在目标工具的按键绑定。
- 同一群里另一名用户「遥控器和手机都用不了」的反馈机制不同且缺日志，不并入本条。

## 检查过的位置

- `Sources/RemoteMic/BridgeAppModel.swift`（`VOICE KEY` / `VOICE INPUT` 日志与按键注入路径）
- `Sources/RemoteMic/PreferredInputSourceMonitor.swift`
- `Sources/RemoteMic/TranscriptCaptureCoordinator.swift`
- `Sources/RemoteMic/SettingsView.swift`（语音触发键选择器）
- `Resources/zh-Hans.lproj/Localizable.strings`、`Resources/en.lproj/Localizable.strings`
