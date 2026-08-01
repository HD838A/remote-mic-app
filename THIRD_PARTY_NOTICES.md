# Third-party notices

## remote-bridge-hub

- Project: `xxb26553663-star/remote-bridge-hub`
- Source: <https://github.com/xxb26553663-star/remote-bridge-hub>
- Reference revision: `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

The Xiaomi RC003 ATVV UUIDs, microphone command behavior, IMA/DVI ADPCM decoding order, capability parsing, and HID usage mapping were adapted from this project. The macOS implementation uses Apple public frameworks and does not include the upstream Windows injection, VB-CABLE packaging, commercial branding, or customer systems.

## Windows RC003 selective port

- Source PR: `HD838A/remote-mic-app#3`
- Reference revision: `c8f68611e4d56440a4ae527a10195c18bed1409e`
- Related fork: <https://github.com/miaomiaozii/windows-remote-mic-app>
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

The independent Windows client under `apps/windows/rc003` selectively ports the WinRT BLE/GATT transport, ATVV session, IMA/DVI ADPCM decoder, PortAudio playback, reconnection, identity, and single-instance logic. It does not include the PR's DJI support, Frida/WUDFHost injection, input-method attachment, Raw Input/SendInput mapping, Qt/QML UI, or VB-CABLE bundle.

Its pinned runtime/build dependencies include NumPy (BSD-3-Clause), python-sounddevice (MIT; Windows wheels use PortAudio), PyWinRT projections (MIT), PyInstaller (GPL-2.0-or-later with its bootloader exception), and Inno Setup (Inno Setup license). See each pinned package or tool distribution for its complete license text. VB-CABLE is not distributed by this repository; the app only links to the vendor website for optional user-managed installation.

## BlackHole

- Project: `ExistentialAudio/BlackHole`
- Source: <https://github.com/ExistentialAudio/BlackHole>
- Pinned source revision: `v0.7.1` / `e2b22aaaba4e507a097131704bf96dabc004d9cf`
- License: GNU General Public License v3.0 (`GPL-3.0`)

BlackHole remains an optional loopback-device choice. This fork includes `scripts/build-doubao-driver.sh` and `third_party/blackhole/blackhole-device-usb.patch`, which build a distinct `MiRemoteV2ch.driver` from the pinned BlackHole source. The patch changes only the actual Audio Device transport type to USB and assigns a separate CFPlugIn factory UUID; it does not modify an installed `BlackHole2ch.driver`. The release build embeds the derived driver in a dedicated macOS Installer package. End users install that package from the DMG and do not need the source build tools.

## MiRemoteVoice

- Project: `VincentKingHsu/MiRemoteVoice`
- Source: <https://github.com/VincentKingHsu/MiRemoteVoice>
- Reference release: `v1.0.0-beta.1`
- Application license: MIT

The Doubao compatibility design is informed by MiRemoteVoice: a side-by-side BlackHole-derived device reports its actual audio Device as USB transport so Doubao can enumerate it. This fork reimplements that idea as a pinned, source-built BlackHole patch instead of reusing MiRemoteVoice's version-specific binary replacement script.

## RC003 product photo

The RC003 product photo bundled as `RC003-remote-photo.png` was supplied by the user on 2026-07-17 for the physical-button mapping interface. It is preserved at its original 508 x 1030 aspect ratio. Copyright and trademark rights in the photo and depicted products remain with their respective owners; the GPL-3.0-only license for the program does not grant additional rights to this image or the Xiaomi marks.
