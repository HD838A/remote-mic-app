# Remote Mic Technical Documentation

[简体中文](TECHNICAL.md)

This document is for developers, auditors, and release engineers. It describes the implementation, build, and release constraints of the current source. End users should start with [README.en.md](README.en.md).

## Support boundary

- Apple Silicon release line: arm64, macOS 14 or later
- Intel release line: x86_64, macOS 13 or later
- Target remote: Xiaomi Bluetooth Remote 2 Pro / RC003
- HID identity: Vendor ID 0x2717, Product ID 0x32B8
- Swift tools version: 6.2; the current release Mac uses Swift 6.3, with source compiled in Swift 5 language mode
- Release signing: local development builds retain ad-hoc signing with a fixed designated requirement. Starting with v1.3.0, official releases use Developer ID Application and Developer ID Installer signing; the app and driver use the Hardened Runtime and trusted timestamps, while the app, both PKGs, and the DMG are notarized by Apple and stapled.

The release lines use separate artifacts and update feeds: Apple Silicon keeps the default names and `appcast.xml`, while Intel uses names containing `Intel` and `appcast-intel.xml`. Build and verification scripts pin each architecture and minimum system version independently; no Universal package is produced.

## Localization

The app supports Simplified Chinese and English. LocalizationStore persists the user's language preference in AppSettings and resolves either the chosen language or the current system language without changing AppleLanguages. It keeps dynamic state as LocalizedMessage keys and arguments, so an open settings window, status menu, tooltips, about panel, and built-in help redraw immediately after a language selection.

SwiftUI receives the selected locale through its environment. The small AppKit boundary in RemoteMicApp.swift rebuilds its status menu and updates window chrome when LocalizationStore publishes a new locale. System permission prompts and Sparkle use macOS or their own current localization on the next presentation; they are not forced or restarted.

The bundle contains en.lproj and zh-Hans.lproj with Localizable.strings, InfoPlist.strings, and localized Markdown help. The base Info.plist is English, while Chinese display and Bluetooth permission text are supplied through zh-Hans.lproj.

## Module layout

| Module | Main responsibility |
| --- | --- |
| RemoteMicApp.swift | AppKit lifecycle, status item, settings window, right-click menu, About/version, language menu, and Sparkle manual update entry |
| SettingsView.swift | Settings UI, status, audio selection, button mapping, and permissions; Liquid Glass on macOS 26 with compatibility styling on macOS 14/15 |
| Localization.swift | language selection, locale resolution, localized resources, and dynamic message rendering |
| BridgeAppModel.swift | coordination of Bluetooth, audio, HID, voice-key mapping, and UI state |
| XiaomiBluetoothBridge.swift | CoreBluetooth scan, connection, capability negotiation, voice session, and reconnect |
| ATVVProtocol.swift | ATVV commands, capabilities, IMA/DVI ADPCM decoding, frame accumulation, and PCM post-processing |
| AudioOutput.swift | CoreAudio output discovery and 16 kHz mono voice delivery |
| HIDRemoteMonitor.swift | raw RC003 HID reports, exclusive/compatibility mode, repeat behavior, and active buttons |
| KeyboardEventSuppressor.swift | short suppression of duplicate native events in compatibility mode |
| KeyboardInjector.swift | keyboard, media-key, and preset-app actions |
| RemoteVoiceFunctionMapper.swift | RC003 voice-button F5 Fn mapping or Command-mode neutralization and restoration |
| AppSettings.swift | persistent audio, language, HID, mapping, and peripheral settings |

## Bluetooth and ATVV

Candidates are accepted only if either condition is met:

- Their trimmed system name is MI RC, Xiaomi Bluetooth Remote 2 Pro, or 小米蓝牙语音遥控器. English-name comparison is case-insensitive.
- Their advertisement includes the ATVV service UUID.

The app does not fuzzy-match every Bluetooth device whose name contains Xiaomi. A successful connection stores the macOS peripheral UUID for priority recovery. Initialization or connection failure clears the stale cache and scans again after three seconds. A user-initiated reconnect uses an approximately 0.1-second delay.

| Purpose | UUID |
| --- | --- |
| Service | AB5E0001-5A21-4F05-BC7D-AF01F617B664 |
| Transmit | AB5E0002-5A21-4F05-BC7D-AF01F617B664 |
| Audio | AB5E0003-5A21-4F05-BC7D-AF01F617B664 |
| Control | AB5E0004-5A21-4F05-BC7D-AF01F617B664 |

The app reaches ready only after characteristic discovery, Audio and Control notification subscriptions, and capability confirmation. Initialization times out after eight seconds. Only 16 kHz encoding is accepted; a remote that offers or switches to 8 kHz is closed and rediscovered.

Voice data is accumulated by the remote-declared frame size and decoded with high-nibble-first IMA/DVI ADPCM. Sync packets reset predictor and step index. Decoded PCM receives three-point smoothing and a safe -24...24 dB gain clamp; the UI currently exposes 0...24 dB.

## Audio output

VirtualAudioOutput uses AVAudioEngine and AVAudioPlayerNode with 16 kHz mono Float32 audio. The app enumerates CoreAudio devices that have output channels and writes voice directly to the selected device without changing the system default input or output.

Test tone audio is generated in memory. It is permitted only when an audio device is configured, RC003 is not streaming voice, and no other test tone is playing. A real voice session or device reconfiguration cancels the tone to avoid blocking voice buffers.

## Doubao compatibility driver

scripts/build-doubao-driver.sh builds MiRemoteV2ch.driver from BlackHole v0.7.1 at commit e2b22aaaba4e507a097131704bf96dabc004d9cf. The project patch changes only the reported Audio Device transport to USB and assigns separate bundle, device UID, and CFPlugIn factory identifiers.

The release device is MiRemoteV 2ch with UID MiRemoteV2ch_UID. It coexists with BlackHole2ch.driver and never overwrites or deletes BlackHole.

The install PKG payload contains:

- /Applications/SayAll.app
- /Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver

Install scripts verify architecture, minimum system version, and code signature, restart Core Audio, and launch the app for the active desktop user. Legacy `/Applications/Remote Mic.app` and `/Applications/无线麦.app` bundles are moved to the target volume's macOS Trash only after the new SayAll.app is verified and each legacy Info.plist confirms the `com.hd838a.RemoteMic` bundle identifier. Collision-safe Trash names keep the old bundles recoverable; unavailable Trash or unrecognized content leaves the old path untouched. The uninstall PKG removes only MiRemoteV2ch.driver and restarts Core Audio.

## HID and button mapping

Custom mapping is off by default. When enabled, Input Monitoring and Accessibility are both required; otherwise HID handling fails closed.

HIDRemoteMonitor first tries to open RC003 exclusively. If macOS rejects exclusive access, it falls back to nonexclusive monitoring. KeyboardEventSuppressor then suppresses matching native system events for 180 milliseconds after an RC003 raw report. Because a system Power event can trigger sleep before the Session Event Tap, enabling custom mapping first applies a device-specific `Keyboard Power → F20` mapping to RC003; HID handling fails closed if that mapping cannot be applied. Synthesized events carry a separate marker and are not suppressed again.

| Remote button | Default action |
| --- | --- |
| Direction / OK | Arrow keys / Return |
| Back | Delete (Backspace) |
| Home | Show Desktop (Fn-F11) |
| Menu | macOS context-menu key |
| TV | Command-Tab |
| Power | Escape |
| Volume + / - | System volume up/down |

Users can also choose mute, play/pause, or launch Codex, Claude, cmux, WeChat, Cursor, Xcode, Slack, WeCom, NetEase Cloud Music, Chrome, Safari, and Zed. The picker hides unavailable preset apps but retains an already configured app that was later removed. App-launch actions do not repeat.

Direction, Back, and volume buttons can hold-repeat. Normal physical button activity is published to SwiftUI to highlight the remote diagram and select its mapping row.

## Voice-button trigger modes and Fn mapping

The RC003 voice button appears as keyboard F5 on usage page 0x07, usage 0x3E. `RemoteVoiceFunctionMapper` matches only RC003 vendor/product IDs and, by default, maps that usage to Apple vendor top-case Fn/Globe on usage page 0xFF, usage 0x03. While custom button mapping is enabled, the same component maps RC003 Keyboard Power usage 0x66 to F20 usage 0x6F.

