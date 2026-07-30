# Automatic Application Focus Investigation

## Observations

- Environment: macOS 26.5.2 (25F84), Swift 6.3, Remote Mic 1.4.7 build 31, cmux 0.64.20.
- User reproduction: Claude focuses correctly; cmux focuses after switching from another app but not when cmux is already frontmost; Codex fails in both states.
- Remote Mic schedules cmux focus after 100 ms and requires the target PID to be frontmost before and during the two RPC calls.
- Remote Mic calls `surface.current` followed by `surface.focus` for cmux.
- cmux `surface.focus` calls `Workspace.focusPanel`, whose normal focus path preserves a foreign first responder such as the right sidebar.
- cmux's own explicit terminal-focus path additionally calls `ensureFocus(... respectForeignFirstResponder: false)`.
- The Codex/Claude Accessibility path currently searches only `AXTextArea` and `AXTextField` descendants of the focused/main window, stops after 1,500 elements, and requires a score of at least 80.
- The Mac returned to `loginwindow` before the live Accessibility probe, so the final investigation used the installed application bundles and the user's reproducible foreground/background boundary instead of claiming a live AX snapshot.
- Codex's installed web bundle shows that the main ProseMirror composer is rendered after the conversation surface, with `role="textbox"`, `aria-multiline="true"`, and an aria label/placeholder of `Message ChatGPT`.
- `Message ChatGPT` already satisfies the existing supporting semantic term `message` even without geometry, which rejects the theory that the Codex composer is excluded by the scorer.
- cmux's `GhosttyNSView` explicitly exposes the terminal as an editable `AXTextArea` with Accessibility help `Terminal content area`, so Remote Mic can request the actual AppKit first responder without using a state-dependent shortcut.

## Hypotheses

### H1: cmux preserves an in-app non-terminal first responder (ROOT HYPOTHESIS: cmux)

- Supports: the failure occurs only when cmux is already frontmost; cmux source explicitly distinguishes ordinary surface selection from forced terminal first-responder focus.
- Conflicts: `surface.focus` reports success even in the failing state, so RPC success alone cannot prove keyboard focus.
- Test: focus a cmux sidebar control, call `surface.focus`, and inspect whether the Accessibility focused element remains outside the terminal.

### H2: Codex exposes the composer under a role not collected by Remote Mic

- Supports: Claude works through the same scheduler and permission gate, while Codex is an independently implemented desktop UI.
- Conflicts: the installed Codex bundle explicitly renders the composer as an ARIA multiline textbox, which Chromium maps to an editable Accessibility text area.
- Test: enumerate the focused Codex window's Accessibility roles and attributes without changing production code.

### H3: Codex exposes an eligible text element but its semantics or geometry score stays below 80

- Supports: the scorer rejects `AXTextField` without recognized prompt/message terms and can reject small or upper-positioned candidates.
- Conflicts: the installed composer label is `Message ChatGPT`; the existing `message` term gives an `AXTextArea` a score of at least 120, above the threshold without geometry.
- Test: feed snapshots from the live Codex tree into the existing scorer and print candidate scores.

### H4: Codex focus runs before its window or composer is ready

- Supports: application activation and Electron/SwiftUI view updates can be asynchronous.
- Conflicts: the implementation retries for about 1.4 seconds and fails even when Codex was already frontmost.
- Test: invoke the existing composer focus synchronously against an already-stable Codex process; success would reject this hypothesis.

### H5: Codex's composer is eligible but is starved by the breadth-first 1,500-node traversal cap (ROOT HYPOTHESIS: Codex)

- Supports: the installed UI places the composer after the conversation surface; the current implementation enqueues the full transcript branch first and stops after 1,500 elements; long Codex tasks contain substantially more Accessibility descendants than Claude's compact composer surface.
- Conflicts: a live AX node count could not be collected after the machine locked, so the fix must also verify the actual focused element instead of trusting an AX setter return code.
- Test: model a long transcript ahead of a valid lower composer and compare the current breadth-first cap with a visible/lower-first traversal; the former omits the composer while the latter reaches it before transcript descendants.

## Experiments

1. **cmux source-path comparison — confirmed H1.** `surface.focus` ends at ordinary `Workspace.focusPanel`, while cmux's explicit terminal-focus controller immediately follows that selection with `ensureFocus(... respectForeignFirstResponder: false)`. This exactly explains why switching into cmux works through window activation but repeating the action while a sidebar owns first responder does not.
2. **Codex bundle semantics — rejected H2 and H3.** The production bundle renders the primary ProseMirror editor as a multiline ARIA textbox and passes `Message ChatGPT` as both aria label and placeholder. Feeding that semantic value through the current scorer is sufficient to pass the 80-point threshold without frame data.
3. **Timing boundary — rejected H4 as the primary cause.** The user reproduces the failure while Codex is already frontmost and stable, after the existing eight retries spanning roughly 1.4 seconds. Activation timing cannot explain that state.
4. **Traversal boundary — confirmed H5 at the code boundary.** The current breadth-first algorithm consumes transcript descendants in DOM/AX order and has an unconditional 1,500-element stop before the bottom composer branch. A lower/visible-first traversal reaches the composer branch before descending through the transcript, removing the failure condition without weakening field filtering.

