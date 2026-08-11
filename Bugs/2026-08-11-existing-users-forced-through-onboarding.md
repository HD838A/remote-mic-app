# 已安装用户升级后被要求重新完成 Onboarding

- 时间：2026-08-11
- 状态：候选修复完成，等待真实升级验收
- 影响范围：macOS `1.8.8 (100)`、`1.8.9 (101)` 及其后续候选；从旧版本升级且没有 Onboarding 持久化状态的用户
- 功能点：首次使用设置向导、升级迁移、启动状态恢复
- 简单描述：Onboarding 加入后，旧版已安装用户升级首次启动会被当成全新用户，必须重新走完整设置向导。

## 复现

使用隔离 `UserDefaults` 写入旧版已经保存的 `launch.lastLaunchedBuild = 68`，不写入任何 `onboarding.*` 状态，再以 Build 102 启动。

旧实现的定向回归结果：

- `recordLaunchAndDetectCompletedUpdate` 正确返回更新已完成；
- `isOnboardingComplete` 仍为 `false`；
- `onboardingStep` 仍为 `.welcome`；
- 测试在这两个状态断言处稳定失败。

正常边界：真正全新安装仍需进入欢迎页；已经开始但未完成的向导需要恢复原步骤；用户主动点击“重新运行设置向导”后仍必须进入向导。

## 日志检查

该问题发生在蓝牙、音频和页面运行时启动之前，旧实现没有为 Onboarding 迁移写运行日志，因此 `runtime.log` 不包含可用于区分旧安装和全新安装的事件。定向 Swift Testing 输出记录了旧安装的错误最终状态，这也是本问题可重复的状态日志；没有把缺少业务日志解释为迁移成功。

## 代码检查与根因

`RemoteMicAppDelegate.applicationDidFinishLaunching` 会先调用 `AppSettings.recordLaunchAndDetectCompletedUpdate`。该方法已经读取旧 Build 和 Sparkle 的 `SUHasLaunchedBefore`，但只用它们返回“是否完成更新”，从未把可靠的旧安装证据迁移为 Onboarding 已完成。

`AppSettings` 随后从不存在的 `onboarding.completedVersion` 回退为 `0`、从不存在的 `onboarding.step` 回退为 `.welcome`，根视图因此显示完整向导。更新完成状态与 Onboarding 完成状态彼此独立，是本次问题的直接根因。

## 修复

1. 在覆盖 `launch.lastLaunchedBuild` 前执行一次版本化 Onboarding 迁移。
2. 当没有任何已保存的 Onboarding 状态，并且旧 Build 或 Sparkle 明确证明 App 曾经启动过时，写入当前 Onboarding 完成版本和 `.complete`。
3. 保存 `onboarding.migrationVersion`，让真正全新安装第一次启动后保持“需要完成向导”，避免第二次启动时因为已经有 `lastLaunchedBuild` 而被误判为旧安装。
4. 已保存的中途步骤和用户主动重新运行产生的状态优先于旧安装证据，不自动跳过。

## 验证

- 旧实现：`swift test --filter OnboardingFlowTests.existingInstallSkipsOnboardingWhileNewAndResumedFlowsRemainRequired` 失败，旧用户仍为未完成状态。
- 候选修复：同一测试通过，覆盖旧 Build、仅有 Sparkle 启动证据、真正全新安装二次启动、跨 Build 更新、中途续接和主动重新运行。

## 验证边界

自动化直接使用生产 `AppSettings` 和隔离偏好域验证持久化与迁移，不依赖 UI 或真实硬件。它不能替代从公开旧版本通过 Sparkle 更新后的真实安装目录、真实用户偏好和可见窗口验收；发布候选后仍需确认旧用户直接进入主面板且既有设置保留。
