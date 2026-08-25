"""Private Windows event used to stop the running RC003 bridge cleanly.

The event is scoped to the current Windows logon session.  Only Remote Mic
knows its fixed name; signalling it cannot terminate an arbitrary process.
The bridge owns the event for its complete lifetime and the settings process
opens it only long enough to request a graceful stop.
"""

from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from dataclasses import dataclass
from enum import Enum
from typing import Optional

STOP_EVENT_NAME = r"Local\RemoteMicRC003BridgeStop-v1"

_ERROR_FILE_NOT_FOUND = 2
_EVENT_MODIFY_STATE = 0x0002
_SYNCHRONIZE = 0x00100000
_WAIT_OBJECT_0 = 0x00000000
_WAIT_TIMEOUT = 0x00000102


class BridgeControlUnavailableError(RuntimeError):
    pass


class StopRequestOutcome(Enum):
    REQUESTED = "requested"
    NOT_RUNNING = "not_running"
    FAILED = "failed"


@dataclass(frozen=True)
class StopRequestResult:
    outcome: StopRequestOutcome
    error: Optional[str] = None


def _kernel32():
    if sys.platform != "win32":
        raise BridgeControlUnavailableError("bridge control is only available on Windows")
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateEventW.argtypes = (
        wintypes.LPVOID,
        wintypes.BOOL,
        wintypes.BOOL,
        wintypes.LPCWSTR,
    )
    kernel32.CreateEventW.restype = wintypes.HANDLE
    kernel32.OpenEventW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
    kernel32.OpenEventW.restype = wintypes.HANDLE
    kernel32.SetEvent.argtypes = (wintypes.HANDLE,)
    kernel32.SetEvent.restype = wintypes.BOOL
    kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    return kernel32


class BridgeStopSignal:
    """Lifetime owner used by the bridge process."""

    def __init__(self) -> None:
        self._handle: Optional[int] = None

    def __enter__(self) -> "BridgeStopSignal":
        api = _kernel32()
        ctypes.set_last_error(0)
        raw_handle = api.CreateEventW(None, True, False, STOP_EVENT_NAME)
        if not raw_handle:
            raise BridgeControlUnavailableError(
                f"CreateEventW failed (GetLastError={ctypes.get_last_error()})"
            )
        self._handle = int(raw_handle)
        return self

    def wait(self, timeout_seconds: float = 0.250) -> bool:
        handle = self._handle
        if not handle:
            raise BridgeControlUnavailableError("bridge stop event is not open")
        timeout_ms = max(0, min(0xFFFFFFFE, int(round(timeout_seconds * 1000))))
        result = int(_kernel32().WaitForSingleObject(handle, timeout_ms))
        if result == _WAIT_OBJECT_0:
            return True
        if result == _WAIT_TIMEOUT:
            return False
        raise BridgeControlUnavailableError(f"WaitForSingleObject failed (result={result})")

    def close(self) -> None:
        handle = self._handle
        self._handle = None
        if handle and not _kernel32().CloseHandle(handle):
            raise BridgeControlUnavailableError(
                f"CloseHandle failed (GetLastError={ctypes.get_last_error()})"
            )

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


def request_bridge_stop() -> StopRequestResult:
    """Signal the current bridge, without enumerating or killing processes."""

    try:
        api = _kernel32()
    except BridgeControlUnavailableError as exc:
        return StopRequestResult(StopRequestOutcome.FAILED, str(exc))
    ctypes.set_last_error(0)
    raw_handle = api.OpenEventW(_EVENT_MODIFY_STATE, False, STOP_EVENT_NAME)
    if not raw_handle:
        error_code = ctypes.get_last_error()
        if error_code == _ERROR_FILE_NOT_FOUND:
            return StopRequestResult(StopRequestOutcome.NOT_RUNNING)
        return StopRequestResult(
            StopRequestOutcome.FAILED,
            f"OpenEventW failed (GetLastError={error_code})",
        )
    handle = int(raw_handle)
    try:
        if not api.SetEvent(handle):
            return StopRequestResult(
                StopRequestOutcome.FAILED,
                f"SetEvent failed (GetLastError={ctypes.get_last_error()})",
            )
        return StopRequestResult(StopRequestOutcome.REQUESTED)
    finally:
        api.CloseHandle(handle)


def bridge_is_running() -> bool:
    """Return whether a bridge owning the private stop event is alive."""

    api = _kernel32()
    ctypes.set_last_error(0)
    raw_handle = api.OpenEventW(_SYNCHRONIZE, False, STOP_EVENT_NAME)
    if not raw_handle:
        error_code = ctypes.get_last_error()
        if error_code == _ERROR_FILE_NOT_FOUND:
            return False
        raise BridgeControlUnavailableError(
            f"OpenEventW failed (GetLastError={error_code})"
        )
    api.CloseHandle(int(raw_handle))
    return True
