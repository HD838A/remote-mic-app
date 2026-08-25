"""Opens Windows-native external targets (Settings app deep links) from the
Permissions page (XRBM-030), via an injectable opener - mirrors
``logging_setup.py``'s ``open_log_location()``/``single_instance.py``'s
injectable-OS-call convention, so every branch is testable without ever
invoking a real Windows shell call.

``ms-settings:`` URIs are Microsoft's own documented deep-link scheme into
the Settings app. ``os.startfile()`` opens both ordinary directories (see
``logging_setup.py``) and these URI schemes identically on Windows (it is
registered as the OS's default handler for both), so the same
``_default_opener`` pattern applies here.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional

# Real, Microsoft-documented ms-settings: deep links (Windows 10/11) - never
# invented. "ms-settings:bluetooth" opens Settings > Bluetooth & other
# devices; "ms-settings:privacy-microphone" opens Settings > Privacy &
# security > Microphone (where RC003 voice/BLE-adjacent access is actually
# granted or denied); "ms-settings:speech" opens the Speech recognition page
# that governs whether Win+H dictation itself works at all - the one real
# dependency the voice hotkey's whole feature rests on (see README's "首次
# 使用" step 4, which already tells users to check this manually).
BLUETOOTH_SETTINGS_URI = "ms-settings:bluetooth"
MICROPHONE_PRIVACY_SETTINGS_URI = "ms-settings:privacy-microphone"
SPEECH_SETTINGS_URI = "ms-settings:speech"
# XRBM-031 In-scope item 5: "sound" opens Settings > System > Sound, where a
# user picks the system input/output devices (e.g. selecting VB-CABLE's
# "CABLE Output" as the system microphone) - this app never changes that
# selection itself, it only opens the page. "appsfeatures" opens Settings >
# Apps > Installed apps, the vendor-controlled surface for repairing or
# removing an already-installed VB-CABLE driver (this project's own
# installer/uninstaller never touches it - see vb_cable_bundle.py).
SOUND_SETTINGS_URI = "ms-settings:sound"
APPS_SETTINGS_URI = "ms-settings:appsfeatures"


class ExternalTargetOutcome(Enum):
    OPENED = "opened"
    OPEN_FAILED = "open_failed"


@dataclass(frozen=True)
class ExternalTargetResult:
    outcome: ExternalTargetOutcome
    target: str
    error: Optional[str] = None


def _default_opener(target: str) -> None:
    # os.startfile only exists on Windows (CPython does not define it on
    # other platforms at all) - checked explicitly rather than caught as an
    # AttributeError, matching logging_setup.py's _default_open_directory.
    startfile = getattr(os, "startfile", None)
    if startfile is None:
        raise OSError("os.startfile is only available on Windows")
    startfile(target)


def open_external_target(
    target: str,
    *,
    _opener: Callable[[str], None] = _default_opener,
) -> ExternalTargetResult:
    """Opens ``target`` (a ``ms-settings:`` URI, or any other
    ``os.startfile``-openable target) via the injected opener, catching and
    reporting any exception rather than propagating it - callers are Qt
    slot handlers that must not crash the settings window over a failed
    open (same contract as ``logging_setup.open_log_location``). Never
    claims a permission was actually granted: opening the Settings page is
    all this function does or reports on.
    """

    try:
        _opener(target)
    except Exception as exc:  # noqa: BLE001 - report, never crash the settings window
        return ExternalTargetResult(ExternalTargetOutcome.OPEN_FAILED, target, error=str(exc))
    return ExternalTargetResult(ExternalTargetOutcome.OPENED, target)
