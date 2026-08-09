# Post-fix Multi-Remote HID Report Routing Regression

- 时间：2026-08-09
- 状态：已修复
- 影响范围：两只遥控器同时连接；方向键和配置选择
- 功能点：按物理设备隔离 HID 报告
- 简单描述：初次修复后 HID 报告仍可能被错误设备监听器消费，引发按键无效和当前遥控器状态跳动。
- 原始记录：DEBUG.md，首次记录 5bceb5c

## 详细过程

## Observations

- The rebuilt development app launched at `16:44` from `dist/Remote Mic.app`; its binary is newer than the modified sources, so the reproduced behavior is not caused by an old process or stale bundle.
- After launch, one Up-button test at `16:54` still produced about eighteen `up / singleClick / customShortcut` records over roughly three seconds even though `ButtonAction.customShortcut.allowsRepeat` is false.
- Every `HIDRemoteMonitor` creates an `IOHIDManager` matching both Xiaomi HID devices. The manager input-report callback ignores its `sender` and forwards every matched-device report to that monitor.
- `hidutil` reports exactly two matching HID devices, one per connected remote. Two dedicated monitors are running, so an unfiltered report can be processed under both remote profiles and repeatedly change the selected profile.
- The connected remote also continues emitting physical reports while Up is held. Disabling the app-owned repeat timer therefore cannot by itself make a custom shortcut single-fire.

## Hypotheses

### H1: Each monitor processes reports from both physical remotes (ROOT HYPOTHESIS)

- Supports: each manager matches both devices; the report callback discards the sending device; two monitors are active; ordinary button actions also appear in duplicate pairs.
- Conflicts: none in the current callback implementation.
- Test: require the report sender fingerprint to equal the monitor's active-device fingerprint, then verify one physical press is routed through only one profile.

### H2: Hardware repeat reports bypass the `allowsRepeat` policy

- Supports: repeated custom-shortcut records continue after the app timer was disabled and span the duration of a held button.
- Conflicts: this alone does not explain profile switching or duplicate pairs from a short press.
- Test: apply the non-repeatable policy to rapid raw press cycles and verify a held custom shortcut fires once while arrow and volume actions remain repeatable.

### H3: The user is running a stale app bundle

- Supports: `/Applications/Remote Mic.app` and the development bundle have different versions.
- Conflicts: the active process path is the development bundle, and its launch and binary timestamps follow the source modification time.
- Test: compare the active executable path and launch timestamp with the source and bundle timestamps.

## Experiments

- H3 rejected: process inspection resolves the active executable to the newly built `dist/Remote Mic.app` launched at `16:44`.
- H1 confirmed by control-flow inspection: `IOHIDManagerRegisterInputReportCallback` supplies the reporting device as `sender`, but the callback does not use it; every monitor therefore accepts reports from every matching Xiaomi HID device.
- H2 confirmed by the post-launch runtime log: `customShortcut.allowsRepeat == false`, yet raw Up events continue for several seconds, proving they do not originate from `startRepeatIfNeeded`.
- A 5-second physical hold captured the exact lifecycle: initial press, a false release after `2714ms`, another press `449ms` later, and the final real release after the user let go. This rejects a fixed press-to-press cooldown and confirms that non-repeatable actions need release stabilization.

## Root Cause

The per-profile HID managers did not filter input reports by their active physical device, and non-repeatable actions were protected only from the app's synthetic repeat timer rather than rapid hardware report cycles.

## Fix

- Route each report only to the monitor whose active-device fingerprint matches the callback sender.
- Latch actions whose repeat policy is disabled after their first raw press. A release must remain stable for `600ms` before the latch clears, so the observed `449ms` false-release gap cannot retrigger the shortcut; repeatable navigation, volume, and delete actions remain unchanged.

## Validation

- 144 Swift tests passed, including report-to-device routing, raw custom-shortcut repeat suppression, and centered mapping-layout regressions.
- 42 low-level self tests passed.
- The Production app build, ad-hoc signature verification, process replacement, and launch verification passed; the active process is the newly built `dist/Remote Mic.app`.
- A continuous Up-button hold produced one custom-shortcut execution. The earlier two-execution sample included a confirmed physical release and second press, so it represents two real presses rather than a held-button repeat.
