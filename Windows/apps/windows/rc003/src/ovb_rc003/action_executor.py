"""Windows execution helpers for semantic RC003 actions.

The reference project separates an action such as ``openCodex`` from a
recorded shortcut.  This module provides the corresponding Windows boundary:
application actions resolve a real installed executable and launch it, while
keyboard/system actions stay in :mod:`win32_input`.  The resolver is kept
dependency-injectable so the action contract can be tested without starting a
real application.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, Dict, Iterable, Optional, Sequence, Tuple

from . import key_mapping


Command = Tuple[str, ...]
Launcher = Callable[[Sequence[str]], object]


# These are executable names rather than guessed window titles.  We resolve
# them through PATH and the normal per-user/system Windows program roots so a
# different install location does not break the mapping.
_APPLICATION_EXECUTABLES: Dict[key_mapping.ActionKind, Tuple[str, ...]] = {
    key_mapping.ActionKind.OPEN_CODEX: ("Codex.exe", "codex.exe"),
    key_mapping.ActionKind.OPEN_CLAUDE: ("Claude.exe", "claude.exe"),
    key_mapping.ActionKind.OPEN_CMUX: ("cmux.exe", "cmux"),
    key_mapping.ActionKind.OPEN_WECHAT: ("WeChat.exe", "Weixin.exe"),
    key_mapping.ActionKind.OPEN_CURSOR: ("Cursor.exe", "cursor.exe"),
    key_mapping.ActionKind.OPEN_SLACK: ("slack.exe", "Slack.exe"),
    key_mapping.ActionKind.OPEN_WECOM: ("WXWork.exe", "WeCom.exe"),
    key_mapping.ActionKind.OPEN_NETEASE_MUSIC: (
        "cloudmusic.exe",
        "CloudMusic.exe",
    ),
    key_mapping.ActionKind.OPEN_CHROME: ("chrome.exe", "Chrome.exe"),
    key_mapping.ActionKind.OPEN_EDGE: ("msedge.exe", "MicrosoftEdge.exe"),
    key_mapping.ActionKind.OPEN_ZED: ("Zed.exe", "zed.exe"),
}

_APPLICATION_SHORTCUT_NAMES: Dict[key_mapping.ActionKind, Tuple[str, ...]] = {
    key_mapping.ActionKind.OPEN_CODEX: ("Codex",),
    key_mapping.ActionKind.OPEN_CLAUDE: ("Claude",),
    key_mapping.ActionKind.OPEN_CMUX: ("cmux",),
    key_mapping.ActionKind.OPEN_WECHAT: ("微信", "WeChat", "Weixin"),
    key_mapping.ActionKind.OPEN_CURSOR: ("Cursor",),
    key_mapping.ActionKind.OPEN_SLACK: ("Slack",),
    key_mapping.ActionKind.OPEN_WECOM: ("企业微信", "WeCom", "WXWork"),
    key_mapping.ActionKind.OPEN_NETEASE_MUSIC: ("网易云音乐", "NetEase Cloud Music"),
    key_mapping.ActionKind.OPEN_CHROME: ("Google Chrome", "Chrome"),
    key_mapping.ActionKind.OPEN_EDGE: ("Microsoft Edge", "Edge"),
    key_mapping.ActionKind.OPEN_ZED: ("Zed",),
}


def is_application_action(action: key_mapping.ButtonAction) -> bool:
    return action.kind in key_mapping.APPLICATION_ACTIONS


def _windows_roots() -> Iterable[Path]:
    # Preserve order: per-user installs are the most common for the desktop
    # tools named in the reference repository, followed by machine installs.
    seen = set()
    for variable in ("LOCALAPPDATA", "PROGRAMFILES", "PROGRAMFILES(X86)"):
        raw = os.environ.get(variable, "").strip()
        if not raw:
            continue
        root = Path(raw)
        if root not in seen:
            seen.add(root)
            yield root


def _candidate_paths(executable_names: Sequence[str]) -> Iterable[Path]:
    # ``where``/PATH is the least opinionated lookup and also covers package
    # managers that intentionally install outside the usual roots.
    for executable_name in executable_names:
        resolved = shutil.which(executable_name)
        if resolved:
            yield Path(resolved)

    common_relative_directories = (
        Path("Programs"),
        Path("Programs", "Common"),
        Path("Google", "Chrome", "Application"),
        Path("Microsoft", "Edge", "Application"),
        Path("Tencent", "WeChat"),
        Path("Tencent", "WeCom"),
        Path("WXWork"),
        Path("Netease", "CloudMusic"),
    )
    for root in _windows_roots():
        for directory in common_relative_directories:
            for executable_name in executable_names:
                yield root / directory / executable_name


def _start_menu_shortcuts(
    names: Sequence[str], *, exact_only: bool = False
) -> Iterable[Path]:
    roots = [
        Path(os.environ.get("APPDATA", ""))
        / "Microsoft"
        / "Windows"
        / "Start Menu"
        / "Programs",
        Path(os.environ.get("PROGRAMDATA", ""))
        / "Microsoft"
        / "Windows"
        / "Start Menu"
        / "Programs",
    ]
    wanted = tuple(name.casefold() for name in names)
    for root in roots:
        if not root.is_dir():
            continue
        try:
            shortcuts = root.rglob("*.lnk")
            for shortcut in shortcuts:
                stem = shortcut.stem.casefold()
                if stem in wanted or (
                    not exact_only and any(name in stem for name in wanted)
                ):
                    yield shortcut
        except OSError:
            continue


def _packaged_codex_paths() -> Iterable[Path]:
    # Codex is commonly delivered as a Windows Store package.  It may not be
    # on PATH or in Start Menu as a normal exe, but the running package exposes
    # this stable relative resource path.  The glob handles version updates.
    for root in _windows_roots():
        windows_apps = root / "WindowsApps"
        if not windows_apps.is_dir():
            continue
        try:
            yield from windows_apps.glob("OpenAI.Codex_*/app/resources/codex.exe")
        except OSError:
            continue


def resolve_application_command(
    action: key_mapping.ButtonAction,
    *,
    executable_exists: Callable[[Path], bool] = lambda path: path.is_file(),
) -> Optional[Command]:
    """Resolve an application action to an executable command.

    ``open_remote_mic`` reuses this EXE and opens the settings window.  Other
    actions are resolved by executable name.  No path or device identity is
    persisted in the config file.
    """

    if action.kind == key_mapping.ActionKind.OPEN_REMOTE_MIC:
        executable = Path(sys.executable)
        if getattr(sys, "frozen", False) and executable_exists(executable):
            return (str(executable), "--settings")
        return None

    names = _APPLICATION_EXECUTABLES.get(action.kind)
    if not names:
        return None
    for candidate in _candidate_paths(names):
        if executable_exists(candidate):
            return (str(candidate),)
    if action.kind == key_mapping.ActionKind.OPEN_CODEX:
        for candidate in _packaged_codex_paths():
            if executable_exists(candidate):
                return (str(candidate),)
    exact_shortcut_action = action.kind in {
        key_mapping.ActionKind.OPEN_WECHAT,
        key_mapping.ActionKind.OPEN_WECOM,
    }
    for shortcut in _start_menu_shortcuts(
        _APPLICATION_SHORTCUT_NAMES.get(action.kind, ()),
        exact_only=exact_shortcut_action,
    ):
        if executable_exists(shortcut):
            return (str(shortcut),)
    return None


def open_configured_application(
    action: key_mapping.ButtonAction,
    *,
    launcher: Optional[Launcher] = None,
) -> bool:
    """Launch one configured application action and report whether it started."""

    command = resolve_application_command(action)
    if command is None:
        return False
    starter = launcher or _launch_command
    starter(command)
    return True


def _launch_command(command: Sequence[str]) -> None:
    if len(command) == 1 and Path(command[0]).suffix.casefold() == ".lnk":
        os.startfile(command[0])  # type: ignore[attr-defined]
        return
    creation_flags = 0
    if sys.platform == "win32":
        creation_flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    subprocess.Popen(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=(sys.platform != "win32"),
        creationflags=creation_flags,
    )
