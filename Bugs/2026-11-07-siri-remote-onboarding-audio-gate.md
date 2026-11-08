# 只有一只 Siri Remote 时 Onboarding 永久卡在音频页

- 时间：2026-11-07
- 状态：已修复（2026-11-08 真机复验通过）
- 影响范围：macOS；控制来源为苹果遥控器、机器上没有小米遥控器或 Chromecast 桥的首次 Onboarding（含重新运行）
- 功能点：Onboarding 音频页、完成页音频门禁
- 简单描述：用户选好 `MiRemoteV 2ch` 后，音频页第三项「音频输出正常」永远不勾选，「重试音频设置」连续点击没有任何变化，无法继续也无法完成。
- 原始记录：用户现场反馈（微信），附 `SayAll first-use diagnostics`；`app_version=2.0.0`、`app_build=287`、`macos_version=27.2.0`。

## 现场证据

关键字段（其余字段与本次判定无关）：

```
step=audio
control_source=siri_remote
control_method=physical_remote
failure=audio.output_not_ready
audio_device_selected=true
audio_device_available=true
audio_output_ready=false
audio_status=audio.output.none_selected
remote_voice_button_press_count=0
```

- `audio_device_selected` 与 `audio_device_available` 同时为真：设备被识别、也被选中，**不是**驱动缺失或设备名不匹配。
- `audio_status=audio.output.none_selected`：虚拟音频输出从未配置成功过（`AudioOutput` 的 `status` 只有「配置时 UID 为空」和「初始值」两种来源会停在这个键上）。
- `remote_voice_button_press_count=0`：用户还没按过语音键。
- `recent_events` 里同一秒内多次 `retry step=audio`，状态没有任何变化。

## 根因

虚拟音频引擎有两条启动路径，都跟遥控器连接无关：

1. `startAudioSubsystem()` 在 App 启动时按**已保存的选择**无条件配置一次（不看控制来源）。
2. 按下语音键时的 `apple_remote_voice_start`。

全新安装没有保存的选择，第 1 条落在 `VirtualAudioSelectionRecoveryPolicy` 的 `.noHistory` 分支、以空 UID 调 `configureAsync`，于是得到 `AUDIO CONFIGURE skipped reason=no_selected_device`，`status` 停在 `audio.output.none_selected`。此后音频页选设备是**唯一**的配置入口，而它被下一段所述的门禁拦下——这就是本现场的序列。

反过来，**升级用户**带着上一版保存的选择，启动时第 1 条就会把引擎配好，`isReadyForTestTone` 为真，音频页「顺带」通过。这解释了为什么这个缺陷在测试机上长期不可见；等一次空闲释放（600 s）或任意一次 `applyAudioSettings` 把引擎释放掉，同一台机器又会卡住。

音频页与完成页的门禁按**控制方式**判断：`physical_remote` 一律要求输出持续 Ready（`OnboardingFlow.swift` 的 `.audio` / `.complete`），只有 `iphone_app` / `web_remote` 走按需分支（2026-08-18 手机与网页版那次修复）。Siri Remote 与小米遥控器同属 `physical_remote`，于是被套上了「持续 Ready」的要求，而在全新安装上它没有任何机会提前 Ready。

「重试音频设置」同样无效：它走 `applyAudioSettings`，第一道门是 `shouldKeepVirtualAudioActive`。该判定只认就绪的小米蓝牙桥、蓝牙语音、手机语音、测试音和 Mac 麦克风；Siri Remote 的连接不在其中，所以点击被静默忽略——这条路径连一行日志都不写，用户的 12 次重试在日志里不留痕迹。

小米遥控器或 Chromecast 在场时，桥保持 Ready 让引擎常驻，音频页会顺带通过。用户机器上只有一只 Siri Remote，就没有这条旁路。

## 日志指纹（同类现场照此定位）

`~/Library/Logs/RemoteMic/sayall.app-<day>-session-<id>.rmlog`（加密；开发构建同目录另有明文 `runtime.log`）里应当出现这组序列：

