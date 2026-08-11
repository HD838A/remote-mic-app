# Voice input destination readiness investigation

## Observations

- User-visible failure: after a mapped button launches or focuses a target app, the first two Fn voice attempts can do nothing and the third succeeds.
- Field logs show the app action returns before the target input is focused:

  ```text
  15:37:44 APP ACTION opened bundle=com.openai.codex
  15:37:47 APP FOCUS succeeded bundle=com.openai.codex

  15:37:49 APP ACTION opened bundle=com.openai.codex
  15:37:51 APP FOCUS succeeded bundle=com.openai.codex
  ```

- `KeyboardInjector.send` returns `true` immediately after submitting an asynchronous application activation/focus request.
- `VoiceFnTapSessionController` independently posts Fn after a fixed 150 ms delay.
- There is no handoff proving that the frontmost app owns a safe editable Accessibility element before Fn is posted.
- The Fn controller and mapper sources are identical between `v1.8.3` and `v1.8.8`; onboarding and wider Typeless exposure made the existing race easier to encounter.
- Existing controller tests cover tap pairing and audio pre-roll, but no test composes target activation latency with the first voice stream.

## Hypotheses

### H1: Fn is posted before asynchronous target focus completes (ROOT HYPOTHESIS)

- Supports: field logs show 2-3 seconds between app-open and focus-success while the Fn controller waits only 150 ms.
- Conflicts: none.
- Test: simulate a target that becomes editable after 3 seconds and assert that the first Fn-down is not attempted before readiness.

### H2: The third-attempt behavior is caused by a counter in the Fn session controller

- Supports: the user observes a repeatable third-attempt success.
- Conflicts: no three-attempt counter exists; the controller starts every idle session the same way.
- Test: inspect and exercise consecutive sessions with identical timing.

### H3: The regression is a Codex-specific Accessibility selector failure

- Supports: the reported target app is Codex and it has a specialized composer focus strategy.
- Conflicts: the missing readiness handoff also affects Claude, cmux, custom apps, recorded fields, focus shortcuts and arbitrary shortcuts.
- Test: use a target-agnostic delayed editable-focus fixture rather than a Codex-specific candidate.

### H4: Audio is lost before the virtual device becomes ready

- Supports: the symptom is missing dictated text.
- Conflicts: existing pre-roll tests prove audio is buffered until the fixed Fn start tap; the field event order points to focus completing after Fn.
- Test: record buffered samples while readiness is delayed and require complete replay after readiness.

## Experiment

The regression test in `CoreVoiceInputJourneyTests` uses the production Fn controller with a simulated target that is not ready during the fixed 150 ms start delay. The key setter records any Fn-down attempted before the target becomes editable.

Observed on the old implementation: the test failed exactly as predicted. At 150 ms it recorded an Fn-down attempt while the simulated target was not ready, then recorded `start_tap_failed`; advancing to the target's 3-second readiness point produced no later Fn tap because the session had already been disabled. This confirms H1 and rejects H2 as the primary cause.

## Root Cause

`KeyboardInjector.send` acknowledges submission of asynchronous target activation/focus, while `VoiceFnTapSessionController` independently posts Fn after 150 ms; without a readiness handoff, Fn can reach the old or non-editable focus before the intended input exists.

## Fix

Added a shared destination-readiness coordinator, connected every external configured-action entry point to it, delayed only Fn sessions that have a recent target-switch request, expanded pre-roll to five seconds, and cancelled unsafe, superseded, changed or timed-out destinations. The original delayed-target reproduction, controller lifecycle tests and RC001/RC003 simulated hardware journeys now pass.

---

# Onboarding upgrade HID-before-BLE investigation

## Observations

- 用户现场 `1.8.9 (101)` 升级首次启动截图中，同一页显示“正在查找小米遥控器”和“已收到实体按键”。
- 普通按键实际可用，重启 App 后 BLE 状态恢复。
- HID 回调直接更新 `lastRemoteButtonPress`，BLE 展示状态只在 `XiaomiBluetoothBridge` Ready 后为已连接，两条链路彼此独立。
- 本机没有现场版本和事故时段日志，因此不能确认首次进程为何没有及时建立 bridge。

