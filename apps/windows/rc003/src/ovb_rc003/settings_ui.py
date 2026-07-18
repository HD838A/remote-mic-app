"""Tk settings window: button mapping list, voice hotkey, output endpoint.

This candidate deliberately ships a text-based mapping list rather than
clickable hotspots on the RC003 product photo. Reproducing the macOS client's
pixel-calibrated hotspot coordinates would require re-deriving them without
the original SwiftUI layout data, which risks fabricating incorrect
coordinates; the photo (if found via resources.find_remote_photo) is instead
shown as a static reference image. Clickable hotspots are left as documented
future work, not simulated here.

Testability (fixed after XRBM-014 review RETRY P1 #7 - see
XRBM-014's independent review): every piece of validation/save logic
that used to live inline in ``SettingsWindow._save`` is now a plain,
Tk-free function (``_action_to_display``, ``_display_to_action``,
``build_save_model``, ``_endpoint_display``, ``_parse_endpoint_display``)
that tests call directly, with no Tk widget or window ever constructed - see
tests/test_settings_ui_helpers.py. The previous bug (the default "mic"
mapping's display string had no reverse mapping back to
``ActionKind.VOICE``, so a user who changed nothing - or clicked "restore
defaults" - could not save) is covered by an explicit round-trip test on
``_VOICE_DISPLAY``.
"""

from __future__ import annotations

import tkinter as tk
from dataclasses import dataclass
from tkinter import messagebox, ttk
from typing import Dict, List, Optional, Tuple

from . import audio_output, config, device_profile, hotkey, key_mapping, resources

# Preset key-combo choices shown in the mapping dropdown, covering every
# default action plus a few common alternates. Any other "mod+mod+key" text
# is also accepted via hotkey.HotkeySpec.parse.
_PRESET_KEY_COMBOS = (
    "escape", "enter", "backspace", "up", "down", "left", "right",
    "win+d", "shift+f10", "alt+esc", "tab", "space",
)

_TRIGGER_MODE_LABELS = {
    key_mapping.VoiceTriggerMode.TOGGLE: "开关型 (toggle)",
    key_mapping.VoiceTriggerMode.HOLD: "按住型 (hold)",
}

# The exact display string for a "mic" (ActionKind.VOICE) button mapping.
# _display_to_action must recognize this literal string and round-trip it
# back to ActionKind.VOICE - it must NOT be handed to HotkeySpec.parse.
_VOICE_DISPLAY = "语音 (Win+H，见下方热键设置)"

# Shown on the read-only "mic" row (XRBM-019 In-scope item 6): reuses
# _VOICE_DISPLAY's exact text plus a note explaining it isn't editable, so a
# user doesn't wonder why "mic" alone has no dropdown.
_MIC_ROW_DISPLAY = _VOICE_DISPLAY + "（固定，不可更改）"

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
    if action.kind == key_mapping.ActionKind.VOICE:
        return _VOICE_DISPLAY
    if action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_UP:
        return "系统音量 +"
    if action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_DOWN:
        return "系统音量 −"
    return "+".join(action.keys)


def _display_to_action(text: str) -> key_mapping.ButtonAction:
    text = text.strip()
    if text == _VOICE_DISPLAY:
        return key_mapping.ButtonAction(key_mapping.ActionKind.VOICE)
    if text in ("系统音量 +",):
        return key_mapping.ButtonAction(key_mapping.ActionKind.SYSTEM_VOLUME_UP)
    if text in ("系统音量 −", "系统音量 -"):
        return key_mapping.ButtonAction(key_mapping.ActionKind.SYSTEM_VOLUME_DOWN)
    parsed = hotkey.HotkeySpec.parse(text)
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
    hotkey_text: str,
    trigger_mode: key_mapping.VoiceTriggerMode,
    endpoint_display_text: str,
    base_config: dict,
    base_bindings: dict,
) -> Tuple[dict, dict]:
    """Pure validation+build step for "Save"/"Restore defaults", with no Tk
    dependency at all - directly unit tested without constructing any
    window (see tests/test_settings_ui_helpers.py). Raises
    SettingsValidationError on invalid input; never raises a Tk exception.
    """

    try:
        hotkey.HotkeySpec.parse(hotkey_text)
    except hotkey.HotkeyParseError as exc:
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

    # The physical mic button is always driven directly by the ATVV voice
    # lifecycle (see app.py) - the runtime never consults a stored "mic"
    # binding at all. Force it to VOICE unconditionally regardless of what
    # button_display_map contained: the settings window no longer offers an
    # editable mic row (see SettingsWindow._build), but this is the
    # authoritative, UI-independent guarantee that this save path can never
    # persist a stale/misleading non-voice mic action (XRBM-019 In-scope
    # item 6, folded in from XRBM-018's independent review round 2's
    # product-contract follow-up).
    bindings["mic"] = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE).to_dict()

    endpoint_name, endpoint_host_api = _parse_endpoint_display(endpoint_display_text)

    new_config = dict(base_config)
    new_config["voice_hotkey"] = hotkey_text.strip()
    new_config["voice_trigger_mode"] = trigger_mode.value
    new_config["output_endpoint_name"] = endpoint_name
    new_config["output_endpoint_host_api"] = endpoint_host_api

    new_bindings = dict(base_bindings)
    new_bindings["bindings"] = bindings

    return new_config, new_bindings


