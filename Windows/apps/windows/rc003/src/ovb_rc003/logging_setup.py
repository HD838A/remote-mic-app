"""Logging configuration that never touches voice content or device identity.

Callers must only ever log opaque markers (button names, session ids,
sample/frame counts, boolean flags) - never a Bluetooth address, HID
interface path, device token, or decoded voice content. This module doesn't
attempt to scrub arbitrary strings after the fact (a redaction filter would
give false confidence); the guarantee instead comes from code review plus
tests/test_privacy_contract.py, which statically scans this package's source
for the sensitive field names and MAC-address-shaped literals.

``log_dir``/``log_file_path`` (XRBM-029) expose this module's canonical
``%LOCALAPPDATA%\\RemoteMic\\RC003\\logs\\app.log`` location WITHOUT the
side effect ``get_logger()`` has of creating that directory - the settings
window's "open log directory" entry needs to tell a user "this doesn't exist
yet, the app hasn't run" as an honest fact, which would be impossible if
merely asking the question always created the directory first.
``describe_log_location``/``open_log_location`` build on those two path
functions to answer "does it exist" and "open it" respectively, the latter
via an injectable ``_open_directory`` callable (mirrors this package's other
OS-facing modules, e.g. ``single_instance.py``) so
tests/test_logging_setup_location.py can exercise every branch without
actually invoking Windows Explorer.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Callable, Optional

from . import config

LOGGER_NAME = "ovb_rc003"
LOG_FILENAME = "app.log"

_configured = False


def get_logger(root: Optional[Path] = None) -> logging.Logger:
    global _configured
    logger = logging.getLogger(LOGGER_NAME)
    if _configured:
        return logger

    logger.setLevel(logging.INFO)
    directory = log_dir(root)
    directory.mkdir(parents=True, exist_ok=True)

    handler = logging.FileHandler(directory / LOG_FILENAME, encoding="utf-8")
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    logger.addHandler(handler)
    _configured = True
    return logger


def log_dir(root: Optional[Path] = None) -> Path:
    """The canonical log directory - does NOT create it (see module
    docstring); only ``get_logger()`` does that, as a side effect of
    actually needing to write to it.
    """

    return (root or config.config_root()) / "logs"


def log_file_path(root: Optional[Path] = None) -> Path:
    return log_dir(root) / LOG_FILENAME


class LogLocationStatus(Enum):
    DIRECTORY_MISSING = "directory_missing"
    FILE_MISSING = "file_missing"
    READY = "ready"


@dataclass(frozen=True)
class LogLocation:
    status: LogLocationStatus
    directory: Path
    file_path: Path


def describe_log_location(root: Optional[Path] = None) -> LogLocation:
    """A pure filesystem check - never creates anything (DoD: "不存在时给出
    诚实提示；不得创建伪日志"). ``FILE_MISSING`` (directory exists, no
    ``app.log`` yet) is distinct from ``DIRECTORY_MISSING`` (the app has
    never even been run on this machine) so a caller can phrase each
    honestly instead of collapsing them into one generic "not found".
    """

    directory = log_dir(root)
    file_path = log_file_path(root)
    if not directory.is_dir():
        return LogLocation(LogLocationStatus.DIRECTORY_MISSING, directory, file_path)
    if not file_path.is_file():
        return LogLocation(LogLocationStatus.FILE_MISSING, directory, file_path)
    return LogLocation(LogLocationStatus.READY, directory, file_path)


class LogOpenOutcome(Enum):
    OPENED = "opened"
    DIRECTORY_MISSING = "directory_missing"
    OPEN_FAILED = "open_failed"


@dataclass(frozen=True)
class LogOpenResult:
    outcome: LogOpenOutcome
    location: LogLocation
    error: Optional[str] = None


def _default_open_directory(directory: Path) -> None:
    # os.startfile only exists on Windows (CPython does not define it on
    # other platforms at all) - checked explicitly rather than caught as an
    # AttributeError, so the resulting OSError message is clear about why.
    startfile = getattr(os, "startfile", None)
    if startfile is None:
        raise OSError("os.startfile is only available on Windows")
    startfile(str(directory))


def open_log_location(
    root: Optional[Path] = None,
    *,
    _open_directory: Callable[[Path], None] = _default_open_directory,
) -> LogOpenResult:
    """Opens the log directory in the OS file browser - never the log FILE
    directly, since which application handles a bare ``.log`` extension is
    unpredictable and not this project's concern. Refuses to open (or
    create) a directory that does not exist yet; any exception the actual
    open call raises is caught and reported rather than propagated, since
    this is called directly from a Tk button handler that must not crash
    the settings window over it.
    """

    location = describe_log_location(root)
    if location.status is LogLocationStatus.DIRECTORY_MISSING:
        return LogOpenResult(LogOpenOutcome.DIRECTORY_MISSING, location)
    try:
        _open_directory(location.directory)
    except Exception as exc:  # noqa: BLE001 - report, never crash the settings window
        return LogOpenResult(LogOpenOutcome.OPEN_FAILED, location, error=str(exc))
    return LogOpenResult(LogOpenOutcome.OPENED, location)