## Hypotheses

### H1: HID 先恢复，但 Onboarding 没有把该证据用于 BLE 恢复（ROOT HYPOTHESIS）

- Supports: 旧页面按键订阅只更新 `observedRemoteButtons`，不调用重连。
- Test: 要求按键已观察、BLE 未连接、尚未恢复时策略返回 true，并检查按键回调接入恢复函数。

### H2: 手动“重新查找”已能创建缺失 bridge

- Conflicts: 旧 `reconnect()` 只遍历现有正式和 discovery bridge；两者均为空时无操作。
- Test: 检查 `reconnect()` 在空 bridge 状态调用 `startBluetoothConnections()`。

### H3: 每个后续实体按键都应重连

- Conflicts: 连续重连会造成连接抖动，并可能破坏已经进行的连接尝试。
- Test: 一次恢复请求后策略必须返回 false。

## Experiments

- 在旧实现先加入 Onboarding 定向回归；`swift test --filter OnboardingFlowTests` 因不存在 `shouldRequestRemoteReconnect` 而失败，生产按键接线和空 bridge 启动分支也不存在。
- 实现一次性策略、按键接线和空 bridge 启动后，同一套 6 项定向测试通过。

## Root Cause

已确认的停滞根因是 HID 与 BLE 状态独立，而收到 HID 按键后没有恢复 BLE；同时空 bridge 状态下的 `reconnect()` 是无操作，使瞬态只能等完整重启重新执行启动流程。首次升级进程为何进入空 bridge 状态仍需现场日志确认。

## Fix

- Onboarding 遥控器页只在“已收到实体按键、BLE 未连接、尚未请求恢复”时调用一次 `model.reconnect()`。
- 重新进入遥控器页时重置该一次性状态。
- `BridgeAppModel.reconnect()` 在运行时已启动且没有任何 bridge 时调用 `startBluetoothConnections()`，同时写入 `BLE RECONNECT starting_missing_bridges` 诊断日志。

## Validation

- `swift test --filter OnboardingFlowTests`：6 项通过。
- `swift test`：194 项、20 个 suite 全部通过。
- `scripts/test.sh`：42 项项目自检通过。
- `swift build -c release`、`scripts/build-app.sh`（含深度签名校验）与 `git diff --check`：通过。
- 自动化只覆盖策略和代码接线；真实 Sparkle 升级首次启动、CoreBluetooth 回调和 RC003 普通语音基线仍待验证。

---

# 普通物理语音 MIC_EXTEND 撤回与 Typeless 尾音反馈调查

## Observations

- 2026-08-11 的 RC001 普通长按会话在 10 秒、20 秒均记录 `ATVV MIC_EXTEND rejected` 与 `ATVV VOICE LEASE extend written=false`；另一个约 10.9 秒会话也在 10 秒处被拒绝。
- 同一批日志的两个会话都继续收到音频，松开后记录 `STREAM_STOP` 和 `AUDIO PLAYBACK drained pending_buffers=0`。
- 普通物理语音的 `startStreaming()` 只设置 `streaming = true`；只有主机主动 `MIC_OPEN` 成功才设置 `microphoneOpened = true`。
- `requestMicrophoneExtend()` 要求 `microphoneOpened && streaming`，所以普通物理会话不会真正写出续期命令。
- 用户反馈 Typeless 长按松手前最后 1–2 秒文字丢失，但尚未提供发生时间、App 版本、遥控器型号或对应日志，当前无法复现其现场。
- Typeless 停止路径先调用 `endSessionAfterDraining`，排空虚拟音频后才发送第二次 Fn 点按；排空最多等待 0.75 秒。
- 2026-08-09 已保存的 13 次 Fn 路线真机验收全部最终记录 `AUDIO PLAYBACK drained`，没有 `AUDIO PLAYBACK interrupted`，不能证明反馈现场发生了排空超时。
- 控制与音频使用不同 BLE 特征；收到 `STREAM_STOP` 后，`handleAudio()` 会静默忽略 0.3 秒内到达的音频数据。现有日志没有记录被该分支丢弃的数据量。