@dataclass(frozen=True)
class DefaultDisplayState:
    """What "restore defaults" resets every widget to - a pure snapshot, so
    it can be asserted on directly in tests without touching a StringVar.
    """

    button_display_map: Dict[str, str]
    hotkey_text: str
    trigger_mode_label: str


def default_display_state() -> DefaultDisplayState:
    defaults = key_mapping.default_button_actions()
    button_display_map = {
        button_id: _action_to_display(action) for button_id, action in defaults.items()
    }
    for button_id in _USER_FACING_BUTTON_IDS:
        button_display_map.setdefault(button_id, "")
    return DefaultDisplayState(
        button_display_map=button_display_map,
        hotkey_text=hotkey.DEFAULT_VOICE_HOTKEY.serialize(),
        trigger_mode_label=_TRIGGER_MODE_LABELS[key_mapping.VoiceTriggerMode.TOGGLE],
    )


class SettingsWindow:
    """Thin Tk wrapper. All validation/save logic is delegated to the pure
    functions above; this class only reads/writes Tk widget state.
    """

    def __init__(self, master: Optional[tk.Misc] = None) -> None:
        self._config_root = config.config_root()
        self._config = config.load_config(config.config_path(self._config_root))
        self._bindings = config.load_key_bindings(
            config.key_bindings_path(self._config_root)
        )

        self.root = tk.Toplevel(master) if master is not None else tk.Tk()
        self.root.title("Open Voice Bridge · RC003 设置")
        self._build()

    def _build(self) -> None:
        photo_path = resources.find_remote_photo()
        if photo_path is not None:
            try:
                image = tk.PhotoImage(file=str(photo_path))
                label = tk.Label(self.root, image=image)
                label.image = image  # keep a reference alive
                label.grid(row=0, column=0, rowspan=20, padx=8, pady=8, sticky="n")
            except tk.TclError:
                pass  # PNG support depends on the local Tk build; degrade quietly

        buttons_frame = ttk.LabelFrame(self.root, text="按键映射")
        buttons_frame.grid(row=0, column=1, sticky="nsew", padx=8, pady=8)

        self._mapping_vars: Dict[str, tk.StringVar] = {}
        bindings = self._bindings.get("bindings", {})
        row = 0
        for button_id in sorted(_USER_FACING_BUTTON_IDS):
            ttk.Label(buttons_frame, text=button_id).grid(row=row, column=0, sticky="w")

            if button_id == "mic":
                # Fixed by the ATVV voice lifecycle (see app.py's
                # _handle_mic_button_pressed/_on_control_event) - the
                # runtime never consults a stored "mic" binding at all, so
                # this row must not look editable like the others (XRBM-019
                # In-scope item 6, folded in from XRBM-018's independent
                # review round 2's product-contract
                # follow-up: a setting the runtime silently ignores must
                # not be presented as configurable). No StringVar is
                # created for it, so _save()/_restore_defaults() never
                # touch it either - build_save_model() forces it to VOICE
                # unconditionally regardless.
                ttk.Label(buttons_frame, text=_MIC_ROW_DISPLAY).grid(
                    row=row, column=1, sticky="w"
                )
                row += 1
                continue

            action_dict = bindings.get(button_id)
            if action_dict is not None:
                action = key_mapping.ButtonAction.from_dict(action_dict)
                current_text = _action_to_display(action)
            else:
                current_text = ""

            var = tk.StringVar(value=current_text)
            combo = ttk.Combobox(
                buttons_frame, textvariable=var, values=_PRESET_KEY_COMBOS, width=24
            )
            combo.grid(row=row, column=1, sticky="w")
            self._mapping_vars[button_id] = var
            row += 1

        voice_frame = ttk.LabelFrame(self.root, text="麦克风与语音")
        voice_frame.grid(row=1, column=1, sticky="nsew", padx=8, pady=8)

        ttk.Label(voice_frame, text="语音热键 (mod+mod+key)").grid(row=0, column=0, sticky="w")
        self._hotkey_var = tk.StringVar(value=self._config.get("voice_hotkey", "win+h"))
        ttk.Entry(voice_frame, textvariable=self._hotkey_var).grid(row=0, column=1, sticky="w")

        self._trigger_var = tk.StringVar(
            value=_TRIGGER_MODE_LABELS[
                key_mapping.VoiceTriggerMode(self._config.get("voice_trigger_mode", "toggle"))
            ]
        )
        ttk.Label(voice_frame, text="触发方式").grid(row=1, column=0, sticky="w")
        ttk.Combobox(
            voice_frame,
            textvariable=self._trigger_var,
            values=list(_TRIGGER_MODE_LABELS.values()),
            state="readonly",
        ).grid(row=1, column=1, sticky="w")

        output_frame = ttk.LabelFrame(self.root, text="语音输出设备")
        output_frame.grid(row=2, column=1, sticky="nsew", padx=8, pady=8)

        try:
            endpoints: List[audio_output.AudioEndpoint] = audio_output.enumerate_output_endpoints()
            endpoint_display_values = [_endpoint_display(endpoint) for endpoint in endpoints]
        except audio_output.AudioOutputUnavailableError:
            endpoint_display_values = []

        ttk.Label(
            output_frame,
            text="语音只会写入下方选中且当前存在的设备；未选择或设备缺失时语音静默失败，普通按键仍可用。",
            wraplength=360,
        ).grid(row=0, column=0, columnspan=2, sticky="w")

        initial_endpoint_display = ""
        saved_name = self._config.get("output_endpoint_name", "")
        if saved_name:
            saved_host_api = self._config.get("output_endpoint_host_api", "")
            initial_endpoint_display = _endpoint_display(
                audio_output.AudioEndpoint(name=saved_name, host_api=saved_host_api)
            )
        self._endpoint_var = tk.StringVar(value=initial_endpoint_display)
        ttk.Combobox(
            output_frame,
            textvariable=self._endpoint_var,
            values=endpoint_display_values,
            width=48,
        ).grid(row=1, column=0, columnspan=2, sticky="w")

        button_bar = ttk.Frame(self.root)
        button_bar.grid(row=3, column=1, sticky="e", padx=8, pady=8)
        ttk.Button(button_bar, text="恢复全部默认", command=self._restore_defaults).grid(
            row=0, column=0, padx=4
        )
        ttk.Button(button_bar, text="保存并应用", command=self._save).grid(row=0, column=1, padx=4)

    def _restore_defaults(self) -> None:
        defaults = default_display_state()
        for button_id, var in self._mapping_vars.items():
            var.set(defaults.button_display_map.get(button_id, ""))
        self._hotkey_var.set(defaults.hotkey_text)
        self._trigger_var.set(defaults.trigger_mode_label)

    def _save(self) -> None:
        trigger_mode = next(
            mode
            for mode, label in _TRIGGER_MODE_LABELS.items()
            if label == self._trigger_var.get()
        )
        display_map = {
            button_id: var.get() for button_id, var in self._mapping_vars.items()
        }
        try:
            new_config, new_bindings = build_save_model(
                button_display_map=display_map,
                hotkey_text=self._hotkey_var.get(),
                trigger_mode=trigger_mode,
                endpoint_display_text=self._endpoint_var.get(),
                base_config=self._config,
                base_bindings=self._bindings,
            )
        except SettingsValidationError as exc:
            title = f"「{exc.button_id}」映射无效" if exc.button_id else "语音热键无效"
            messagebox.showerror(title, exc.message)
            return

        self._config = new_config
        self._bindings = new_bindings
        config.save_config(config.config_path(self._config_root), self._config)
        config.save_key_bindings(config.key_bindings_path(self._config_root), self._bindings)
        messagebox.showinfo("已保存", "设置已保存。重启桥接以应用新的连接/输出设置。")


def main() -> None:
    window = SettingsWindow()
    window.root.mainloop()


if __name__ == "__main__":
    main()
