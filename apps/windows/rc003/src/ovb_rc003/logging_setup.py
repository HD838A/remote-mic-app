"""Logging configuration that never persists voice content or device identity.

Callers log opaque markers (button names, session ids, sample/frame counts,
boolean flags) - never a Bluetooth address, HID interface path, device token,
or decoded voice content. Two independent layers enforce this:

1. Code review + tests/test_privacy_contract.py statically scan this package's
   source for sensitive field names and MAC-address-shaped literals.
2. A runtime redaction filter on the FileHandler scrubs any MAC-address-shaped,
   Bluetooth device-id-shaped, or long raw-byte-repr string that could still
   reach a log record via an exception message (defense in depth; a WinRT or
   protocol exception must never be able to echo a device identity into the
   persistent log). Static scanning alone cannot cover interpolated values.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Optional

from . import config

LOGGER_NAME = "ovb_rc003"
LOG_FILENAME = "app.log"

_configured = False

# Device-identity shapes that must never appear in app.log even if a lower
# layer puts them into an exception's text. Keep this deliberately narrow so
# ordinary opaque markers (button names, counts, booleans) pass through.
_REDACT_PATTERNS = (
    re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"),  # MAC
    re.compile(r"BluetoothLE#Bluetooth[A-Za-z0-9:#\-\.]+", re.IGNORECASE),
    re.compile(r"b'[0-9A-Fa-f\s]{24,}'"),  # long raw byte repr
)
_REDACTED = "[redacted]"


def _redact(text: str) -> str:
    for pattern in _REDACT_PATTERNS:
        text = pattern.sub(_REDACTED, text)
    return text


class _PrivacyFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            record.msg = _redact(str(record.getMessage()))
            record.args = ()
        except Exception:  # pragma: no cover - never let logging break the app
            record.msg = _REDACTED
            record.args = ()
        return True


def get_logger(root: Optional[Path] = None) -> logging.Logger:
    global _configured
    logger = logging.getLogger(LOGGER_NAME)
    if _configured:
        return logger

    logger.setLevel(logging.INFO)
    log_dir = (root or config.config_root()) / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    handler = logging.FileHandler(log_dir / LOG_FILENAME, encoding="utf-8")
    handler.addFilter(_PrivacyFilter())
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    logger.addHandler(handler)
    _configured = True
    return logger