## Hypotheses

### H1: 定时 MIC_EXTEND 导致 Typeless 尾音丢失

- Supports: 两者都位于普通蓝牙语音会话生命周期中。
- Conflicts: 普通会话的命令实际未写出；反馈发生在松手边界而不是 10 秒定时边界；收到 `STREAM_STOP` 时租期计时器立即取消。
- Test: 对照现场会话的 `MIC_EXTEND`、`STREAM_STOP` 与音频排空时序。
- 结论：依据现有代码和日志基本排除。

### H2: Typeless 停止时 0.75 秒排空上限清除了剩余缓冲

- Supports: 超时路径会把待播放计数清零并结束 Fn 会话；如果积压超过 0.75 秒，尾音会被截断。
- Conflicts: 已保存的 Fn 真机基线全部正常排空，没有中断证据；现场尚无日志。
- Test: 获取反馈现场完整日志并检查停止时 `pending_buffers`、排空完成时间及是否出现 `AUDIO PLAYBACK interrupted`；用可控积压超过 0.75 秒的音频输出复现。
- 结论：候选原因，未确认。

### H3: STREAM_STOP 先于最后音频特征通知到达，0.3 秒保护窗静默丢弃尾包（当前优先假设）

- Supports: 控制和音频是不同 BLE 特征，通知顺序不能由单一特征保证；代码明确丢弃停止后 0.3 秒的数据且不记录日志；丢失最后一个音素或词组可能表现为识别文字少 1–2 秒。
- Conflicts: 代码窗只有 0.3 秒，尚不能直接解释完整 1–2 秒原始音频丢失；历史真机验收没有观察到尾音异常。
- Test: 增加只读诊断计数并用模拟硬件回放 `STREAM_STOP → 延迟音频通知`，再结合现场日志确认实际乱序和丢弃 sample 数；在用户明确授权修复前不修改生产行为。
- 结论：优先候选，未确认。

### H4: Typeless 自身在第二次 Fn 点按或识别提交时截断未完成结果

- Supports: 用户看到的是最终识别文字而不是原始 PCM；第三方 App 的提交时机可能放大很短的音频尾部延迟。
- Conflicts: Mac 端已经设计为排空后再发送停止点按；没有现场日志或对照 App 结果。
- Test: 同一长按会话同时在可保存原始输入结果的目标和 Typeless 中对照，并记录第二次 Fn 点按时间。
- 结论：环境候选，未确认。

## Experiment

- 只读核对生产日志与状态门禁，确认普通会话的 `MIC_EXTEND` 在写 BLE 前被拒绝；无需修改代码即可否定 H1。
- 未对 Typeless 候选原因做生产实验：缺少用户现场时间段和明确修复授权，不能把推测性改动当成修复。

## Root Cause

- 普通 `MIC_EXTEND` 候选方案失败的根因：物理按键会话只进入 `streaming`，没有主机主动开麦的 `microphoneOpened` 状态，因此续期请求被本地门禁拒绝，从未写入遥控器。
- Typeless 尾音反馈：当前未确认根因；现有证据基本排除与定时 `MIC_EXTEND` 相关，优先调查停止控制与尾部音频通知乱序，其次调查 0.75 秒排空上限。

## Fix

- 删除普通会话的 10 秒续期、180 秒强制关闭和 2 秒停止确认超时重连，以及只验证该候选实现的测试。
- 保留底层 `MIC_EXTEND` 协议能力，限定给未来已经成功主动 `MIC_OPEN` 的独立实验。
- 本轮不修改 Typeless 停止或音频处理逻辑；需要现场日志或可重复模拟后再进入正式修复。
- 撤回后验证：`swift test` 189 项、`scripts/test.sh` 42 项、`hardware-simulation/scripts/test-remote-mic.sh` 16 项全部通过；未执行新的真实 RC001/RC003 或 Typeless 真机验收。