The opt-in Typeless compatibility mode first requires Accessibility permission, then transactionally maps F5 to usage 0 on every matching RC003 service. Missing targets or any partial failure roll back all changes, disable the setting, and restore the default Fn mapping. Once enabled, `VoiceFnTapSessionController` buffers pre-roll at physical voice-stream start and writes it to the loopback device only after the opening Fn tap succeeds. On release it waits for `VirtualAudioOutput.endSessionAfterDraining` before sending the matching closing Fn tap. Generations and cancellable tasks isolate rapid consecutive sessions and clean up on disable, disconnect, reconnect, or app exit; a failed opening tap never produces a closing tap.

This mode only adapts the trigger semantics seen by the target app. The RC003 must still be physically held to capture audio; it does not provide continuous recording or independent transcription. Configuration import/export includes optional `voiceKeyMode`, `voiceFnTapModeEnabled`, and `voiceShortTapFocusEnabled`; legacy configurations keep new behavior off. Fn tap and short-tap focus are mutually exclusive. Mode changes, disconnects, and app exit release any held Command and restore the managed source usages while preserving unrelated runtime changes.

The supported `voiceKeyMode` values are `fn` (default), `left_command`, and `right_command`. Command mode uses one shared voice-session lifecycle for RC003, iPhone, Apple Watch, and Web voice sources: voice start sends keyDown for the selected Command and voice end sends the matching keyUp. Ordinary keyboard Command events do not start input-source switching; only a confirmed voice session opens and closes the explicit input-source session.

`VoiceShortTapFocusPolicy` reuses `HIDRemoteTiming.longPressMilliseconds`. When enabled, a session below that boundary cancels transcript capture, flushes the short audio attempt, and asynchronously calls `KeyboardInjector.focusFrontmostComposer`. Candidate ranking rejects search, settings, password, token, terminal, and code-editor fields. Electron and Chromium reuse the existing accessibility-tree activation and bounded retry path. WeChat exposes no composer, so only its exact bundle identifier uses a minimum-window-size gate and a window-relative click fallback.

## Menu bar and window

The app runs as an LSUIElement accessory and has no Dock icon. The status item receives left and right mouse-up events:

- Left-click creates or brings forward the resizable settings window, whose default and minimum size is 1020×772.
- Right-click shows connection, audio, and HID status plus reconnect, settings, logs, language, About, version, update, GitHub, and Quit actions.

On macOS 26, the settings window uses native `glassEffect`, glass button styles, and scroll-edge effects. On macOS 14/15 it uses standard buttons, system Material panels, and compatible selection states. Both paths share the same functionality and layout and follow the system light/dark appearance, reduced transparency, and increased contrast settings.

## Data and logs

- Voice PCM exists only in process memory and the selected CoreAudio output path. It is not saved or uploaded.
- Test tone is generated only in memory.
- Persistent values include language, gain, audio device UID, custom-mapping state, button bindings, and the macOS peripheral UUID.
- Runtime logs are written to ~/Library/Logs/RemoteMic/runtime.log. They contain status and errors but not voice content, Bluetooth addresses, or peripheral UUIDs.

## Build and test

Development verification:

    ./scripts/test.sh
    swift test
    ./scripts/build-app.sh
    ./scripts/verify-app.sh

`scripts/test.sh` runs protocol and policy self-tests and compiles the full app. Swift Testing covers ATVV, Bluetooth lifecycle, audio-device policy, button mapping, permissions, configuration compatibility, Fn mapping, the Typeless session lifecycle, pre-roll, audio draining, and test-tone behavior.

Build and launch:

    ./script/build_and_run.sh
    ./script/build_and_run.sh --verify

--verify builds, launches, and confirms that the RemoteMic process exists. It is not hardware acceptance for the remote or a real voice path.

## Release artifacts

Full release build:

    ./scripts/build-dmg.sh
    ./scripts/verify-dmg.sh

build-dmg.sh builds and verifies the app, driver, install PKG, and uninstall PKG in sequence. It produces:

- dist/SayAll.app
- dist/MiRemoteV2ch.driver
- dist/Install Remote Mic.pkg
- dist/Uninstall Remote Mic.pkg
- dist/Remote-Mic-<version>.dmg
- dist/Remote-Mic-<version>.dmg.sha256

