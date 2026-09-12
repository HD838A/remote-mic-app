# Third-party notices

## remote-bridge-hub

- Project: `xxb26553663-star/remote-bridge-hub`
- Source: <https://github.com/xxb26553663-star/remote-bridge-hub>
- Reference revision: `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

The Xiaomi RC003 ATVV UUIDs, microphone command behavior, IMA/DVI ADPCM decoding order, capability parsing, and HID usage mapping were adapted from this project. The macOS implementation uses Apple public frameworks and does not include the upstream Windows injection, VB-CABLE packaging, commercial branding, or customer systems.

## codex-siri-remote

- Project: `luobosibing2/codex-siri-remote`
- Source: <https://github.com/luobosibing2/codex-siri-remote>
- Reference revision: `3da8bc74cc840c3e048448de203586cd24108f6a`
- License: GNU General Public License v3.0 or later (`GPL-3.0-or-later`)

The Apple Siri Remote A2854 vendor/product identifiers, HID usage table, dynamically loaded `MultitouchSupport` ABI, small external touch-surface selection rule, and initial circular-scroll tuning were informed by this project. SayAll reimplements the adapter and lifecycle routing in this repository; it does not include the upstream DriverKit components or virtual audio implementation.

## SiriRemoteForge

- Project: `HOLODATA-COM/SiriRemoteForge`
- Source: <https://github.com/HOLODATA-COM/SiriRemoteForge>
- Reference revision: `10581a960f0738e36516defb79db24b18df214d3`
- License: GNU General Public License v3.0 or later (`GPL-3.0-or-later`)

The lossless PacketLogger file-tail capture shape, binary `.pklg` record layout, ACL/L2CAP fragmentation handling, A2854 voice notification framing, Opus packet handling, and packet-loss concealment strategy were informed by this project. SayAll uses its existing `MiRemoteV 2ch` output instead of including SiriRemoteForge's HAL driver, root LaunchDaemon, shared-memory ring, application UI, or built-in microphone fallback.

## iRemote A2854

- Project: `DaviBaum/iRemote-A2854`
- Source: <https://github.com/DaviBaum/iRemote-A2854>
- Reference revision: `3f6fd807a6b11df12789df3fdd5874ad9336a684`
- License: MIT

The direct `com.apple.bluetooth.BTPacketLogger` XPC connection, `RequiresAuth` / `Authentication` handshake, `com.apple.PacketLogger.HCI` Authorization Services flow, profile-required diagnostic recognition, and bounded in-memory traffic handling were informed by this project. SayAll implements its own narrowly scoped client and does not include iRemote's Whisper transcription, text insertion, pointer control, UI, model management, or user data handling.

## Opus

- Project: Opus Interactive Audio Codec
- Source: <https://www.opus-codec.org/>
- Bundled version in this local build: 1.6.1
- License: BSD 3-Clause (`BSD-3-Clause`)

The local Apple Remote audio helper dynamically loads the bundled `libopus.0.dylib` to decode remote voice packets. Apple PacketLogger is not included or redistributed by SayAll.

Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of Internet Society, IETF or IETF Trust, nor the names of specific contributors, may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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