```
AUDIO STARTUP scheduled id=1
AUDIO DEVICES startup id=1 devices={...}
AUDIO SELECTION RECOVERY phase=skipped source=none reason=noHistory kind=unavailable supported_candidates=1 historical=false
AUDIO REBIND begin reason=startup state={...ready=false...}
AUDIO CONFIGURE skipped reason=no_selected_device queue=audio_output elapsed_ms=...
AUDIO REBIND finished reason=startup success=false status=audio.output.none_selected
```

判定：`reason=noHistory` + `skipped reason=no_selected_device` ⇒ 全新安装、启动没有可用选择；此后用户在音频页的每次点击都**不产生日志**（被 `shouldKeepVirtualAudioActive` 静默拦下），所以日志停在 `AUDIO REBIND finished` 之后不动，这就是「重试无效」的日志形态。

反向对照（修好后的期望）：用户在语音测试页按下语音键时出现

```
AUDIO CONFIGURE operation_id=<n> phase=completed result=ready reason=ready status_key=audio.output.current_format
AUDIO READY target={...}
```

若 `AUDIO CONFIGURE failed` 出现，`reason=` 会直接区分驱动缺失（`selected_device_unavailable`）、音量/静音自愈失败（`virtual_device_level_not_applied`）、输出单元打不开（`no_output_unit`）和绑定失败（`set_current_device`）；这三类都不是本 Bug。

## 修复

把「语音音频是否按需建立」的判断从控制方式扩展到**控制来源**：

- `OnboardingControlSource.usesOnDemandAudioOutput`：`siri_remote` 为真。
- 新增 `OnboardingAudioReadinessPolicy`：按 `controlMethod` + `controlSource` 统一裁决，`.audio` 与 `.complete` 两处门禁、诊断失败原因、视图侧状态卡与侧栏检查都改用它。
- 设备仍必须被选中且仍在受支持列表里：按需不等于放弃设备选择。
- 音频页说明文案新增 `onboarding.audio.on_demand_detail_remote`（中英），写清「按住遥控器语音键时会自动连接」，不再复用手机版的「手机开始语音时」。
- 诊断新增 `audio_gate=on_demand|ready_required`，下次同类现场可以直接看出走的是哪条门禁。

## 验证

- `swift test --filter OnboardingFlowTests`：111 项通过（新增 2 项）。`siriRemoteAudioGateFollowsTheOnDemandLifecycle` 覆盖音频页、完成页、恢复步骤、失败原因、设备消失仍阻塞；`onboardingViewPassesTheControlSourceIntoTheAudioGate` 锁定视图真的把来源传进门禁。
- 反向验证：把策略里的 `controlSource` 判断去掉后，新用例在音频页、完成页、恢复步骤和失败原因四处变红（5 个 issue）；把视图侧 `controlSource:` 参数去掉后，接线用例变红。恢复后复跑通过。

## 真机验收（2026-11-08）

- 环境：只有一只苹果遥控器的机器，没有同时连接小米遥控器或 Chromecast（这正是本缺陷的触发条件）。
- 结果：重新运行设置向导可以通过音频页，不再出现「语音输出还没有准备好」，后续流程走通。完成页本身要求真实语音会话与文字上屏（`OnboardingFlowPolicy.canContinue` 的 `.voiceTest` / `.complete`），因此走通即包含一次真实按键收音与文字上屏。
- 可观察差异：音频页第三项从「音频输出正常」未勾选，变成「语音开始时连接音频」已勾选——这是修复前后唯一应发生变化的地方；设备选择、小米/Chromecast 门禁与其余页面均未变。
- 本轮未复核：小米遥控器与 Chromecast 的真机对照、诊断摘要中 `audio_gate` 的实际取值、干净机器上的首次安装（需管理员认证）。
- 自动化边界不变：单元测试与离屏截图只证明门禁分支、接线与文案版式，真机结论以本节为准。
