# Custom Shortcut Repeat and Sidebar Focus Regression

- 时间：2026-08-09
- 状态：已修复
- 影响范围：自定义组合键与设置窗口侧边栏
- 功能点：按键连发抑制、侧边栏焦点样式
- 简单描述：组合快捷键在按住期间重复注入，侧边栏第一项还出现异常焦点边框与顶部覆盖。
- 原始记录：DEBUG.md，首次记录 5bceb5c

## 详细过程

## Observations

- Both physical remote profiles have distinct persisted HID fingerprints and both map the Up button to the same `Command + Return` custom shortcut.
- During the reported test, one held Up-button interval produced dozens of `HID BUTTON ... action=customShortcut` records at roughly 100 ms intervals.
- `ButtonAction.allowsRepeat` currently permits every non-application, non-internal action to repeat, including arbitrary custom keyboard shortcuts.
- Codex Steer needs one `Command + Return`; repeated injection floods the target. When Remote Mic itself is frontmost, the same unsupported shortcut produces the system error sound repeatedly.
- The sidebar button keeps the standard macOS keyboard focus ring after clicking, and its first selected background occupies the title/header band.

## Hypotheses

### H1: Custom shortcuts incorrectly inherit directional-key auto-repeat (ROOT HYPOTHESIS)

- Supports: the runtime log shows repeated custom-shortcut execution every ~100 ms, matching `HIDRemoteMonitor.startRepeatIfNeeded`.
- Conflicts: none.
- Test: make `.customShortcut.allowsRepeat` false and verify application-independent arrow/volume/delete actions remain repeatable.

### H2: Two HID profiles share one physical fingerprint and alternate the selected card

- Supports: the user sees the selected remote state move while testing both remotes.
- Conflicts: persisted profiles contain two distinct HID fingerprints; logs do not prove one physical report is routed to two profile IDs.
- Test: inspect persisted profile fingerprints and add profile-tagged logging only if selection still alternates after removing shortcut repeat.

### H3: The blue sidebar border is the macOS focus effect, not the selected-state styling

- Supports: the source no longer draws a border; the screenshot shows the blue outline only around the currently focused first navigation button.
- Conflicts: none.
- Test: disable the visual focus effect while preserving the existing selected background.

## Experiments

- H1 confirmed: the log cadence matches the 100 ms repeat timer and continues for the duration of the held Up button.
- H2 rejected as the current root cause: RC001 and RC003 have distinct stored HID fingerprints and identical intentional shortcut mappings.
- H3 confirmed by source/screenshot comparison: no explicit stroke remains in `sidebarButton`; the outline is supplied by the system focus effect.

## Root Cause

Arbitrary custom keyboard shortcuts were treated as repeatable directional actions, causing a held Up button to inject `Command + Return` continuously, while the sidebar retained a system focus ring and placed its first selection inside the title band.

## Fix

- Make custom shortcuts non-repeatable while retaining repeat for real navigation, volume, and delete actions.
- Disable the sidebar button focus effect and reserve the title/header band above the first navigation item.
- Match the settings window's default and minimum size to the user-provided 2042 x 1544 Retina screenshot (approximately 1020 x 772 points).
- Do not implement the mapping-page layout redesign until the user confirms the generated mockup.
