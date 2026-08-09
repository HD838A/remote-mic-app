# Multi-Remote Automatic HID Routing and RC003 Voice Regression

- 时间：2026-08-09
- 状态：已修复
- 影响范围：多只 RC001/RC003；普通按键、配置切换和语音
- 功能点：多遥控器自动路由
- 简单描述：多监听器会重复消费同一 HID 报告，配置显示为待绑定；共享语音改动还造成 RC003 普通语音回归。
- 原始记录：DEBUG.md，首次记录 5bceb5c

## 详细过程

## Observations

- Environment: macOS 26.5.2, two simultaneously connected Xiaomi remotes (RC001 and RC003), current development build based on commit `0da5b7e`.
- Both remote cards show an unbound state and neither remote's custom shortcuts execute.
- `BridgeAppModel.startHIDMonitors` starts dedicated monitors only for profiles that already have a `hidFingerprint`, then starts exactly one discovery monitor.
- One `HIDRemoteMonitor` accepts only one `activeDevice`, so the single discovery monitor cannot listen to a second unbound physical remote.
- An unbound discovery event resolves only through an existing fingerprint or `pendingHIDBindingProfileID`; without manual binding it returns `nil`, and the first button event is not executed.
- `AppSettings.registerBluetoothRemote` initializes an additional profile with default mappings instead of copying the currently selected remote's mappings.
- Runtime logs show RC003 is identified, reaches BLE ready, and produces repeated `STREAM_START -> AUDIO -> STREAM_STOP` sessions. There are no `rejected_busy`, `ignored_not_ready`, or `ignored_cancelled` records around those sessions, so the ATVV transport itself is not yet proven broken.

## Hypotheses

### H1: A single discovery monitor can occupy only the first unbound HID device (ROOT HYPOTHESIS)

- Supports: two profiles have no fingerprint; only one discovery monitor is created; `HIDRemoteMonitor.deviceDidMatch` rejects all later devices after `activeDevice` becomes non-nil.
- Conflicts: none in the current implementation.
- Test: statically trace monitor creation and device acceptance; a second unbound device has no possible monitor instance that can accept it.

### H2: Unbound button events are intentionally swallowed while waiting for manual profile selection

- Supports: `onButtonPressed` returns `nil` when no profile, saved fingerprint, or pending binding exists; a newly bound event returns `shouldPerformAction = false`.
- Conflicts: none; this exactly matches the missing shortcut symptom even for the first discovered device.
- Test: invoke the resolution policy with an unbound fingerprint and no pending profile; it produces no profile and cannot execute an action.

### H3: New profiles lose the previous remote's shortcuts because they start from defaults

- Supports: `registerBluetoothRemote` constructs new `RemoteDeviceMappings` from `defaultBindings` and empty shortcut dictionaries.
- Conflicts: migrated first-profile mappings are retained, so this affects additional remotes rather than the initial migration.
- Test: register a second Bluetooth identifier after configuring the first profile and compare both profiles' mappings.

### H4: RC003 voice transport works, but device/profile activation or downstream audio routing is not visible to the user

- Supports: logs show RC003 identification and valid ATVV stream/audio activity; the UI switches profiles from BLE voice activity independently of HID routing.
- Conflicts: current logs do not tag stream acceptance and first decoded audio with the remote model, so the user's RC003 press cannot be conclusively paired with downstream enqueue behavior.
- Test: add one start log tagged only with model/profile class and one first-audio routing log per session, then separately press RC001 and RC003.

## Experiments

- H1 confirmed by static control-flow experiment: with two unbound fingerprints, `startHIDMonitors` creates zero dedicated monitors plus one discovery monitor; after its first `deviceDidMatch`, `activeDevice == nil` is false for the second device. No second callback path can accept it.
- H2 confirmed by direct branch inspection: with `profileID == nil`, no stored fingerprint, and no pending manual binding, `resolvedProfileID` is nil; the event returns without running its configured action.
- H3 confirmed by constructor comparison: the second profile receives default bindings and empty shortcut dictionaries, regardless of the selected profile's current mappings.
- H4 remains under live verification. The production fix will add low-noise per-session device-model routing logs without changing ATVV protocol behavior.

## Root Cause

The multi-remote HID implementation still depended on a single-device manual-binding discovery path, so it could neither assign nor monitor two unbound physical remotes, and newly created Bluetooth profiles did not inherit the user's existing mappings.

## Fix

- Replace the manual binding dependency with deterministic automatic assignment of each newly discovered HID fingerprint to an unbound remote profile.
- Start another discovery monitor after each automatic assignment so every connected physical HID remote receives its own monitor.
- Execute the first button event after automatic assignment instead of consuming it.
- Initialize a newly discovered Bluetooth profile from the currently selected profile's full mappings, then persist independent copies.
- Remove binding UI/status from user-facing remote cards and compact the selector layout.
- Add device-model-tagged voice start/first-audio logs to distinguish RC001 and RC003 during real-device verification without changing audio protocol behavior.

## Validation

- 140 Swift tests passed, including additional-profile mapping copy, two automatic HID assignments, independent editing, and first-button execution coverage.
- 42 low-level self tests passed.
- Production app build and bundle verification passed; the local development app was launched from `dist/Remote Mic.app`.
- At the 1000 x 720 minimum window size, Connection, Mapping, Statistics, Permissions, and About were opened successfully. The sidebar is full-bleed, the two mapping-page remote cards fit without horizontal scrolling, and remote cards use two rows.
- RC003 live voice acceptance and downstream route remain pending one user-triggered voice session; the new log records model and route once per session without recording identifiers or audio content.
