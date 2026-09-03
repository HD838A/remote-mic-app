"""Temporary broad Raw Input probe for the RC003 keyboard collection.

The normal listener intentionally scopes and decodes only translated keyboard
events.  This probe registers usage pages in page-only mode and records the
complete WM_INPUT payload for the RC003 path, including any event that the
normal decoder would classify as unknown.  It is passive and never injects or
suppresses input.
"""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import struct
import threading
import time
import uuid
from ctypes import wintypes

from ovb_rc003 import hid_identity


WM_DESTROY = 0x0002
WM_CLOSE = 0x0010
WM_INPUT = 0x00FF
HWND_MESSAGE = -3
RIDEV_INPUTSINK = 0x00000100
RIDEV_PAGEONLY = 0x00000020
RIDEV_REMOVE = 0x00000001
RID_INPUT = 0x10000003
RIDI_DEVICENAME = 0x20000007
RIM_TYPEKEYBOARD = 1
RIM_TYPEHID = 2
PM_REMOVE = 0x0001
WM_QUIT = 0x0012


class RawInputDeviceList(ctypes.Structure):
    _fields_ = [("hDevice", wintypes.HANDLE), ("dwType", wintypes.DWORD)]


class Writer:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = path.open("a", encoding="utf-8", buffering=1)
        self.lock = threading.Lock()

    def write(self, kind: str, **fields: object) -> None:
        record = {
            "time": datetime.now(timezone.utc).astimezone().isoformat(
                timespec="milliseconds"
            ),
            "kind": kind,
            **fields,
        }
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        with self.lock:
            try:
                print(line, flush=True)
            except UnicodeEncodeError:
                print(
                    line.encode("ascii", "backslashreplace").decode("ascii"),
                    flush=True,
                )
            self.handle.write(line + "\n")

    def close(self) -> None:
        with self.lock:
            self.handle.close()


def _device_name(user32, handle) -> str | None:
    size = wintypes.UINT(0)
    user32.GetRawInputDeviceInfoW(handle, RIDI_DEVICENAME, None, ctypes.byref(size))
    if not size.value:
        return None
    buffer = ctypes.create_unicode_buffer(size.value)
    written = user32.GetRawInputDeviceInfoW(
        handle, RIDI_DEVICENAME, buffer, ctypes.byref(size)
    )
    if written in (0, 0xFFFFFFFF):
        return None
    return buffer.value


def _enumerate_rc003_paths(user32) -> list[str]:
    count = wintypes.UINT(0)
    user32.GetRawInputDeviceList(
        None, ctypes.byref(count), ctypes.sizeof(RawInputDeviceList)
    )
    items = (RawInputDeviceList * count.value)()
    written = user32.GetRawInputDeviceList(
        items, ctypes.byref(count), ctypes.sizeof(RawInputDeviceList)
    )
    paths: list[str] = []
    for index in range(int(written)):
        path = _device_name(user32, items[index].hDevice)
        if path and hid_identity.device_path_matches_rc003(path):
            paths.append(path)
    return paths


