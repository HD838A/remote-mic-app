# Held Remote Key Leaks Native Auto-repeat

- 时间：2026-08-09
- 状态：已修复
- 影响范围：方向键、删除键与自定义组合键；无线麦前台
- 功能点：长按、硬件重复报告和原始系统事件抑制
- 简单描述：长按遥控器时原始 HID 自动重复事件泄漏给 macOS，导致组合键重复执行或无线麦持续播放错误音。
- 原始记录：DEBUG.md，首次记录 b79fd0a

## 详细过程

## Observations

- With Remote Mic frontmost, holding the physical Up button produces a continuous macOS error sound even though Up is configured as the non-repeatable `Command + Return` custom shortcut.
- The latest matching runtime sample contains exactly one `HID BUTTON button=up trigger=singleClick action=customShortcut` record for the held interval, so the configured shortcut is not being executed repeatedly.
- Both Xiaomi HID devices are opened in monitored fallback mode because exclusive seize returns `-536870207`; native keyboard events therefore still enter the macOS event stream.
- `KeyboardEventSuppressor` arms one pending Down event and removes it after the first matching `keyDown`. Additional macOS auto-repeat `keyDown` events generated before the physical release have no pending match and pass to the frontmost app.

## Hypotheses

### H1: Only the first native key-down is suppressed; macOS auto-repeat leaks to Remote Mic (ROOT HYPOTHESIS)

- Supports: the action log fires once while the sound repeats; the device is not seized; the suppressor removes the sole Down token on its first match.
- Conflicts: none.
- Test: keep the native Down descriptor active until the matching HID release, then verify multiple `keyDown` events are suppressed while a post-release `keyDown` passes normally.

### H2: The custom shortcut injector still repeats

- Supports: each injected `Command + Return` could produce an error sound when Remote Mic is frontmost.
- Conflicts: the runtime action log contains one execution, `customShortcut.allowsRepeat` is false, and the raw-press latch regression passes.
- Test: compare action-log count with the audible interval; repeated injection requires repeated action records.

### H3: Both physical-remote monitors process the same report

- Supports: this caused an earlier duplicate-action regression.
- Conflicts: sender fingerprint filtering is active and the current held interval has one action record rather than paired records.
- Test: verify the reporting and active fingerprints match before report processing and retain the existing routing regression.

## Experiments

- H2 rejected by the latest runtime sample: one configured-action record cannot explain a continuous series of sounds from repeated shortcut injection.
- H3 rejected for this symptom: per-device report routing is covered by the current implementation and the observed action is not duplicated.
- H1 confirmed by event-filter control flow: the first native Down match removes its pending token, while all later repeat Downs arrive before any new `arm(.down)` call and are explicitly allowed through.

## Root Cause

The monitored HID fallback suppressed only the first native key-down event, allowing macOS-generated auto-repeat key-down events to reach the frontmost Remote Mic window and repeatedly play the system error sound.

## Fix

- Keep a reference count for each held native remote-key descriptor and suppress every matching key-down until all physical remotes holding that key have released it.
- Continue suppressing each final native key-up once, then immediately restore normal keyboard behavior for later physical-keyboard input.
- Preserve the synthetic-event marker bypass so actions intentionally injected by Remote Mic are never swallowed by its own event filter.

## Validation

- A focused regression verifies that repeated native Up key-down events remain suppressed throughout a hold, including when two remotes hold the same key, and that a new Up key-down passes after both releases.
- All 145 Swift tests and all 42 low-level self tests passed.
- The Production app built, signed, verified, and launched from `dist/Remote Mic.app`; final audible acceptance still requires one physical Up-button hold with Remote Mic frontmost.
