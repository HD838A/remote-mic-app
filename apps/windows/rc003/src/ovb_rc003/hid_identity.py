"""RC003 HID identity matching and button-report decoding.

Pure protocol/string logic, no Windows API calls, so it is unit-testable
everywhere. The actual Raw Input / hidapi plumbing lives in
raw_input_windows.py (Windows-only, guarded import).

Report shape (9 bytes: 3-byte HID-over-GATT report-id prefix + 6 bytes of
three little-endian uint16 Keyboard-page usage slots, zero = empty slot) and
the "back" button's Windows compatibility gap are documented in this
package's top-level README.md "Known gaps" section, informed by the
upstream reference (see device_profile.py module docstring for citation).
"""

from __future__ import annotations

from typing import FrozenSet, Optional, Sequence, Tuple

from . import device_profile

REPORT_LENGTH = 9
_REPORT_PREFIX = bytes((0x01, 0x00, 0x00))
_REPORT_ID = 0x01


class HidIdentityError(Exception):
    """Base class for HID device-path resolution failures. All fail closed."""


class NoDevicePathFoundError(HidIdentityError):
    """No connected HID device path matched the RC003 VID/PID at all."""


class AmbiguousDevicePathError(HidIdentityError):
    """More than one matching HID device path was found; refusing to guess
    which one is the RC003 the user actually wants (mirrors
    identity.AmbiguousCandidateError's fail-closed policy at the BLE layer -
    see XRBM-014 review RETRY P1 #5: this replaces the previous
    "return the first match" behavior).
    """

    def __init__(self, count: int):
        super().__init__(
            f"{count} RC003 HID device paths found; keep only one connected and retry"
        )
        self.count = count


def select_single_device_path(paths: Sequence[str]) -> str:
    """Return the sole RC003-matching device path, or fail closed.

    Zero matches -> NoDevicePathFoundError. Two or more -> always
    AmbiguousDevicePathError, never "pick the first" - callers must not
    silently choose among ambiguous physical devices.
    """

    matches = [path for path in paths if device_path_matches_rc003(path)]
    if not matches:
        raise NoDevicePathFoundError("no RC003 HID device path was found")
    if len(matches) > 1:
        raise AmbiguousDevicePathError(len(matches))
    return matches[0]


def device_path_matches_rc003(device_interface_path: str) -> bool:
    """Check a Windows HID device interface path (e.g. from
    GetRawInputDeviceInfoW/RIDI_DEVICENAME or hidapi's ``path``) for the
    RC003 VID/PID, case-insensitively. Windows uses both the classic
    ``VID_2717&PID_32B8`` spelling and the BLE HID collection spelling
    ``Dev_VID&012717_PID&32B8``.
    """

    low = device_interface_path.lower()
    classic_vid_token = f"vid_{device_profile.HID_VENDOR_ID:04x}"
    classic_pid_token = f"pid_{device_profile.HID_PRODUCT_ID:04x}"
    if classic_vid_token in low and classic_pid_token in low:
        return True

    # BLE HID collections are exposed by Windows as ``Dev_VID`` followed by
    # the device-id vendor token (the RC003 uses the observed ``012717``
    # spelling), then ``PID`` with the product token. Keep the prefix and
    # both tokens together so an unrelated HID path cannot match by
    # containing a VID and PID in separate components.
    ble_vid_tokens = (
        f"dev_vid&{device_profile.HID_VENDOR_ID:06x}",
        f"dev_vid&01{device_profile.HID_VENDOR_ID:04x}",
    )
    ble_pid_token = f"pid&{device_profile.HID_PRODUCT_ID:04x}"
    return any(token in low for token in ble_vid_tokens) and ble_pid_token in low


