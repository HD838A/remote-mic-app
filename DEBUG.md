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

# cmux Frontmost Refocus Follow-up 2

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

# iOS 手机语音键无响应

## Observations

- 用户真机反馈：iOS App 已连接，普通遥控按键可用；按住麦克风时 iPhone 出现系统收音指示，但 Mac 与豆包没有响应。
- 用户真机反馈：麦克风键只有松开时能感到震动；期望按下、松开各震动一次。确定键也必须在按下时震动。
- `RemoteControlScreen.setVoiceActive(_:)` 已分别请求按下与松开震动，但 `VoiceButton` 使用 `DragGesture.onChanged` 作为按下入口，不能提供与按钮按压状态同等明确的触摸落下语义。
- 两个确定入口均通过普通 `Button` action 调用 `perform(.confirm)`；SwiftUI 的 Button action 在成功抬起后执行，所以现有确定键震动发生在松手时。
- iOS 录音成功后会持续发送 `voiceStart`、16 kHz 单声道 PCM 和 `voiceStop`；Mac 端已将收到的 PCM 接到现有虚拟音频输出。
- Mac 的手机语音开始路径会调用 `updateVoiceFunctionKeyState(streaming: true)`，但该方法只更新 `VoiceFunctionKeyLatch`、状态文案和日志，没有向系统投递 Fn/Globe 按下事件。
- 实体遥控器可用是因为 RC003 自身会产生 F5 硬件事件，并由 `RemoteVoiceFunctionMapper` 映射为 Fn/Globe；手机不存在这条硬件事件来源。
- 工作区原始状态干净，本次调查前没有未提交修改。

## Hypotheses

### H1: 手机语音路径没有真正产生 Fn/Globe 按键事件（ROOT HYPOTHESIS）

- Supports: 手机语音开始只改变锁存状态并写 `VOICE FN HARDWARE` 日志；代码调用图中没有 CGEvent/IOHID 按下或释放操作。实体遥控器则有独立的 F5 硬件事件来源。
- Conflicts: 无。
- Test: 检查手机语音调用图是否能到达任何系统按键投递 API，并用当前 SDK 构造 Fn 按下事件验证所需 key code 与 modifier flag 可表达。

### H2: Mac 在 `voiceStart` 异步确认期间丢弃了全部音频

- Supports: `PhoneRemoteServer.Client` 在 `isVoiceStarting` 阶段会忽略音频帧。
- Conflicts: 确认窗口只覆盖开始时的少量帧；持续按住后 `isVoiceActive` 会变为 true，后续帧应继续进入输出，无法解释豆包始终没有触发。
- Test: 为开始阶段缓存一帧或记录首帧到达状态，观察持续按住时是否仍无输出。

### H3: iOS 音频转换器没有产生 PCM

- Supports: iPhone 的系统收音指示只证明录音会话已激活，不直接证明转换回调有输出。
- Conflicts: 转换器、tap 和发送路径完整；当前症状首先表现为豆包没有被 Fn 唤起，且没有 iOS 端麦克风错误提示。
- Test: 记录非零 PCM 帧计数，确认 tap 与转换回调是否持续运行。

### H4: Mac 虚拟音频输出未就绪

- Supports: `startPhoneVoice()` 在输出未就绪时会拒绝手机语音。
- Conflicts: 拒绝时 Mac 会回传通用可理解错误，iOS 会结束语音并显示处理提示；用户描述是保持收音但 Mac/豆包无响应。
- Test: 检查语音开始返回值与音频输出就绪状态。

## Experiments

### E1: 验证 H1

- 调用图检查结果：`BridgeAppModel.updateVoiceFunctionKeyState` 没有调用 `KeyboardInjector`、`CGEvent.post` 或 IOHID 投递接口，H1 的缺失路径成立。
- SDK 原型结果：使用 `kVK_Function` 可构造 key code 63 的键盘事件，并可携带 `maskSecondaryFn`；事件字段可被 CoreGraphics 正确表达。
- 结论：H1 confirmed。无需修改网络协议或音频格式即可先修复系统语音键触发断点。

### E2: 验证确定键震动时机

