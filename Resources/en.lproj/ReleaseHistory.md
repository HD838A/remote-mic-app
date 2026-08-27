# Version History

## 1.9.16 (Pre-release)

- Added Left Command and Right Command voice-trigger modes while keeping Fn/Globe as the default.
- Voice keys now start on press and end on release without focus-gesture delays; input focus is available as a separate regular remote-button action.
- Improved focus reliability for Electron, Web, search, and Terminal input fields.
- Fixed RC003 TV-key characters leaking into the frontmost text field across keyboard layouts.
- Improved Bluetooth recovery after Mac wake and audio-failure diagnostics.
- Added remote control of the macOS Command-Tab app switcher.
- Added an optional rapid-press setting for non-repeatable actions, disabled by default.
- Fixed the combination-action editor from consuming ordinary remote-button events.
- Added local original-recording storage and improved Reflections records when no editable input field is available.
- Added Up and Down scroll actions for remote buttons.
- Improved alignment of the language selector on the About page.

## 1.9.10 (Pre-release)

- Combination Actions are now available by default, with no invitation code required to view, create, bind, or use them.

## 1.9.9 (Pre-release)

- Added an opt-in “Launch at login” setting under About → App Preferences, with a direct link to macOS Login Items Settings when approval is required.
- Added in-page keyboard shortcut selection for common keys, navigation keys, F1–F20, the numeric keypad, and independent left/right modifiers while retaining physical-key recording.
- Improved first-run and permission recovery: onboarding centers after sizing, and enabled custom button mappings are reapplied after Input Monitoring or Accessibility permissions change.
- Runtime voice input now selects only an enabled preferred input source, avoids repeated confirmation prompts, and restores the previous input source unless you changed it during the session.
- Improved Bluetooth recovery for stale cached remotes with bounded backoff and power-recovery handling without losing saved profiles or mappings.
- Reduced unnecessary UI invalidation during voice streaming while preserving audio processing and diagnostics.
- Prevented duplicate SayAll instances; reopening the app activates the existing instance instead of starting another Bluetooth, audio, or HID stack.
- Kept the Settings window visible when switching apps and retained its Dock presence until the window is actually closed.
- Fixed the RC003 monitored-mode TV button leaking a “§” character into the frontmost text field when mapped to a custom action.

## 1.9.8 (Pre-release)

- Improved upgrades from older Remote Mic installations: the previous app now stops before the audio driver is updated, and the new SayAll.app stays at its canonical Applications location so audio setup can continue reliably after the upgrade.

## 1.9.7 (Pre-release)

- Fixed repeated macOS input-source confirmation prompts during first-run voice setup; changing the selected input method now happens only when the voice-tool step requires it.

## 1.9.6 (Pre-release)

- First-run setup permission cards remain clickable after authorization, so you can reopen the relevant macOS Privacy settings when checking or repairing access.
- Users upgrading from an existing installation are guided to the permission repair page when required access is missing.
- Improved first-run physical-remote discovery so the first real button press selects the correct remote without waiting indefinitely for an initial HID report; clearer guidance is shown when another input tool has exclusive access.

## 1.9.5 (Pre-release)

- Fixed an issue where an unbound physical remote could be detected during first-run setup but its first button press might not respond; first-run setup now accepts the initial input reliably.

## 1.9.4 (Pre-release)

- After Connect iPhone is enabled on the Mac, an iPhone can scan a short-lived QR code to connect directly over the current local network. If direct connection fails, SayAll automatically falls back to existing Bonjour/P2P discovery, while legacy iPhone and Apple Watch connection paths remain unchanged.

## 1.9.3 (Pre-release)

- First-run setup now keeps Typeless Fn-tap behavior in sync and can continue connection checks after a physical remote button has been recognized.
- Combination Actions no longer require an invitation code and are directly available in builds that include the corresponding private module. Independent access restrictions for other invitation-only features remain unchanged.

## 1.9.1 (Pre-release)

