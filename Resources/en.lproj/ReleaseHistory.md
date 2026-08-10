# Version History

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
