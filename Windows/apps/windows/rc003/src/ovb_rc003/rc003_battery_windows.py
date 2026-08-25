"""Read the RC003 battery percentage from the Windows device node.

Windows Settings exposes the remote's battery on the paired BTHLE device as
the standard Bluetooth battery DEVPROPKEY.  The WinRT BLE selector used by
the transport does not expose that property on this machine, so this module
uses SetupAPI directly.  It returns only a percentage: device instance paths,
Bluetooth addresses and other identifiers never leave this boundary.
"""

from __future__ import annotations

import ctypes
import sys
import uuid
from ctypes import wintypes
from typing import Callable, Iterable, Optional, Sequence, Tuple

from . import device_profile


class GUID(ctypes.Structure):
    _fields_ = [
        ("Data1", wintypes.DWORD),
        ("Data2", wintypes.WORD),
        ("Data3", wintypes.WORD),
        ("Data4", wintypes.BYTE * 8),
    ]


class DEVPROPKEY(ctypes.Structure):
    _fields_ = [("fmtid", GUID), ("pid", wintypes.DWORD)]


class SP_DEVINFO_DATA(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("ClassGuid", GUID),
        ("DevInst", wintypes.DWORD),
        ("Reserved", ctypes.c_size_t),
    ]


_DIGCF_PRESENT = 0x00000002
_DIGCF_ALLCLASSES = 0x00000004
_SPDRP_FRIENDLYNAME = 0x0000000C
_SPDRP_DEVICEDESC = 0x00000000
_ERROR_NO_MORE_ITEMS = 259
_DEVPROP_TYPE_BYTE = 0x00000003
_BATTERY_PROPERTY = DEVPROPKEY()
ctypes.memmove(
    ctypes.byref(_BATTERY_PROPERTY.fmtid),
    uuid.UUID("104ea319-6ee2-4701-bd47-8ddbf425bbe5").bytes_le,
    ctypes.sizeof(GUID),
)
_BATTERY_PROPERTY.pid = 2


class BatteryProbeUnavailableError(RuntimeError):
    """Raised when the Windows device-property API cannot be used."""


def _normalize_name(value: str) -> str:
    return " ".join(value.split()).casefold()


def _select_battery_percent(
    rows: Iterable[Tuple[str, Optional[int]]],
) -> Optional[int]:
    """Return one unambiguous RC003 percentage from sanitized device rows."""

    accepted_names = {_normalize_name(name) for name in device_profile.BLUETOOTH_NAMES}
    values = {
        int(value)
        for name, value in rows
        if _normalize_name(name) in accepted_names
        and value is not None
        and 0 <= int(value) <= 100
    }
    return next(iter(values)) if len(values) == 1 else None


def read_rc003_battery_percent(
    *,
    enumerate_rows: Optional[Callable[[], Sequence[Tuple[str, Optional[int]]]]] = None,
) -> Optional[int]:
    """Return 0..100 for the paired RC003, or ``None`` when unavailable."""

    if enumerate_rows is None:
        enumerate_rows = _enumerate_device_rows
    return _select_battery_percent(enumerate_rows())


def _enumerate_device_rows() -> Sequence[Tuple[str, Optional[int]]]:
    if sys.platform != "win32":
        raise BatteryProbeUnavailableError("RC003 battery is only available on Windows")

    setupapi = ctypes.WinDLL("setupapi", use_last_error=True)
    setupapi.SetupDiGetClassDevsW.argtypes = (
        ctypes.POINTER(GUID),
        wintypes.LPCWSTR,
        wintypes.HWND,
        wintypes.DWORD,
    )
    setupapi.SetupDiGetClassDevsW.restype = wintypes.HANDLE
    setupapi.SetupDiEnumDeviceInfo.argtypes = (
        wintypes.HANDLE,
        wintypes.DWORD,
        ctypes.POINTER(SP_DEVINFO_DATA),
    )
    setupapi.SetupDiEnumDeviceInfo.restype = wintypes.BOOL
    setupapi.SetupDiGetDeviceRegistryPropertyW.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(SP_DEVINFO_DATA),
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(wintypes.BYTE),
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
    )
    setupapi.SetupDiGetDeviceRegistryPropertyW.restype = wintypes.BOOL
    setupapi.SetupDiGetDevicePropertyW.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(SP_DEVINFO_DATA),
        ctypes.POINTER(DEVPROPKEY),
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(wintypes.BYTE),
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        wintypes.DWORD,
    )
    setupapi.SetupDiGetDevicePropertyW.restype = wintypes.BOOL
    setupapi.SetupDiDestroyDeviceInfoList.argtypes = (wintypes.HANDLE,)
    setupapi.SetupDiDestroyDeviceInfoList.restype = wintypes.BOOL

    device_set = setupapi.SetupDiGetClassDevsW(
        None, None, None, _DIGCF_PRESENT | _DIGCF_ALLCLASSES
    )
    invalid_handle = ctypes.c_void_p(-1).value
    if device_set in (None, invalid_handle):
        raise BatteryProbeUnavailableError("Windows could not open the device set")

    rows = []
    try:
        index = 0
        while True:
            info = SP_DEVINFO_DATA(cbSize=ctypes.sizeof(SP_DEVINFO_DATA))
            if not setupapi.SetupDiEnumDeviceInfo(device_set, index, ctypes.byref(info)):
                if ctypes.get_last_error() == _ERROR_NO_MORE_ITEMS:
                    break
                raise BatteryProbeUnavailableError("Windows device enumeration failed")
            index += 1

            name = _read_device_name(setupapi, device_set, info)
            if not name:
                continue
            if _normalize_name(name) not in {
                _normalize_name(item) for item in device_profile.BLUETOOTH_NAMES
            }:
                continue
            rows.append((name, _read_battery_value(setupapi, device_set, info)))
    finally:
        setupapi.SetupDiDestroyDeviceInfoList(device_set)
    return rows


def _read_device_name(setupapi, device_set, info: SP_DEVINFO_DATA) -> str:
    for property_id in (_SPDRP_FRIENDLYNAME, _SPDRP_DEVICEDESC):
        buffer = ctypes.create_unicode_buffer(256)
        registry_type = wintypes.DWORD()
        required = wintypes.DWORD()
        if setupapi.SetupDiGetDeviceRegistryPropertyW(
            device_set,
            ctypes.byref(info),
            property_id,
            ctypes.byref(registry_type),
            ctypes.cast(buffer, ctypes.POINTER(wintypes.BYTE)),
            ctypes.sizeof(buffer),
            ctypes.byref(required),
        ):
            return buffer.value
    return ""


def _read_battery_value(setupapi, device_set, info: SP_DEVINFO_DATA) -> Optional[int]:
    value = wintypes.BYTE()
    property_type = wintypes.DWORD()
    required = wintypes.DWORD()
    if not setupapi.SetupDiGetDevicePropertyW(
        device_set,
        ctypes.byref(info),
        ctypes.byref(_BATTERY_PROPERTY),
        ctypes.byref(property_type),
        ctypes.byref(value),
        ctypes.sizeof(value),
        ctypes.byref(required),
        0,
    ):
        return None
    if property_type.value != _DEVPROP_TYPE_BYTE or not 0 <= value.value <= 100:
        return None
    return int(value.value)