The DMG root contains only Install Remote Mic.pkg. The app-only ZIP and architecture-matched uninstall PKG remain advanced assets in the same Release. The install PKG is no longer uploaded again as a standalone Release asset, but it remains inside the DMG and continues to pass signature, notarization, Gatekeeper, and payload verification. It stages the driver internally and replaces an existing driver only when it is missing, damaged, built for the wrong architecture, invalidly signed, or a different version; a healthy current driver remains untouched.

verify-dmg.sh validates the SHA-256, HFS+ image, single root entry, and install-PKG payload. The app bundle, uninstall PKG, versions, architecture, minimum OS, signatures, localized resources, and absence of leaked local paths remain covered by their dedicated artifact verifiers. Official mode also validates the Developer ID Team, Hardened Runtime, PKG/DMG signatures, stapled notarization tickets, and Gatekeeper assessment.

Sparkle 2.9.4 is embedded through SwiftPM. Its feed URL and EdDSA public key are in Info.plist; the private key remains in the publisher's restricted local storage and never enters the project or a release. SUEnableAutomaticChecks=true with SUScheduledCheckInterval=86400 enables daily checks, while SUAutomaticallyUpdate=false and SUAllowsAutomaticUpdates=false prevent silent downloads or automatic installation. The menu command remains available for immediate checks. Sparkle updates the app bundle only and never installs or replaces the compatibility microphone driver.

Official Preview publication can run only through the protected `.github/workflows/mac-release-package.yml` workflow. Inside its protected Environment, the workflow invokes `scripts/notarize-release.sh` with the existing Developer ID identities, notarization credentials, and restricted Sparkle private key to sign, notarize, and staple both architecture lanes and generate the ZIPs and appcasts. Local commands must not read those credentials or publish directly.

Candidate builds are published as GitHub pre-releases first. `notarize-release.sh` keeps the appcast release page on the fixed GitHub `RELEASE_TAG`, while the enclosure ZIP and localized update notes use immutable `download.sayall.app/mac/releases/<tag>/` Cloudflare CDN URLs. After GitHub assets become public, the publication script downloads the same assets through the CDN, compares them byte for byte, and verifies `HEAD` and `Range` behavior. The application's `SUFeedURL` remains fixed at GitHub `releases/latest/download/appcast.xml`, so existing installations do not need a feed migration. GitHub excludes drafts and pre-releases from the latest full release, so users who keep pre-release checks disabled continue to receive the production appcast. When a user explicitly enables pre-release checks on About, the app resolves the newest non-draft GitHub Release containing `appcast.xml` through the public Releases API and supplies that immutable asset URL to Sparkle as a dynamic feed. It refreshes before manual checks and periodically while the app remains running.

The protected workflow's Apple-credential-free publish job invokes `scripts/publish-release.sh prerelease` and accepts only a clean, pushed source commit referenced by the same remote tag. The candidate provenance / canonical manifest determines the complete asset set and count; neither the command nor this document hard-codes a production count. Each install PKG remains inside its architecture-matched DMG instead of being uploaded again as a standalone asset. The job verifies that the pre-release did not change the latest full release, then downloads every manifest-listed asset from GitHub and the CDN and compares it byte for byte while retaining promotion-verification compatibility with historical asset matrices. A test Mac should use the architecture-matched Sparkle CLI one-shot `--feed-url <candidate appcast URL>` override for candidate discovery or installation without persisting an `SUFeedURL` preference. Installing the candidate requires an unlocked graphical session.

`scripts/fast-release.sh` is only a no-secret candidate preflight and dispatcher. After the sole `release/pre-vX.Y.Z` branch, exact-SHA Draft PR, candidate CI, and release-pipeline qualification proof already exist, invoke it with the original request time and immutable request ID:

```bash
RELEASE_REQUEST_STARTED_AT=<original-request-unix-seconds> \
RELEASE_REQUEST_ID=<immutable-request-id> \
./scripts/fast-release.sh
```

The command verifies the clean worktree, exact remote head, candidate CI, sole Draft PR, and qualification proof, then dispatches the protected workflow and resolves and prints the new Run ID/URL within a bounded 25-second window. If dispatch succeeded but the Run identity is not yet resolved, it explicitly tells the operator to reconcile the existing Run and never dispatches again automatically. It does not read Apple, Match, Notary, or Sparkle credentials; sign or notarize locally; create or push a tag; create or edit a Release; upload assets; or publish an appcast. A non-content failure on the same SHA must re-dispatch the identical branch, PR, version, Build, request ID, and original clocks.

