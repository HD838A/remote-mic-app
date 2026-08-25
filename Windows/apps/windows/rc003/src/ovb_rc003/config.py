"""Configuration persistence with an enforced privacy contract.

Config root: ``%LOCALAPPDATA%\\RemoteMic\\RC003`` (falls back to the
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
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Union

APP_ID = "RemoteMic"
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
    from . import key_mapping

    return {
        "schema_version": SCHEMA_VERSION,
        # Existing installations predate multi-device selection and must
        # continue to open as RC003 rather than silently switching behavior.
        "selected_device_profile": "xiaomi-rc003",
        # RC003's upstream decoder applies a 10 dB speech gain before the
        # 16 kHz PCM is sent to the virtual microphone.
        "gain_db": 10.0,
        "retry_delay": 5.0,
        "max_retry_delay": 60.0,
        "voice_shortcut_enabled": True,
        # Typeless listens on Left Ctrl + Left Alt. Keep the default aligned
        # so a fresh install uses the already accepted toggle path; the
        # Qianwen preset switches both shortcut and protocol explicitly.
        "voice_hotkey": "lctrl+lalt",
        "voice_trigger_mode": "toggle",
        # Empty until the user explicitly picks one in settings; voice fails
        # closed while this is empty (see audio_output.resolve_selected_endpoint).
        # Both fields together disambiguate endpoints that share a display
        # name across host APIs (e.g. the same device exposed via both
        # Windows WASAPI and MME) - name alone is not always unique.
        "output_endpoint_name": "",
        "output_endpoint_host_api": "",
        # Voice-edge release debounce window for ADR-0003 Fix B.  Default 200 ms
        # is the 3x margin over the 65 ms RC003 firmware bounce observed on
        # 2026-08-23.  Stored value is clamped to [0.050, 0.500] s by
        # ``_normalize_voice_release_debounce``; out-of-range or invalid
        # values fall back to the 0.200 default so the debouncer cannot
        # silently regress.
        "voice_release_debounce_seconds": 0.200,
    }


# Valid range for the voice-edge release debounce window; see ADR-0003
# "Window refinement 2026-08-23".  Values outside the band fall back to the
# default so a future firmware revision that needs a wider window only has
# to lift the bound in one place.
_VOICE_RELEASE_DEBOUNCE_MIN_SECONDS = 0.050
_VOICE_RELEASE_DEBOUNCE_MAX_SECONDS = 0.500
_VOICE_RELEASE_DEBOUNCE_DEFAULT_SECONDS = 0.200


def _normalize_voice_release_debounce(config: Dict[str, Any]) -> None:
    """Clamp ``voice_release_debounce_seconds`` into its valid range.

    A non-numeric, negative, or out-of-range value silently falls back to
    the 0.200 default.  The intent is that any persistence-side corruption
    or hand-edited config.json gracefully re-routes through the same safe
    default the debouncer ships with, never letting the production widget
    silently regress to a 0 ms or 5 s window.
    """

    raw = config.get("voice_release_debounce_seconds", _VOICE_RELEASE_DEBOUNCE_DEFAULT_SECONDS)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        value = _VOICE_RELEASE_DEBOUNCE_DEFAULT_SECONDS
    if value < _VOICE_RELEASE_DEBOUNCE_MIN_SECONDS or value > _VOICE_RELEASE_DEBOUNCE_MAX_SECONDS:
        value = _VOICE_RELEASE_DEBOUNCE_DEFAULT_SECONDS
    config["voice_release_debounce_seconds"] = value


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
    _normalize_voice_hotkey(config)
    _normalize_voice_release_debounce(config)
    return config


def save_config(path: Path, config: Dict[str, Any]) -> None:
    _assert_no_forbidden_keys(config)
    persisted = dict(config)
    _normalize_voice_hotkey(persisted)
    _normalize_voice_release_debounce(persisted)
    _save_json_atomic(path, persisted)


def _normalize_voice_hotkey(config: Dict[str, Any]) -> None:
    """Keep the two built-in voice modes paired with their real shortcuts.

    Legacy built-in values are repaired, and a recorded built-in chord also
    restores its required mode if the UI previously saved the two fields out
    of sync. A user-supplied shortcut such as ``win+h`` remains untouched.
    """

    current = str(config.get("voice_hotkey", "")).strip().lower()
    from . import key_mapping

    # The former HOLD preset was Ctrl+Win. It is a shipped built-in, not a
    # user customization: migrate it to the right-Alt physical bridge and
    # repair the mode even if the two old fields were saved out of sync.
    if current in {"lctrl+win", "lctrl+lwin"}:
        config["voice_trigger_mode"] = key_mapping.VoiceTriggerMode.HOLD.value
        config["voice_hotkey"] = key_mapping.voice_hotkey_for_trigger_mode(
            key_mapping.VoiceTriggerMode.HOLD
        )
        return

    # ``lctrl+lalt`` is the shipped TOGGLE preset.  Older interrupted
    # acceptance work persisted this chord with HOLD after mistaking the
    # target's two-short-press protocol for hold-to-dictate.  Repair that
    # inconsistent pair on both load and save: the RC003 physical button
    # remains held while audio streams, while the host receives one TAP at
    # each session boundary.  Custom chords remain under explicit user
    # control below.
    if current == "lctrl+lalt":
        config["voice_trigger_mode"] = key_mapping.VoiceTriggerMode.TOGGLE.value
        return

    try:
        mode = key_mapping.VoiceTriggerMode(config.get("voice_trigger_mode"))
    except ValueError:
        mode = None

    # Qianwen's short-press option uses ralt+TOGGLE. Its process-local input
    # filter is a delivery concern and does not change the session protocol.
    if current == "ralt" and mode == key_mapping.VoiceTriggerMode.TOGGLE:
        return

    # ``lalt`` was an invalid recording of the RC003 F5 leak. Repair it only
    # for the built-in HOLD mode; arbitrary user shortcuts remain untouched.
    if mode == key_mapping.VoiceTriggerMode.HOLD and current == "lalt":
        config["voice_hotkey"] = key_mapping.voice_hotkey_for_trigger_mode(mode)
        return

    if current not in key_mapping.LEGACY_VOICE_HOTKEYS:
        inferred_mode = key_mapping.voice_trigger_mode_for_hotkey(current)
        if inferred_mode is not None:
            config["voice_trigger_mode"] = inferred_mode.value
        return

    if mode is None:
        return
    config["voice_hotkey"] = key_mapping.voice_hotkey_for_trigger_mode(mode)


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
        # Secondary gestures follow the reference project's separate map.
        # Keeping the primary action flat preserves compatibility with all
        # existing Windows config files.
        "secondary_bindings": {},
        # Physical signatures are learned from Raw Input captures. They are
        # deliberately independent of semantic actions and contain no device
        # path or Bluetooth identity.
        "physical_bindings": {},
    }


def load_key_bindings(path: Path) -> Dict[str, Any]:
    bindings = default_key_bindings()
    if path.is_file():
        with path.open("r", encoding="utf-8-sig") as handle:
            stored = json.load(handle)
        _assert_no_forbidden_keys(stored)
        for key, value in stored.items():
            if key in {"bindings", "secondary_bindings", "physical_bindings"}:
                if isinstance(value, dict):
                    current = bindings.get(key)
                    if not isinstance(current, dict):
                        current = {}
                        bindings[key] = current
                    current.update(value)
                else:
                    bindings[key] = value
            else:
                bindings[key] = value
    if not isinstance(bindings.get("bindings"), dict):
        bindings["bindings"] = {}
    if not isinstance(bindings.get("secondary_bindings"), dict):
        bindings["secondary_bindings"] = {}
    _normalize_physical_bindings(bindings)
    _normalize_semantic_actions(bindings)
    _normalize_mic_binding(bindings)
    _normalize_secondary_bindings(bindings)
    return bindings


def _normalize_semantic_actions(bindings: Dict[str, Any]) -> None:
    """Migrate old reference-looking key chords to real action kinds.

    Builds before the semantic action layer wrote values such as
    ``{"kind":"key_combo","keys":["up"]}``.  Keeping those values in
    memory would make the UI look correct while the runtime still takes the
    generic shortcut path.  Convert only the exact built-in chords; arbitrary
    user-recorded combinations remain custom ``key_combo`` actions.
    """

    from . import key_mapping

    def normalize(raw: Any) -> Any:
        if not isinstance(raw, dict):
            return raw
        try:
            action = key_mapping.ButtonAction.from_dict(raw)
        except (KeyError, TypeError, ValueError):
            return raw
        migrated = key_mapping.semantic_action_for_keys(action.keys)
        return migrated.to_dict() if migrated is not None else raw

    primary = bindings.get("bindings")
    if isinstance(primary, dict):
        for button_id, raw in list(primary.items()):
            primary[button_id] = normalize(raw)

    secondary = bindings.get("secondary_bindings")
    if isinstance(secondary, dict):
        for button_id, trigger_map in list(secondary.items()):
            if not isinstance(trigger_map, dict):
                continue
            for trigger_name, raw in list(trigger_map.items()):
                trigger_map[trigger_name] = normalize(raw)


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


def _normalize_secondary_bindings(bindings: Dict[str, Any]) -> None:
    """Keep optional double/long mappings structurally safe on load.

    A malformed secondary entry is ignored by the runtime action lookup, but
    the container itself must still be a mapping so a damaged config cannot
    make the settings page or save path crash.  The microphone is excluded:
    it is always owned by the ATVV voice lifecycle, never ordinary gestures.
    """

    secondary = bindings.get("secondary_bindings")
    if not isinstance(secondary, dict):
        bindings["secondary_bindings"] = {}
        return
    secondary.pop("mic", None)
    for button_id in list(secondary):
        entry = secondary[button_id]
        if not isinstance(entry, dict):
            secondary.pop(button_id, None)
            continue
        for trigger in list(entry):
            if trigger not in {"double_click", "long_press"} or not isinstance(
                entry[trigger], dict
            ):
                entry.pop(trigger, None)
        if not entry:
            secondary.pop(button_id, None)


def _normalize_physical_bindings(bindings: Dict[str, Any]) -> None:
    """Keep learned physical overrides portable and action-safe."""

    from . import device_profile

    physical = bindings.get("physical_bindings")
    if not isinstance(physical, dict):
        bindings["physical_bindings"] = {}
        return
    bindings["physical_bindings"] = {
        str(signature): str(button_id)
        for signature, button_id in physical.items()
        if isinstance(signature, str)
        and signature.strip()
        and isinstance(button_id, str)
        and button_id in device_profile.ALL_BUTTON_IDS
    }


def save_key_bindings(path: Path, bindings: Dict[str, Any]) -> None:
    _assert_no_forbidden_keys(bindings)
    _save_json_atomic(path, bindings)


def _save_json_atomic(path: Path, data: Dict[str, Any]) -> None:
    """Write one settings file without exposing a half-written JSON file."""

    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise
