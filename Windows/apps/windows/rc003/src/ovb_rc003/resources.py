"""Locates the optional RC003 product photo for the settings window.

The photo itself lives once at the repository root (Resources/RC003-remote-
photo.png) and is not duplicated here; this only searches a couple of
plausible relative locations (packaged build vs. source checkout) and
returns None if it can't be found, so the settings UI degrades to a text-only
button list rather than fabricating or stretching an image (see
XRBM-014 for why this candidate does not
attempt clickable image hotspots).

Frozen (PyInstaller one-dir) layout (XRBM-018 RETRY 1 P2 #4, wording
corrected in XRBM-019 P2 #7 - see XRBM-018's independent review
round 2's product-contract follow-up): the spec's ``datas`` entry collects
the photo under a ``Resources`` folder inside the COLLECT output, which
PyInstaller's bootloader exposes at runtime via ``sys._MEIPASS`` -
documented as "the path to the folder from which the frozen application is
run", i.e. wherever the bootloader actually placed the bundled ``datas``,
regardless of the exact on-disk layout. That is NOT necessarily the same
directory as the executable file itself in a modern one-dir build: since
PyInstaller 6's default one-dir layout, most bundled content (including
anything listed in ``datas``) is placed in a ``_internal`` subdirectory
next to the executable, not loose alongside it, and ``sys._MEIPASS`` points
at that ``_internal`` directory rather than the top-level dist folder the
``.exe`` itself lives in. Checking ``Path(sys._MEIPASS) / "Resources" /
...`` first (below) is correct regardless of which exact subdirectory
``_MEIPASS`` resolves to, precisely because it is always wherever the
bootloader put ``datas`` - the code does not need to know or assume the
internal layout, only trust ``sys._MEIPASS`` itself. The previous version
of this docstring incorrectly claimed ``sys._MEIPASS`` "equals the
directory containing the frozen executable itself"; that claim is wrong
for this layout and has been removed, without changing the lookup logic
itself, which was already correct. The previous *code* (before XRBM-018)
only checked a ``Resources`` path relative to the process's current working
directory, which is NOT guaranteed to be the executable's own directory
either (it depends on how the user/shortcut launched it) - a real gap
between "the photo was bundled" and "the running app can find it".
``sys._MEIPASS`` is checked first, and only when actually set (i.e. only in
a frozen build); the source-checkout and CWD-relative fallbacks below still
cover the unfrozen/dev case exactly as before.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator, Optional

_PHOTO_FILENAME = "RC003-remote-photo.png"
_APP_ICON_FILENAME = "RemoteMic-AppIcon.ico"
_DEVICE_PROFILES_DIRECTORY = "device-profiles"


def _candidate_paths() -> Iterator[Path]:
    frozen_root = getattr(sys, "_MEIPASS", None)
    if frozen_root:
        # Packaged (frozen) build: PyInstaller's bootloader sets this before
        # any application code runs, so it's always current - checked
        # dynamically here (not cached at import time) so tests can
        # simulate a frozen bundle by monkeypatching sys._MEIPASS.
        yield Path(frozen_root) / "Resources" / _PHOTO_FILENAME
    # Unfrozen packaged build (e.g. launched with CWD already set to the
    # dist folder): PyInstaller spec copies the photo next to the exe.
    yield Path("Resources") / _PHOTO_FILENAME
    # Source checkout: apps/windows/rc003/src/ovb_rc003/resources.py -> repo root.
    yield Path(__file__).resolve().parents[5] / "Resources" / _PHOTO_FILENAME


def find_remote_photo() -> Optional[Path]:
    for candidate in _candidate_paths():
        if candidate.is_file():
            return candidate
    return None


def find_app_icon() -> Optional[Path]:
    """Locate the product icon in frozen and source-checkout layouts."""

    frozen_root = getattr(sys, "_MEIPASS", None)
    candidates = []
    if frozen_root:
        candidates.append(Path(frozen_root) / "Resources" / _APP_ICON_FILENAME)
    candidates.extend(
        (
            Path("Resources") / _APP_ICON_FILENAME,
            Path(__file__).resolve().parents[5] / "Resources" / _APP_ICON_FILENAME,
        )
    )
    return next((candidate for candidate in candidates if candidate.is_file()), None)


def _device_profile_directory_candidates() -> Iterator[Path]:
    frozen_root = getattr(sys, "_MEIPASS", None)
    if frozen_root:
        yield Path(frozen_root) / _DEVICE_PROFILES_DIRECTORY
        return
    # Source checkout: apps/windows/rc003/src/ovb_rc003/resources.py -> repo root.
    yield Path(__file__).resolve().parents[5] / _DEVICE_PROFILES_DIRECTORY


def find_device_profiles_directory() -> Optional[Path]:
    """Returns only a real shared-catalog directory; never a CWD fallback."""

    for candidate in _device_profile_directory_candidates():
        if candidate.is_dir():
            return candidate
    return None
