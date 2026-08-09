# Frontmost Remote Mic Navigation Repeat Error Sound

- 时间：2026-08-09
- 状态：已修复
- 影响范围：无线麦位于前台时的方向键和删除键长按
- 功能点：前台导航连发抑制
- 简单描述：方向键和删除键在无线麦前台仍持续执行系统导航，页面无对应目标时不断播放错误提示音。
- 原始记录：DEBUG.md，首次记录 b79fd0a

## 详细过程

## Observations

- The Up button no longer produces a continuous error sound after native auto-repeat suppression was changed to remain active for the full hold.
- With Remote Mic frontmost, holding Left, Right, Down, or Back still produces a continuous system error sound; these buttons are configured as `arrowLeft`, `arrowRight`, `arrowDown`, and `deleteBackward`.
- The runtime log contains repeated `HID BUTTON` executions for held Left, Right, and Down reports, proving that hardware press/release cycles can re-enter the configured-action path for actions whose repeat policy remains enabled.
- `startRepeatIfNeeded` also starts a 100 ms navigation timer, or a 50 ms Back timer, after the first press. Its timer calls `KeyboardInjector.send` directly and therefore does not add another `HID BUTTON` log entry.
- Back has no native event descriptor, so its continuous sound cannot come from leaked native HID keyboard events; it must come from repeated configured delete injection.

## Hypotheses

### H1: App-owned repeat and repeatable raw HID cycles continuously inject focus-dependent navigation actions into Remote Mic (ROOT HYPOTHESIS)

- Supports: all four failing actions allow repeat; the timer is unconditionally started after a qualifying press; the log independently proves raw Left/Right/Down re-entry; Back has no native event path.
- Conflicts: none.
- Test: compare the four failing action types with the timer/raw-repeat guards and the Back native-event boundary.

### H2: Native macOS auto-repeat suppression still fails for every direction key

- Supports: Left, Right, and Down each expose native keyboard descriptors.
- Conflicts: Up uses the same suppression path and is fixed; Back exposes no native descriptor but still fails.
- Test: require a native descriptor for the symptom; Back falsifies this as the common root cause.

### H3: Two physical-device monitors still process the same held report

- Supports: duplicated routing previously caused repeated actions and remote-selection jumping.
- Conflicts: per-device sender fingerprint filtering is active; the current failure is action-specific and includes the App-owned timer path.
- Test: retain the existing fingerprint-routing regression and inspect whether the repeat occurs without a second monitor callback.

## Experiments

- H2 rejected as the shared cause: `RemoteButton.back.nativeEvent == nil`, yet holding Back still continuously sounds.
- H3 rejected as necessary for reproduction: one accepted press is sufficient for `startRepeatIfNeeded` to inject Delete every 50 ms while the key remains active.
- H1 confirmed by control-flow and runtime evidence: each failing action both permits App-owned repeat and, for observed direction keys, accepts repeated raw hardware press cycles; Up no longer fails because its custom shortcut is non-repeatable.

## Root Cause

Focus-dependent navigation and delete actions remain repeatable while Remote Mic itself is frontmost, so both the App timer and repeatable raw HID cycles continuously inject keys that the settings UI cannot handle and macOS responds with the system error sound.

## Fix

- Treat arrow and backward-delete actions as non-repeatable only while Remote Mic is the frontmost application.
- Apply the same effective-repeat policy to both raw HID press acceptance and App-owned repeat-timer startup.
- Preserve repeat in other applications and preserve system-volume repeat even when Remote Mic is frontmost.

## Validation

- The focused regression proves that arrow and delete actions do not repeat with `com.hd838a.RemoteMic` frontmost, still repeat with Codex frontmost, and system volume remains repeatable in Remote Mic.
- All 146 Swift tests and all 42 low-level self tests passed.
- The Production app built, received its development ad-hoc signature, passed bundle verification, and launched from `dist/Remote Mic.app` through the project run script.
- Actual inspection at `1020 x 772` confirmed that the sidebar separator reaches the title-bar top and the mapping page remains fully visible without layout regression.
- The connector layer now visibly begins at each calibrated physical-button hotspot. Static hotspots remain hidden; the active marker is rendered only from `activeButtons` or the live voice state and still requires a physical-button acceptance check.