- Renamed the app bundle to SayAll.app and added migration from legacy Remote Mic.app and 无线麦.app installations.
- Combination Actions can bind app launch, waiting, keyboard shortcuts, and input-field focus to remote buttons.
- Added Reflections, an on-device voice history with undoable deletion. SayAll MCP remains off by default and provides read-only access when enabled.
- Reworked first-run setup around explicitly compatible devices such as MiRemoteV 2ch and BlackHole 2ch, including real voice-input validation before completion.
- Improved direct Apple Watch voice input and rapid restart after stopping. Full real-device scenarios remain under validation.
- Fixed the first phrase after initially focusing an input field sometimes not being recorded in Reflections.
- Improved virtual-audio release and recovery after stale output state, Mac sleep, or wake.
- Added sharing to the sidebar, About, and Statistics, and moved issue feedback into About.
- Added clearer upgrade checks and recovery guidance when permissions are missing.
- Enhanced layered HID button-path diagnostics to continue investigating intermittent lost input.

## 1.8.25 (Pre-release)

- Opening an installer for the wrong architecture now clearly points to the correct version for the current Mac.
- Updated SayAll branding and standardized the in-app website link on sayall.app.
- Improved remote pairing guidance in first-run setup, including waking the remote and holding Home and Menu together to enter pairing mode.
- Improved iPhone, Apple Watch, and web voice connections with isolated sources, accurate connection status, and a way to cancel a connection.
- Added a feedback entry to the menu bar for reporting issues from the app.

## 1.8.23 (Pre-release)

- Fixed an issue that could cause Remote Mic to quit when opening Quick Commands from the sidebar.
- Improved Quick Commands resource loading in installed builds so the page opens reliably after a fresh install or upgrade.

## 1.8.22 (Pre-release)

- Fixed raw localization identifiers appearing on selected settings pages and tightened the input and status layout.
- Text fields in Settings now support standard Mac editing shortcuts for copy, paste, cut, undo, redo, and select all.
- Updated the shared Apple Watch direct-connection component with improved Bluetooth fallback and notification retry behavior. Discovery, authorization, buttons, and microphone flows still require real-device validation.

## 1.8.21 (Pre-release)

- Preview updates no longer show update prompts from background checks; open About and check manually to view preview candidates.
- Stable updates keep their automatic checks and update prompts.

## 1.8.20 (Pre-release)

- Improved access to selected preview features from the About page while keeping the feature switches off until you enable them.
- Improved preview-feature setup feedback and state handling.

## 1.8.19 (Pre-release)

- Added a dedicated Apple Watch entry to Connection & Voice, with on-demand nearby-device waiting and cancellation. Real-device validation of Apple Watch discovery, authorization, buttons, and microphone remains pending.
- Added a Quick Commands preview for combining app launch, app wait, keyboard shortcut, and input-focus steps, then assigning them to remote buttons.
- Improved state restoration and error feedback for selected preview features, and fixed a possible unexpected exit when opening Settings for the first time from the final package.

## 1.8.12 (Pre-release)

- Improved the speed and reliability of Mac installer and automatic-update downloads. Existing versions can continue checking for updates, with GitHub downloads retained as a fallback.

## 1.8.11 (Pre-release)

- Fixed newly paired remotes appearing connected in macOS while the setup guide kept searching until Remote Mic was restarted. Returning from Bluetooth Settings now restarts discovery and connects the new device automatically.
- Fixed ordinary remote buttons sometimes doing nothing while macOS system actions such as volume still worked. When only some low-level button services are usable, remotes that passed the safety checks can continue working.
- The setup guide now shows the real button-monitoring status and provides a retry action, refreshes audio devices after returning to Remote Mic, and rechecks permissions, the remote, and audio output before opening the main panel.
- Remote cards show the full Xiaomi Bluetooth Remote 2 and Xiaomi Bluetooth Remote 2 Pro names with clearer battery and charging icons. The File menu can now open the log folder directly.

## 1.8.10 (Pre-release)

