"""Hotkey specification parsing/serialization.

Deliberately simple compared to the upstream reference's low-level-keyboard-
hook shortcut capture: it models a hotkey as an ordered tuple of modifier
tokens plus one final trigger token, serialized as "mod+mod+key" (e.g.
"win+h"). A chord made entirely from modifier keys, such as
"lctrl+win", stores its last modifier as that final trigger token so it can
use the same runtime and serialization path as ordinary key combinations.
The actual OS-level key-down/key-up hooking lives in the Windows-only app
wiring (app.py), not here.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Tuple

from . import key_mapping

_MODIFIER_ORDER = (
    "ctrl", "shift", "alt", "win",
    "lctrl", "rctrl", "lshift", "rshift", "lalt", "ralt", "lwin", "rwin",
)
_VALID_MODIFIERS = frozenset(_MODIFIER_ORDER)
_TOKEN_ALIASES = {
    "left_ctrl": "lctrl",
    "right_ctrl": "rctrl",
    "left_shift": "lshift",
    "right_shift": "rshift",
    "left_alt": "lalt",
    "right_alt": "ralt",
    "left_win": "lwin",
    "right_win": "rwin",
}


class HotkeyParseError(ValueError):
    pass


@dataclass(frozen=True)
class HotkeySpec:
    modifiers: Tuple[str, ...]
    key: str

    def __post_init__(self) -> None:
        if not self.key:
            raise HotkeyParseError("hotkey must have a trigger key")
        for modifier in self.modifiers:
            if modifier not in _VALID_MODIFIERS:
                raise HotkeyParseError(f"unknown modifier: {modifier!r}")

    def serialize(self) -> str:
        ordered = tuple(m for m in _MODIFIER_ORDER if m in self.modifiers)
        return "+".join((*ordered, self.key.lower()))

    @classmethod
    def parse(cls, text: str) -> "HotkeySpec":
        if not text or not text.strip():
            raise HotkeyParseError("hotkey text must not be empty")
        tokens = [
            _TOKEN_ALIASES.get(token.strip().lower(), token.strip().lower())
            for token in text.split("+")
            if token.strip()
        ]
        if not tokens:
            raise HotkeyParseError(f"could not parse hotkey: {text!r}")
        # A directional modifier can itself be the trigger key (the voice
        # client's HOLD mode uses the physical right Alt key alone).
        if len(tokens) == 1 and tokens[0] in {
            "lctrl", "rctrl", "lshift", "rshift", "lalt", "ralt", "lwin", "rwin"
        }:
            return cls(modifiers=(), key=tokens[0])
        modifiers = tuple(modifier for modifier in _MODIFIER_ORDER if modifier in tokens)
        keys = [token for token in tokens if token not in _VALID_MODIFIERS]
        if not keys:
            # A modifier-only chord still has a meaningful edge: press the
            # earlier modifiers first and use the final modifier as the
            # trigger. This is what makes settings such as left Ctrl + Win
            # representable instead of incorrectly rejecting them as having
            # no "real" key.
            if len(tokens) < 2:
                raise HotkeyParseError(
                    f"hotkey must contain at least two keys: {text!r}"
                )
            trigger = tokens[-1]
            modifiers = tuple(
                modifier
                for modifier in _MODIFIER_ORDER
                if modifier in tokens[:-1]
            )
            return cls(modifiers=modifiers, key=trigger)
        if len(keys) != 1:
            raise HotkeyParseError(
                f"hotkey must have exactly one non-modifier key: {text!r}"
            )
        return cls(modifiers=modifiers, key=keys[0])


# A deliberately uncommon default for fresh installations. Users who rely on
# Windows Voice Typing can change this back to ``win+h``; third-party input
# methods can bind the same chord in their own shortcut settings. Existing
# config files keep their saved value because config.load_config() merges them
# over default_config().
DEFAULT_VOICE_HOTKEY = HotkeySpec.parse(
    key_mapping.voice_hotkey_for_trigger_mode(key_mapping.VoiceTriggerMode.TOGGLE)
)