def _read_raw_input(user32, lparam: int) -> tuple[int, str | None, bytes] | None:
    class Header(ctypes.Structure):
        _fields_ = [
            ("dwType", wintypes.DWORD),
            ("dwSize", wintypes.DWORD),
            ("hDevice", wintypes.HANDLE),
            ("wParam", wintypes.WPARAM),
        ]

    size = wintypes.UINT(0)
    user32.GetRawInputData(
        lparam, RID_INPUT, None, ctypes.byref(size), ctypes.sizeof(Header)
    )
    if not size.value:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    written = user32.GetRawInputData(
        lparam, RID_INPUT, buffer, ctypes.byref(size), ctypes.sizeof(Header)
    )
    if written != size.value:
        return None
    header = Header.from_buffer_copy(buffer, 0)
    path = _device_name(user32, header.hDevice)
    body = bytes(buffer.raw[ctypes.sizeof(Header) :])
    return int(header.dwType), path, body


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=180)
    parser.add_argument(
        "--all-devices",
        action="store_true",
        help="also print raw input from non-RC003 device paths for diagnosis",
    )
    parser.add_argument(
        "--include-mouse",
        action="store_true",
        help="include non-RC003 mouse input when --all-devices is enabled",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))
        )
        / "RemoteMic"
        / "RC003"
        / "logs"
        / "broad-raw-probe.jsonl",
    )
    args = parser.parse_args()
    writer = Writer(args.output)
    stop = threading.Event()
    counts = {"parsed": 0, "rc003": 0}
    class_name = f"RemoteMicRC003BroadRaw-{uuid.uuid4().hex}"
    registered = False
    hwnd = None
    try:
        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        user32.GetRawInputDeviceList.argtypes = (
            ctypes.POINTER(RawInputDeviceList),
            ctypes.POINTER(wintypes.UINT),
            wintypes.UINT,
        )
        user32.GetRawInputDeviceList.restype = ctypes.c_uint
        user32.GetRawInputDeviceInfoW.argtypes = (
            wintypes.HANDLE,
            wintypes.UINT,
            wintypes.LPVOID,
            ctypes.POINTER(wintypes.UINT),
        )
        user32.GetRawInputDeviceInfoW.restype = ctypes.c_uint
        user32.GetRawInputData.argtypes = (
            wintypes.HANDLE,
            wintypes.UINT,
            wintypes.LPVOID,
            ctypes.POINTER(wintypes.UINT),
            wintypes.UINT,
        )
        user32.GetRawInputData.restype = ctypes.c_uint
        lresult = ctypes.c_ssize_t
        wndproc_type = ctypes.WINFUNCTYPE(
            lresult,
            wintypes.HWND,
            wintypes.UINT,
            wintypes.WPARAM,
            wintypes.LPARAM,
        )

        class WNDCLASSW(ctypes.Structure):
            _fields_ = [
                ("style", wintypes.UINT),
                ("lpfnWndProc", wndproc_type),
                ("cbClsExtra", ctypes.c_int),
                ("cbWndExtra", ctypes.c_int),
                ("hInstance", wintypes.HINSTANCE),
                ("hIcon", wintypes.HICON),
                ("hCursor", wintypes.HANDLE),
                ("hbrBackground", wintypes.HBRUSH),
                ("lpszMenuName", wintypes.LPCWSTR),
                ("lpszClassName", wintypes.LPCWSTR),
            ]

        user32.RegisterClassW.argtypes = (ctypes.POINTER(WNDCLASSW),)
        user32.RegisterClassW.restype = wintypes.ATOM
        user32.CreateWindowExW.argtypes = (
            wintypes.DWORD,
            wintypes.LPCWSTR,
            wintypes.LPCWSTR,
            wintypes.DWORD,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            wintypes.HWND,
            wintypes.HMENU,
            wintypes.HINSTANCE,
            wintypes.LPVOID,
        )
        user32.CreateWindowExW.restype = wintypes.HWND
        user32.RegisterRawInputDevices.argtypes = (
            ctypes.c_void_p,
            wintypes.UINT,
            wintypes.UINT,
        )
        user32.RegisterRawInputDevices.restype = wintypes.BOOL
        user32.GetMessageW.argtypes = (
            ctypes.POINTER(wintypes.MSG),
            wintypes.HWND,
            wintypes.UINT,
            wintypes.UINT,
        )
        user32.GetMessageW.restype = ctypes.c_int
        user32.DefWindowProcW.argtypes = (
            wintypes.HWND,
            wintypes.UINT,
            wintypes.WPARAM,
            wintypes.LPARAM,
        )
        user32.DefWindowProcW.restype = ctypes.c_ssize_t
        user32.PeekMessageW.argtypes = (
            ctypes.POINTER(wintypes.MSG),
            wintypes.HWND,
            wintypes.UINT,
            wintypes.UINT,
            wintypes.UINT,
        )
        user32.PeekMessageW.restype = wintypes.BOOL
        user32.TranslateMessage.argtypes = (ctypes.POINTER(wintypes.MSG),)
        user32.DispatchMessageW.argtypes = (ctypes.POINTER(wintypes.MSG),)
        user32.DestroyWindow.argtypes = (wintypes.HWND,)
        user32.DestroyWindow.restype = wintypes.BOOL
        user32.PostQuitMessage.argtypes = (ctypes.c_int,)
        user32.PostMessageW.argtypes = (
            wintypes.HWND,
            wintypes.UINT,
            wintypes.WPARAM,
            wintypes.LPARAM,
        )
        user32.PostMessageW.restype = wintypes.BOOL

        def callback(window, message, wparam, lparam):
            if message == WM_INPUT:
                parsed = _read_raw_input(user32, lparam)
                if parsed is not None:
                    raw_type, path, body = parsed
                    counts["parsed"] += 1
                    is_rc003 = bool(
                        path and hid_identity.device_path_matches_rc003(path)
                    )
                    if is_rc003:
                        counts["rc003"] += 1
                    include_event = is_rc003 or (
                        args.all_devices
                        and (raw_type != RIM_TYPEMOUSE or args.include_mouse)
                    )
                    if include_event:
                        counts["written"] = counts.get("written", 0) + 1
                        fields: dict[str, object] = {
                            "raw_type": raw_type,
                            "path": path or "<unresolved>",
                            "rc003": is_rc003,
                            "body": body.hex(" "),
                        }
                        if raw_type == RIM_TYPEKEYBOARD and len(body) >= 16:
                            make, flags, _reserved, vkey, message_code, extra = struct.unpack_from(
                                "<HHHHII", body, 0
                            )
                            fields.update(
                                {
                                    "make": f"0x{make:04X}",
                                    "flags": f"0x{flags:04X}",
                                    "vkey": f"0x{vkey:04X}",
                                    "message": f"0x{message_code:04X}",
                                    "extra": f"0x{extra:08X}",
                                }
                            )
                        writer.write("raw_input", **fields)
                return 0
            if message == WM_CLOSE:
                user32.DestroyWindow(window)
                return 0
            if message == WM_DESTROY:
                user32.PostQuitMessage(0)
                return 0
            return user32.DefWindowProcW(window, message, wparam, lparam)

        wndproc = wndproc_type(callback)
        instance = kernel32.GetModuleHandleW(None)
        window_class = WNDCLASSW(
            style=0,
            lpfnWndProc=wndproc,
            cbClsExtra=0,
            cbWndExtra=0,
            hInstance=instance,
            hIcon=None,
            hCursor=None,
            hbrBackground=None,
            lpszMenuName=None,
            lpszClassName=class_name,
        )
        if not user32.RegisterClassW(ctypes.byref(window_class)):
            raise ctypes.WinError()
        hwnd = user32.CreateWindowExW(
            0,
            class_name,
            class_name,
            0,
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            None,
            instance,
            None,
        )
        if not hwnd:
            raise ctypes.WinError()

        class RawInputDevice(ctypes.Structure):
            _fields_ = [
                ("usUsagePage", wintypes.USHORT),
                ("usUsage", wintypes.USHORT),
                ("dwFlags", wintypes.DWORD),
                ("hwndTarget", wintypes.HWND),
            ]

        devices = (RawInputDevice * 3)()
        for index, page in enumerate((0x01, 0x07, 0x0C)):
            devices[index] = RawInputDevice(
                usUsagePage=page,
                usUsage=0,
                dwFlags=RIDEV_PAGEONLY | RIDEV_INPUTSINK,
                hwndTarget=hwnd,
            )
        if not user32.RegisterRawInputDevices(
            devices, len(devices), ctypes.sizeof(RawInputDevice)
        ):
            raise ctypes.WinError()
        registered = True
        paths = _enumerate_rc003_paths(user32)
        writer.write(
            "ready",
            rc003_paths=paths,
            text=(
                "请按一次返回、音量+、音量-和一个已知正常按键；"
                "记录完整 WM_INPUT，不执行映射。"
            ),
            all_devices=args.all_devices,
            include_mouse=args.include_mouse,
        )
        deadline = time.monotonic() + max(1.0, args.seconds)
        message = wintypes.MSG()
        while time.monotonic() < deadline and not stop.is_set():
            while user32.PeekMessageW(
                ctypes.byref(message), None, 0, 0, PM_REMOVE
            ):
                if message.message == WM_QUIT:
                    stop.set()
                    break
                user32.TranslateMessage(ctypes.byref(message))
                user32.DispatchMessageW(ctypes.byref(message))
            if not stop.is_set():
                time.sleep(0.01)
    except KeyboardInterrupt:
        pass
    except BaseException as exc:  # noqa: BLE001 - diagnostic process
        writer.write("error", error=f"{type(exc).__name__}: {exc}")
        return 1
    finally:
        if registered:
            try:
                # RIDEV_REMOVE requires the same usage pairs with no target window.
                remove_devices = (RawInputDevice * 3)()
                for index, page in enumerate((0x01, 0x07, 0x0C)):
                    remove_devices[index] = RawInputDevice(
                        usUsagePage=page,
                        usUsage=0,
                        dwFlags=RIDEV_REMOVE,
                        hwndTarget=None,
                    )
                user32.RegisterRawInputDevices(
                    remove_devices,
                    len(remove_devices),
                    ctypes.sizeof(RawInputDevice),
                )
            except Exception:
                pass
        if hwnd:
            try:
                user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
            except Exception:
                pass
        writer.write(
            "summary",
            parsed_raw_input=counts["parsed"],
            rc003_raw_input=counts["rc003"],
            written_raw_input=counts.get("written", 0),
        )
        writer.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
