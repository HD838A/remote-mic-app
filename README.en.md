# Remote Mic

[简体中文](README.md)

![Remote Mic — a voice remote for Vibe Coding](Screenshots/Remote-Mic-Introduce-1.png)

Remote Mic is a macOS app that turns a Xiaomi Bluetooth Remote 2 Pro (RC003) into a wireless voice remote for your Mac. It provides both a standard Dock entry and a persistent menu bar entry.

Hold the remote voice button to speak. The direction, OK, Back, Home, Menu, TV, Power, and volume buttons can control macOS or launch commonly used apps.

![Connection and Voice settings](Screenshots/connection-and-voice.png)

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Xiaomi Bluetooth Remote 2 Pro / RC003
- For voice input, install the compatible microphone included with the installer, or use an existing loopback device such as BlackHole 2ch.

## Download and install

Download releases from [GitHub Releases](https://github.com/HD838A/remote-mic-app/releases/latest). Each release is named Remote-Mic-<version>.dmg.

The DMG provides two installation paths:

1. Recommended: double-click **Install Remote Mic.pkg**. It installs **Remote Mic.app** and the MiRemoteV 2ch compatible microphone for Doubao Input Method and other voice-input apps.
2. App only: drag **Remote Mic.app** to Applications. This requires a usable loopback audio device to already be installed.

Starting with v1.3.0, official release packages are signed with an Apple Developer ID and notarized by Apple. Download only from this project's GitHub Releases and verify the DMG with the `.sha256` file from the same release.

## First use

1. Turn on Bluetooth in System Settings.
2. Hold the remote Home and Menu buttons together to enter pairing mode.
3. Pair the device named MI RC, Xiaomi Bluetooth Remote 2 Pro, or 小米蓝牙语音遥控器.
4. Launch Remote Mic and grant Bluetooth access when asked.
5. To customize ordinary buttons, also grant Input Monitoring and Accessibility. Restarting the app is required only after changing those macOS permissions.

Remote Mic appears in the Dock and remains in the menu bar after launch:

- Click the Dock icon to open Settings.
- Left-click the icon to open Settings.
- Right-click the icon to show status, reconnect, logs, About, version, update, GitHub, language, and Quit actions.

The **About** page at the bottom of the Settings sidebar provides version, update, GitHub, language, Quit, and Dock display controls. Turn off **Show app icon in the Dock** to keep Remote Mic available only from its menu bar entry; the Dock icon can be restored from the same page.

Choose **System Default**, **简体中文**, or **English** under **App Language**. Remote Mic's open settings window, status text, menu, and built-in help update immediately; restarting the app is not required. System permission prompts and third-party panels continue to use the language selected by macOS when they are next opened.

The app checks for updates once per day and asks before installing a newer version; it does not silently download or install updates. **Check for Updates…** is available from both the About page and the right-click menu. Sparkle updates the app bundle only; the compatible microphone driver is managed by the installer in the DMG.

## Use voice input

1. Open **Connection & Voice**.
2. Select **Refresh Audio Devices**.
3. Select **MiRemoteV 2ch**, or another loopback device you already installed.
4. Choose the same device as the microphone in the app that receives dictation or voice input.
5. Click the target text field, hold the remote voice button to speak, then release it to finish.

To confirm the audio path, send a one-second test tone or inspect input level in QuickTime Player's **New Audio Recording** window.

If Doubao Input Method cannot see an ordinary virtual microphone, install **MiRemoteV 2ch** with **Install Remote Mic.pkg**, then select it in Remote Mic. See the [Doubao Input Method Compatibility Guide](Resources/豆包输入法兼容说明.en.md).

## Customize remote buttons

![Button mapping settings](Screenshots/key-mapping.png)

Open **Button Mapping** and enable custom mapping to change direction, OK, Back, Home, Menu, TV, Power, and volume buttons.

Each ordinary button supports a single-click action and optional double-click and long-press actions. Available actions include keyboard input, system volume, playback control, launching installed apps, and recording any custom keyboard shortcut.

- Without double-click or long-press configuration, single-click keeps its immediate response and hold-to-repeat behavior.
- A double-click waits about 0.3 seconds so the app can distinguish a single click.
- A long press triggers after about 0.55 seconds and suppresses the single-click action.
- Buttons with a configured double-click or long-press do not hold-repeat, preventing multiple actions from firing at once.

The voice button is always reserved for voice input and does not participate in ordinary button mapping.

## Permissions and privacy

- Bluetooth: connect to the remote and receive voice.
- Input Monitoring: identify ordinary remote buttons.
- Accessibility: send mapped button actions to the active app.

Remote Mic does not upload or store voice, does not change the system default input or output device, and does not log voice content, Bluetooth addresses, or peripheral identifiers.

## Uninstall

1. Quit Remote Mic.
2. Double-click **Uninstall Remote Mic.pkg** in the DMG to remove MiRemoteV 2ch.
3. Delete **Remote Mic.app** from Applications.

Uninstalling the compatible microphone does not change or remove BlackHole.

When installing over an older release, the installer recognizes the legacy /Applications/无线麦.app only when its bundle identifier is com.hd838a.RemoteMic. It then migrates it safely to **Remote Mic.app**; unrelated bundles at that legacy path are left untouched.

## Troubleshooting

Read the [Troubleshooting Guide](TROUBLESHOOTING.en.md) first. The complete onboarding flow is in the [First-Install Guide](Resources/首次安装说明.en.md).

For development, build, protocol, test, and release details, see the [Technical Documentation](TECHNICAL.en.md).

## License and sources

The program code is GPL-3.0-only. The app logo is a proprietary brand asset that requires a separate grant; see [LOGO-LICENSE.en.md](LOGO-LICENSE.en.md). Full copyright and third-party information is available in [COPYRIGHT.en.md](COPYRIGHT.en.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The project was originally forked from [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge) and is now maintained independently in this repository.

The MiRemoteV 2ch naming and USB-transport compatibility approach for Doubao device enumeration were informed by [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) v1.0.0-beta.1 (MIT). This project does not reuse that project's binary replacement script. Instead, it independently derives MiRemoteV2ch.driver from [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 at commit e2b22aaaba4e507a097131704bf96dabc004d9cf under GPL-3.0. The driver has a separate identity, coexists with BlackHole, and never overwrites or removes BlackHole files.
