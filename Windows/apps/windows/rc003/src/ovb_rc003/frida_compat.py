"""RC003 HID-over-GATT compatibility tap.

Windows' normal keyboard stack does not expose the RC003 usages for Back and
the two volume buttons.  The original ``remote-bridge-hub`` Windows client
solves that by observing the completed HID read inside the RC003 WUDF host via
a verified Frida Gadget.  This module reuses that narrow transport and keeps
button policy in the existing Remote Mic application.

The tap is deliberately optional.  Without the explicitly fetched, SHA256
verified Gadget archive the normal BLE/Raw Input client still starts, while
these three missing usages remain unavailable instead of being guessed.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
import socket
import threading
import time
from typing import Callable

from . import frida_hid_tap_runtime
from .device_profile import BUTTON_USAGE_IDS
from .frida_hid_tap_injector import inject_current_process


@dataclass(frozen=True)
class ThirdPartyAsset:
    name: str
    version: str
    url: str
    sha256: str
    license_name: str
    license_url: str


FRIDA_GADGET = ThirdPartyAsset(
    name="Frida Gadget",
    version=frida_hid_tap_runtime.GADGET_VERSION,
    url=(
        "https://github.com/frida/frida/releases/download/17.15.3/"
        "frida-gadget-17.15.3-windows-x86_64.dll.xz"
    ),
    sha256=frida_hid_tap_runtime.GADGET_ARCHIVE_SHA256,
    license_name="Frida core license",
    license_url="https://raw.githubusercontent.com/frida/frida-core/main/COPYING",
)

BACK_USAGE = 0x00F1
VOLUME_UP_USAGE = 0x0080
VOLUME_DOWN_USAGE = 0x0081
MISSING_USAGE_TO_BUTTON = {
    BACK_USAGE: "back",
    VOLUME_UP_USAGE: "volume_up",
    VOLUME_DOWN_USAGE: "volume_down",
}

# The tap observes the full 6-byte keyboard report (three little-endian 16-bit
# usages), not just the three usages Windows' keyboard class drops.  Reporting
# every known RC003 keyboard usage lets the application arm its duplicate
# suppressor from the tap's socket thread - a side channel the low-level hook
# does not block, unlike the WM_INPUT arm that arrives too late (measured
# ~63-72ms after the hook on the RC003).
TAP_USAGE_TO_BUTTON = dict(MISSING_USAGE_TO_BUTTON)
for _usage, _button in BUTTON_USAGE_IDS.items():
    TAP_USAGE_TO_BUTTON.setdefault(_usage, _button)

# usage -> (VK, make code, extended) matching what Windows' keyboard class
# reports for the same physical key, so the hook's consume() sees identical
# vk/scan/extended values whether the arm came from Raw Input or from the tap.
TAP_USAGE_TO_KEY = {
    0x0028: (0x0D, 0x1C, False),  # ok / Enter
    0x0035: (0xC0, 0x29, False),  # tv / grave accent
    0x003E: (0x74, 0x3F, False),  # mic / F5 (direct voice edge; F5 swallowed)
    0x004A: (0x24, 0x47, True),  # home
    0x004F: (0x27, 0x4D, True),  # right
    0x0050: (0x25, 0x4B, True),  # left
    0x0051: (0x28, 0x50, True),  # down
    0x0052: (0x26, 0x48, True),  # up
    0x0065: (0x5D, 0x5D, True),  # menu / App key
    0x0066: (0xFF, 0x5E, True),  # power (untranslated VK)
    0x007F: (0xAD, 0x20, True),  # volume_mute
    0x0080: (0xAF, 0x30, True),  # volume_up
    0x0081: (0xAE, 0x2E, True),  # volume_down
    0x00F1: (0xFF, 0x6A, True),  # back (untranslated VK)
}


def verify_asset(path: Path, asset: ThirdPartyAsset = FRIDA_GADGET) -> bool:
    """Return true only when ``path`` is the exact pinned archive."""

    if not path.is_file():
        return False
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest.casefold() == asset.sha256.casefold()


def gadget_archive_path() -> Path:
    return frida_hid_tap_runtime.gadget_archive_path()


def decode_rc003_ioctl_output(data: bytes) -> bytes | None:
    """Extract the six-byte usage payload from a HidOverGatt read buffer."""

    if len(data) != 9 or data[:3] != b"\x01\x00\x00":
        return None
    return data[3:9]


def payload_usages(payload: bytes) -> set[int]:
    if len(payload) != 6:
        return set()
    return {
        int.from_bytes(payload[index : index + 2], "little")
        for index in range(0, len(payload), 2)
    } - {0}


class RC003HidReportTap:
    """Observe missing RC003 usages and emit edge-stable six-byte reports."""

    def __init__(
        self,
        report_handler: Callable[[int, bytes], None],
        *,
        archive_path: Path | None = None,
        enabled: bool = True,
        retry_delay: float = 2.0,
        heartbeat_timeout: float = 15.0,
    ) -> None:
        self.report_handler = report_handler
        self.archive_path = archive_path or gadget_archive_path()
        self.enabled = bool(enabled) and os.name == "nt"
        self.retry_delay = max(0.5, float(retry_delay))
        self.heartbeat_timeout = max(10.0, float(heartbeat_timeout))
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.active_usages: set[int] = set()
        self._state_lock = threading.Lock()
        self._last_wait_log = 0.0

    @property
    def dependency_available(self) -> bool:
        return verify_asset(self.archive_path)

    @property
    def available(self) -> bool:
        return self.dependency_available

    @property
    def status(self) -> str:
        if not self.enabled:
            return "disabled_non_windows"
        if not self.archive_path.is_file():
            return "unavailable_gadget_not_downloaded"
        if not self.dependency_available:
            return "unavailable_gadget_hash_mismatch"
        if self.thread is not None and self.thread.is_alive():
            return "running_waiting_for_hidogatt_io"
        return "ready_gadget_verified"

    def _release_active(self) -> None:
        with self._state_lock:
            was_active = bool(self.active_usages)
            self.active_usages.clear()
        if was_active:
            self.report_handler(1, b"\x00" * 6)

    def _handle_ioctl_output(self, data: bytes) -> None:
        payload = decode_rc003_ioctl_output(data)
        if payload is None:
            return
        active = payload_usages(payload) & set(TAP_USAGE_TO_BUTTON)
        with self._state_lock:
            previous = self.active_usages
            if active == previous:
                return
            pressed = active - previous
            released = previous - active
            self.active_usages = set(active)
        filtered = b"".join(
            value.to_bytes(2, "little") for value in sorted(active)
        )
        self.report_handler(1, (filtered + b"\x00" * 6)[:6])
        changes = [
            f"{TAP_USAGE_TO_BUTTON[value]}=down" for value in sorted(pressed)
        ]
        changes.extend(
            f"{TAP_USAGE_TO_BUTTON[value]}=up" for value in sorted(released)
        )
        print(
            f"RC003 HID TAP {' '.join(changes)} raw={data.hex()}",
            flush=True,
        )

    def _run(self) -> None:
        injection_attempted_pid: int | None = None
        while not self.stop_event.is_set():
            pid = frida_hid_tap_runtime.find_rc003_hidogatt_host_pid()
            if pid is None:
                now = time.monotonic()
                if now - self._last_wait_log >= 30.0:
                    self._last_wait_log = now
                    print("RC003 HID TAP waiting_for_rc003_host", flush=True)
                self.stop_event.wait(self.retry_delay)
                continue
            if pid != injection_attempted_pid:
                injection_attempted_pid = None

            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                server.bind(("127.0.0.1", frida_hid_tap_runtime.HID_TAP_PORT))
                server.listen(1)
                server.settimeout(1.0)
                if injection_attempted_pid is None:
                    try:
                        inject_current_process(pid)
                        injection_attempted_pid = pid
                    except Exception as exc:
                        print(
                            f"RC003 HID TAP injection retry {type(exc).__name__}: {exc}",
                            flush=True,
                        )
                        self.stop_event.wait(self.retry_delay)
                        continue
                try:
                    client, _address = server.accept()
                except socket.timeout:
                    continue
                client.settimeout(1.0)
                try:
                    print(
                        f"RC003 HID TAP ATTACHED pid={pid} awaiting_io=true",
                        flush=True,
                    )
                    buffer = b""
                    last_heartbeat = time.monotonic()
                    io_verified = False
                    announced_ready = False
                    while not self.stop_event.is_set():
                        if frida_hid_tap_runtime.find_rc003_hidogatt_host_pid() != pid:
                            print(f"RC003 HID TAP HOST CHANGED old_pid={pid}", flush=True)
                            injection_attempted_pid = None
                            break
                        try:
                            chunk = client.recv(65536)
                        except socket.timeout:
                            chunk = None
                        if chunk == b"":
                            break
                        if chunk:
                            buffer += chunk
                            while b"\n" in buffer:
                                line, buffer = buffer.split(b"\n", 1)
                                try:
                                    message = json.loads(line.decode("utf-8"))
                                except (UnicodeDecodeError, json.JSONDecodeError):
                                    continue
                                kind = message.get("kind")
                                if kind in {"heartbeat", "ready"}:
                                    last_heartbeat = time.monotonic()
                                elif kind == "gatt_read":
                                    raw = message.get("raw", "")
                                    try:
                                        data = bytes.fromhex(raw)
                                    except (TypeError, ValueError):
                                        data = b""
                                    if data:
                                        io_verified = True
                                        self._handle_ioctl_output(data)
                                elif kind == "error":
                                    print(
                                        f"RC003 HID TAP hook_error={message.get('message')}",
                                        flush=True,
                                    )
                        now = time.monotonic()
                        if now - last_heartbeat >= self.heartbeat_timeout:
                            print(
                                f"RC003 HID TAP UNHEALTHY pid={pid} "
                                "reason=agent_heartbeat_stale",
                                flush=True,
                            )
                            break
                        if io_verified and not announced_ready:
                            announced_ready = True
                            print(
                                f"RC003 HID TAP READY pid={pid} io_verified=true",
                                flush=True,
                            )
                finally:
                    try:
                        client.close()
                    except OSError:
                        pass
                    self._release_active()
            finally:
                server.close()
            if not self.stop_event.is_set():
                self.stop_event.wait(0.5)

    def start(self) -> bool:
        if not self.enabled:
            print("RC003 HID TAP disabled", flush=True)
            return False
        if not self.dependency_available:
            print("RC003 HID TAP unavailable verified_gadget_not_installed", flush=True)
            return False
        if self.thread is not None and self.thread.is_alive():
            return True
        self.stop_event.clear()
        self.thread = threading.Thread(
            target=self._run,
            name="rc003-hidogatt-report-tap",
            daemon=True,
        )
        self.thread.start()
        return True

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread is not None and self.thread is not threading.current_thread():
            self.thread.join(timeout=3.0)
            if self.thread.is_alive():
                raise RuntimeError("RC003 HID report tap did not stop")
        self._release_active()
        self.thread = None


class BackKeyCompatLayer(RC003HidReportTap):
    """Compatibility name retained for callers of the earlier back-only shim."""

    def __init__(
        self,
        gadget_path: Path | None = None,
        asset: ThirdPartyAsset = FRIDA_GADGET,
        report_handler: Callable[[int, bytes], None] | None = None,
    ) -> None:
        archive_path = gadget_path or gadget_archive_path()
        # Custom test assets can still use the generic descriptor without
        # changing the production pinned archive.
        self._custom_asset = asset
        super().__init__(
            report_handler or (lambda _report_id, _payload: None),
            archive_path=archive_path,
        )

    @property
    def dependency_available(self) -> bool:
        return verify_asset(self.archive_path, self._custom_asset)


def injector_main(argv: list[str] | None = None) -> int:
    from .frida_hid_tap_injector import main

    return main(argv)
