# cmux Frontmost Refocus Follow-up 2

- 时间：2026-07-31
- 状态：已修复
- 影响范围：macOS 1.4.9/1.4.10；cmux 前台窗口和侧边栏交互
- 功能点：cmux 终端强制聚焦与结果校验
- 简单描述：surface.focus 成功不等于终端成为 AppKit first responder，需要以应用级 Accessibility 焦点做最终校验。
- 原始记录：DEBUG.md，首次记录 dafe223

## 详细过程

## Observations

- User verification of 1.4.9: the cmux-already-frontmost case still fails.
- The exact user reproduction is clicking cmux's left workspace sidebar, then triggering the Remote Mic open-cmux action.
- 1.4.9 only tightened focus verification; after verification fails it still uses generic AX setters and performs no delayed retry.
- On cmux 0.64.20, a live `surface.focus` moved focus from the ordinary workspace table to `Terminal content area`, so the RPC is capable of focusing the terminal in that state.
- cmux deliberately preserves exactly two legitimate foreign first-responder categories during ordinary `surface.focus`: an `NSText` editor and a right-sidebar owner.
- cmux's default `Cmd+Shift+A` path toggles an active TextBox back to the terminal with `respectForeignFirstResponder: false`; its default `Cmd+Shift+E` path moves right-sidebar focus back through `MainWindowFocusController.focusTerminal()`.
- The current cmux configuration does not override either default shortcut.
- `NSWorkspace.openApplication` returned the existing cmux PID, rejecting the missing-process hypothesis. The graphical session locked before a delayed post-activation sample could be collected.

## Hypotheses

### H10: Tightened verification was mistaken for a force-focus fix (ROOT HYPOTHESIS)

- Supports: 1.4.9 changes only the success predicate; it never invokes cmux's two explicit foreign-responder escape paths.
- Conflicts: generic AX focus can work for some controls, but the user reproduces the state where it does not.
- Test: trace the failing TextBox/right-sidebar paths from `surface.focus` to their `respectForeignFirstResponder: true` early returns, then trace the official shortcuts to the force-focus calls.

### H11: The single 100 ms attempt loses an activation/focus reconciliation race

- Supports: cmux restores focus intent during AppKit window lifecycle callbacks, and Remote Mic performs no final delayed verification.
- Conflicts: the failure also has a deterministic source-level explanation for legitimate foreign responders.
- Test: retry after the official recovery shortcut and require terminal verification before reporting success.

### H12: `openApplication` returns no running process when cmux is already active

- Supports: that would skip all focus work.
- Conflicts: a live call returned PID 94253 with no error.
- Test: completed by printing the completion result while the existing cmux process was running.

## Experiments

1. **Ordinary sidebar focus — rejected a blanket RPC failure.** `surface.focus` changed the live application-level focused element from the workspace table to `Terminal content area`.
2. **Foreign-responder policy trace — confirmed H10.** `surface.focus` preserves `NSText` and right-sidebar responders, while `Cmd+Shift+A` and `Cmd+Shift+E` reach cmux-owned methods that pass `respectForeignFirstResponder: false`.
3. **Process completion — rejected H12.** `NSWorkspace.openApplication` returned the existing cmux process identifier without error.
4. **Exact left-sidebar production path — confirmed the retry fix.** With the live application-level focus on the left workspace `AXTable`, an opt-in integration test called `KeyboardInjector.send(.openCmux)` and verified that the final focus became the terminal `AXTextArea` with help `Terminal content area`.
5. **Neighboring live states — passed.** The same complete production action restored focus from cmux TextBox and right-sidebar states and remained focused when the terminal already owned focus.

## Root Cause

1.4.9 corrected a false-positive focus check but did not add a force-focus mechanism for the two responder classes that cmux intentionally preserves, so the original frontmost failure remained.

## Fix

- When terminal verification fails, use geometry plus AX role to select cmux's official recovery shortcut: main-panel TextBox fields use `Cmd+Shift+A`, confirmed right-sidebar controls use `Cmd+Shift+E`, and left-sidebar controls do not detour through the right sidebar.
- Retry the complete `surface.current` / `surface.focus` / terminal-verification sequence after a short delay and report success only after the terminal owns application focus.
- Keep an opt-in live integration test that calls the production open action and verifies the final application-level terminal focus; require it for cmux-focus releases.
