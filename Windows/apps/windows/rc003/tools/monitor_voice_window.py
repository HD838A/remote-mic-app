"""Correlate one RemoteMic voice session with visible host-window changes.

This diagnostic is read-only: it tails the privacy-safe RemoteMic application
log and enumerates visible top-level Windows windows.  It never injects input,
records audio, captures screenshots, or logs window titles/process paths.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
from datetime import datetime
import os
from pathlib import Path
import sys
import time
from typing import Dict, FrozenSet, Optional


PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


@dataclass(frozen=True)
class WindowIdentity:
    hwnd: int
    pid: int
    matched_by: str


class VisibleWindowProbe:
    def __init__(self, match_text: str) -> None:
        self._needle = match_text.casefold()
        self._user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        self._kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        self._process_names: Dict[int, str] = {}

    def matching_windows(self) -> FrozenSet[WindowIdentity]:
        matches = []
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

        @callback_type
        def callback(hwnd, _lparam):
            if not self._user32.IsWindowVisible(hwnd):
                return True
            title = self._window_text(hwnd)
            class_name = self._class_name(hwnd)
            pid = wintypes.DWORD()
            self._user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            process_name = self._process_name(int(pid.value))
            fields = {
                "title": title,
                "class": class_name,
                "process": process_name,
            }
            matched_by = next(
                (name for name, value in fields.items() if self._needle in value.casefold()),
                None,
            )
            if matched_by is not None:
                matches.append(WindowIdentity(int(hwnd), int(pid.value), matched_by))
            return True

        self._user32.EnumWindows(callback, 0)
        return frozenset(matches)

    def _window_text(self, hwnd: int) -> str:
        length = int(self._user32.GetWindowTextLengthW(hwnd))
        buffer = ctypes.create_unicode_buffer(max(1, length + 1))
        self._user32.GetWindowTextW(hwnd, buffer, len(buffer))
        return buffer.value

    def _class_name(self, hwnd: int) -> str:
        buffer = ctypes.create_unicode_buffer(256)
        self._user32.GetClassNameW(hwnd, buffer, len(buffer))
        return buffer.value

    def _process_name(self, pid: int) -> str:
        cached = self._process_names.get(pid)
        if cached is not None:
            return cached
        handle = self._kernel32.OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION, False, pid
        )
        if not handle:
            self._process_names[pid] = ""
            return ""
        try:
            size = wintypes.DWORD(32768)
            buffer = ctypes.create_unicode_buffer(size.value)
            if not self._kernel32.QueryFullProcessImageNameW(
                handle, 0, buffer, ctypes.byref(size)
            ):
                name = ""
            else:
                name = Path(buffer.value).name
        finally:
            self._kernel32.CloseHandle(handle)
        self._process_names[pid] = name
        return name


class LogTail:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._stream = None

    def open_at_end(self) -> None:
        self._stream = self._path.open("r", encoding="utf-8", errors="replace")
        self._stream.seek(0, os.SEEK_END)

    def read_new_lines(self):
        if self._stream is None:
            return []
        lines = []
        while True:
            line = self._stream.readline()
            if not line:
                break
            lines.append(line.rstrip("\r\n"))
        return lines


def _clock_text() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--match", default="typeless")
    parser.add_argument(
        "--log",
        type=Path,
        default=Path(os.environ.get("LOCALAPPDATA", "."))
        / "RemoteMic"
        / "RC003"
        / "logs"
        / "app.log",
    )
    parser.add_argument("--poll-ms", type=int, default=50)
    parser.add_argument("--timeout-after-release", type=float, default=15.0)
    args = parser.parse_args()

    if sys.platform != "win32":
        raise SystemExit("This monitor requires Windows")
    if not args.log.is_file():
        raise SystemExit(f"RemoteMic log not found: {args.log}")

    probe = VisibleWindowProbe(args.match)
    tail = LogTail(args.log)
    tail.open_at_end()
    baseline = probe.matching_windows()
    previous = baseline
    press_at: Optional[float] = None
    release_at: Optional[float] = None
    closing_tap_at: Optional[float] = None
    deadline: Optional[float] = None
    host_tap_count = 0

    print(
        f"READY {_clock_text()} match={args.match!r} "
        f"baseline_visible={len(baseline)} poll_ms={args.poll_ms}",
        flush=True,
    )

    while True:
        now = time.monotonic()
        for line in tail.read_new_lines():
            if "voice host tap delivered:" in line:
                host_tap_count += 1
                if press_at is None:
                    press_at = now
                    print(
                        f"PRESS_TAP {_clock_text()} t=0ms thread={line.rsplit('thread=', 1)[-1]}",
                        flush=True,
                    )
                else:
                    closing_tap_at = now
                    if deadline is None:
                        deadline = now + max(0.0, args.timeout_after_release)
                    relative = (now - press_at) * 1000.0
                    after_release = (
                        "unknown"
                        if release_at is None
                        else f"{(now - release_at) * 1000.0:.0f}ms"
                    )
                    print(
                        f"CLOSING_TAP {_clock_text()} t={relative:.0f}ms "
                        f"after_release={after_release} "
                        f"thread={line.rsplit('thread=', 1)[-1]}",
                        flush=True,
                    )
            elif "voice physical mic released;" in line:
                release_at = now
                deadline = now + max(0.0, args.timeout_after_release)
                relative = (
                    "unknown"
                    if press_at is None
                    else f"{(now - press_at) * 1000.0:.0f}ms"
                )
                print(
                    f"PHYSICAL_RELEASE {_clock_text()} t={relative}", flush=True
                )
            elif "voice audio started" in line and "waiting" not in line:
                relative = (
                    "before_press_tap"
                    if press_at is None
                    else f"{(now - press_at) * 1000.0:.0f}ms"
                )
                print(f"AUDIO_STARTED {_clock_text()} t={relative}", flush=True)
            elif "voice audio stopped" in line:
                relative = (
                    "before_press_tap"
                    if press_at is None
                    else f"{(now - press_at) * 1000.0:.0f}ms"
                )
                print(f"AUDIO_STOPPED {_clock_text()} t={relative}", flush=True)

        current = probe.matching_windows()
        appeared = current - previous
        disappeared = previous - current
        if appeared:
            relative = (
                "before_press_tap"
                if press_at is None
                else f"{(now - press_at) * 1000.0:.0f}ms"
            )
            print(
                f"WINDOW_APPEARED {_clock_text()} t={relative} "
                f"count={len(current)} match_by={','.join(sorted({w.matched_by for w in appeared}))}",
                flush=True,
            )
        if disappeared:
            relative = (
                "before_press_tap"
                if press_at is None
                else f"{(now - press_at) * 1000.0:.0f}ms"
            )
            after_release = (
                "unknown"
                if release_at is None
                else f"{(now - release_at) * 1000.0:.0f}ms"
            )
            after_close = (
                "unknown"
                if closing_tap_at is None
                else f"{(now - closing_tap_at) * 1000.0:.0f}ms"
            )
            print(
                f"WINDOW_DISAPPEARED {_clock_text()} t={relative} "
                f"after_release={after_release} after_closing_tap={after_close} "
                f"count={len(current)}",
                flush=True,
            )
            if release_at is not None or closing_tap_at is not None:
                print(f"DONE host_taps={host_tap_count}", flush=True)
                return 0
        previous = current

        if deadline is not None and now >= deadline:
            print(
                f"TIMEOUT {_clock_text()} window_did_not_disappear_after_close_within="
                f"{args.timeout_after_release:.1f}s host_taps={host_tap_count} "
                f"visible_matches={len(current)}",
                flush=True,
            )
            return 2
        time.sleep(max(0.01, args.poll_ms / 1000.0))


if __name__ == "__main__":
    raise SystemExit(main())
