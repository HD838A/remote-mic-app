# Version History

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
