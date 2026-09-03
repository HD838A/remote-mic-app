"""Settings-window pure logic: button mapping list, voice hotkey, output
endpoint, bridge-launch and log-location status text.

This module is deliberately Tk/Qt-free (XRBM-030 replaced the previous Tk
view with a PySide6-Essentials + Qt Quick/QML one - see
``qt_settings_app.py`` and ``qml/`` - but every piece of validation/save/
launch/log-status logic below is unchanged and stays here so it keeps being
directly unit-testable without constructing any window at all, matching the
contract fixed after XRBM-014 review RETRY P1 #7): every piece of
validation/save logic is a plain function (``_action_to_display``,
``_display_to_action``, ``build_save_model``, ``_endpoint_display``,
``_parse_endpoint_display``, ``describe_launch_result``,
``describe_log_open_result``) that tests call directly - see
tests/test_settings_ui_helpers.py. The previous bug (the default "mic"
mapping's display string had no reverse mapping back to
``ActionKind.VOICE``, so a user who changed nothing - or clicked "restore
defaults" - could not save) is covered by an explicit round-trip test on
``_VOICE_DISPLAY``.

``main()`` at the bottom of this module is the only place that touches Qt at
all, and does so via a lazy import inside the function body - importing this
module (e.g. from ``__main__.py``'s ``--dry-run`` smoke check) never
requires PySide6 to be installed, the same optional-dependency convention
this package already uses for ``sounddevice``/``numpy``/``winrt`` (see
``qt_settings_app.py``'s module docstring for the exact error raised when
Qt is missing).
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import Dict, Optional, Tuple

from . import (
    audio_output,
    bridge_launcher,
    device_catalog,
    device_profile,
    hotkey,
    key_mapping,
    logging_setup,
    win32_keys,
)

# Reference action names map to semantic values.  The Windows implementation
# is intentionally behind these values; the dropdown must never turn
# ``方向上`` back into a generic ``key_combo`` just because the platform uses
# a key event to deliver it.
_REFERENCE_ACTION_LABELS: Dict[key_mapping.ActionKind, str] = {
    key_mapping.ActionKind.ESCAPE: "Escape",
    key_mapping.ActionKind.RETURN: "Return",
    key_mapping.ActionKind.ARROW_UP: "方向上",
    key_mapping.ActionKind.ARROW_DOWN: "方向下",
    key_mapping.ActionKind.ARROW_LEFT: "方向左",
    key_mapping.ActionKind.ARROW_RIGHT: "方向右",
    key_mapping.ActionKind.DELETE_BACKWARD: "Delete（退格）",
    key_mapping.ActionKind.SHOW_DESKTOP: "显示桌面",
    key_mapping.ActionKind.CONTEXT_MENU: "上下文菜单",
    key_mapping.ActionKind.APP_SWITCHER: "应用切换",
    key_mapping.ActionKind.SYSTEM_VOLUME_UP: "系统音量 +",
    key_mapping.ActionKind.SYSTEM_VOLUME_DOWN: "系统音量 −",
    key_mapping.ActionKind.SYSTEM_VOLUME_MUTE: "系统静音",
    key_mapping.ActionKind.PLAY_PAUSE: "播放 / 暂停",
    key_mapping.ActionKind.OPEN_REMOTE_MIC: "打开无线麦",
    key_mapping.ActionKind.OPEN_CODEX: "打开 Codex",
    key_mapping.ActionKind.OPEN_CLAUDE: "打开 Claude",
    key_mapping.ActionKind.OPEN_CMUX: "打开 cmux",
    key_mapping.ActionKind.OPEN_WECHAT: "打开微信",
    key_mapping.ActionKind.OPEN_CURSOR: "打开 Cursor",
    key_mapping.ActionKind.OPEN_SLACK: "打开 Slack",
    key_mapping.ActionKind.OPEN_WECOM: "打开企业微信",
    key_mapping.ActionKind.OPEN_NETEASE_MUSIC: "打开网易云音乐",
    key_mapping.ActionKind.OPEN_CHROME: "打开 Chrome",
    key_mapping.ActionKind.OPEN_EDGE: "打开 Edge",
    key_mapping.ActionKind.OPEN_ZED: "打开 Zed",
}
_REFERENCE_ACTION_KINDS_BY_LABEL: Dict[str, key_mapping.ActionKind] = {
    label: action_kind for action_kind, label in _REFERENCE_ACTION_LABELS.items()
}

# Preset choices shown in the mapping dropdown. Any other
# "mod+mod+key" text is still accepted as a custom shortcut through
# hotkey.HotkeySpec.parse.
_PRESET_KEY_COMBOS = (
    "Escape", "Return", "Delete（退格）", "方向上", "方向下", "方向左", "方向右",
    "显示桌面", "上下文菜单", "应用切换", "系统音量 +", "系统音量 −",
    "系统静音", "播放 / 暂停",
    "打开无线麦", "打开 Codex", "打开 Claude", "打开 cmux", "打开微信",
    "打开 Cursor", "打开 Slack", "打开企业微信", "打开网易云音乐",
    "打开 Chrome", "打开 Edge", "打开 Zed",
    "lctrl+win", "lctrl+lalt", "ralt", "ralt+space", "tab", "space", "f5", "禁用",
)

_TRIGGER_MODE_LABELS = {
    key_mapping.VoiceTriggerMode.TOGGLE: "免按住（左 Ctrl + 左 Alt）",
    key_mapping.VoiceTriggerMode.HOLD: "长按（右 Alt）",
}

_VOICE_INPUT_PRESET_LABELS = {
    key_mapping.VoiceInputPreset.TYPELESS: "Typeless（点按：左 Ctrl + 左 Alt）",
    key_mapping.VoiceInputPreset.QIANWEN: "千问（点按：右 Alt）",
}

_VOICE_INPUT_PRESET_ACTIVE_LABELS = {
    key_mapping.VoiceInputPreset.TYPELESS: "Typeless（左 Ctrl + 左 Alt）",
    key_mapping.VoiceInputPreset.QIANWEN: "千问（右 Alt）",
}


def voice_hotkey_for_input_preset(preset: key_mapping.VoiceInputPreset) -> str:
    return key_mapping.voice_hotkey_for_input_preset(preset)

def voice_hotkey_for_trigger_mode(trigger_mode: key_mapping.VoiceTriggerMode) -> str:
    """Return the physical host shortcut paired with a voice trigger mode."""

    return key_mapping.voice_hotkey_for_trigger_mode(trigger_mode)

# The exact display string for a "mic" (ActionKind.VOICE) button mapping.
# _display_to_action must recognize this literal string and round-trip it
# back to ActionKind.VOICE - it must NOT be handed to HotkeySpec.parse.
_VOICE_DISPLAY = "语音（使用专用组合键）"

# Secondary gestures are optional.  Keep an explicit display value in the
# editable ComboBox so Qt does not fall back to the first real preset (usually
# ``escape``) when an older key_bindings.json has no secondary_bindings map.
SECONDARY_UNCONFIGURED_DISPLAY = "未设置"

# The microphone button remains a VOICE lifecycle action (it cannot be changed
# into an unrelated normal-key mapping), but the host chord it emits is
# editable through SettingsController.hotkeyText in the same row.
_MIC_ROW_DISPLAY = "触发语音（免按住：左 Ctrl+左 Alt；长按：右 Alt）"

# device_profile.ALL_BUTTON_IDS also carries "volume_mute", a HID usage-table
# entry kept for protocol compatibility (see key_mapping.py's module
# docstring) even though the physical RC003 has no dedicated mute key - only
# Volume + and Volume -. The settings window must not offer a mapping row a
# real remote can never actually trigger (XRBM-019 review round 1 P2), so
# every button list this module builds for display uses this narrowed set
# instead of ALL_BUTTON_IDS directly.
_USER_FACING_BUTTON_IDS = frozenset(device_profile.ALL_BUTTON_IDS - {"volume_mute"})

_ENDPOINT_NAME_HOST_API_SEPARATOR = " — "


class SettingsValidationError(Exception):
    """Raised by build_save_model on invalid input. ``button_id`` is None
    for a hotkey-level error, or the offending button's id for a mapping
    error.
    """

    def __init__(self, button_id: Optional[str], message: str) -> None:
        super().__init__(message)
        self.button_id = button_id
        self.message = message


def _action_to_display(action: key_mapping.ButtonAction) -> str:
    if action.kind == key_mapping.ActionKind.DISABLED:
        return "禁用"
    if action.kind == key_mapping.ActionKind.VOICE:
        return _VOICE_DISPLAY
    reference_label = _REFERENCE_ACTION_LABELS.get(action.kind)
    if reference_label is not None:
        return reference_label
    # Make old configs readable even before the loader has had a chance to
    # migrate them (e.g. a caller is rendering a raw document in a test).
    legacy_action = key_mapping.semantic_action_for_keys(action.keys)
    if legacy_action is not None:
        return _REFERENCE_ACTION_LABELS[legacy_action.kind]
    return "+".join(action.keys)


def _display_to_action(text: str) -> key_mapping.ButtonAction:
    text = text.strip()
    if text in ("禁用", "disabled", SECONDARY_UNCONFIGURED_DISPLAY):
        return key_mapping.ButtonAction(key_mapping.ActionKind.DISABLED)
    if text == _VOICE_DISPLAY:
        return key_mapping.ButtonAction(key_mapping.ActionKind.VOICE)
    if text == "系统音量 -":
        text = "系统音量 −"
    reference_kind = _REFERENCE_ACTION_KINDS_BY_LABEL.get(text)
    if reference_kind is not None:
        return key_mapping.ButtonAction(reference_kind)
    # Keep the previous spelling accepted for users who copied the macOS
    # reference label into the Windows field.
    if text == "Command-Tab":
        return key_mapping.ButtonAction(key_mapping.ActionKind.APP_SWITCHER)
    parsed = hotkey.HotkeySpec.parse(text)
    try:
        win32_keys.resolve_vk_codes(tuple(parsed.modifiers) + (parsed.key,))
    except win32_keys.UnknownKeyTokenError as exc:
        raise hotkey.HotkeyParseError(str(exc)) from exc
    return key_mapping.ButtonAction(
        key_mapping.ActionKind.KEY_COMBO, tuple(parsed.modifiers) + (parsed.key,)
    )


def _endpoint_display(endpoint: audio_output.AudioEndpoint) -> str:
    if endpoint.host_api:
        return f"{endpoint.name}{_ENDPOINT_NAME_HOST_API_SEPARATOR}{endpoint.host_api}"
    return endpoint.name


def _parse_endpoint_display(text: str) -> Tuple[str, str]:
    """Inverse of _endpoint_display: returns (name, host_api), where
    host_api is "" if the text has no disambiguating suffix.
    """

    text = text.strip()
    if _ENDPOINT_NAME_HOST_API_SEPARATOR in text:
        name, host_api = text.rsplit(_ENDPOINT_NAME_HOST_API_SEPARATOR, 1)
        return name.strip(), host_api.strip()
    return text, ""


def build_save_model(
    *,
    button_display_map: Dict[str, str],
    secondary_display_map: Optional[Dict[str, Dict[str, str]]] = None,
    hotkey_text: str,
    trigger_mode: key_mapping.VoiceTriggerMode,
    endpoint_display_text: str,
    base_config: dict,
    base_bindings: dict,
    selected_device_profile: str = device_catalog.RC003_ID,
) -> Tuple[dict, dict]:
    """Pure validation+build step for "Save"/"Restore defaults", with no Tk
    dependency at all - directly unit tested without constructing any
    window (see tests/test_settings_ui_helpers.py). Raises
    SettingsValidationError on invalid input; never raises a Tk exception.
    """

    try:
        parsed_hotkey = hotkey.HotkeySpec.parse(hotkey_text)
        win32_keys.resolve_vk_codes(tuple(parsed_hotkey.modifiers) + (parsed_hotkey.key,))
    except hotkey.HotkeyParseError as exc:
        raise SettingsValidationError(None, str(exc)) from exc
    except win32_keys.UnknownKeyTokenError as exc:
        raise SettingsValidationError(None, str(exc)) from exc

    bindings: Dict[str, dict] = {}
    for button_id, text in button_display_map.items():
        text = text.strip()
        if not text:
            continue
        try:
            action = _display_to_action(text)
        except hotkey.HotkeyParseError as exc:
            raise SettingsValidationError(button_id, str(exc)) from exc
        bindings[button_id] = action.to_dict()

    if secondary_display_map is None:
        raw_secondary = base_bindings.get("secondary_bindings", {})
        secondary_bindings = (
            copy.deepcopy(raw_secondary) if isinstance(raw_secondary, dict) else {}
        )
    else:
        secondary_bindings: Dict[str, Dict[str, dict]] = {}
        valid_triggers = {
            key_mapping.ButtonTrigger.DOUBLE_CLICK.value,
            key_mapping.ButtonTrigger.LONG_PRESS.value,
        }
        for button_id, trigger_map in secondary_display_map.items():
            if button_id == "mic" or not isinstance(trigger_map, dict):
                continue
            for trigger_name, text in trigger_map.items():
                if trigger_name not in valid_triggers:
                    raise SettingsValidationError(
                        button_id, f"未知手势：{trigger_name}"
                    )
                text = str(text).strip()
                if not text or text in (
                    "禁用",
                    "disabled",
                    SECONDARY_UNCONFIGURED_DISPLAY,
                ):
                    continue
                try:
                    action = _display_to_action(text)
                except hotkey.HotkeyParseError as exc:
                    raise SettingsValidationError(button_id, str(exc)) from exc
                if action.kind == key_mapping.ActionKind.DISABLED:
                    continue
                secondary_bindings.setdefault(button_id, {})[trigger_name] = action.to_dict()

    # The physical mic button is always driven directly by the ATVV voice
    # lifecycle (see app.py) - the runtime never consults a stored "mic"
    # binding at all. Force it to VOICE unconditionally regardless of what
    # button_display_map contained: the settings window no longer offers an
    # editable mic row (see ButtonMappingModel in qt_settings_app.py), but
    # this is the authoritative, UI-independent guarantee that this save
    # path can never
    # persist a stale/misleading non-voice mic action (XRBM-019 In-scope
    # item 6, folded in from XRBM-018's independent review round 2's
    # product-contract follow-up).
    bindings["mic"] = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE).to_dict()

    endpoint_name, endpoint_host_api = _parse_endpoint_display(endpoint_display_text)

    new_config = dict(base_config)
    new_config["selected_device_profile"] = device_catalog.normalize_device_id(
        selected_device_profile
    )
    new_config["voice_hotkey"] = hotkey_text.strip()
    new_config["voice_trigger_mode"] = trigger_mode.value
    new_config["output_endpoint_name"] = endpoint_name
    new_config["output_endpoint_host_api"] = endpoint_host_api

    new_bindings = dict(base_bindings)
    new_bindings["bindings"] = bindings
    new_bindings["secondary_bindings"] = secondary_bindings

    return new_config, new_bindings


@dataclass(frozen=True)
class DefaultDisplayState:
    """What "restore defaults" resets every widget to - a pure snapshot, so
    it can be asserted on directly in tests without touching a StringVar.
    """

    button_display_map: Dict[str, str]
    secondary_display_map: Dict[str, Dict[str, str]]
    hotkey_text: str
    trigger_mode_label: str


def default_display_state() -> DefaultDisplayState:
    defaults = key_mapping.default_button_actions()
    button_display_map = {
        button_id: _action_to_display(action) for button_id, action in defaults.items()
    }
    for button_id in _USER_FACING_BUTTON_IDS:
        button_display_map.setdefault(button_id, "")
    secondary_display_map = {
        button_id: {
            key_mapping.ButtonTrigger.DOUBLE_CLICK.value: "",
            key_mapping.ButtonTrigger.LONG_PRESS.value: "",
        }
        for button_id in _USER_FACING_BUTTON_IDS
        if button_id != "mic"
    }
    return DefaultDisplayState(
        button_display_map=button_display_map,
        secondary_display_map=secondary_display_map,
        hotkey_text=hotkey.DEFAULT_VOICE_HOTKEY.serialize(),
        trigger_mode_label=_TRIGGER_MODE_LABELS[key_mapping.VoiceTriggerMode.TOGGLE],
    )


# Bridge-control status text (XRBM-029). Kept as pure, Tk-free functions -
# same testability contract as the save-model helpers above (see
# tests/test_settings_ui_helpers.py) - so every one of the four required
# stable states (not-started / running / already-running / abnormal-quick-
# exit) is asserted on directly without constructing a window or a real
# subprocess.
#
# Wording contract: a STARTED result is deliberately never described as
# "RC003 已连接"/"RC003 connected" - only as the process itself still being
# alive. Whether the bridge actually reached a working BLE/HID/audio
# connection is only observable from app.log, which every branch below
# points the user at.
LAUNCH_NOT_STARTED_TEXT = "未启动（本次设置窗口打开后还没有尝试启动桥接）"


def describe_launch_result(result: bridge_launcher.LaunchResult) -> str:
    if result.outcome is bridge_launcher.LaunchOutcome.STOP_FAILED:
        return f"切换失败：无法通知旧桥接退出（{result.error}）。"
    if result.outcome is bridge_launcher.LaunchOutcome.STOP_TIMEOUT:
        return "切换失败：旧桥接没有在限定时间内完成清理，未启动第二个桥接。请查看 app.log。"
    if result.outcome is bridge_launcher.LaunchOutcome.STARTED:
        pid_text = f"（PID {result.pid}）" if result.pid is not None else ""
        return (
            f"已启动桥接进程{pid_text}，目前仍在运行。这只说明进程本身存活，"
            "不代表已经与 RC003 建立连接——请用下方“打开日志目录”查看 app.log "
            "确认实际连接、按键与语音状态。"
        )
    if result.outcome is bridge_launcher.LaunchOutcome.ALREADY_RUNNING:
        return (
            "切换未完成：现有桥接不支持软件内停止，新的桥接被单实例保护拒绝（退出码 "
            f"{result.exit_code}）。请用最新源码测试入口启动一次；此后可直接在软件内切换。"
        )
    if result.outcome is bridge_launcher.LaunchOutcome.QUICK_EXIT:
        return (
            f"启动异常：进程在短时间内退出（退出码 {result.exit_code}），可能没有成功"
            "建立 BLE/HID/音频连接。请用下方“打开日志目录”查看 app.log 了解具体原因。"
        )
    # LAUNCH_FAILED
    return (
        f"启动失败：无法创建桥接进程（{result.error}）。请用下方“打开日志目录”查看 "
        "app.log，并确认安装/便携版文件是否完整。"
    )


def describe_log_open_result(result: logging_setup.LogOpenResult) -> str:
    if result.outcome is logging_setup.LogOpenOutcome.OPENED:
        note = ""
        if result.location.status is logging_setup.LogLocationStatus.FILE_MISSING:
            note = "（该目录存在，但 app.log 尚不存在——桥接可能还没有运行过一次，这不是错误。）"
        return f"已打开日志目录：{result.location.directory}{note}"
    if result.outcome is logging_setup.LogOpenOutcome.DIRECTORY_MISSING:
        return (
            f"日志目录尚不存在：{result.location.directory}。这通常表示桥接程序在这台"
            "电脑上还没有运行过；本程序不会为了显示而伪造日志。"
        )
    return f"无法打开日志目录（{result.error}）：{result.location.directory}"


def main() -> None:
    """Launches the Qt Quick/QML settings window (XRBM-030). Imports
    ``qt_settings_app`` lazily so importing THIS module (e.g. from
    ``__main__.py``'s ``--dry-run`` smoke check, or from any test that only
    needs the pure functions above) never requires PySide6 to be installed -
    see ``qt_settings_app.py``'s module docstring for the exact, clear error
    raised here if it is missing.
    """

    from . import qt_settings_app

    qt_settings_app.run_settings_window()


if __name__ == "__main__":
    main()
