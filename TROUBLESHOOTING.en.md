# Remote Mic Troubleshooting Guide

[简体中文](TROUBLESHOOTING.md)

Confirm that your Mac is Apple Silicon and runs macOS 14 or later.

## The remote cannot be found or connected

1. Confirm that the remote is paired in **System Settings → Bluetooth**.
2. Hold the remote Home and Menu buttons together to put it back in pairing mode.
3. Confirm that its name is MI RC, Xiaomi Bluetooth Remote 2 Pro, or 小米蓝牙语音遥控器.
4. Left-click the Remote Mic menu bar icon and choose **Reconnect Now**.
5. If the status does not change, quit and relaunch Remote Mic, then confirm that Bluetooth access is still granted.

The app connects only to RC003 devices with an approved name or an advertised ATVV service. It does not fuzzy-match other Xiaomi Bluetooth devices.

## Holding the voice button produces no sound

1. Open **Connection & Voice** and confirm that Bluetooth is connected.
2. Choose **Refresh Audio Devices**, then select MiRemoteV 2ch or another available loopback device.
3. Choose **Send 1-Second Test Tone**. If the control is unavailable, select the audio device again.
4. In QuickTime Player, create a new audio recording with the same device and hold the remote voice button while watching the input level.
5. Confirm that the target app also uses the same device as its microphone.

Remote Mic never changes system default input or output, so it and the target app must use the same device.

## QuickTime has input level but Doubao does not react

This usually means the remote and audio path work, but Doubao is not using an ordinary virtual audio device.

1. Install MiRemoteV 2ch from **Install Remote Mic.pkg** in the DMG.
2. Quit Doubao completely and reopen it.
3. In Remote Mic, choose **Refresh Audio Devices** and select MiRemoteV 2ch.
4. Click an editable text field so that its insertion cursor is visible, then hold the remote voice button.

For details, read the [Doubao Input Method Compatibility Guide](Resources/豆包输入法兼容说明.en.md).

## Ordinary buttons do not work

1. Open **Button Mapping** and enable **RC003 Custom Button Mapping**.
2. Grant Input Monitoring and Accessibility from the **Permissions** page in that order.
3. Quit and reopen Remote Mic so macOS applies newly granted permissions.
4. Return to Button Mapping and press a physical button. Its matching button should highlight and its mapping row should be selected.

When custom mapping is disabled, macOS may still handle some remote buttons as a regular Bluetooth keyboard, but Remote Mic mappings do not run.

## Buttons repeat or make a system alert sound

Remote Mic first attempts exclusive access to the RC003 button device. If macOS rejects that, the app uses compatibility mode and briefly suppresses matching native system events.

Try the following:

1. Confirm that Input Monitoring and Accessibility are both granted.
2. Restore default button mappings and try again.
3. Quit other utilities that rewrite keyboard or media keys.
4. Right-click the menu bar icon, choose **Show Logs**, and record the button and state at the time of the issue.

The Menu action uses the native macOS context-menu key rather than Shift-F10. If an alert sound remains, report the physical button, current mapping, foreground app, and whether HID status is exclusive or compatibility mode.

## The voice button does not trigger Fn

The Fn mapping matches RC003 only; it never changes a MacBook keyboard or other devices.

1. Confirm that Bluetooth status shows a successful connection.
2. Quit and relaunch Remote Mic so the device mapping can be applied again.
3. Confirm that the remote model is RC003.
4. Inspect **Voice Trigger** under **Connection & Voice**.

Remote Mic restores the RC003 voice-button mapping that existed before launch when it quits.

## macOS blocks the installer

Starting with v1.3.0, official releases sign the app, both PKGs, and the DMG with Developer ID identities and notarize them with Apple. If macOS still blocks installation, delete the local download, download it again from this project's GitHub Releases, and verify it with the `.sha256` file from the same release; do not use an untrusted copy.

Verify a DMG with the checksum file from the same release:

    shasum -a 256 -c Remote-Mic-1.3.0.dmg.sha256

## Automatic update reports missing Autoupdate executable permissions

If Console contains any of the following messages, the problem is not the appcast, download network, or update signature. The installed copy of Sparkle has lost executable permissions:

    The remote port connection was invalidated from the updater.
    Autoupdate may not have executable permissions.
    failed to probe status service for com.hd838a.RemoteMic

The older `1.4.2` / `1.4.3` installer PKGs changed every regular file in the app to mode `0644` and restored executable permissions only on the main binary. This prevented Autoupdate, Updater, and both XPC services from launching. Checking again or reinstalling the same old PKG does not repair it, and a broken updater cannot update itself.

The preferred recovery is to download the latest `Remote-Mic-<version>-Installer.pkg` from GitHub Releases and run it once through local or remote management. If only a remote shell is available, run:

    sudo chmod 755 \
      "/Applications/Remote Mic.app/Contents/MacOS/RemoteMic" \
      "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
      "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
      "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
      "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
      "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"

    codesign --verify --deep --strict "/Applications/Remote Mic.app"

Remote repair does not require physical access to the Mac. Sparkle's installation confirmation UI does require an unlocked graphical session, however. Fetching the appcast successfully while the screen is locked proves only that the feed is reachable; it is not proof of a completed upgrade.

## View logs

Right-click the menu bar icon and choose **Show Logs**. The log file is:

    ~/Library/Logs/RemoteMic/runtime.log

Logs do not contain voice content, Bluetooth addresses, or peripheral UUIDs. When reporting an issue, include macOS version, Mac chip, remote model, reproduction steps, and the relevant log excerpt.
