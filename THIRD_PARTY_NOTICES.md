# Third-party notices

## remote-bridge-hub

- Project: `xxb26553663-star/remote-bridge-hub`
- Source: <https://github.com/xxb26553663-star/remote-bridge-hub>
- Reference revision: `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

The Xiaomi RC003 ATVV UUIDs, microphone command behavior, IMA/DVI ADPCM decoding order, capability parsing, and HID usage mapping in the first Open Voice Bridge adapter were adapted from this project. The macOS implementation uses Apple public frameworks and does not include the upstream Windows injection, VB-CABLE packaging, commercial branding, or customer systems. Other future device profiles do not inherit this attribution unless they actually use the upstream work.

The Windows source/build candidate at `apps/windows/rc003/` was informed by the same reference project and revision for the same interoperability facts (ATVV UUIDs/opcodes, IMA/DVI ADPCM tables, RC003 HID usage IDs and VID/PID). It is a clean-room Python reimplementation, not a port of upstream's Windows source files; see `apps/windows/rc003/ATTRIBUTION.md` for the file-by-file record. It does not include the upstream VB-CABLE driver packaging, Frida injection/gadget binary, T1/V60 device bridges, or commercial branding, and has not completed real-Windows-device acceptance.

## Frida Gadget (optional, not bundled)

`apps/windows/rc003/build/fetch-frida-gadget.ps1` can optionally download the official Frida Gadget release asset (`frida-gadget-17.15.3-windows-x86_64.dll.xz` from `github.com/frida/frida`) and verifies its SHA-256 (`b566d70189b6d551ad8f4e0bea24de08a3d4c0f559bb35b2bdb67d45182240c2`) before use. No Frida binary is committed to this repository, downloaded automatically by any normal build or test step, or required for the application to run. This candidate does not implement the actual gadget-injection step (see `apps/windows/rc003/README.md`), so fetching this asset currently has no effect on the running application. Frida is licensed separately from this project (its own license text is fetched from `raw.githubusercontent.com/frida/frida-core/main/COPYING`) and is not authored by, or affiliated with, this project or its upstream reference.

## VB-Audio VB-CABLE (optional, user-installed; not bundled)

Unlike the upstream reference project, Open Voice Bridge's Windows candidate does not bundle, download, install, configure, license, or redistribute VB-CABLE or any other virtual audio driver. The project's own documentation (`apps/windows/rc003/README.md` and its installed `readme-rc003.txt`) may mention the official VB-Audio VB-CABLE download as one optional, user-installed endpoint a reader can set up entirely at their own discretion and outside this project, so that a recognizer/listening app has a virtual microphone to read from. At runtime, voice output is written only to a Windows audio endpoint the user has already installed and explicitly selected by name in the application's own settings window — never a default device, and never anything auto-picked.

## BlackHole

BlackHole is not bundled, downloaded, or installed by this project. The application can send decoded PCM to any user-selected CoreAudio output device; BlackHole is only a documented optional loopback-device choice.

## RC003 product photo

The RC003 product photo bundled as `RC003-remote-photo.png` was supplied by the user on 2026-07-17 for the physical-button mapping interface. It is preserved at its original 508 x 1030 aspect ratio. Copyright and trademark rights in the photo and depicted products remain with their respective owners; the GPL-3.0-only license for the program does not grant additional rights to this image or the Xiaomi marks.
