"""执行 RC003 映射动作，并隔离应用启动与 SendInput 边界。"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable

from . import key_mapping, win32_input

APPLICATION_EXECUTABLES = {
    "open_codex": ("Codex.exe", "codex.exe"),
    "open_claude": ("Claude.exe", "claude.exe"),
    "open_wechat": ("WeChat.exe", "Weixin.exe"),
    "open_cursor": ("Cursor.exe", "cursor.exe"),
    "open_slack": ("slack.exe", "Slack.exe"),
    "open_chrome": ("chrome.exe", "Chrome.exe"),
    "open_edge": ("msedge.exe",),
}


def _application_roots() -> Iterable[Path]:
    for variable in ("LOCALAPPDATA", "PROGRAMFILES", "PROGRAMFILES(X86)"):
        value = os.environ.get(variable, "").strip()
        if value:
            yield Path(value)


def _resolve_executable(names: tuple[str, ...]) -> Path | None:
    for name in names:
        resolved = shutil.which(name)
        if resolved:
            return Path(resolved)
    relative_roots = (
        Path("Programs"),
        Path("Google", "Chrome", "Application"),
        Path("Microsoft", "Edge", "Application"),
        Path("Tencent", "WeChat"),
    )
    for root in _application_roots():
        for relative in relative_roots:
            for name in names:
                candidate = root / relative / name
                if candidate.is_file():
                    return candidate
    return None


def _launch(command: list[str]) -> bool:
    creationflags = (
        getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        if sys.platform == "win32"
        else 0
    )
    subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=(sys.platform != "win32"),
        creationflags=creationflags,
    )
    return True


def open_application(action: str) -> bool:
    if action == "open_remote_mic":
        if getattr(sys, "frozen", False):
            return _launch([sys.executable, "--settings"])
        return _launch([sys.executable, "-m", "ovb_rc003", "--settings"])
    executable = _resolve_executable(APPLICATION_EXECUTABLES.get(action, ()))
    return False if executable is None else _launch([str(executable)])


def execute_action(action: str) -> bool:
    if action in {"disabled", "voice"}:
        return True
    if action.startswith(key_mapping.CUSTOM_SHORTCUT_PREFIX):
        win32_input.send_shortcut(action[len(key_mapping.CUSTOM_SHORTCUT_PREFIX) :])
        return True
    if win32_input.send_action(action):
        return True
    if action.startswith("open_"):
        return open_application(action)
    return False
