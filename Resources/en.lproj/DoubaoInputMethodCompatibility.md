# Doubao Input Method Compatible Virtual Microphone

The SayAll microphone is a standalone stereo loopback device. It allows Doubao to recognize voice sent from the remote. Existing installations keep MiRemoteV 2ch, its stable identity, and saved selections. It can coexist with BlackHole 2ch and never modifies, removes, or replaces BlackHole.

## Install

You do not need Xcode, Git, or Terminal.

1. Double-click `Install SayAll.pkg` at the root of the DMG.
2. Enter an administrator password when macOS Installer asks.
3. The installer adds SayAll and the compatible microphone, restarts Core Audio, and launches SayAll.
4. Left-click the menu bar icon, then select **Refresh Audio Devices** in **Connection & Voice**.
5. Select the microphone shown by the system: SayAll for a new installation, or MiRemoteV 2ch for an existing installation.
6. Quit Doubao completely, reopen it, and test again.

## Verify

In QuickTime Player, choose **File → New Audio Recording**, then set the input device to SayAll (MiRemoteV 2ch on an existing installation). The input level should move while you hold the remote voice button and speak.

If QuickTime receives sound but Doubao does not, click an editable text field in Doubao to show the insertion cursor before holding the voice button again.

## Uninstall

Download and double-click `SayAll-<version>-Uninstaller.pkg` from the same Release. It verifies and moves SayAll, recognized legacy app bundles, and the compatible microphone to the macOS Trash, then restarts Core Audio. It does not modify BlackHole or SayAll's local settings.

## Technology and License

The driver is built from pinned BlackHole v0.7.1 source, this project's patch, and release build parameters. Its Audio Device reports USB transport and new installations display SayAll; existing installations keep MiRemoteV 2ch.

BlackHole is licensed under GPL-3.0. See THIRD_PARTY_NOTICES.md inside the app bundle for details.