## Root Cause

- cmux selects the correct terminal surface but deliberately preserves an in-app foreign first responder, so a successful RPC does not mean the terminal accepts keyboard input.
- Codex's valid composer sits behind a large conversation Accessibility subtree, while Remote Mic searches only ordinary `AXChildren` breadth-first with a hard 1,500-element cap and treats an AX setter return code as proof of focus.

## Fix

- After cmux selects its current terminal surface, focus the terminal's explicit `AXTextArea` and verify that it became the focused Accessibility element.
- Discover composers through navigation-order, visible, content, and ordinary child relationships; prioritize editable and lower visible elements; search all application windows; and only report success after the focused element is verified.

# cmux Frontmost Refocus Follow-up

## Observations

- User verification of 1.4.8: Claude and Codex focus correctly; cmux focuses when activated from another app but still fails when cmux is already frontmost.
- The current regression test only proves that `surface.current`, `surface.focus`, and a mocked terminal-focus callback are invoked. It does not verify the final application-level focused Accessibility element.
- In cmux 0.64.20, the live Accessibility tree exposes the terminal as an `AXTextArea` with help `Terminal content area`; focusing the Help popover moves the application-level focused element to a sidebar button while the terminal remains present in the same window.
- A live `surface.current` call identifies the expected terminal surface and `surface.focus` returns success, so surface discovery and RPC transport are not sufficient evidence of keyboard focus.
- `accessibilityElementIsFocused` currently returns true immediately when the candidate's own `AXFocused` attribute is true, before checking the application's `AXFocusedUIElement`.

## Hypotheses

### H6: cmux's terminal reports stale/local `AXFocused` while another control owns the application focus (ROOT HYPOTHESIS)

- Supports: the failure only occurs when cmux is already frontmost and an in-app control can retain first responder; the verifier trusts element-local focus before application-level focus.
- Conflicts: the Computer Use tree does not expose the raw terminal `AXFocused` attribute, only the final application-level focused element.
- Test: focus a sidebar control, run the existing terminal focus path, and require application-level `AXFocusedUIElement` equality instead of accepting element-local focus alone.

### H7: Remote Mic chooses a terminal from the wrong cmux window or pane

- Supports: the search examines every application window and ranks candidates by selected context and geometry rather than by the RPC surface identifier.
- Conflicts: the live reproduction currently has one cmux window and one terminal candidate, and `surface.current` returns that window's terminal.
- Test: inspect the live Accessibility candidates and compare their window/pane geometry with `surface.current`.

### H8: cmux asynchronously restores sidebar focus after Remote Mic focuses the terminal

- Supports: cmux mixes AppKit terminal views with SwiftUI sidebar/popover controls, so responder changes may be deferred.
- Conflicts: the current implementation does not sample the final focused element after a delay, so no evidence yet shows a post-focus reversal.
- Test: sample the application-level focused element immediately and again after 100-300 ms following the focus request.

### H9: `NSWorkspace.openApplication` does not provide a usable PID/completion when cmux is already active

- Supports: this path is only entered through the application-open completion.
- Conflicts: macOS normally returns the existing `NSRunningApplication`, and the background activation case uses the same opener successfully.
- Test: record the returned PID and compare it with the running cmux process in both foreground states.

## Experiments

1. **Live cmux focus boundary — confirmed the RPC/model mismatch.** With the workspace sidebar table as the application-level focused element, `surface.current` returned the expected terminal, pane, workspace, and window. Both `surface.focus` and `pane.focus` returned success, but those APIs only establish cmux's selected surface/pane model and are not a reliable contract for AppKit first responder ownership.
2. **cmux 0.64.20 source comparison — confirmed the foreign-responder behavior.** `surface.focus` calls `Workspace.focusPanel`, which reaches `TerminalPanel.focus()` and `focusTerminalSurface(respectForeignFirstResponder: true)`. cmux's own explicit `MainWindowFocusController.focusTerminal()` instead calls `ensureFocus(... respectForeignFirstResponder: false)` and verifies `isSurfaceViewFirstResponder()`; that force-focus operation is not exposed as a socket method.
3. **Candidate targeting — rejected H7 for the reproduction.** The live tree contains one cmux window and one `Terminal content area` candidate, and the RPC response resolves that same window/pane/surface.
4. **Verification-policy inspection — confirmed H6 at the Remote Mic boundary.** `accessibilityElementIsFocused` accepts the terminal element's local `AXFocused` value before consulting the application's `AXFocusedUIElement`. cmux can keep the terminal surface selected/focused in its model while a legitimate foreign responder owns keyboard focus, so the fallback can report success without attempting the force-focus setters or `AXPress`.

## Root Cause

The cmux fallback mistakes the terminal element's local surface-focus state for application keyboard focus, allowing a sidebar/TextBox first responder to remain active while Remote Mic reports success.

## Fix

- Require application-level `AXFocusedUIElement` equality when verifying cmux terminal focus, while preserving the existing local-or-application verification policy for Codex and Claude.
- Add a regression test for stale local focus with an application-level mismatch.