- `Button` action 是现有唯一震动入口，且只在成功抬起时运行。
- 结论：确定键按下无震动由当前事件绑定直接导致。

### E3: 验证麦克风键震动时机

- 按下震动依赖 `DragGesture.onChanged`，松开震动依赖 `onEnded`；两者不是统一的按钮按压状态来源。
- 结论：改用明确的按压状态回调，并保持按下/松开分别触发，可消除按下反馈不稳定。

## Root Cause

手机语音会话只在 Mac 内部记录了 Fn 按下/释放状态，却没有真正投递系统 Fn/Globe 事件；同时 iOS 确定键把震动绑定在抬起 action，麦克风键的按下震动依赖不够明确的拖动变化入口。

## Fix

- 已实施：Mac 手机语音开始/停止时真正投递一次 Fn 按下/释放，并在失败时回滚锁存状态；实体遥控器继续使用自身硬件映射，不产生重复的软件事件。
- 已实施：iOS 麦克风键使用明确的按下/抬起状态回调；两个确定入口在按下时震动、抬起时发送命令。
- 不修改任何布局、网络协议、配对逻辑或音频编码格式。
- 验证：85 项 Swift Testing、36 项 Self Test、macOS Release 构建和 iOS 模拟器构建均通过；模拟器独立 touch down/up 验证麦克风按钮值按“正在准备 → 未录音”变化，且无障碍树只有一个麦克风按钮。
- 待真机验收：iPhone 的实际震动强度与 Mac 上豆包的真实唤起/收音，需要安装包含本修复的新包后确认。

# iOS 重启后仍无法重新连接 Mac

## Observations

- 用户真机反馈：iOS 与 Mac 最初连接成功；一段时间后连接失败，重启 iOS App 仍不能恢复；重启 Mac App 并再次点击“连接手机”后立即恢复。
- 当前环境中的历史运行日志包含手机监听启动和授权成功记录，没有出现 `listener_failed`；本次用户现场无法在开发机上原样复现，因此以用户步骤和现有状态机边界作为最小复现条件。
- `PhoneRemoteServer.accept(_:)` 在已有客户端时，只允许 `canBeReplaced == true` 的客户端被替换；已授权客户端的 `canBeReplaced` 永远为 `false`，所以新的 TCP 连接会在协议握手前被直接取消。
- 旧客户端只有在 Network.framework 报告 `.failed` / `.cancelled` 或接收回调返回完成/错误时才从 `clients` 移除；服务端没有心跳，也没有允许新的已认证会话接管旧会话的路径。
- 重启 iOS 会创建新的连接，但不会改变 Mac 内存中的旧 `clients`；重启 Mac 会执行 `PhoneRemoteServer.stop()` 并清空全部客户端，和用户观察完全一致。
- iOS App 重启会重新创建 `NWBrowser`，因此“已有 Bonjour 结果没有再次触发”不能解释重启 iOS 后仍持续失败。

## Hypotheses

### H1: Mac 中残留的已授权旧客户端阻塞了所有新连接（ROOT HYPOTHESIS）

- Supports: 新连接在 `accept(_:)` 中会被已授权客户端无条件拒绝；重启 iOS 不清理 Mac 状态，重启 Mac 会清空客户端；三者与用户步骤逐项对应。
- Conflicts: 没有现场 Network.framework 状态日志能证明旧 TCP 连接当时仍被系统视为活跃。
- Test: 沿新连接接入路径验证“旧客户端已授权”时是否存在任何继续握手或认证后接管的分支。

### H2: Mac 的 `NWListener` 失败后仍被非空引用阻止重启

- Supports: `.failed` 当前只写日志，没有清空 `listener`；同一 App 生命周期内再次调用 `startOnQueue()` 会被 `listener != nil` 拦截。
- Conflicts: 现有手机连接日志没有 `listener_failed`；用户重启 iOS 时表现为连接失败，而不是明确的服务完全消失。
- Test: 检查现场日志是否存在 `listener_failed`，并确认失败后 Bonjour 服务是否消失。

### H3: iOS 断线后没有重新使用已有 Bonjour 服务结果

