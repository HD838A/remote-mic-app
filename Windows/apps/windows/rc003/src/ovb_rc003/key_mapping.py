"""RC003 -> Windows *semantic* action mapping.

The reference app stores behavior actions (``arrowUp``, ``showDesktop``,
``openCodex``), not presentation strings such as ``"up"`` or
``"win+d"``.  Windows keeps that same separation: this module is pure action
data, while :mod:`app` and :mod:`win32_input` execute each action through its
own platform operation.  ``KEY_COMBO`` remains available for a genuinely
custom user shortcut and for backward-compatible hand-edited files.

Default table matches the reference app's action choices:

| RC003 按键 | Windows 候选动作 |
| --- | --- |
| 麦克风 | 专用语音生命周期 |
| 电源 | Escape |
| 上 / 下 / 左 / 右 | 对应方向动作 |
| 确定 | Return |
| 返回 | Delete（退格） |
| 音量 + / − | 系统音量 + / − |
| 主页 | 显示桌面 |
| 菜单 | 上下文菜单 |
| TV | 应用切换 |

The RC003 HID usage table also defines a "volume_mute" usage (see
device_profile.BUTTON_USAGE_IDS), but this Windows client documents that the
physical remote has no dedicated mute key - "系统静音" is only an optional
assignable action, never a default. This module mirrors that: mute is a valid,
bindable logical button but intentionally has no default entry.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, Optional, Tuple


class ActionKind(str, Enum):
    DISABLED = "disabled"
    KEY_COMBO = "key_combo"
    ESCAPE = "escape"
    RETURN = "return"
    ARROW_UP = "arrow_up"
    ARROW_DOWN = "arrow_down"
    ARROW_LEFT = "arrow_left"
    ARROW_RIGHT = "arrow_right"
    DELETE_BACKWARD = "delete_backward"
    SHOW_DESKTOP = "show_desktop"
    CONTEXT_MENU = "context_menu"
    APP_SWITCHER = "app_switcher"
    SYSTEM_VOLUME_UP = "system_volume_up"
    SYSTEM_VOLUME_DOWN = "system_volume_down"
    SYSTEM_VOLUME_MUTE = "system_volume_mute"
    PLAY_PAUSE = "play_pause"
    VOICE = "voice"
    OPEN_REMOTE_MIC = "open_remote_mic"
    OPEN_CODEX = "open_codex"
    OPEN_CLAUDE = "open_claude"
    OPEN_CMUX = "open_cmux"
    OPEN_WECHAT = "open_wechat"
    OPEN_CURSOR = "open_cursor"
    OPEN_SLACK = "open_slack"
    OPEN_WECOM = "open_wecom"
    OPEN_NETEASE_MUSIC = "open_netease_music"
    OPEN_CHROME = "open_chrome"
    OPEN_EDGE = "open_edge"
    OPEN_ZED = "open_zed"


class ButtonTrigger(str, Enum):
    """The three gestures available for an ordinary RC003 button."""

    SINGLE_CLICK = "single_click"
    DOUBLE_CLICK = "double_click"
    LONG_PRESS = "long_press"


class VoiceTriggerMode(str, Enum):
    TOGGLE = "toggle"
    HOLD = "hold"


class VoiceInputPreset(str, Enum):
    TYPELESS = "typeless"
    QIANWEN = "qianwen"


VOICE_INPUT_PRESET_HOTKEYS = {
    VoiceInputPreset.TYPELESS: "lctrl+lalt",
    VoiceInputPreset.QIANWEN: "ralt",
}

VOICE_INPUT_PRESET_TRIGGER_MODES = {
    VoiceInputPreset.TYPELESS: VoiceTriggerMode.TOGGLE,
    # Qianwen's short-press option uses the same boundary TAP protocol, but
    # its verified target callback requires a process-local physicalizer.
    VoiceInputPreset.QIANWEN: VoiceTriggerMode.TOGGLE,
}


def voice_hotkey_for_input_preset(preset: VoiceInputPreset) -> str:
    """Return the host shortcut configured by an application preset."""

    return VOICE_INPUT_PRESET_HOTKEYS[preset]


def voice_trigger_mode_for_input_preset(
    preset: VoiceInputPreset,
) -> VoiceTriggerMode:
    """Return the RC003-to-host protocol required by an application preset."""

    return VOICE_INPUT_PRESET_TRIGGER_MODES[preset]


def voice_input_preset_for_hotkey(hotkey_text: str) -> Optional[VoiceInputPreset]:
    normalized = "+".join(
        token.strip().lower()
        for token in str(hotkey_text).split("+")
        if token.strip()
    )
    normalized_tokens = frozenset(normalized.split("+"))
    for preset, preset_hotkey in VOICE_INPUT_PRESET_HOTKEYS.items():
        if normalized_tokens == frozenset(preset_hotkey.split("+")):
            return preset
    return None


VOICE_HOTKEY_PRESETS = {
    # Compatibility mapping retained for custom/older mode-oriented callers.
    VoiceTriggerMode.TOGGLE: "lctrl+lalt",
    # Doubao's long-press mode is configured as the physical right Alt key.
    # The Windows bridge emits a right-Alt virtual-key edge after swallowing
    # RC003's leaked F5, so the host never sees F5 or a left-side modifier.
    VoiceTriggerMode.HOLD: "ralt",
}

# These values were shipped by earlier Windows builds. They are reserved
# built-ins rather than user customizations, so config migration may replace
# either spelling with the current physical shortcut.
LEGACY_VOICE_HOTKEYS = frozenset(
    {"ralt", "ralt+space", "lctrl+lalt", "lctrl+win", "lctrl+lwin"}
)


# Exact old Windows chords that were previously presented as the reference
# action labels.  These are migrations, not the representation used for new
# saves.  ``alt+esc`` is included because the first Windows build shipped it
# as the TV default before it was corrected to the native app-switch action.
LEGACY_SEMANTIC_ACTIONS = {
    ("escape",): ActionKind.ESCAPE,
    ("enter",): ActionKind.RETURN,
    ("up",): ActionKind.ARROW_UP,
    ("down",): ActionKind.ARROW_DOWN,
    ("left",): ActionKind.ARROW_LEFT,
    ("right",): ActionKind.ARROW_RIGHT,
    ("backspace",): ActionKind.DELETE_BACKWARD,
    ("win", "d"): ActionKind.SHOW_DESKTOP,
    ("shift", "f10"): ActionKind.CONTEXT_MENU,
    ("alt", "tab"): ActionKind.APP_SWITCHER,
    ("alt", "esc"): ActionKind.APP_SWITCHER,
}


APPLICATION_ACTIONS = frozenset(
    {
        ActionKind.OPEN_REMOTE_MIC,
        ActionKind.OPEN_CODEX,
        ActionKind.OPEN_CLAUDE,
        ActionKind.OPEN_CMUX,
        ActionKind.OPEN_WECHAT,
        ActionKind.OPEN_CURSOR,
        ActionKind.OPEN_SLACK,
        ActionKind.OPEN_WECOM,
        ActionKind.OPEN_NETEASE_MUSIC,
        ActionKind.OPEN_CHROME,
        ActionKind.OPEN_EDGE,
        ActionKind.OPEN_ZED,
    }
)


def semantic_action_for_keys(keys: Tuple[str, ...]) -> Optional["ButtonAction"]:
    """Return the semantic action represented by one legacy key tuple."""

    action_kind = LEGACY_SEMANTIC_ACTIONS.get(tuple(keys))
    if action_kind is None:
        return None
    return ButtonAction(action_kind)


def action_allows_repeat(action: "ButtonAction") -> bool:
    """Match the reference app's ``allowsRepeat`` behavior.

    Opening an application is a one-shot operation.  Keyboard/system actions
    can repeat when the physical button itself is a repeatable control.
    """

    return action.kind not in APPLICATION_ACTIONS


def voice_trigger_mode_for_hotkey(hotkey_text: str) -> Optional[VoiceTriggerMode]:
    """Infer the built-in voice trigger semantics from a recorded chord.

    The two current Doubao voice modes are not interchangeable: ``ralt+space``
    is a toggle, while ``ralt`` is held for the duration of speech. The old
    Ctrl+Win chord is still recognized so legacy settings and recordings can
    be migrated, but it is not the current HOLD preset. A physical recorder
    can return either generic or directional Win, and users may press the
    keys in either order, so compare the normalized token set. Return ``None``
    for a genuinely custom shortcut and leave its selected mode under user
    control.
    """

    tokens = frozenset(
        token.strip().lower()
        for token in str(hotkey_text).split("+")
        if token.strip()
    )
    if tokens == frozenset({"ralt"}):
        return VoiceTriggerMode.TOGGLE
    if tokens == frozenset({"ralt", "space"}):
        return VoiceTriggerMode.TOGGLE
    # Typeless's toggle chord is Left Ctrl + Left Alt; a config
    # that recorded only the hotkey (no mode) must round-trip back to
    # TOGGLE so the bridge still injects the discrete double-tap.
    if tokens == frozenset({"lctrl", "lalt"}):
        return VoiceTriggerMode.TOGGLE
    if (
        len(tokens) == 2
        and "lctrl" in tokens
        and bool(tokens & {"win", "lwin", "rwin"})
    ):
        return VoiceTriggerMode.HOLD
    return None


def voice_hotkey_for_trigger_mode(trigger_mode: VoiceTriggerMode) -> str:
    """Return the host shortcut paired with a voice trigger mode."""

    return VOICE_HOTKEY_PRESETS[trigger_mode]


@dataclass(frozen=True)
class ButtonAction:
    kind: ActionKind
    keys: Tuple[str, ...] = field(default_factory=tuple)

    def to_dict(self) -> dict:
        return {"kind": self.kind.value, "keys": list(self.keys)}

    @classmethod
    def from_dict(cls, data: dict) -> "ButtonAction":
        if not isinstance(data, dict):
            raise TypeError("button action must be a mapping")
        kind = ActionKind(data["kind"])
        raw_keys = data.get("keys", ())
        if not isinstance(raw_keys, (list, tuple)) or not all(
            isinstance(key, str) and key.strip() for key in raw_keys
        ):
            raise ValueError("button action keys must be non-empty strings")
        keys = tuple(key.strip().lower() for key in raw_keys)
        if kind == ActionKind.KEY_COMBO and not keys:
            raise ValueError("key_combo action must contain at least one key")
        if kind != ActionKind.KEY_COMBO and keys:
            raise ValueError("non-key action must not contain keys")
        return cls(kind=kind, keys=keys)


def button_action_for(
    bindings: Dict[str, object], button_id: str, trigger: ButtonTrigger
) -> ButtonAction:
    """Read one gesture action from the versioned bindings document.

    The original Windows build stored the single action directly under each
    button.  Secondary actions use the reference project's separate map so
    every existing ``key_bindings.json`` remains valid and keeps its primary
    mapping unchanged.
    """

    button_bindings = bindings.get("bindings", {})
    if not isinstance(button_bindings, dict):
        return ButtonAction(ActionKind.DISABLED)
    if trigger == ButtonTrigger.SINGLE_CLICK:
        raw = button_bindings.get(button_id)
    else:
        secondary = bindings.get("secondary_bindings", {})
        raw = (
            secondary.get(button_id, {}).get(trigger.value)
            if isinstance(secondary, dict)
            and isinstance(secondary.get(button_id, {}), dict)
            else None
        )
    if not isinstance(raw, dict):
        return ButtonAction(ActionKind.DISABLED)
    try:
        return ButtonAction.from_dict(raw)
    except (KeyError, TypeError, ValueError):
        return ButtonAction(ActionKind.DISABLED)


def has_secondary_action(bindings: Dict[str, object], button_id: str) -> bool:
    return any(
        button_action_for(bindings, button_id, trigger).kind != ActionKind.DISABLED
        for trigger in (ButtonTrigger.DOUBLE_CLICK, ButtonTrigger.LONG_PRESS)
    )


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
        "power": ButtonAction(ActionKind.ESCAPE),
        "up": ButtonAction(ActionKind.ARROW_UP),
        "down": ButtonAction(ActionKind.ARROW_DOWN),
        "left": ButtonAction(ActionKind.ARROW_LEFT),
        "right": ButtonAction(ActionKind.ARROW_RIGHT),
        "ok": ButtonAction(ActionKind.RETURN),
        "back": ButtonAction(ActionKind.DELETE_BACKWARD),
        "volume_up": ButtonAction(ActionKind.SYSTEM_VOLUME_UP),
        "volume_down": ButtonAction(ActionKind.SYSTEM_VOLUME_DOWN),
        "home": ButtonAction(ActionKind.SHOW_DESKTOP),
        "menu": ButtonAction(ActionKind.CONTEXT_MENU),
        "tv": ButtonAction(ActionKind.APP_SWITCHER),
    }