- Existing users no longer have to repeat the first-run setup after upgrading. New installations, unfinished setup, and a setup guide started again by the user still complete the required checks.
- The setup guide no longer requires MiRemoteV 2ch. BlackHole 2ch and other installed audio devices can be selected and continued once their output is ready.
- Fixed the setup guide continuing to show that it was searching for the remote after an upgrade even though a physical remote button had already been received. Bluetooth recovery now starts automatically.
- Fixed the compatible microphone remaining active after the remote disconnected and potentially staying attached to meeting or voice-input apps. Disconnecting now ends the active voice session and releases the virtual audio device.
- Removed the ineffective physical-remote recording renewal attempt to avoid unnecessary forced stops and reconnects. The roughly one-minute recording limit remains under investigation.

## 1.8.9 (Pre-release)

- Fixed the first Fn voice input sometimes doing nothing after a remote button launched or switched to an app. Remote Mic now waits for the target's editable input to be ready and preserves the beginning of speech during that wait.
- If the target app closes, changes, takes too long, or focuses a sensitive field, the pending voice input is cancelled instead of being sent to the wrong window.

## 1.8.8 (Pre-release)

- Added a complete first-run setup guide that checks Bluetooth, Input Monitoring, and Accessibility permissions, then verifies the remote, compatible microphone, real voice input, and everyday buttons. Required checks cannot be skipped or bypassed to enter the main panel.
- Existing users can run the setup guide again from About to recheck their environment and troubleshoot problems without clearing connections, button mappings, the compatible microphone, or other settings.
- The setup guide uses a consistent two-pane design in light and dark modes, does not display a total step count, and remains mandatory after relaunching until setup is complete.

## 1.8.7 (Pre-release)

- Redesigned About to keep the current version, available update, update check, version history, and pre-release channel together.
- When a new version is available, About now shows localized release notes before the update starts.
- Switching between stable and pre-release updates refreshes the result immediately, while an unavailable candidate feed still falls back silently to stable updates.

## 1.8.6 (Pre-release)

- Fixed holding the remote's Left or Right button not continuously moving the text cursor in input fields of other apps. Matching arrow mappings now use macOS native key repeat.
- Shortcut capture now starts only after clicking Record Shortcut and can record combinations already reserved by macOS or another app, such as Command-Space, with clear success feedback.
- Fixed dragging the gain slider or settings-page content moving the entire window. Only the dedicated top area remains draggable.

## 1.8.5 (Pre-release)

- Physical remote voice sessions are now renewed periodically to try to continue beyond the roughly one-minute limit, with an initial maximum of three minutes.
- Remote Mic for iPhone now supports tap to start and tap again to stop, while retaining hold-to-talk and release-to-stop.

## 1.8.4 (Pre-release)

- Added Command-W, Command-X, Command-A, Command-Z, Command-Shift-Z, Command-F, and Command-S to Basic Keys, so common window, editing, search, and save actions can be mapped directly to remote buttons.
- Remote Mic now supports the standard Command-Q shortcut to quit and Command-W to close the Settings window while keeping the menu-bar app running.

## 1.8.3 (Pre-release)

- Fixed custom button controls remaining visibly enabled but inactive after a Sparkle upgrade until the toggle was turned off and on. The app now waits for the previous process to release HID access and rebuilds button monitoring automatically after an update.

## 1.8.2 (Pre-release)

- Buttons can now open any installed Mac app and automatically focus it through an app shortcut or a learned Accessibility input field. Recorded shortcuts, apps, and input targets remain available after switching actions or temporarily disabling a trigger, and are preserved by configuration export and import.
- Reorganized Button Mapping with grouped in-page actions, a collapsible app section, and inline shortcut capture and input-field learning. Chinese text is larger, and Disable Button is now a prominent standalone switch.
- Added Command-Return, Shift-Return, Command-C, Command-V, Command-Q, Command-Left Arrow, and Command-Right Arrow preset actions.
- Fixed an issue where macOS device enumeration order could make single-click and double-click actions stop responding on one of multiple remotes that had not yet completed button binding.

## 1.8.1 (Pre-release)

- Fixed short voice input from Xiaomi Remote 2 sometimes disappearing entirely or losing its ending after the voice key was released. Queued audio is now allowed to finish playing when the remote stops streaming.
- Improved voice reliability while Xiaomi Remote 2 and Xiaomi Remote 2 Pro are connected together, including alternating use through both the virtual microphone and Simulate Fn Tap modes.

## 1.8.0 (Pre-release)