After the candidate passes clean installation, runtime, and end-to-end Sparkle update testing, only an explicit request naming that existing Pre-release may dispatch the protected stable-promotion workflow to promote the same tag and exact assets. The promotion gate verifies that the latest appcast is byte-identical to the tested candidate appcast. Never replace or promote a failed candidate; choose a new display version and `CFBundleVersion` only when the published bytes actually need to change, then run the complete protected pipeline again.

### Release incident review and mandatory checks

The `1.4.5` installer PKG called `/usr/bin/lipo` and `/usr/bin/vtool` from `postinstall` to check architecture and minimum OS version. Those commands belong to the Xcode Command Line Tools and are not part of a normal macOS installation environment. Macs without developer tools prompted the user to download them, and `set -e` then aborted installation. This was an installer-script defect, not an application runtime, Developer ID signing, or Apple notarization failure.

Installer scripts run on the end user's Mac and may depend only on system commands guaranteed by the product's minimum macOS version. Developer tools such as `lipo`, `vtool`, `xcrun`, `xcode-select`, `xcodebuild`, `swift`, `swiftc`, and `clang` must not appear in PKG `preinstall`, `postinstall`, or other installation scripts. Architecture and minimum-OS checks belong on the release machine in build verifiers such as `verify-app.sh` and `verify-doubao-driver.sh`; they must not be repeated on the user's Mac.

`scripts/verify-doubao-driver-pkg.sh` expands the final PKG and rejects installer scripts that invoke any of those developer tools. Every release must run the same check again against the final PKG downloaded back from GitHub Releases. Inspecting only the script source in the repository is insufficient because packaging may consume a different or stale copy.

The `1.4.2` / `1.4.3` installer PKGs changed every regular file in the app directory to mode `0644` during `postinstall`, then restored `0755` only on `Contents/MacOS/RemoteMic`. This removed executable permissions from Sparkle, Autoupdate, Updater, and the XPC services after installation. The original app, ZIP, PKG, and DMG could still pass signing, notarization, and Gatekeeper checks because the damaging permission rewrite happened after installation. Validating release artifacts alone therefore cannot detect this failure.

The installed app must keep these files at mode `0755`:

- `Contents/MacOS/RemoteMic`
- `Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle`
- `Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate`
- `Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater`
- `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer`
- `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader`

`packaging/doubao-driver/install/postinstall` restores and tests each permission explicitly. `scripts/verify-doubao-driver-pkg.sh` rejects an installer that omits these rules. Every official release must also:

1. Simulate the PKG's post-install permission handling in an isolated target instead of inspecting only the payload.
2. Run `codesign --verify --deep --strict` on the installed app and launch Autoupdate, Updater, and the related XPC/Mach services through launchd.
3. Download the appcast, ZIP, DMG, and both PKGs back from the published Release, then compare GitHub digests, local SHA-256 values, signatures, stapled notarization tickets, and Gatekeeper results.
4. Claim a completed end-to-end Sparkle UI upgrade only from an unlocked graphical session. An HTTP 200 appcast response while the screen is locked proves only feed reachability.
5. Distinguish an old installation from a new one. An updater already damaged by an older PKG cannot update itself; it must first be repaired with the current Installer.pkg or by restoring permissions through a remote shell.

Release signing must also distinguish a certificate being listed from its private key being usable. When the login Keychain is locked, `security find-identity` may still list the certificate while `codesign` fails with `errSecInternalComponent` because it cannot access the private key. With explicit user authorization, the existing certificate may be synchronized through readonly Match/P12 into a temporary empty-password release Keychain used only for that release; no certificate may be created, revoked, or changed. After publishing, remove the temporary Keychain, P8 file, Match password, and temporary clone, then confirm that the user Keychain search list contains only its original login Keychain.

## License and sources

The macOS app, driver, and related software in this repository are GPL-3.0-only; the iOS app is now maintained in a separate private repository. The macOS app logo and app icon are governed by the separate [Logo License](LOGO-LICENSE.en.md). ATVV and RC003 behavior refer to xxb26553663-star/remote-bridge-hub; the Doubao compatibility driver is built from a pinned BlackHole version. See [COPYRIGHT.en.md](COPYRIGHT.en.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution and constraints.
