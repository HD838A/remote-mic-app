# Onboarding 曾允许替代音频设备（历史方案，已撤销）

> 2026-08-18 产品验收确认 Onboarding 必须选择无线麦配套的 `MiRemoteV 2ch`。本文件记录的“允许 BlackHole 和其他设备”方案已被撤销；当前结论见 [`2026-08-18-onboarding-miremote-and-manual-text-gates.md`](2026-08-18-onboarding-miremote-and-manual-text-gates.md)。

- 时间：2026-08-11
- 状态：历史方案，已被 2026-08-18 修复取代
- 影响范围：macOS `1.8.8 (100)`、`1.8.9 (101)` 及后续未修复候选；使用 BlackHole 2ch 或其他音频回环设备的用户
- 功能点：首次使用设置向导、音频输出选择、语音输入准备
- 简单描述：BlackHole 2ch 已被用户选中且音频输出可用时，Onboarding 第五步仍要求改选 MiRemoteV 2ch，无法继续。

## 复现

旧页面源码回归测试截取 `OnboardingView.audioContent` 后确认：

- 页面没有遍历 `model.audioDevices`；
- 唯一主要操作是 `selectDoubaoAudioDevice()`；
- “已选择”状态由 `DoubaoAudioDevicePolicy.device(...)` 决定，而不是当前实际选择的可用设备。

定向测试 `audioStepOffersEveryAvailableOutputInsteadOfRequiringMiRemote` 在旧实现失败，证明 BlackHole 等设备没有选择入口。

## 日志检查

`BridgeAppModel.applyAudioSettings` 已经会记录所选 UID 的配置开始、成功结果和音频输出状态。该日志可显示 BlackHole 配置成功，但旧 Onboarding 仍会在视图层把 `compatibleMicrophoneSelected` 计算为 false；因此日志与页面结果的矛盾把范围缩小到 Onboarding 的重复门禁，而不是 Core Audio 配置失败。

## 根因

主设置页的音频选择支持全部 `audioDevices`，但 Onboarding 另写了一套只查找 MiRemoteV 2ch 的选择逻辑，并用它控制继续按钮。两条选择规则不一致，使正常可用的替代回环设备被错误拒绝。

## 修复

1. 音频页直接平铺显示当前检测到的全部输出设备，不使用下拉框。
2. 用户可选择 MiRemoteV 2ch、BlackHole 2ch 或其他已经安装的设备；选择后继续复用生产 `applyAudioSettings` 配置链路。
3. 门禁改为“所选 UID 仍存在于当前设备列表，并且生产音频输出已就绪”。
4. 下一步仍要求真实 PCM、完整停止和文字进入输入框，因此选错非回环设备不能完成整个 Onboarding。
5. 离屏截图夹具同时提供 MiRemoteV 2ch 与 BlackHole 2ch，用于检查平铺列表；不伪造音频引擎成功状态。

## 验证

- 旧实现：`swift test --filter OnboardingFlowTests.audioStepOffersEveryAvailableOutputInsteadOfRequiringMiRemote` 失败。
- 候选修复：`swift test --filter OnboardingFlowTests` 9 项通过，包含 BlackHole 选择策略、页面平铺接线、无 Picker 和既有流程门禁。

## 验证边界

自动化证明 BlackHole UID 能通过设备选择门禁，并且页面没有继续硬编码 MiRemoteV 选择按钮。离屏截图只能证明布局；真实 BlackHole 2ch、其他第三方回环设备、Core Audio 输出和最终文字上屏仍需按测试手册验收。
