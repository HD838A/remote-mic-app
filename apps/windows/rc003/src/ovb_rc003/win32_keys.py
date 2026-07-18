"""Virtual-key code table and pure key-token resolution.

Split out from the actual Win32 ``SendInput`` call (see app.py) so the token
-> VK mapping is unit-testable without ctypes/user32 on any OS.
"""

from __future__ import annotations

from typing import List, Sequence

# Standard Windows virtual-key codes (winuser.h).
VK_CODES = {
    "backspace": 0x08,
    "tab": 0x09,
    "enter": 0x0D,
    "shift": 0x10,
    "ctrl": 0x11,
    "alt": 0x12,
    "escape": 0x1B,
    "esc": 0x1B,
    "space": 0x20,
    "left": 0x25,
    "up": 0x26,
    "right": 0x27,
    "down": 0x28,
    "win": 0x5B,
    "volume_mute": 0xAD,
    "volume_down": 0xAE,
    "volume_up": 0xAF,
    "f10": 0x79,
    "d": 0x44,
    "h": 0x48,
}

for _digit in range(10):
    VK_CODES[str(_digit)] = 0x30 + _digit
for _letter_ord in range(ord("a"), ord("z") + 1):
    VK_CODES[chr(_letter_ord)] = 0x41 + (_letter_ord - ord("a"))


class UnknownKeyTokenError(ValueError):
    pass


def resolve_vk_codes(tokens: Sequence[str]) -> List[int]:
    """Resolve an ordered sequence of key tokens (e.g. ``("win", "d")``) into
    Windows virtual-key codes, raising if any token is unrecognized.
    """

    codes = []
    for token in tokens:
        key = token.strip().lower()
        if key not in VK_CODES:
            raise UnknownKeyTokenError(f"unknown key token: {token!r}")
        codes.append(VK_CODES[key])
    return codes
