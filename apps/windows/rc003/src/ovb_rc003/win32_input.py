"""使用 Win32 SendInput 执行键盘和系统媒体动作。"""

from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes

INPUT_KEYBOARD = 1
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002

VK = {
    "backspace": 0x08,
    "tab": 0x09,
    "enter": 0x0D,
    "shift": 0x10,
    "ctrl": 0x11,
    "alt": 0x12,
    "pause": 0x13,
    "escape": 0x1B,
    "space": 0x20,
    "pageup": 0x21,
    "pagedown": 0x22,
    "end": 0x23,
    "home": 0x24,
    "left": 0x25,
    "up": 0x26,
    "right": 0x27,
    "down": 0x28,
    "delete": 0x2E,
    "0": 0x30,
    "1": 0x31,
    "2": 0x32,
    "3": 0x33,
    "4": 0x34,
    "5": 0x35,
    "6": 0x36,
    "7": 0x37,
    "8": 0x38,
    "9": 0x39,
    "win": 0x5B,
    "lwin": 0x5B,
    "rwin": 0x5C,
    "menu": 0x5D,
    "lshift": 0xA0,
    "rshift": 0xA1,
    "lctrl": 0xA2,
    "rctrl": 0xA3,
    "lalt": 0xA4,
    "ralt": 0xA5,
    "volume_mute": 0xAD,
    "volume_down": 0xAE,
    "volume_up": 0xAF,
    "play_pause": 0xB3,
}
VK.update({chr(code): code for code in range(ord("A"), ord("Z") + 1)})
VK.update({f"f{number}": 0x6F + number for number in range(1, 25)})

EXTENDED_KEYS = frozenset(
    {
        "rctrl",
        "ralt",
        "win",
        "lwin",
        "rwin",
        "menu",
        "pageup",
        "pagedown",
        "end",
        "home",
        "left",
        "up",
        "right",
        "down",
        "delete",
        "volume_mute",
        "volume_down",
        "volume_up",
        "play_pause",
    }
)


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("data",)
    _fields_ = [("type", wintypes.DWORD), ("data", _INPUTUNION)]


class Win32InputUnavailableError(RuntimeError):
    pass


def parse_shortcut(shortcut: str) -> tuple[str, ...]:
    tokens = tuple(
        token.strip().lower() for token in shortcut.split("+") if token.strip()
    )
    if not tokens:
        raise ValueError("快捷键不能为空")
    unknown = [token for token in tokens if token.upper() not in VK and token not in VK]
    if unknown:
        raise ValueError(f"不支持的快捷键：{', '.join(unknown)}")
    return tuple(
        token.upper() if len(token) == 1 and token.isalpha() else token
        for token in tokens
    )


def _input_for(key: str, *, key_up: bool) -> INPUT:
    lookup = key if key in VK else key.upper()
    flags = KEYEVENTF_KEYUP if key_up else 0
    if key.casefold() in EXTENDED_KEYS:
        flags |= KEYEVENTF_EXTENDEDKEY
    return INPUT(
        type=INPUT_KEYBOARD,
        data=_INPUTUNION(ki=KEYBDINPUT(VK[lookup], 0, flags, 0, 0)),
    )


def send_shortcut(shortcut: str) -> None:
    if sys.platform != "win32":
        raise Win32InputUnavailableError("SendInput 仅可在 Windows 上使用")
    keys = parse_shortcut(shortcut)
    inputs = [_input_for(key, key_up=False) for key in keys]
    inputs.extend(_input_for(key, key_up=True) for key in reversed(keys))
    array = (INPUT * len(inputs))(*inputs)
    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    user32.SendInput.argtypes = (
        wintypes.UINT,
        ctypes.POINTER(INPUT),
        ctypes.c_int,
    )
    user32.SendInput.restype = wintypes.UINT
    sent = user32.SendInput(len(array), array, ctypes.sizeof(INPUT))
    if sent != len(array):
        raise ctypes.WinError()


ACTION_SHORTCUTS = {
    "escape": "escape",
    "return": "enter",
    "arrow_up": "up",
    "arrow_down": "down",
    "arrow_left": "left",
    "arrow_right": "right",
    "delete_backward": "backspace",
    "show_desktop": "win+d",
    "context_menu": "shift+f10",
    "app_switcher": "alt+tab",
    "system_volume_up": "volume_up",
    "system_volume_down": "volume_down",
    "system_volume_mute": "volume_mute",
    "play_pause": "play_pause",
}


def send_action(action: str) -> bool:
    shortcut = ACTION_SHORTCUTS.get(action)
    if shortcut is None:
        return False
    send_shortcut(shortcut)
    return True
