"""仅监听小米 RC003 的 Windows Raw Input 按键边沿。"""

from __future__ import annotations

import ctypes
import sys
import threading
from ctypes import wintypes
from typing import Callable

from . import hid_identity

RIM_TYPEKEYBOARD = 1
RIM_TYPEHID = 2
RID_INPUT = 0x10000003
RIDI_DEVICENAME = 0x20000007
WM_INPUT = 0x00FF
WM_CLOSE = 0x0010
WM_DESTROY = 0x0002
RIDEV_INPUTSINK = 0x00000100
RI_KEY_BREAK = 0x0001
HWND_MESSAGE = -3

VK_TO_BUTTON = {
    0x74: "mic",
    0x27: "right",
    0x25: "left",
    0x28: "down",
    0x26: "up",
    0x0D: "ok",
    0x24: "home",
    0x5D: "menu",
    0xC0: "tv",
    0x5F: "power",
    0xAD: "volume_mute",
    0xAF: "volume_up",
    0xAE: "volume_down",
}

MAKE_CODE_TO_BUTTON = {
    0x5E: "power",
    0x6A: "back",
    0x30: "volume_up",
    0x2E: "volume_down",
    0x20: "volume_mute",
}


class RAWINPUTHEADER(ctypes.Structure):
    _fields_ = [
        ("dwType", wintypes.DWORD),
        ("dwSize", wintypes.DWORD),
        ("hDevice", wintypes.HANDLE),
        ("wParam", wintypes.WPARAM),
    ]


class RAWKEYBOARD(ctypes.Structure):
    _fields_ = [
        ("MakeCode", wintypes.USHORT),
        ("Flags", wintypes.USHORT),
        ("Reserved", wintypes.USHORT),
        ("VKey", wintypes.USHORT),
        ("Message", wintypes.UINT),
        ("ExtraInformation", wintypes.ULONG),
    ]


class RAWHID(ctypes.Structure):
    _fields_ = [
        ("dwSizeHid", wintypes.DWORD),
        ("dwCount", wintypes.DWORD),
        ("bRawData", ctypes.c_ubyte * 1),
    ]


class _RAWINPUTDATA(ctypes.Union):
    _fields_ = [("keyboard", RAWKEYBOARD), ("hid", RAWHID)]


class RAWINPUT(ctypes.Structure):
    _fields_ = [("header", RAWINPUTHEADER), ("data", _RAWINPUTDATA)]


class RAWINPUTDEVICE(ctypes.Structure):
    _fields_ = [
        ("usUsagePage", wintypes.USHORT),
        ("usUsage", wintypes.USHORT),
        ("dwFlags", wintypes.DWORD),
        ("hwndTarget", wintypes.HWND),
    ]


class RawInputUnavailableError(RuntimeError):
    pass


def device_path_matches_rc003(path: str) -> bool:
    return hid_identity.device_path_matches_rc003(path)


def keyboard_button(vkey: int, make_code: int) -> str | None:
    return VK_TO_BUTTON.get(vkey) or MAKE_CODE_TO_BUTTON.get(make_code)


