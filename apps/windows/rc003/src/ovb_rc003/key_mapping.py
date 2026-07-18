"""Default RC003 -> Windows action mapping.

Pure data/logic module (no platform dependency). The actual key-injection
call (e.g. SendInput) lives in the Windows-only app wiring.

Default table matches the XRBM-014 task book's "默认 Windows 映射候选":

| RC003 按键 | Windows 候选动作 |
| --- | --- |
| 麦克风 | Win+H（按下开始、松开结束的 toggle 边沿；UI 可改） |
| 电源 | Escape |
| 上 / 下 / 左 / 右 | 对应方向键 |
| 确定 | Enter |
| 返回 | Backspace |
| 音量 + / − | 系统音量 + / − |
| 主页 | Win+D |
| 菜单 | Shift+F10 |
| TV | Alt+Esc |

The RC003 HID usage table also defines a "volume_mute" usage (see
device_profile.BUTTON_USAGE_IDS), but this project's macOS adapter documents
that the physical remote has no dedicated mute key - "系统静音" is only an
optional assignable action, never a default. This module mirrors that: mute
is a valid, bindable logical button but intentionally has no default entry.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, Tuple


class ActionKind(str, Enum):
    KEY_COMBO = "key_combo"
    SYSTEM_VOLUME_UP = "system_volume_up"
    SYSTEM_VOLUME_DOWN = "system_volume_down"
    VOICE = "voice"


class VoiceTriggerMode(str, Enum):
    TOGGLE = "toggle"
    HOLD = "hold"


@dataclass(frozen=True)
class ButtonAction:
    kind: ActionKind
    keys: Tuple[str, ...] = field(default_factory=tuple)

    def to_dict(self) -> dict:
        return {"kind": self.kind.value, "keys": list(self.keys)}

    @classmethod
    def from_dict(cls, data: dict) -> "ButtonAction":
        return cls(kind=ActionKind(data["kind"]), keys=tuple(data.get("keys", ())))


# Buttons that have a defined default action out of the box. "volume_mute" is
# deliberately absent (see module docstring).
DEFAULT_BUTTON_IDS = frozenset(
    {
        "mic",
        "power",
        "up",
        "down",
        "left",
        "right",
        "ok",
        "back",
        "volume_up",
        "volume_down",
        "home",
        "menu",
        "tv",
    }
)


def default_button_actions() -> Dict[str, ButtonAction]:
    return {
        "mic": ButtonAction(ActionKind.VOICE),
        "power": ButtonAction(ActionKind.KEY_COMBO, ("escape",)),
        "up": ButtonAction(ActionKind.KEY_COMBO, ("up",)),
        "down": ButtonAction(ActionKind.KEY_COMBO, ("down",)),
        "left": ButtonAction(ActionKind.KEY_COMBO, ("left",)),
        "right": ButtonAction(ActionKind.KEY_COMBO, ("right",)),
        "ok": ButtonAction(ActionKind.KEY_COMBO, ("enter",)),
        "back": ButtonAction(ActionKind.KEY_COMBO, ("backspace",)),
        "volume_up": ButtonAction(ActionKind.SYSTEM_VOLUME_UP),
        "volume_down": ButtonAction(ActionKind.SYSTEM_VOLUME_DOWN),
        "home": ButtonAction(ActionKind.KEY_COMBO, ("win", "d")),
        "menu": ButtonAction(ActionKind.KEY_COMBO, ("shift", "f10")),
        "tv": ButtonAction(ActionKind.KEY_COMBO, ("alt", "esc")),
    }
