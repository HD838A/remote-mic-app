"""RC003 实体按键、手势与 Windows 动作的纯数据模型。"""

from __future__ import annotations

from dataclasses import dataclass

from . import win32_input


@dataclass(frozen=True)
class RemoteButton:
    button_id: str
    display_name: str


REMOTE_BUTTONS = (
    RemoteButton("power", "电源"),
    RemoteButton("up", "上"),
    RemoteButton("left", "左"),
    RemoteButton("ok", "确定"),
    RemoteButton("right", "右"),
    RemoteButton("down", "下"),
    RemoteButton("back", "返回"),
    RemoteButton("volume_up", "音量 +"),
    RemoteButton("home", "主页"),
    RemoteButton("volume_down", "音量 −"),
    RemoteButton("menu", "菜单"),
    RemoteButton("tv", "TV"),
    RemoteButton("mic", "麦克风"),
)

BUTTON_IDS = frozenset(button.button_id for button in REMOTE_BUTTONS)
BUTTON_NAMES = {button.button_id: button.display_name for button in REMOTE_BUTTONS}

SINGLE_CLICK = "single_click"
DOUBLE_CLICK = "double_click"
LONG_PRESS = "long_press"
TRIGGERS = (SINGLE_CLICK, DOUBLE_CLICK, LONG_PRESS)

ACTION_LABELS = {
    "disabled": "无操作",
    "voice": "语音（固定）",
    "escape": "Escape",
    "return": "回车",
    "arrow_up": "方向键 ↑",
    "arrow_down": "方向键 ↓",
    "arrow_left": "方向键 ←",
    "arrow_right": "方向键 →",
    "delete_backward": "退格",
    "show_desktop": "显示桌面",
    "context_menu": "上下文菜单",
    "app_switcher": "切换应用",
    "system_volume_up": "系统音量 +",
    "system_volume_down": "系统音量 −",
    "system_volume_mute": "系统静音",
    "play_pause": "播放 / 暂停",
    "open_remote_mic": "打开 Remote Mic",
    "open_codex": "打开 Codex",
    "open_claude": "打开 Claude",
    "open_wechat": "打开微信",
    "open_cursor": "打开 Cursor",
    "open_slack": "打开 Slack",
    "open_chrome": "打开 Chrome",
    "open_edge": "打开 Edge",
}

ACTION_IDS = frozenset(ACTION_LABELS)
LABEL_TO_ACTION = {label: action for action, label in ACTION_LABELS.items()}
CUSTOM_SHORTCUT_PREFIX = "shortcut:"
CUSTOM_SHORTCUT_LABEL_PREFIX = "快捷键："

DEFAULT_SINGLE_ACTIONS = {
    "power": "escape",
    "up": "arrow_up",
    "left": "arrow_left",
    "ok": "return",
    "right": "arrow_right",
    "down": "arrow_down",
    "back": "delete_backward",
    "volume_up": "system_volume_up",
    "home": "show_desktop",
    "volume_down": "system_volume_down",
    "menu": "context_menu",
    "tv": "app_switcher",
    "mic": "voice",
}

REPEATABLE_ACTIONS = frozenset(
    {
        "arrow_up",
        "arrow_down",
        "arrow_left",
        "arrow_right",
        "delete_backward",
        "system_volume_up",
        "system_volume_down",
    }
)


def default_button_bindings() -> dict[str, dict[str, str]]:
    return {
        button_id: {
            SINGLE_CLICK: DEFAULT_SINGLE_ACTIONS[button_id],
            DOUBLE_CLICK: "disabled",
            LONG_PRESS: "disabled",
        }
        for button_id in DEFAULT_SINGLE_ACTIONS
    }


def normalize_shortcut(shortcut: str) -> str:
    tokens = [token.casefold() for token in win32_input.parse_shortcut(shortcut)]
    if len(tokens) > 5:
        raise ValueError("快捷键最多包含 5 个按键")
    return "+".join(tokens)


def is_valid_action(action: object) -> bool:
    if not isinstance(action, str):
        return False
    if action in ACTION_IDS:
        return True
    if not action.startswith(CUSTOM_SHORTCUT_PREFIX):
        return False
    try:
        return bool(normalize_shortcut(action[len(CUSTOM_SHORTCUT_PREFIX) :]))
    except ValueError:
        return False


def action_to_display(action: str) -> str:
    if action.startswith(CUSTOM_SHORTCUT_PREFIX):
        shortcut = action[len(CUSTOM_SHORTCUT_PREFIX) :]
        return f"{CUSTOM_SHORTCUT_LABEL_PREFIX}{shortcut}"
    return ACTION_LABELS.get(action, ACTION_LABELS["disabled"])


def display_to_action(display: str) -> str:
    value = display.strip()
    if value in LABEL_TO_ACTION:
        return LABEL_TO_ACTION[value]
    if value.startswith(CUSTOM_SHORTCUT_LABEL_PREFIX):
        shortcut = normalize_shortcut(value[len(CUSTOM_SHORTCUT_LABEL_PREFIX) :])
    else:
        shortcut = normalize_shortcut(value)
    return f"{CUSTOM_SHORTCUT_PREFIX}{shortcut}"


def configured_action(settings: dict[str, object], button_id: str, trigger: str) -> str:
    bindings = settings.get("button_bindings", {})
    if not isinstance(bindings, dict):
        return "disabled"
    gestures = bindings.get(button_id, {})
    if not isinstance(gestures, dict):
        return "disabled"
    action = gestures.get(trigger, "disabled")
    return action if is_valid_action(action) else "disabled"


def has_secondary_action(settings: dict[str, object], button_id: str) -> bool:
    return any(
        configured_action(settings, button_id, trigger) != "disabled"
        for trigger in (DOUBLE_CLICK, LONG_PRESS)
    )


def action_allows_repeat(action: str) -> bool:
    return action in REPEATABLE_ACTIONS
