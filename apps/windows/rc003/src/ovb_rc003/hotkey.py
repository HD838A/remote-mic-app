"""Hotkey specification parsing/serialization.

Deliberately simple compared to the upstream reference's low-level-keyboard-
hook shortcut capture: it models a hotkey as an ordered tuple of modifier
tokens plus one final key token, serialized as "mod+mod+key" (e.g. "win+h").
The actual OS-level key-down/key-up hooking lives in the Windows-only app
wiring (app.py), not here.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Tuple

_MODIFIER_ORDER = ("ctrl", "shift", "alt", "win")
_VALID_MODIFIERS = frozenset(_MODIFIER_ORDER)


class HotkeyParseError(ValueError):
    pass


@dataclass(frozen=True)
class HotkeySpec:
    modifiers: Tuple[str, ...]
    key: str

    def __post_init__(self) -> None:
        if not self.key:
            raise HotkeyParseError("hotkey must have a non-modifier key")
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
        tokens = [token.strip().lower() for token in text.split("+") if token.strip()]
        if not tokens:
            raise HotkeyParseError(f"could not parse hotkey: {text!r}")
        modifiers = tuple(token for token in tokens if token in _VALID_MODIFIERS)
        keys = [token for token in tokens if token not in _VALID_MODIFIERS]
        if len(keys) != 1:
            raise HotkeyParseError(
                f"hotkey must have exactly one non-modifier key: {text!r}"
            )
        return cls(modifiers=modifiers, key=keys[0])


DEFAULT_VOICE_HOTKEY = HotkeySpec(modifiers=("win",), key="h")