- Supports: `handleFailure` 会清空 `pendingEndpoint`，浏览结果不变化时当前实例不会自动重连。
- Conflicts: 用户已重启 iOS App，新的 `NWBrowser` 会重新收到服务结果；仍需重启 Mac 才恢复。
- Test: 新建 iOS 连接对象并确认首次浏览结果会调用 `connect(to:)`。

## Experiments

### E1: 验证 H1

- 接入路径检查结果：当旧客户端 `isApproved == true` 时，`canBeReplaced` 为 `false`，`accept(_:)` 立即取消新连接；后续身份校验、长期信任和授权逻辑均不会执行。
- 生命周期检查结果：iOS 重启只产生新的客户端；Mac 重启会调用 `stop()`，清空 `clients` 并取消旧客户端。
- 结论：H1 confirmed。修复点应位于 Mac 客户端接纳策略，不能要求用户重启任一 App，也不能让未授权的新连接直接踢掉正常连接。

### E2: 验证 H2

- 历史运行日志中没有手机监听失败记录，当前证据不足以把监听器失败列为本次根因。
- 结论：H2 inconclusive，本次不扩大范围修改监听器生命周期。

### E3: 验证 H3

- iOS `RemoteMacConnection` 初始化后会创建全新的浏览器；浏览器 ready 且收到服务结果时会调用 `connect(to:)`。
- 结论：H3 rejected，无法解释重启 iOS 后仍被持续拒绝。

## Root Cause

Mac 服务端把首个已授权客户端视为永远不可替换；当底层连接已经失效但 Network.framework 尚未关闭旧对象时，所有新 iOS 连接都会在认证前被取消，只有重启 Mac 清空内存会话后才能恢复。

## Fix

- 保留正常的已授权连接，同时允许新的待认证连接完成握手。
- 新连接只有在完成长期信任校验或用户授权、并成功发送 ready 后，才取消并替换旧客户端。
- 多个未授权连接仍互相替换，避免待认证客户端无限累积；未授权连接不能直接中断正常客户端。
- 验证：会话替换策略回归测试通过；Mac 86 项 Swift Testing、36 项 Self Test、macOS Release 构建、iOS Debug/Release 模拟器构建全部通过。

# iOS 从后台返回后不自动重连

## Observations

- 用户真机反馈：iOS App 与 Mac 已连接，退到后台再返回后不会自动连接；点击右上角 Mac 按钮后可立即恢复。
- `RemoteControlScreen` 只在首次 `.task` 中调用 `connection.start()`，没有监听 `scenePhase`。
- `RemoteMacConnection.start()` 在 `browser != nil` 时直接返回；连接失败会清空 `connection`，但不会清空仍存在的 `browser`。
- 右上角按钮调用 `restartDiscovery()`，会取消并清空连接、浏览器和会话状态，再重新开始发现。

## Hypotheses

### H1: App 返回前台时缺少生命周期重连入口（ROOT HYPOTHESIS）

- Supports: 页面没有 `scenePhase` 监听；用户必须手动调用与重新发现等价的右上角按钮。
- Conflicts: 如果底层连接在后台始终保持健康，则不应重启正常连接。
- Test: 仅在 App 重新进入 active 且当前未连接时调用 `restartDiscovery()`，验证是否能恢复且不打断健康连接。

### H2: 普通 `start()` 可以在前台恢复现有浏览器

- Supports: `start()` 是页面首次启动入口。
- Conflicts: `browser != nil` 时它明确提前返回，无法重置后台留下的浏览器或连接状态。
- Test: 在 `connection == nil && browser != nil` 的状态调用 `start()`，确认不会创建新浏览器。

### H3: Mac 服务端必须重新点击“连接手机”才能恢复

- Supports: 历史上曾存在 Mac 旧会话阻塞新客户端的问题。
- Conflicts: 本次点击 iOS 右上角按钮即可恢复，说明 Mac 监听和接纳流程仍可用。
- Test: 保持 Mac 端不操作，仅触发 iOS 完整重新发现；成功即排除此假设。

## Experiments