class RawInputListener:
    """在消息窗口线程中接收 RC003 按键，回调 ``(button_id, pressed)``。"""

    def __init__(self, callback: Callable[[str, bool], None]) -> None:
        self._callback = callback
        self._thread: threading.Thread | None = None
        self._ready = threading.Event()
        self._window_handle = 0
        self._startup_error: BaseException | None = None
        self._hid_active: dict[int, set[str]] = {}
        self._window_proc = None

    def start(self) -> None:
        if sys.platform != "win32":
            raise RawInputUnavailableError("Raw Input 仅可在 Windows 上使用")
        if self._thread is not None:
            return
        self._ready.clear()
        self._startup_error = None
        self._thread = threading.Thread(
            target=self._message_loop,
            name="rc003-raw-input",
            daemon=True,
        )
        self._thread.start()
        if not self._ready.wait(5.0):
            raise RawInputUnavailableError("Raw Input 消息窗口启动超时")
        if self._startup_error is not None:
            error = self._startup_error
            self._thread = None
            raise RawInputUnavailableError(f"Raw Input 启动失败：{error}") from error

    def stop(self) -> None:
        thread = self._thread
        if thread is None:
            return
        if self._window_handle and sys.platform == "win32":
            ctypes.windll.user32.PostMessageW(self._window_handle, WM_CLOSE, 0, 0)  # type: ignore[attr-defined]
        thread.join(timeout=2.0)
        self._thread = None
        self._window_handle = 0
        self._hid_active.clear()

    def _message_loop(self) -> None:
        try:
            user32 = ctypes.windll.user32  # type: ignore[attr-defined]
            kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
            wndproc_type = ctypes.WINFUNCTYPE(
                ctypes.c_ssize_t,
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

            class MSG(ctypes.Structure):
                _fields_ = [
                    ("hwnd", wintypes.HWND),
                    ("message", wintypes.UINT),
                    ("wParam", wintypes.WPARAM),
                    ("lParam", wintypes.LPARAM),
                    ("time", wintypes.DWORD),
                    ("pt", wintypes.POINT),
                    ("lPrivate", wintypes.DWORD),
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
            user32.DefWindowProcW.argtypes = (
                wintypes.HWND,
                wintypes.UINT,
                wintypes.WPARAM,
                wintypes.LPARAM,
            )
            user32.DefWindowProcW.restype = ctypes.c_ssize_t
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
            user32.RegisterRawInputDevices.argtypes = (
                ctypes.POINTER(RAWINPUTDEVICE),
                wintypes.UINT,
                wintypes.UINT,
            )
            user32.RegisterRawInputDevices.restype = wintypes.BOOL
            user32.GetRawInputData.argtypes = (
                wintypes.HANDLE,
                wintypes.UINT,
                wintypes.LPVOID,
                ctypes.POINTER(wintypes.UINT),
                wintypes.UINT,
            )
            user32.GetRawInputData.restype = wintypes.UINT
            user32.GetRawInputDeviceInfoW.argtypes = (
                wintypes.HANDLE,
                wintypes.UINT,
                wintypes.LPVOID,
                ctypes.POINTER(wintypes.UINT),
            )
            user32.GetRawInputDeviceInfoW.restype = wintypes.UINT
            user32.GetMessageW.argtypes = (
                ctypes.POINTER(MSG),
                wintypes.HWND,
                wintypes.UINT,
                wintypes.UINT,
            )
            user32.GetMessageW.restype = wintypes.BOOL
            user32.TranslateMessage.argtypes = (ctypes.POINTER(MSG),)
            user32.DispatchMessageW.argtypes = (ctypes.POINTER(MSG),)
            user32.DispatchMessageW.restype = ctypes.c_ssize_t
            user32.UnregisterClassW.argtypes = (wintypes.LPCWSTR, wintypes.HINSTANCE)
            user32.UnregisterClassW.restype = wintypes.BOOL
            kernel32.GetModuleHandleW.argtypes = (wintypes.LPCWSTR,)
            kernel32.GetModuleHandleW.restype = wintypes.HINSTANCE

            def window_proc(hwnd, message, wparam, lparam):
                if message == WM_INPUT:
                    self._handle_input(lparam)
                elif message == WM_CLOSE:
                    user32.DestroyWindow(hwnd)
                    return 0
                elif message == WM_DESTROY:
                    user32.PostQuitMessage(0)
                    return 0
                return user32.DefWindowProcW(hwnd, message, wparam, lparam)

            self._window_proc = wndproc_type(window_proc)
            class_name = f"RemoteMicRC003RawInput{id(self):x }"
            instance = kernel32.GetModuleHandleW(None)
            window_class = WNDCLASSW(
                0,
                self._window_proc,
                0,
                0,
                instance,
                None,
                None,
                None,
                None,
                class_name,
            )
            atom = user32.RegisterClassW(ctypes.byref(window_class))
            if not atom:
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
                wintypes.HWND(HWND_MESSAGE),
                None,
                instance,
                None,
            )
            if not hwnd:
                raise ctypes.WinError()
            self._window_handle = int(hwnd)
            devices = (RAWINPUTDEVICE * 2)(
                RAWINPUTDEVICE(0x01, 0x06, RIDEV_INPUTSINK, hwnd),
                RAWINPUTDEVICE(0x0C, 0x01, RIDEV_INPUTSINK, hwnd),
            )
            if not user32.RegisterRawInputDevices(
                devices, len(devices), ctypes.sizeof(RAWINPUTDEVICE)
            ):
                raise ctypes.WinError()
            self._ready.set()
            message = MSG()
            while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
                user32.TranslateMessage(ctypes.byref(message))
                user32.DispatchMessageW(ctypes.byref(message))
            user32.UnregisterClassW(class_name, instance)
        except BaseException as exc:  # noqa: BLE001 - reported to starter
            self._startup_error = exc
            self._ready.set()

    def _device_path(self, device_handle: int) -> str:
        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        size = wintypes.UINT(0)
        user32.GetRawInputDeviceInfoW(
            device_handle, RIDI_DEVICENAME, None, ctypes.byref(size)
        )
        if size.value == 0:
            return ""
        buffer = ctypes.create_unicode_buffer(size.value + 1)
        result = user32.GetRawInputDeviceInfoW(
            device_handle, RIDI_DEVICENAME, buffer, ctypes.byref(size)
        )
        return "" if result == 0xFFFFFFFF else buffer.value

    def _handle_input(self, raw_handle: int) -> None:
        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        size = wintypes.UINT(0)
        header_size = ctypes.sizeof(RAWINPUTHEADER)
        if (
            user32.GetRawInputData(
                raw_handle, RID_INPUT, None, ctypes.byref(size), header_size
            )
            != 0
        ):
            return
        buffer = ctypes.create_string_buffer(size.value)
        if (
            user32.GetRawInputData(
                raw_handle, RID_INPUT, buffer, ctypes.byref(size), header_size
            )
            != size.value
        ):
            return
        raw = ctypes.cast(buffer, ctypes.POINTER(RAWINPUT)).contents
        device_handle = int(raw.header.hDevice or 0)
        if not device_path_matches_rc003(self._device_path(device_handle)):
            return
        if raw.header.dwType == RIM_TYPEKEYBOARD:
            keyboard = raw.data.keyboard
            button_id = keyboard_button(int(keyboard.VKey), int(keyboard.MakeCode))
            if button_id is not None:
                self._callback(button_id, not bool(keyboard.Flags & RI_KEY_BREAK))
        elif raw.header.dwType == RIM_TYPEHID:
            self._handle_hid(buffer, raw, device_handle)

    def _handle_hid(
        self, buffer: ctypes.Array, raw: RAWINPUT, device_handle: int
    ) -> None:
        report_size = int(raw.data.hid.dwSizeHid)
        report_count = int(raw.data.hid.dwCount)
        if report_size <= 0 or report_count <= 0:
            return
        offset = RAWINPUT.data.offset + RAWHID.bRawData.offset
        payload = bytes(buffer[offset : offset + report_size * report_count])
        active: set[str] = set()
        for index in range(report_count):
            report = payload[index * report_size : (index + 1) * report_size]
            try:
                active.update(hid_identity.decode_active_buttons(report))
            except ValueError:
                continue
        previous = self._hid_active.get(device_handle, set())
        for button_id in sorted(active - previous):
            self._callback(button_id, True)
        for button_id in sorted(previous - active):
            self._callback(button_id, False)
        self._hid_active[device_handle] = active
