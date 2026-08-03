# Version History

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