- E1：加入前台 active 状态的条件重新发现入口，并临时记录 `restartDiscovery()` 调用。模拟器进入主屏幕后重新打开 App，日志确认同一进程调用了完整重新发现。
- E2：条件限定为 `!connection.isConnected`，正常连接状态不会被前台切换打断；首次 `.task` 仍负责冷启动，不依赖场景变化。
- E3：`start()` 在旧 `browser` 仍存在时直接返回，确认普通启动入口不能修复此状态；H2 rejected。
- E4：实验期间未操作 Mac 端，iOS 端前台恢复即可触发与右上角按钮相同的重新发现路径；H3 rejected。

## Root Cause

iOS 页面没有监听从后台返回 active 的生命周期；后台期间连接失效后，仍存在的浏览器对象会让普通 `start()` 提前返回，因此只有手动点击右上角执行完整重新发现才能恢复。

## Fix

- 监听 `scenePhase`，App 回到 active 且当前未连接时调用现有 `restartDiscovery()`。
- 已连接时不重启，避免打断健康会话以及系统权限弹窗返回后的正常连接。
- 不修改发现协议、配对授权、长期信任或 Mac 服务端逻辑。
- 验证：模拟器同进程后台/前台实验确认重新发现被触发；使用截图中的真实自定义标题完成视觉复核，`Command-Tab` 完整显示，菜单与同排按钮标题基线一致；86 项 Swift Testing、36 项 Self Test、iOS Debug/Release 模拟器构建全部通过。

# iOS 0.8.3 无法连接 Mac App

## Observations

- 用户真机反馈：升级到 iOS `0.8.3` 后无法成功连接 Mac App。
- 当前 `/Applications/Remote Mic.app` 的实际版本是 `1.5.1 (39)`，而不是仓库最新发布的 `1.6.7`。
- Mac `1.5.1` 对应的仓库标签中尚不存在 `PhoneRemoteServer.swift`；手机伴侣服务是在后续 `1.6.x` 才加入。
- 当前没有 Mac App 进程，也没有 Remote Mic 的 TCP 监听端口，因此当前环境没有发布 `_remotemic._tcp` Bonjour 服务。
- `0.8.2 → 0.8.3` 的 iOS 握手只新增了 Mac 发往 iOS 的可选 `appVersion` 字段；JSON 解码对缺失可选字段兼容，未改变 iOS 发出的 `hello`、密钥协商或长期身份格式。
- 历史 `PHONE REMOTE` 日志来自共享日志目录中的开发/测试运行，不能证明当前安装的 `1.5.1` 正式 App 支持手机连接。
- 用户补充：问题 Mac 的授权码弹窗最初没有及时出现，稍后弹出并允许连接后，iOS 已成功连接。
- 用户补充：连接成功后，iOS 显示“Mac 暂时无法执行这个操作，请稍后重试”。该文案只会在 iOS 收到 Mac 的安全消息 `type == "error"` 后出现，不是发现、握手或授权失败文案。
- Mac `1.6.7` 不会在纯连接成功后主动发送 `error`；只有遥控按键执行失败或手机语音启动失败会发送该消息。
- iOS 当前丢弃 Mac 返回的具体 `detail`，把辅助功能/按键失败和语音输出失败统一显示为同一条通用文案，因此仅凭界面无法判断是哪一种操作失败。

## Hypotheses

### H1: 当前启动或准备启动的是不支持手机伴侣协议的 Mac 1.5.1

- Supports: 已安装正式 App 明确为 `1.5.1`；对应标签没有手机服务端源码；当前也没有 Bonjour 服务或监听端口。
- Conflicts: 用户此前曾成功连接，说明当时可能运行的是仓库构建版、DMG 中的新 App 或其他路径下的副本。
- Test: 枚举所有 `com.hd838a.RemoteMic` App 副本，并检查当前安装二进制是否包含 `_remotemic._tcp` 与手机服务实现。

### H2: Mac 服务没有运行或没有点击“连接手机”

- Supports: 当前没有 Mac App 进程、监听端口或 Bonjour 广播；产品设计要求每次启动后由用户主动点击“连接手机”。
- Conflicts: 用户报告的是新版回归，可能已经完成了这一步；当前开发机状态也未必就是用户报告发生时的现场状态。
- Test: 使用支持手机协议的 Mac 版本启动服务，确认 `_remotemic._tcp` 出现后 iOS 是否能进入握手。

