# Doubao Input Method Compatible Virtual Microphone

MiRemoteV 2ch is Remote Mic's standalone stereo loopback device. It allows Doubao to recognize voice sent from the remote. It can coexist with BlackHole 2ch and never modifies, removes, or replaces BlackHole.

## Install

You do not need Xcode, Git, or Terminal.

1. Double-click Install Remote Mic.pkg at the root of the DMG.
2. Enter an administrator password when macOS Installer asks.
3. The installer adds Remote Mic and MiRemoteV 2ch, restarts Core Audio, and launches Remote Mic.
4. Left-click the menu bar icon, then select **Refresh Audio Devices** in **Connection & Voice**.
5. Choose **Select MiRemoteV 2ch**.
6. Quit Doubao completely, reopen it, and test again.

## Verify

In QuickTime Player, choose **File → New Audio Recording**, then set the input device to MiRemoteV 2ch. The input level should move while you hold the remote voice button and speak.

If QuickTime receives sound but Doubao does not, click an editable text field in Doubao to show the insertion cursor before holding the voice button again.

## Uninstall

Double-click Uninstall Remote Mic.pkg at the root of the DMG. It removes only:

    /Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver

It restarts Core Audio without deleting Remote Mic or changing BlackHole.

## Technology and License

The driver is built from pinned BlackHole v0.7.1 source, this project's patch, and release build parameters. Its Audio Device reports USB transport and its device name is MiRemoteV 2ch.

BlackHole is licensed under GPL-3.0. See THIRD_PARTY_NOTICES.md inside the app bundle for details.