def normalize_device_path(device_interface_path: str) -> str:
    """Normalize a Windows device interface path for exact equality
    comparison (XRBM-018: raw_input_windows.py's per-event device-scoping
    gate).

    ``GetRawInputDeviceInfoW``/``RIDI_DEVICENAME`` is documented to return
    the same physical device's path with consistent characters across
    calls, but Windows device interface paths are case-insensitive by
    contract; normalizing before comparison keeps the per-event gate a
    correct case-insensitive equality check on the exact string
    ``select_single_device_path`` already fail-closed-selected, rather than
    a looser VID/PID substring re-check that a second matching device could
    also satisfy.
    """

    return device_interface_path.strip().lower()


def decode_report_usages(report: bytes) -> FrozenSet[int]:
    """Decode an RC003 report into all currently-active usage IDs.

    Windows Raw Input has been observed with both the three-byte report
    prefix used by the original adapter (``01 00 00`` + six payload bytes)
    and the compact HID form (report ID ``01`` + six payload bytes). Accept
    the compact six-byte payload as well so capture/replay preserves the
    report shape instead of forcing a guessed normalization at the caller.
    Unknown usages are intentionally retained here; the physical learning
    path needs to show them instead of silently treating the report as empty.

    Each report is an absolute snapshot of up to three concurrently-pressed
    buttons, not a discrete edge event; ``diff_usages`` below derives edges
    across two snapshots.
    """

    if len(report) == REPORT_LENGTH and report[:3] == _REPORT_PREFIX:
        payload = report[3:]
    elif len(report) == 7 and report[0] == _REPORT_ID:
        payload = report[1:]
    elif len(report) == 6:
        payload = report
    else:
        raise ValueError(
            "expected a 6-byte payload, 7-byte report-id form, or "
            f"{REPORT_LENGTH}-byte RC003 report, got {report!r}"
        )

    active = set()
    for slot in range(3):
        usage = int.from_bytes(payload[slot * 2 : slot * 2 + 2], "little")
        if usage != 0:
            active.add(usage)
    return frozenset(active)


def decode_active_usages(report: bytes) -> FrozenSet[int]:
    """Decode a report into the known RC003 usage IDs.

    This compatibility wrapper keeps the action path fail-closed while
    :func:`decode_report_usages` remains available to diagnostics and replay.
    """

    return frozenset(
        usage
        for usage in decode_report_usages(report)
        if usage in device_profile.BUTTON_USAGE_IDS
    )


def diff_usages(
    previous: FrozenSet[int], current: FrozenSet[int]
) -> Tuple[FrozenSet[int], FrozenSet[int]]:
    """Return (pressed, released) usage-ID sets between two snapshots."""

    pressed = current - previous
    released = previous - current
    return frozenset(pressed), frozenset(released)


def usage_to_button(usage: int) -> Optional[str]:
    return device_profile.BUTTON_USAGE_IDS.get(usage)


def parse_rawinput_hid_payload(raw_body: bytes) -> Tuple[bytes, ...]:
    """Split a Windows ``RAWHID`` structure body into its individual reports.

    The ``RAWHID`` struct (delivered inside a ``RAWINPUT`` when
    ``header.dwType == RIM_TYPEHID``) is laid out as:
    ``dwSizeHid: uint32 LE`` (bytes 0-3), ``dwCount: uint32 LE`` (bytes 4-7),
    followed by ``dwSizeHid * dwCount`` raw report bytes starting at offset 8
    - see raw_input_windows.py for where this is fed real bytes from
    ``GetRawInputData``. Kept as a pure function, independent of any ctypes
    call, so it is unit-testable with synthetic buffers on any OS.
    """

    if len(raw_body) < 8:
        raise ValueError(f"RAWHID body too short: {len(raw_body)} bytes")

    size_hid = int.from_bytes(raw_body[0:4], "little")
    count = int.from_bytes(raw_body[4:8], "little")
    expected_length = 8 + size_hid * count
    if size_hid <= 0 or count < 0 or len(raw_body) < expected_length:
        raise ValueError(
            f"RAWHID body truncated: dwSizeHid={size_hid} dwCount={count} "
            f"but only {len(raw_body)} bytes available"
        )

    reports = []
    offset = 8
    for _ in range(count):
        reports.append(bytes(raw_body[offset : offset + size_hid]))
        offset += size_hid
    return tuple(reports)
