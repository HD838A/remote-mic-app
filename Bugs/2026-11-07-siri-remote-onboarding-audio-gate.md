# 只有一只 Siri Remote 时 Onboarding 永久卡在音频页

- 时间：2026-11-07
- 状态：已修复（候选，等待真机复验与签名包验收）
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

Siri Remote 的语音音频是**按需**建立的：连接遥控器只登记资料与 HID（`BridgeAppModel.handleAppleRemoteConnection`），不启动虚拟音频引擎；引擎只在 `apple_remote_voice_start` 里建立。因此只要没按过语音键，`isReadyForTestTone`（要求引擎运行、播放器播放）必然为假。

但音频页与完成页的门禁按**控制方式**判断：`physical_remote` 一律要求输出持续 Ready（`OnboardingFlow.swift` 的 `.audio` / `.complete`），只有 `iphone_app` / `web_remote` 走按需分支（2026-08-18 手机与网页版那次修复）。Siri Remote 与小米遥控器同属 `physical_remote`，于是被套上了「持续 Ready」的要求，而它的输出永远不会提前 Ready。

「重试音频设置」同样无效：它走 `applyAudioSettings`，第一道门是 `shouldKeepVirtualAudioActive`。该判定只认就绪的小米蓝牙桥、蓝牙语音、手机语音、测试音和 Mac 麦克风；Siri Remote 的连接不在其中，所以重试被静默忽略，连一条 `AUDIO CONFIGURE` 日志都不会产生。

小米遥控器或 Chromecast 在场时，桥保持 Ready 让引擎常驻，音频页会顺带通过——这也是这个缺陷能在测试里长期不被发现的原因。用户机器上只有一只 Siri Remote，就没有这条旁路。

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
- 未覆盖：真实 Siri Remote 现场复验（只有一只 Siri Remote 的机器上重跑 Onboarding 直到完成页）、签名包、语音键按下后的真实音频与文字上屏。