### H3: iOS 0.8.3 的 `scenePhase` 自动重连取消了正在进行的授权连接（ROOT HYPOTHESIS：授权弹窗延迟）

- Supports: 这是 `0.8.2 → 0.8.3` 唯一直接改变发现生命周期的逻辑；`!isConnected` 同时覆盖 `.searching`、`.connecting` 和 `.awaitingApproval`，而 `restartDiscovery()` 会取消当前连接；Mac 在连接关闭时会取消尚未完成的手机授权请求。该时序能解释弹窗先不出现、后来第二次连接稳定后才出现。
- Conflicts: 本地冷启动约 1 秒即可稳定显示双方相同校验码，尚未直接捕捉到第一次授权请求被取消。
- Test: 临时记录每次 `scenePhase` 变为 active 时的连接状态及是否调用 `restartDiscovery()`，验证健康的 `.connecting` 或 `.awaitingApproval` 是否被取消；实验日志不超过 5 行并在记录结果后撤销。

### H4: 已信任设备升级后的自动授权或旧会话接管异常

- Supports: 早期 Mac 手机服务端曾存在已授权旧客户端阻塞新连接的问题；升级 iOS 会中断旧进程并建立新 TCP 连接。本地全新身份可以稳定到达授权弹窗，而用户现场更可能走已有信任记录的自动授权路径。
- Conflicts: Mac `1.6.7` 已加入“新连接认证成功后接管旧会话”的修复和单元测试，且用户后来看到授权弹窗并成功连接，说明本次连接最终可以通过授权并进入 ready。
- Test: 获取问题 Mac 的 `PHONE REMOTE` 日志和 iPhone 当前状态，确认是否出现 `trusted_identity_approved`、授权弹窗以及 ready 之后的连接关闭。

### H5: 连接后的通用错误来自首次遥控按键执行失败（ROOT HYPOTHESIS：连接后 operation error）

- Supports: Mac `1.6.7` 的按键失败会发送 `detail = "Mac 需要辅助功能权限，或该按键当前不可用。"`；新安装或重签名的 Mac App 可能尚未获得辅助功能权限；iOS 会把该 detail 覆盖成用户看到的通用文案。
- Conflicts: 用户尚未说明错误出现前是否点击了普通按键或确定键；若完全没有操作，Mac 按当前代码不应发送此 error。
- Test: 确认错误出现前的首个操作，并获取问题 Mac `~/Library/Logs/RemoteMic/runtime.log` 中同一时刻的 `PHONE REMOTE`、`HID PERMISSIONS`、`PHONE VOICE FN` 和 `AUDIO` 记录。

### H6: 连接后的通用错误来自按住说话时语音启动失败

- Supports: Mac `1.6.7` 在语音已忙、音频输出未就绪或 Fn/Globe 注入失败时发送 `detail = "Mac 的语音输出当前不可用。"`；iOS 同样会覆盖成通用文案。
- Conflicts: 用户尚未说明错误前是否按住了麦克风；如果首个操作是普通按键，该假设不成立。
- Test: 确认是否由麦克风操作触发，并检查问题 Mac 同时刻的 `PHONE VOICE FN` 与 `AUDIO` 日志。

## Experiments

### E1: 核对问题 Mac 版本

- 用户补充确认：发生问题的 Mac 安装并运行的是 `1.6.7`，不是当前开发机 `/Applications` 中的 `1.5.1`。
- 结论：H1 rejected。本机旧安装副本与用户现场无关，不能作为本次根因。

### E2: 本地 Mac 1.6.7 与 iOS 0.8.3 发现及握手

- 直接运行仓库中已签名的 Mac `1.6.7 (47)`，点击“连接手机”后日志出现 `listener_ready`，进程建立 TCP 监听。
- 保持 iPhone 12 模拟器中的 iOS `0.8.3` 不变，Mac 服务启动后 iOS 自动发现并显示校验码 `85`；Mac 同时弹出相同校验码的授权对话框。
- 结论：Bonjour 发现、TCP 建连、`hello`、密钥协商和 `pairingReady` 在 `1.6.7 + 0.8.3` 组合下均可到达。H3 对“所有设备都无法冷启动连接”的解释 rejected。
- 未点击“允许连接”，因为该操作会创建持久受信任设备；因此尚未覆盖用户现场可能发生的“已信任设备自动授权”或“点击允许后收不到 ready”阶段。