- Supports multiple Xiaomi Remote 2 and Xiaomi Remote 2 Pro devices at the same time. Each remote keeps independent shortcuts, a newly added remote copies the current settings, and physical activity automatically selects the matching device.
- Shows the remote model, battery level, and available charging or power status. Button Mapping now centers the physical remote and displays every single-click, double-click, and long-press action on one screen.
- Connectors originate at the real hardware hotspots and reveal the pressed position. Refined curves, arrow spacing, the main enable switch, and concise explanations make the mapping easier to understand.
- Fixed cross-device button routing, unexpected selection changes, and continuous actions or system error sounds when holding custom shortcuts, navigation buttons, or Delete.
- When custom button controls are enabled without the required permissions, the app now explains what is missing, opens the Permissions page, and applies the setting after authorization.

## 1.7.8 (Pre-release)

- Redesigned Connection & Voice around the physical remote, voice output, compatible microphone, and phone connections while retaining reconnect, device selection, TestFlight, Mobile Web, and trusted-device controls.
- Redesigned Button Mapping to show every button's single-click, double-click, and long-press settings at a glance, with an option to lock the button currently being edited.
- Moved Simulate Fn Tap on Voice Key below the remote image so the microphone button's fixed behavior and related setting stay together, without changing configuration or runtime behavior.

## 1.7.7 (Pre-release)

- Fixed `1.7.6` quitting immediately at launch on some macOS 26 Macs with the Xiaomi Bluetooth voice remote connected by retaining the owning system client throughout HID mapping reads and writes.
- Configurable Mobile Web and nearby iPhone/iPad buttons now support the same single-click, double-click, and long-press actions as the physical remote while keeping gesture state isolated between connection types.
- Added a hard launch gate for the final ZIP and PKG artifacts: both must pass two launches, a normal quit, and crash-report checks on an interactive Mac with the remote connected before publication.

## 1.7.5

- Silently falls back to the stable update feed when no pre-release exists or the candidate lookup times out or is temporarily unavailable, without showing an error alert.
- Corrected daily and weekly history attribution: usage without a known date remains available only in All Time and is no longer guessed to be earlier activity.
- Added richer on-device aggregate metadata for future statistics views, including input source, control or voice entry point, hourly distribution, voice-session counts and duration, longest session, and first/last activity times; device identifiers, user text, and audio are not stored.

## 1.7.4

- Clarified the on-device voice-session ranking description so its storage scope and displayed results are easier to understand.

## 1.7.3

- Fixed update-channel fallback so enabling pre-release checks can never prevent stable updates from being detected when the candidate feed is unavailable or stale.
- Added a private, on-device Top 10 list of the longest voice sessions recorded from this version onward; no usage data is uploaded.

## 1.7.2

- Replaced the remote-control product image with a clearer, consistent rendering across the connection and button-mapping pages while preserving interactive button alignment.

## 1.7.1

- Fixed weekly charts not reconciling with all-time totals. They now show the recent seven weeks plus an Earlier bucket for legacy and older history without inventing dates, and voice labels use precise clock durations that add up to the all-time value.

## 1.7.0

- Fixed production builds that omitted the Mobile Web relay endpoint; release builds and final App verification now fail when the endpoint is missing.
- Clarified that the iOS TestFlight beta does not require an invite code, and fixed duplicate Return submission and unreliable QR-sheet transitions.
- Removed the unnecessary statistics-period animation and simplified the local-data messaging on About.

## 1.6.11 (Pre-release)

- Added a dedicated Statistics page with seven-day and eight-week bar charts plus a simplified all-time totals view.
- Refined the window and About styling, increased the default window size, hid scroll indicators and redundant page subtitles, and highlighted the website and GitHub links.
- Added a session-only invite code for the Mobile Web remote. Its invite sheet now recommends the iOS app first and provides TestFlight open and copy actions.

## 1.6.9 (Pre-release)

- Requires an explicit **Connect Mac** click after scanning before a remote session is opened; microphone access still starts only while push-to-talk is held.
- Automatically resumes an approved web session after a brief network interruption instead of immediately requiring a new QR code.
- Improves phone speech with browser voice processing, weak-network buffering, and tail draining so releasing push-to-talk does not discard queued audio.

