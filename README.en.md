# SayAll

[简体中文](README.md)

Chinese website: [sayall.app](https://sayall.app/)

English website: [sayall.app/en](https://sayall.app/en/)

iOS app beta: [Join the TestFlight public beta](https://testflight.apple.com/join/J8k8fb7v)

The Mac app continues to be distributed directly. Mac App Store submission is paused, while the current App Store launch focus is the iOS app and its Apple Watch app.

![SayAll — a voice remote for Vibe Coding](Screenshots/Remote-Mic-Introduce-1.png)

SayAll is a macOS app that turns a Xiaomi Bluetooth Remote 2 Pro into a wireless voice remote for your Mac. It provides both a standard Dock entry and a persistent menu bar entry.

Hold the remote voice button to speak. The direction, OK, Back, Home, Menu, TV, Power, and volume buttons can control macOS or launch commonly used apps.

SayAll is built natively with SwiftUI. While running in the background, it uses less than 0.5% CPU and around 50 MB of memory—lighter than a single Chrome tab.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connection-and-voice-dark-en.png">
  <img alt="Connection and Voice settings" src="Screenshots/connection-and-voice-en.png">
</picture>

## Requirements

- Apple Silicon Mac with macOS 14 or later, or Intel Mac with macOS 13 or later
- Xiaomi Bluetooth Remote 2 Pro
- For voice input, install the compatible microphone included with the installer, or use an existing loopback device such as BlackHole 2ch.

## Download and install

- Latest stable release (Apple Silicon): download it through the permanent [Cloudflare CDN entry](https://download.sayall.app/mac). The current stable entry provides only the Apple Silicon package and does not change between versions.
- Latest pre-release (Apple Silicon / Intel): open [GitHub Releases](https://github.com/HD838A/remote-mic-app/releases), find the newest macOS candidate marked **Pre-release** in the release list, and download the DMG for your Mac architecture. Until a release containing the Intel package is promoted to stable, Intel users should download the latest pre-release DMG whose name includes `Intel`.

The Apple Silicon installer is named `Remote-Mic-<version>.dmg`; the Intel installer is named `Remote-Mic-<version>-Intel.dmg`. They are not interchangeable.

The DMG has one ordinary installation entry: double-click **Install Remote Mic.pkg** on Apple Silicon, or **Install Remote Mic Intel.pkg** on Intel Macs. It installs **Remote Mic.app** and checks the existing MiRemoteV 2ch. A healthy compatible driver is kept in place; a missing or unusable driver is installed or updated. Advanced users who need only the app can download the app-only ZIP from the same Release.

Starting with v1.3.0, official release packages are signed with an Apple Developer ID and notarized by Apple. Download only through the official Cloudflare CDN entry or this project's GitHub Releases. To verify a DMG, use the `.sha256` file from the corresponding GitHub Release.

## First use

1. Turn on Bluetooth in System Settings.
2. Hold the remote Home and Menu buttons together to enter pairing mode.
3. Pair the device named MI RC, Xiaomi Bluetooth Remote 2 Pro, or 小米蓝牙语音遥控器.
4. Launch SayAll and grant Bluetooth access when asked.
5. To customize ordinary buttons, also grant Input Monitoring and Accessibility. Restarting the app is required only after changing those macOS permissions.

SayAll appears in the Dock and remains in the menu bar after launch:

- Click the Dock icon to open Settings.
- Left-click the icon to open Settings.
- Right-click the icon to show status, reconnect, logs, About, version, update, GitHub, language, and Quit actions.

SayAll opens its main window by default on ordinary launches. The **About** page at the bottom of the Settings sidebar provides version, update, version history, glossary, GitHub, language, Dock display, and launch controls. Turn off **Open main window at launch** to keep ordinary launches in the menu bar; an update relaunch still opens the main window unconditionally. Turn off **Show app icon in the Dock** to keep SayAll available only from its menu bar entry; the Dock icon can be restored from the same page.

**App Language** displays **System Default**, **简体中文**, and **English** together. The settings window, status text, menu, and built-in help follow the selection. System permission prompts and third-party panels continue to use the language selected by macOS when they are next opened.

The app checks for updates once per day and asks before installing a newer version; it does not silently download or install updates. **Check for Updates…** is available from both the About page and the right-click menu. **Check for pre-release updates** on the About page is off by default; when enabled, automatic and manual checks also include the latest GitHub pre-release candidate. Sparkle updates the app bundle only; the compatible microphone driver is managed by the installer in the DMG.

## Use voice input

1. Open **Connection & Voice**.
2. Select **Refresh Audio Devices**.
3. Select **MiRemoteV 2ch**, or another loopback device you already installed.
4. Choose the same device as the microphone in the app that receives dictation or voice input.
5. Click the target text field, hold the remote voice button to speak, then release it to finish.

To confirm the audio path, send a one-second test tone or inspect input level in QuickTime Player's **New Audio Recording** window.

### Typeless compatibility

Tap-to-toggle voice tools such as Typeless are incompatible with the RC003's default Fn-hold behavior. Enable **Simulate Fn Tap on Voice Key** under **Connection & Voice** to send one Fn tap when the voice stream starts and a matching tap after queued audio drains. Typeless and SayAll must still select the same loopback device, and SayAll needs Accessibility permission.

You must still **hold the RC003 voice key while speaking and release it to finish**. The RC003 firmware stops microphone audio when the key is released, so this is not continuous or hands-free recording. The mode is off by default; keep it off for Fn-hold tools such as Doubao Input Method. Missing permission or incomplete RC003 HID mapping automatically disables the mode and restores the default Fn-hold mapping.

If Doubao Input Method cannot see an ordinary virtual microphone, install **MiRemoteV 2ch** with **Install Remote Mic.pkg**, then select it in SayAll. See the [Doubao Input Method Compatibility Guide](Resources/豆包输入法兼容说明.en.md).

## Customize remote buttons

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/key-mapping-dark-en.png">
  <img alt="Button mapping settings" src="Screenshots/key-mapping-en.png">
</picture>

Open **Button Mapping** and enable custom mapping to change direction, OK, Back, Home, Menu, TV, Power, and volume buttons.

Each ordinary button supports a single-click action and optional double-click and long-press actions. Available actions include keyboard input, system volume, playback control, launching installed apps, and recording any custom keyboard shortcut.

**Open Custom App** lets you select any local `.app`, then either open it only, send its focus shortcut after activation, or record a target input field once and focus it automatically. Re-record the target if an app update changes its interface. SayAll does not use fixed screen coordinates or save text from the input field.

- Without double-click or long-press configuration, single-click keeps its immediate response and hold-to-repeat behavior.
- A double-click waits about 0.3 seconds so the app can distinguish a single click.
- A long press triggers after about 0.55 seconds and suppresses the single-click action.
- Buttons with a configured double-click or long-press do not hold-repeat, preventing multiple actions from firing at once.

The voice button is always reserved for voice input and Fn functions and does not participate in ordinary button mapping.

## Usage statistics

The **Statistics** page shows remote button presses, voice duration, and the longest individual voice sessions for the selected day, week, or all-time range. All statistics stay on this Mac and are never uploaded.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/statistics-dark-en.png">
  <img alt="SayAll usage statistics" src="Screenshots/statistics-en.png">
</picture>

## Permissions and privacy

- Bluetooth: connect to the remote and receive voice.
- Input Monitoring: identify ordinary remote buttons.
- Accessibility: send mapped button actions to the active app.

SayAll does not upload or store voice, does not change the system default input or output device, and does not log voice content, Bluetooth addresses, or peripheral identifiers.

## Uninstall

1. Quit SayAll.
2. Download and run **Uninstall Remote Mic.pkg** from the same GitHub Release to remove MiRemoteV 2ch.
3. Delete **Remote Mic.app** from Applications.

Uninstalling the compatible microphone does not change or remove BlackHole.

When installing over an older release, the installer recognizes the legacy /Applications/无线麦.app only when its bundle identifier is com.hd838a.RemoteMic. It then migrates it safely to the existing **Remote Mic.app** bundle path; unrelated bundles at that legacy path are left untouched.

## Troubleshooting

Read the [Troubleshooting Guide](TROUBLESHOOTING.en.md) first. The complete onboarding flow is in the [First-Install Guide](Resources/首次安装说明.en.md).

For development, build, protocol, test, and release details, see the [Technical Documentation](TECHNICAL.en.md).

## License and sources

The macOS app, driver, and related software code in this repository are GPL-3.0-only. The iOS app is now maintained in a separate private repository and continues to be distributed through the TestFlight beta link above. The macOS app logo and app icon are proprietary brand assets that require a separate grant; see [LOGO-LICENSE.en.md](LOGO-LICENSE.en.md). Full copyright and third-party information is available in [COPYRIGHT.en.md](COPYRIGHT.en.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The project was originally forked from [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge) and is now maintained independently in this repository.

The MiRemoteV 2ch naming and USB-transport compatibility approach for Doubao device enumeration were informed by [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) v1.0.0-beta.1 (MIT). This project does not reuse that project's binary replacement script. Instead, it independently derives MiRemoteV2ch.driver from [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 at commit e2b22aaaba4e507a097131704bf96dabc004d9cf under GPL-3.0. The driver has a separate identity, coexists with BlackHole, and never overwrites or removes BlackHole files.
