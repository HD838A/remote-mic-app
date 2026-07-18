# File-by-file provenance

Every file under `apps/windows/rc003/` is either (a) new glue/wiring code
with no upstream counterpart, or (b) a clean-room reimplementation informed
by reading the GPL-3.0-only reference project
[`xxb26553663-star/remote-bridge-hub`](https://github.com/xxb26553663-star/remote-bridge-hub)
at reference revision `8a93f321ac71a602300c6cd77f7256fa4b63068e` (read-only,
consulted for interoperability facts - GATT UUIDs, control opcodes,
IMA/DVI ADPCM tables, HID usage IDs, VID/PID values - never copy-pasted).
No file in this directory was copied line-for-line from that repository.

See also this repository's root `COPYRIGHT` and `THIRD_PARTY_NOTICES.md`,
which record the project-wide adaptation statement covering both the macOS
and this Windows adapter.

## `src/ovb_rc003/`

| File | Upstream file(s) consulted | Notes |
| --- | --- | --- |
| `device_profile.py` | `source/bridges/xiaomi/hid_report_tap.py`, `hid_tap_runtime.py` (hardware token); kept consistent with this repo's own `Sources/XiaomiRemoteBridgeMac/VoiceBridgeDeviceProfile.swift` | RC003 name/VID/PID/HID usage-ID facts only |
| `atvv_protocol.py` | `source/bridges/xiaomi/atvv_record.py`, `atvv_live_bridge.py`; kept consistent with `Sources/XiaomiRemoteBridgeMac/ATVVProtocol.swift` | GATT UUIDs, capability parsing, IMA/DVI ADPCM tables and decode order, control opcodes - protocol facts, reimplemented in Python |
| `atvv_session.py` | Same as above (session/state-machine behavior: decoder reset on AUDIO_START, one-shot AUDIO_SYNC, late-audio guard window) | New transport-agnostic state machine; no upstream file has this exact shape |
| `identity.py` | `source/bridges/xiaomi/atvv_live_bridge.py` (`discover_xiaomi_2_pro_candidates`, `choose_xiaomi_2_pro_candidate`) | Deliberately hardened: upstream falls back to a remembered address or silently no-ops on ambiguity; this module always fails closed and never persists an address |
| `hid_identity.py` | `source/bridges/xiaomi/hid_report_tap.py` (report byte layout, usage table, snapshot-diff edge derivation); `source/bridges/raw_input_bridge.py` (`RAWHID` body layout: `dwSizeHid`/`dwCount`/report bytes) | New pure-logic reimplementation; also fails closed on multiple matching HID device paths (`select_single_device_path`) instead of "return the first match", per XRBM-014 review RETRY P1 #5. `normalize_device_path()` added per XRBM-018 so `raw_input_windows.py` can enforce the exact selected device path on every event, not just a VID/PID re-match |
| `connection_supervisor.py` | None (new connect/wait/cleanup/retry state machine) | New; no upstream file has this exact shape. Added per XRBM-014 review RETRY P1 #2. `request_reconnect()` made thread-safe (`call_soon_threadsafe`, not a direct `asyncio.Event.set()`) per XRBM-018, fixing XRBM-014 review round 2 P1 #5 |
| `hotkey.py` | `source/bridges/xiaomi/shortcut_capture.py` (concept only: representing a hotkey as modifiers + key) | New, much simpler serialization; does not reuse the low-level-keyboard-hook capture mechanism |
| `key_mapping.py` | the XRBM-014 task book's default mapping table; `source/bridges/xiaomi/xiaomi_config.py` (`DEFAULT_BUTTON_BINDINGS` concept) | Default table values come from the task book, not copied from upstream defaults |
| `voice_controller.py` | Concept informed by `atvv_live_bridge.py`'s voice-shortcut logging markers | New pure state machine; hold/toggle semantics designed for this project. Toggle-mode lifecycle changed per XRBM-018 (frozen there, superseding the XRBM-014 RETRY P1 #4 fix): taps again on the device's own `AUDIO_STOP`, not only on press, so Windows dictation doesn't stay on indefinitely |
| `audio_output.py` | `source/bridges/audio/audio_router.py` (`find_output_device`, fail-closed-on-missing-device pattern) | Reuses only the fail-closed idea; drops upstream's hardcoded VB-CABLE name and default-fallback host-API preference in favor of user-selected-by-name only. Disambiguates by (name, host API) after XRBM-014 review RETRY P2 #1 noted a bare name is not always unique across PortAudio host APIs |
| `audio_playback.py` | `source/bridges/audio/audio_router.py` (use of `sounddevice`/PortAudio for output) | New, single-purpose sink; no mixer, no VB-CABLE constant; same (name, host API) disambiguation as `audio_output.py` |
| `config.py` | `source/bridges/xiaomi/xiaomi_config.py` (config file location/shape concept) | Deliberately excludes upstream's `address`/`device_match` persisted fields entirely; adds an enforced `FORBIDDEN_KEYS` guard with no upstream counterpart. `load_key_bindings()` gained `_normalize_mic_binding()` per XRBM-019 so a stale/non-voice `mic` entry on disk is always normalized back to the voice action in memory, matching what the runtime actually honors |
| `logging_setup.py` | `source/standalone/xiaomi_main.py` (log directory concept) | New; does not redirect stdout/stderr wholesale the way upstream's `configure_pythonw_logging` does |
| `frida_compat.py` | `source/bridges/xiaomi/hid_report_tap.py`, `hid_tap_injector.py`, `hid_tap_runtime.py` (why Frida is used for the back key; SHA-pinned local-asset-verification concept) | Deliberately does NOT reimplement upstream's remote-thread DLL injection; provides only the asset descriptor and an honest always-degrades contract |
| `win32_keys.py` | None (standard Win32 `winuser.h` VK constants) | New |
| `win32_input.py` | None (standard Win32 `SendInput` API) | New; batches a combo into one `SendInput` call with deterministic partial-failure rollback, per XRBM-014 review RETRY P1 #4. `INPUT`'s ctypes union corrected to the real `MOUSEINPUT \| KEYBDINPUT \| HARDWAREINPUT` shape (`sizeof(INPUT) == 40` on x64) per XRBM-018, fixing XRBM-014 review round 2 P1 #1/#8 - the previous union declared only `KEYBDINPUT`, understating `cbSize` |
| `raw_input_windows.py` | `source/bridges/raw_input_bridge.py` (Raw Input API usage: `RAWINPUTDEVICE`/`RIDEV_INPUTSINK` registration, `WM_INPUT`/`GetRawInputData` two-pass pattern, device-path filtering via `GetRawInputDeviceInfoW`) | New Windows adapter; **replaces** the earlier `hid_input_windows.py` (hidapi-based direct HID-collection open), removed after XRBM-014 review RETRY P1 #5/#9 found that architecture didn't match how the cited upstream project actually reads ordinary buttons on Windows. Which Raw Input event shape (`RIM_TYPEKEYBOARD` vs `RIM_TYPEHID`) the RC003 actually produces is disclosed as unverified in the module's own docstring, not claimed as proven. Per XRBM-018 (fixing XRBM-014 review round 2 P1 #3/#4/#8): `stop()` now posts `WM_CLOSE` (never `WM_QUIT`, which Microsoft documents as invalid to `PostMessage`) and relies on `WM_CLOSE`→`DestroyWindow`→`WM_DESTROY`→`PostQuitMessage`; `start()` fails closed and tears down on a readiness timeout instead of assuming success; every event is checked against the exact normalized selected device path, not just a VID/PID re-match; and several Win32 calls (`GetModuleHandleW`, `CreateWindowExW`, `DefWindowProcW`, the window-procedure callback itself) gained explicit pointer-sized argtypes/restype. Per XRBM-019 (fixing XRBM-018's independent review round 2 finding #1): `PostMessageW` - the one remaining untyped window-handle call - now goes through a shared, fully-prototyped `_post_close_message()` helper reused by both `stop()` and `_abandon_failed_start()`, and a failed post or an unjoined thread both leave `is_running`/the owner state reporting the truth instead of being cleared |
| `ble_transport_winrt.py` | `source/bridges/xiaomi/atvv_live_bridge.py` (WinRT BLE connect/subscribe/write flow, GATT service/characteristic discovery order) | New Windows adapter wiring. Rewritten after XRBM-014 review RETRY P1 #1 to match the locked `winrt-Windows.*==3.2.1` projection's actual signatures (`uuid.UUID` arguments, `GattWriteResult.status`, event-registration tokens, CCCD/service/device cleanup, connection-status subscription) and reviewed via an in-memory fake of that projection in `tests/test_ble_transport_contract.py` - still unverified against a live runtime/real hardware. Discovery rewritten again per XRBM-018 (fixing XRBM-014 review round 2 P1 #2) to use `BluetoothLEDevice.get_device_selector_from_pairing_state(True)` + `DeviceInformation.find_all_async_aqs_filter()` instead of `GattDeviceService.get_device_selector_from_uuid()`, which enumerates a different (GATT service-instance) WinRT ID domain than `BluetoothLEDevice.from_id_async()` requires; `send_mic_open_threadsafe()` gained a generation/closing gate and error observation (P1 #6 area). Per XRBM-019 (fixing XRBM-018's independent review round 2 finding #2): `close()` now treats an ATVV worker-thread join timeout as a real close() failure - raised only after every other independent GATT cleanup step has still been attempted, with `self._worker_thread` deliberately left set - instead of merely reporting it via `on_error` while returning normally |
| `resources.py` | None | New. Gained a `sys._MEIPASS`-aware lookup per XRBM-018 (round 2 finding #4); the module docstring's wording was corrected per XRBM-019 (round 2 product-contract follow-up) to stop claiming `_MEIPASS` equals the frozen executable's own directory - true for older PyInstaller onedir layouts, not guaranteed for PyInstaller 6's default `_internal`-subdirectory layout - without changing the already-correct `sys._MEIPASS/Resources` lookup logic itself |
| `settings_ui.py` | Concept informed by `Sources/XiaomiRemoteBridgeMac/SettingsView.swift` (what a settings screen should expose) and `source/bridges/xiaomi/xiaomi_settings.py` (same concept, upstream's Tk/UI is not reused) | New Tk implementation; deliberately does not attempt clickable photo hotspots (see file docstring). Validation/save logic extracted into Tk-free functions (`build_save_model`, `_display_to_action`, etc.) after XRBM-014 review RETRY P1 #7 found the default "mic" mapping could not round-trip through save. Per XRBM-019 (folded in from a XRBM-018 review round 2 product-contract finding): the "mic" row is now rendered read-only (no `Combobox`/`StringVar` at all) instead of an editable mapping, and `build_save_model()` unconditionally forces the saved "mic" action to voice regardless of what (if anything) the display map contains, since the runtime never consults a stored "mic" binding |
| `app.py`, `__main__.py` | Concept informed by `source/standalone/xiaomi_main.py` (role/entry-point wiring shape) | New; does not reuse upstream's multi-process/subprocess-per-role architecture. `app.py` rewritten to drive `connection_supervisor.py`'s reconnect loop and to resolve/open the audio endpoint *before* sending the voice hotkey/`MIC_OPEN` (XRBM-014 review RETRY P1 #2/#3). Per XRBM-018 (fixing XRBM-014 review round 2 P1 #6): MIC_OPEN is now only sent if the hotkey itself fully delivered, and a playback write failure now fails closed (discards the sink) and requests a reconnect instead of logging indefinitely. Per XRBM-019 (fixing XRBM-018's independent review round 2 finding #2): `_cleanup_once()` now only clears `self._hid_listener`/`self._ble_session` to `None` on a successful `stop()`/`close()` - a step whose resource reports it is still alive leaves the owner reference in place - and raises a new `CleanupIncompleteError` once every step has still been attempted, which ends `ConnectionSupervisor.run_forever()`'s retry loop entirely instead of reconnecting over possibly-still-live resources. `__main__.py` gained a `--dry-run`/`--help` mode for CI/build smoke checks (P2 #3) |
| `__init__.py` | None | New |

## `tests/`

All new. Test *names and intent* for the ATVV/config/privacy areas were
chosen after reading what upstream's own `tests/test_xiaomi_config.py` and
`tests/test_core_behavior.py` check (see
XRBM-014 for the research summary), so this
project's behavioral guarantees are at least as strict, but no test code was
copied - the fixtures, assertions, and helper functions here are new.

`tests/fakes/fake_winrt.py` is a new, from-scratch in-memory fake of the
`winrt-Windows.*==3.2.1` projection surface (not derived from any upstream
or third-party test double), added per XRBM-014 review RETRY P2 #2 so
`tests/test_ble_transport_contract.py` can assert the exact WinRT call shape
(method names, `uuid.UUID` argument types, event-token plumbing) without a
live Windows/WinRT runtime. Updated per XRBM-018 to model the paired-BLE-
device selector domain and to reject a GATT service-instance-domain ID
passed to `from_id_async`, matching the round-2-review-driven production fix.

`tests/test_win32_input_abi.py` (new, XRBM-018) asserts the real x64 Win32
`INPUT` struct shape - `sizeof(INPUT) == 40` and the union's member layout -
using only `ctypes.sizeof()`/plain `ctypes.Structure` classes, so it runs
cross-platform without needing `ctypes.windll`/Windows at all.

`tests/test_app_wiring.py` (new, XRBM-018) exercises `app.py`'s `RC003App`
wiring decisions (host-hotkey-failure suppresses MIC_OPEN, playback-write-
failure fails closed and requests a reconnect, both proven safe when called
from a real background OS thread) by constructing a real `RC003App` and
substituting lightweight recorder objects for its BLE-session/playback
collaborators - no Windows API involved, since `RC003App.__init__` and
these code paths are pure Python off the real Win32/WinRT calls. Gained a
`CleanupOwnershipTests` class per XRBM-019 proving `_cleanup_once()`
retains a still-alive HID/BLE owner rather than clearing it, aggregates and
raises once every step has been attempted, and that this failure
propagates through a real `ConnectionSupervisor.run_forever()` without a
second `connect()` ever running.

`tests/test_win32_ctypes_argtypes.py` (new during the first XRBM-018
retry, extended per XRBM-019) is a from-scratch, cross-platform ctypes
regression suite - no third-party test double, no upstream counterpart.
The `SendInput`/`GetRawInputDeviceList` classes reproduce the
`ctypes.byref(array)`-vs-`POINTER(Struct)` `ArgumentError` the round-1
independent review found using `ctypes.CFUNCTYPE` stubs built from this
project's own real production structs/argtypes. The XRBM-019
`PostMessageWArgtypeTests` class reproduces the *silent-truncation* bug
class (an unprototyped foreign-function call passing a bare Python int as
the platform default 32-bit C `int`) using a real, already-loaded C
library function (`libc`'s `labs`) - a technique with no upstream or
third-party origin, chosen because it needed a real foreign function call
outside this project's own code to demonstrate ctypes' own default
argument-marshaling behavior, not something either project's source
provided.

`tests/test_connection_supervisor.py` gained a `CleanupFailureFailsClosedTests`
class per XRBM-019 - new, no upstream counterpart - proving (without any
change to `connection_supervisor.py` itself) that a raising `cleanup()`
already ends `run_forever()`'s retry loop entirely via ordinary Python
`try/finally` semantics, which is what makes `app.py`'s new
`CleanupIncompleteError` raise actually fail the supervisor closed.

## `build/`, `installer/`, `.github/workflows/windows-rc003-ci.yml`

| File | Upstream file(s) consulted | Notes |
| --- | --- | --- |
| `build/OpenVoiceBridgeRC003.spec` | `source/XiaomiRemoteBridge.spec` (one-dir COLLECT shape, hiddenimports/excludes categories) | New; excludes are adjusted for this tree (T1/Hanvon/licensing don't exist here but are excluded defensively); no VB-CABLE/Frida binary in `datas` |
| `build/fetch-frida-gadget.ps1` | `scripts/fetch-third-party.ps1` (`Get-VerifiedAsset` SHA-pinning pattern) | Reuses only the generic download-then-verify-then-move pattern; the VB-CABLE fetch call is not ported at all |
| `build/check-public-boundary.ps1` | `scripts/check-public-boundary.ps1` (category list and regex-scan structure) | New regex set tailored to this project's forbidden terms/paths |
| `build/build-candidate.ps1` | `delivery/build-standalone-packages.ps1` (venv + install + test + build orchestration shape) | New, much shorter (single product, no packaging-content diffing) |
| `installer/OpenVoiceBridgeRC003Setup.iss` | `delivery/standalone/setup/XiaomiRemoteBridgeSetup.iss`, `StandaloneBridgeSetup.common.iss` (the non-Xiaomi/native-audio `#else` branch template, since it already has no VB-CABLE footprint) | `PrivilegesRequired=lowest` kept; startup-task/icon omitted; no audio-driver `[Run]`/`[UninstallRun]` steps at all (stricter than even the non-Xiaomi upstream template, which still swaps default mic) |
| `installer/stop-app.ps1` | `delivery/standalone/setup/stop-product.ps1` | Nearly the same generic pattern (find-by-executable-path, force-stop); upstream's version is already product-agnostic |
| `installer/readme-rc003.txt` | `delivery/standalone/setup/readme-xiaomi.txt` (section shape) | New wording; VB-CABLE/admin-prompt section replaced with an explanation that no driver/elevation is used |
| `.github/workflows/windows-rc003-ci.yml` | `.github/workflows/ci.yml` (job/step shape: checkout, setup-python, boundary scan, install, compileall, test) | Adds a path filter scoping it to this subtree, and an unsigned PyInstaller build + `--dry-run` smoke check + artifact upload step not present upstream. Per XRBM-018, the Inno Setup compile step was promoted from best-effort/`continue-on-error` to a required gate like every other step - it still only compiles the installer SOURCE and never runs/installs it |