## 1.6.8 (Pre-release)

- Added an install-free Mobile Web remote with one-time QR codes and explicit approval on the Mac.
- Added white-listed remote buttons, synchronized custom titles, and push-to-talk audio through the existing virtual microphone path.
- Added short-lived relay sessions, encrypted transport, rate limits, and a privacy boundary that does not store voice content.

## 1.6.7 (Pre-release)

- Fixed an issue where a stale Mac session could block a new iPhone connection after a long disconnect, requiring the Mac App to restart before reconnecting.
- Updated the iPhone remote with a light brushed-aluminum background, centered connection status, no top logo, and concise custom titles across every configurable button.
- Strengthened push-to-talk press visuals and two-stage haptics, while warming and reusing the recording pipeline to reduce first-phrase delay.

## 1.6.6 (Pre-release)

- Added an off-by-default **Check for pre-release updates** toggle to About. When enabled, Sparkle's automatic and manual checks include the latest GitHub pre-release candidate.
- Refreshes the opt-in candidate feed before manual checks and periodically while the app remains running, without affecting the stable update feed when candidate metadata is unavailable.

## 1.6.5 (Pre-release)

- Fixed press-and-release feedback for iPhone push-to-talk while preserving the existing Fn/Globe-key trigger and virtual-microphone output path.
- Fixed the iPhone middle controls to Back / TV / Volume Up on the first row and Home / Menu / Volume Down on the second row.
- Synced concise, bounded action titles to the corresponding iPhone buttons when the Mac uses non-default button mappings.

## 1.6.4

- Made phone remote control an optional, on-demand backup. Nearby phone connections now remain off at Mac launch and start only after the user clicks Connect Phone.

## 1.6.3

- Changed the first-connection verification code shown on iPhone and Mac from six digits to two digits, with matching values on both devices.

## 1.6.2

- Remembered an approved phone installation for future nearby connections, with a Settings action to clear trusted phones.
- Improved pairing-code synchronization and visibility, including reconnecting after the iOS App restarts.
- Fixed microphone startup failures that could occur even when iPhone microphone access was already enabled, while keeping technical errors out of user-facing messages.

## 1.6.1

- Added nearby iPhone/iPad remote control and push-to-talk with pairing-code verification and encrypted transport.
- Reused the Mac's current button mappings and routed phone microphone audio into the existing virtual audio output.

## 1.6.0 (Pre-release)

- Migrated all interface copy to stable semantic localization keys, with English fallback and dynamic language-resource validation.
- Replaced implementation terminology in ordinary screens with user-facing product language and added a bilingual Glossary entry to About.
- Hid the visible window title and separator so the page background blends naturally with the native macOS window controls.

## 1.5.1

- Opened the main window by default on ordinary launches, with an About-page preference to disable it.
- Always brought the main window and update-completed confirmation to the front after an update relaunch.

## 1.5.0

- Redesigned About so the version and update check appear together.
- Made every language option permanently visible and added in-app version history.
- Synchronized the macOS 14 support, installation, release, and technical documentation.

## 1.4.13

- Fixed an AppKit exception caused by reusing attached menu items while rebuilding the menu after a language change.

## 1.4.12 (Pre-release)

- Lowered the minimum system version to macOS 14.0 while remaining Apple Silicon only.
- Kept Liquid Glass on macOS 26 and added compatible styling for macOS 14/15.

## 1.4.11

- Added configuration import and export.
- Added local-only button-press and voice-duration usage totals.

## 1.4.10

- Fixed terminal input refocusing when cmux was already frontmost.

## 1.4.9 (Pre-release)

- Improved cmux terminal refocusing and release-note generation.

## 1.4.8 (Pre-release)

- Improved automatic input focus for Codex, Claude, and cmux.

## 1.4.7 (Pre-release)

- Added guarded pre-release publishing and full-release promotion.
- Added automatic input focus after opening supported apps.

## 1.4.6

- Fixed installation asking ordinary users to download the Xcode Command Line Tools.

## 1.4.5

- Fixed a crash after sleep/wake or audio-route changes when reopening the app window.
