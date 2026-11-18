# Onboarding 切到非 Siri 来源后仍保持 Siri Remote 临时启用

- 时间：2026-11-19
- 状态：候选修复，自动化通过，真实 UI 与设备切换仍待现场验收
- 影响范围：完整私有构建（存在苹果遥控器与 Mac Remote 来源）的 Onboarding 控制来源切换
- 功能点：Onboarding 控制来源、Siri Remote 临时试用状态

## 错误证据

使用私有平台 `2.12.5` 预构件运行公开全量测试时，`offscreenOnboardingRegistersAndDrivesEveryInteractiveControl` 在 `Tests/RemoteMicTests/OnboardingFlowTests.swift:3940` 失败两次：

```text
Expectation failed: !remoteSource.settings.siriRemoteEnabled
remoteSource.settings.siriRemoteEnabled → true
```

复现顺序：

1. 进入控制来源页。
2. 选择苹果遥控器卡片，触发 Onboarding 临时启用 Siri Remote。
3. 再选择 iPhone / Apple Watch 或网页版来源。

预期：切换后不再保持 Siri Remote 临时启用。实际：`siriRemoteEnabled` 仍为 true。

公开 CI 只显示小米来源，不暴露苹果和 Mac Remote 来源，因此该路径未在公开测试中执行。

## 根因

`selectAppleRemote` 调用 `model.enableSiriRemoteForOnboarding()`，后者记录进入 Onboarding 前的启用状态并临时开启 Siri Remote。

`selectControlSource` 切到非 Siri 来源时只清空 `onboardingAppleRemoteGeneration` 和更新控制来源，没有结束本次临时试用。于是临时开启状态被保留到后续来源选择。

## 最小修复

- `BridgeAppModel` 新增 `endSiriRemoteOnboardingTrialIfNeeded()`：仅当 Onboarding 开始时 Siri Remote 原本关闭时，关闭本次临时试用；进入 Onboarding 前已启用的情况保持不变。
- `OnboardingView.selectControlSource` 在切换到非 Siri 来源时调用该方法。
- 新增 `switchingAwayFromSiriTrialRestoresInitialDisabledState`，同时覆盖原本关闭和原本启用两种状态。

## 验证

- 新增定向测试覆盖 `initiallyEnabled=false` 和 `initiallyEnabled=true`。
- 使用私有平台 `2.12.5` 预构件运行完整公开测试，原失败用例恢复通过。
- 公开构建、签名包和真实 Onboarding 视觉仍按发布流程验证。

## 验证边界

- 自动化使用离屏 Onboarding fixture，不证明真实窗口中的来源切换视觉、管理员授权或真实遥控器行为。
- 本修复不改变 Siri Remote 在设置页的独立启用入口；它只结束 Onboarding 自己创建的临时试用。