### E3: 协议差异检查

- `0.8.2 → 0.8.3` 没有改变 iOS 发出的握手字段、身份签名、HKDF 参数或加密封装。
- Mac 新增的 `appVersion` 只存在于当前源码，问题 Mac `1.6.7` 不发送该字段；iOS 将其声明为可选值，实际解码已成功到达校验码阶段。
- 结论：新增版本字段不是根因。

### E4: 根据用户最新现场缩小故障边界

- 授权弹窗最终出现、用户允许后成功连接，证明问题现场最终完成了发现、TCP、密钥协商、人工授权和 ready；“始终无法连接”的描述应拆成“授权弹窗延迟”和“连接后操作失败”两个问题。
- iOS 通用错误的唯一网络入口是收到 Mac `type == "error"`；Mac `1.6.7` 只有按键失败和语音启动失败两个发送来源。
- 结论：H4 不再是当前主假设；连接后的错误必须结合触发操作或 Mac 运行日志在 H5/H6 之间判定，不能从通用 UI 文案继续猜测。

### E5: 验证冷启动 `scenePhase` 重复重启

- 在 `RemoteControlScreen` 的 `scenePhase` 回调临时加入 1 行状态输出，使用 iPhone 12 模拟器冷启动 iOS App。
- 冷启动直接记录 `phase=active state=searching connected=false`；现有条件会在 `.task` 已调用 `start()` 后立刻再次执行完整 `restartDiscovery()`，取消刚创建的浏览器并重新开始。
- 已连接后切到后台再返回依次记录 `.inactive / .background / .inactive / .active`，状态始终为 `.connected`，健康连接不会被现有条件重启。
- 结论：H3 confirmed。冷启动 active 事件确实会无意义地取消第一轮发现；不同设备调度时序下也可能在更晚的建连/授权阶段执行。诊断输出已撤销。

### E6: 核对 Mac `1.6.7` 的 operation error 与修复验证

- 直接检查 `v1.6.7` 标签源码，确认按键失败返回“Mac 需要辅助功能权限，或该按键当前不可用。”，语音启动失败返回“Mac 的语音输出当前不可用。”；没有第三个纯连接成功后自动发送 error 的路径。
- 新增状态策略与错误映射回归测试：`.searching / .connecting / .awaitingApproval / .connected` 不会因 active 重启，只有本地网络权限等待和明确不可用状态会重启；两条已知 Mac 错误映射为可操作提示，未知错误继续使用通用文案。
- iPhone 12 模拟器连接正式签名 Mac `1.6.7`：冷启动 3 秒内显示已连接测试 Mac，切到后台再返回后仍保持连接。
- 结论：授权弹窗延迟的 iOS 生命周期根因已修复；连接后实际执行失败仍需由新版 iOS 显示的具体提示或问题 Mac 日志判断是 H5 还是 H6。

## Root Cause

- 授权弹窗延迟：iOS 冷启动时 `.task` 已开始 Bonjour 搜索，紧接着的 `scenePhase == .active` 又把所有“尚未连接”的中间状态当成失败状态，取消并重建第一轮发现/连接。
- 错误信息不明确：Mac `1.6.7` 已返回具体的按键或语音失败原因，但 iOS 把两者统一覆盖为“Mac 暂时无法执行这个操作”，隐藏了用户需要处理的权限或音频信息。

## Fix

- 前台 active 只在 `.awaitingLocalNetworkPermission` 或 `.unavailable` 时完整重启发现；不再取消冷启动搜索、正在连接或等待 Mac 授权。
- 对 Mac `1.6.7` 的两条已知 operation error 使用白名单映射，分别提示检查 Mac 辅助功能/按键配置，或辅助功能/虚拟麦克风；未知错误保留通用提示。
- 不修改网络协议、长期信任、Mac 服务端和 iOS 遥控器布局。
