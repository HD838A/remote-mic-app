"""Passive, time-bounded probe for RC003-compatible Windows key events.

Only known remote-control virtual keys are logged. Other keyboard input is
ignored, and no key is suppressed or replayed.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path
from typing import TextIO

from ovb_rc003.legacy_key_suppressor_windows import (
    KBDLLHOOKSTRUCT,
    LLKHF_INJECTED,
    WM_KEYDOWN,
    WM_KEYUP,
    WM_SYSKEYDOWN,
    WM_SYSKEYUP,
)


WH_KEYBOARD_LL = 13
WM_QUIT = 0x0012
HC_ACTION = 0
KNOWN_KEYS = {
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
    0xA6: "browser_back",
}


def _run(seconds: float) -> int:
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    lresult = ctypes.c_ssize_t
    hookproc_type = ctypes.WINFUNCTYPE(
        lresult, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
    )
    user32.SetWindowsHookExW.argtypes = (
        ctypes.c_int,
        hookproc_type,
        wintypes.HINSTANCE,
        wintypes.DWORD,
    )
    user32.SetWindowsHookExW.restype = wintypes.HANDLE
    user32.CallNextHookEx.argtypes = (
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.WPARAM,
        wintypes.LPARAM,
    )
    user32.CallNextHookEx.restype = lresult
    user32.UnhookWindowsHookEx.argtypes = (wintypes.HANDLE,)
    user32.UnhookWindowsHookEx.restype = wintypes.BOOL
    user32.GetMessageW.argtypes = (
        ctypes.POINTER(wintypes.MSG),
        wintypes.HWND,
        wintypes.UINT,
        wintypes.UINT,
    )
    user32.GetMessageW.restype = ctypes.c_int
    user32.PostThreadMessageW.argtypes = (
        wintypes.DWORD,
        wintypes.UINT,
        wintypes.WPARAM,
        wintypes.LPARAM,
    )
    user32.PostThreadMessageW.restype = wintypes.BOOL
    kernel32.GetCurrentThreadId.restype = wintypes.DWORD

    edges = 0
    hook = wintypes.HANDLE()

    @hookproc_type
    def callback(code: int, wparam: int, lparam: int) -> int:
        nonlocal edges
        if code == HC_ACTION:
            event = ctypes.cast(
                lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)
            ).contents
            label = KNOWN_KEYS.get(int(event.vkCode))
            if label is not None and not (int(event.flags) & LLKHF_INJECTED):
                if int(wparam) in (WM_KEYDOWN, WM_SYSKEYDOWN):
                    state = "down"
                elif int(wparam) in (WM_KEYUP, WM_SYSKEYUP):
                    state = "up"
                else:
                    state = "other"
                edges += 1
                print(
                    f"RC003 LEGACY KEY button={label} state={state} "
                    f"vk=0x{int(event.vkCode):02X} scan=0x{int(event.scanCode):02X}",
                    flush=True,
                )
        return int(user32.CallNextHookEx(hook, code, wparam, lparam))

    thread_id = int(kernel32.GetCurrentThreadId())
    hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, callback, None, 0)
    if not hook:
        raise ctypes.WinError(ctypes.get_last_error())

    timer = threading.Timer(
        seconds, lambda: user32.PostThreadMessageW(thread_id, WM_QUIT, 0, 0)
    )
    timer.daemon = True
    timer.start()
    print(f"RC003 LEGACY PROBE START duration_seconds={seconds:g}", flush=True)
    try:
        message = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
            pass
    finally:
        timer.cancel()
        user32.UnhookWindowsHookEx(hook)
    print(f"RC003 LEGACY PROBE END edges={edges}", flush=True)
    return 0 if edges else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=45.0)
    parser.add_argument("--output", type=Path)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if args.seconds <= 0:
        raise SystemExit("--seconds must be greater than zero")
    stream: TextIO | None = None
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        stream = args.output.open("w", encoding="utf-8", buffering=1)
    try:
        if stream is None:
            return _run(args.seconds)
        with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
            return _run(args.seconds)
    finally:
        if stream is not None:
            stream.close()


if __name__ == "__main__":
    sys.exit(main())
