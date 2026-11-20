# Onboarding 语音测试松键后不结束，无法进入下一步

## 状态

代码修复、自检、Release 构建、CI、Onboarding 完成截图和真实设备验收已完成；PR #1137 已合入 `main`（`08e0dae5`）。

## 复现条件

1. 使用 `main` 提交 `27bb43ad` 的公开本地构建（2.0.8 Build 175），完成权限、遥控器连接和音频设备选择。
2. 进入首次设置向导的语音测试页，语音工具选择微信输入法，语音触发键使用默认 Fn。
3. 点一下测试输入框，按住小米遥控器语音键说话，然后松开。
4. 实际链路可以正常收音并把音频送到 `MiRemoteV 2ch`，但向导侧边第一项“语音键已按下并松开”不会完成，页面停在“已收到声音，正在等待文字出现”，无法进入下一步。

## 环境

- macOS 26.3，Apple Silicon
- SayAll 2.0.8 Build 175（本地公开构建，源码 `27bb43ad`）
- 小米蓝牙遥控器 2 Pro（RC003）
- 微信输入法 WeType，Fn 按住说话
- 虚拟麦克风 `MiRemoteV 2ch`

## 现场证据与日志结论

同一次尝试中，语音传输已经正常结束：

```text
05:30:01.850 ONBOARDING VOICE_ATTEMPT started attempt=15 ... window_key=true first_responder=true audio_selected=miremotev_2ch
05:30:04.543 ATVV STREAM STOP session=15 reason=remote_release
05:30:04.544 UI STATUS_ITEM ... from=streaming to=connected
05:30:04.576 VOICE KEY tail_release trace=15 completion=normal
```

但 Onboarding 语音尝试仍停留在 `recording`，从未进入等待文字阶段：

```text
05:30:12.099 ONBOARDING TRANSCRIPT_TARGET attempt=15 phase=recording mounted=true window_key=false first_responder=true ready=false loss_count=1
05:30:16.956 ONBOARDING TRANSCRIPT_TARGET attempt=15 phase=recording mounted=true window_key=true first_responder=true ready=true loss_count=1
```

同一问题在 Build 175 上连续出现于 attempt 3–15。侧边检查项 `onboarding.side.voice_key` 依赖 `voiceSessionStarted && voiceSessionEnded`，因此始终不完成；`endVoiceAttempt()` 未执行也不会启动 3 秒文字等待截止时间。

## 代码根因

`Sources/RemoteMic/BridgeAppModel.swift` 的 `endVoiceSessionIfNeeded` 在结束会话时先发布 `isStreaming = false`，随后清空来源：

```swift
isStreaming = false
activeVoiceSource = nil
```

`Sources/RemoteMic/OnboardingView.swift` 的 `.onReceive(model.$isStreaming)` 在判断 `isStreaming` 之前先执行：

```swift
guard selectedControlAcceptsVoice(model.activeVoiceSource) else { return }
```

松键通知到达视图时 `activeVoiceSource` 已被清空，guard 直接返回，`endVoiceAttempt()` 永远不会执行。

该 guard 由提交 `1d7b6735 fix: support iPhone and web onboarding paths`（2026-08-17）引入，存在于 `v1.9.1` 到 `v2.0.8` 的标签中，包括官方 `v1.9.21`。这不是本地构建、ad-hoc 签名或音频驱动造成的。

## 修复方案

- 新增纯策略 `OnboardingVoiceStreamPolicy`，由它决定 `isStreaming` 变化对应的动作。
- `isStreaming == true` 时仍要求当前来源被接受，保持原有连接和来源隔离。
- `isStreaming == false` 时只要求本次尝试已开始，不再依赖已被清空的 `activeVoiceSource`，确保 `endVoiceAttempt()` 执行。
- 视图只负责把策略结果映射到 `recordRemoteVoiceButtonPress()`、`beginVoiceAttempt(...)`、`endVoiceAttempt()` 或忽略。
- 新增针对松键、开始、未开始和普通遥控器观察的回归测试。

## 验证

- `./scripts/test.sh`：通过，`RESULT passed=50 failed=0`；新增的松键结束和开始来源检查均通过，应用 `swift build --disable-keychain` 成功。
- `xcrun swift test --disable-keychain --filter OnboardingFlowTests`：本地未运行成功。当前机器只安装 Command Line Tools，缺少完整 XCTest 和 Testing/Foundation cross-import overlay；已补充 `OnboardingFlowTests` 回归用例，由 CI 执行。
- Release 构建：`SAYALL_PRIVATE_PLATFORM_MODE=public ./scripts/build-app.sh` 通过（`Build complete! (163.34s)`，`SANITIZE RELEASE PATHS result=passed`，ad-hoc 签名）。
- CI：Public Swift tests and dual-architecture build、Apple Silicon、Intel Ventura、Repository governance 全部通过。运行：https://github.com/HD838A/remote-mic-app/actions/runs/44472820670
- 真实设备验收（Build 176，行为修复版本）：语音尝试 attempt 1 通过；`audio_received/scheduled/played=20400`，`interrupted/pending=0`，`focus_loss_count=0`，`transcript_wait_ms=728`；随后 `controls` 和 `complete` 步骤通过，Onboarding 已完成。
- 验收边界：Build 176 使用与 PR 相同的行为修复的最小补丁；PR 的 `OnboardingVoiceStreamPolicy` 重构由 CI 和自检覆盖，未再单独用 PR 构建重跑真机。
- 自动化边界：自检和单元测试覆盖状态转换策略；真实遥控器弱信号、微信输入法上屏时机和完整旅程仍需真机验收。

## 独立复验与合入（2026-11-21）

- build 413 使用等价修复在 RC003 上连续完成两次会话。两次结束事件都记录
  `ONBOARDING VOICE_STREAM transition streaming=false ... accepts_source=false`，
  随后执行 `stream_end_received`；这直接证明旧 guard 会丢弃结束事件。
- 第二次会话记录 `ONBOARDING EVENT kind=passed step=voiceTest`。音频 46080 样本
  全部调度并播放，`audio_interrupted_samples=0`，`audio_pending_samples=0`，
  `audio_enqueue_failures=0`；首样本 154 ms，松键到终态 459 ms，焦点丢失 0 次。
- 合并后本地 `swift test --disable-keychain --filter 'OnboardingFlowTests|LocalizationTests'`：
  138 项通过；`scripts/test.sh` 50 项自检通过；`swift build --disable-keychain` 通过。
- PR #1137 已按普通 Merge 合入 `main`，合并提交 `08e0dae5`。
- 连接页 UI 改动不属于本修复，已由 #1161 单独合入。

## 关联

- Issue #602 报告了“voiceTest 恒报 external_tool_no_commit，但实际链路可用”，其诊断中 `voice_ended=true`，与本问题“松键后尝试从未结束”不同；本修复不改变外部工具文字提交的观察逻辑。
- 2026-11-19 扫描仓库 Open PR，未发现覆盖同一根因的重复修复。
