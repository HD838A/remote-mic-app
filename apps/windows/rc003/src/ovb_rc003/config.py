"""Configuration persistence with an enforced privacy contract.

Config root: ``%LOCALAPPDATA%\\OpenVoiceBridge\\RC003`` (falls back to the
user's home directory if ``LOCALAPPDATA`` is unset, e.g. when unit testing on
non-Windows). Two JSON files live there: ``config.json`` (tuning/behavior) and
``key_bindings.json`` (per-button actions plus the voice hotkey).

Hard privacy rule: neither file may ever contain a real Bluetooth address,
HID device interface path/GUID, or device token. ``save_config`` and
``save_key_bindings`` actively refuse to write any of ``FORBIDDEN_KEYS`` -
this is enforced in code, not just by convention, and is covered by
tests/test_config.py and tests/test_privacy_contract.py.

The guard walks the ENTIRE structure recursively (nested dicts, and dicts
nested inside lists at any depth), not just the top-level keys - a field
like ``bindings.menu.metadata.address`` is refused exactly the same as a
top-level ``address`` key (see XRBM-014 review RETRY P1 #6).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict, List, Union

APP_ID = "OpenVoiceBridge"
PRODUCT_ID = "RC003"

CONFIG_FILENAME = "config.json"
KEY_BINDINGS_FILENAME = "key_bindings.json"

SCHEMA_VERSION = 1

# Any config key matching one of these names is refused at save time,
# regardless of which file it would land in.
FORBIDDEN_KEYS = frozenset(
    {
        "address",
        "bluetooth_address",
        "bt_address",
        "mac_address",
        "device_match",
        "device_token",
        "interface_id",
        "device_interface_id",
    }
)


class ConfigPrivacyError(Exception):
    """Raised when code attempts to persist a forbidden identity field."""


def config_root() -> Path:
    base = os.environ.get("LOCALAPPDATA")
    if not base:
        base = str(Path.home())
    return Path(base) / APP_ID / PRODUCT_ID


def config_path(root: Path = None) -> Path:  # type: ignore[assignment]
    return (root or config_root()) / CONFIG_FILENAME


def key_bindings_path(root: Path = None) -> Path:  # type: ignore[assignment]
    return (root or config_root()) / KEY_BINDINGS_FILENAME


def default_config() -> Dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "gain_db": 0.0,
        "retry_delay": 2.0,
        "voice_shortcut_enabled": True,
        "voice_hotkey": "win+h",
        "voice_trigger_mode": "toggle",
        # Empty until the user explicitly picks one in settings; voice fails
        # closed while this is empty (see audio_output.resolve_selected_endpoint).
        # Both fields together disambiguate endpoints that share a display
        # name across host APIs (e.g. the same device exposed via both
        # Windows WASAPI and MME) - name alone is not always unique.
        "output_endpoint_name": "",
        "output_endpoint_host_api": "",
    }


def _find_forbidden_key_paths(
    node: Union[Dict[str, Any], List[Any], Any], path: str = ""
) -> List[str]:
    """Recursively collect dotted-path locations of any forbidden key,
    found at any nesting depth inside dicts and lists-of-dicts.
    """

    found: List[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            child_path = f"{path}.{key}" if path else str(key)
            if key in FORBIDDEN_KEYS:
                found.append(child_path)
            found.extend(_find_forbidden_key_paths(value, child_path))
    elif isinstance(node, list):
        for index, item in enumerate(node):
            found.extend(_find_forbidden_key_paths(item, f"{path}[{index}]"))
    return found


def _assert_no_forbidden_keys(data: Dict[str, Any]) -> None:
    found = _find_forbidden_key_paths(data)
    if found:
        raise ConfigPrivacyError(
            "refusing to persist forbidden identity field(s) at: "
            + ", ".join(sorted(found))
        )


def load_config(path: Path) -> Dict[str, Any]:
    config = default_config()
    if path.is_file():
        with path.open("r", encoding="utf-8-sig") as handle:
            stored = json.load(handle)
        _assert_no_forbidden_keys(stored)
        config.update(stored)
    return config


def save_config(path: Path, config: Dict[str, Any]) -> None:
    _assert_no_forbidden_keys(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2, sort_keys=True)
        handle.write("\n")


def default_key_bindings() -> Dict[str, Any]:
    # Imported lazily to avoid a hard import-order dependency between the two
    # modules at package-load time.
    from . import key_mapping

    return {
        "schema_version": SCHEMA_VERSION,
        "bindings": {
            button_id: action.to_dict()
            for button_id, action in key_mapping.default_button_actions().items()
        },
    }


def load_key_bindings(path: Path) -> Dict[str, Any]:
    bindings = default_key_bindings()
    if path.is_file():
        with path.open("r", encoding="utf-8-sig") as handle:
            stored = json.load(handle)
        _assert_no_forbidden_keys(stored)
        bindings.update(stored)
    _normalize_mic_binding(bindings)
    return bindings


def _normalize_mic_binding(bindings: Dict[str, Any]) -> None:
    """The runtime never consults a stored ``mic`` binding at all - the
    physical mic button is always driven directly by the ATVV voice
    lifecycle (see app.py's ``_handle_mic_button_pressed``/
    ``_on_control_event``), never by ``ActionKind`` dispatch. A stale
    non-voice ``mic`` entry (from an older build, a hand-edited file, or a
    corrupted save) must not be silently kept around looking like it does
    something it doesn't - force it back to ``ActionKind.VOICE`` in place,
    in memory, every time bindings are loaded (XRBM-018's independent
    review round 2 product-contract follow-up, folded
    into XRBM-019 In-scope item 6).
    """

    # Imported lazily, matching default_key_bindings()'s own import-order
    # reasoning above.
    from . import key_mapping

    button_bindings = bindings.setdefault("bindings", {})
    button_bindings["mic"] = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE).to_dict()


def save_key_bindings(path: Path, bindings: Dict[str, Any]) -> None:
    _assert_no_forbidden_keys(bindings)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(bindings, handle, indent=2, sort_keys=True)
        handle.write("\n")
