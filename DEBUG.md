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
