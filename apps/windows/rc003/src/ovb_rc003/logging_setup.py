"""Logging configuration that never touches voice content or device identity.

Callers must only ever log opaque markers (button names, session ids,
sample/frame counts, boolean flags) - never a Bluetooth address, HID
interface path, device token, or decoded voice content. This module doesn't
attempt to scrub arbitrary strings after the fact (a redaction filter would
give false confidence); the guarantee instead comes from code review plus
tests/test_privacy_contract.py, which statically scans this package's source
for the sensitive field names and MAC-address-shaped literals.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

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
    log_dir = (root or config.config_root()) / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    handler = logging.FileHandler(log_dir / LOG_FILENAME, encoding="utf-8")
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    logger.addHandler(handler)
    _configured = True
    return logger
