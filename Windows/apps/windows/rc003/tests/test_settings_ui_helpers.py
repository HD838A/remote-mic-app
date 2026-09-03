"""Tests the pure display<->action/save-model helper functions in
settings_ui.py without constructing any real Tk widget or window - see
XRBM-014 review RETRY P1 #7/#8 boundary ("不启动 Tk 或任何可见窗口"). Every
function under test here takes and returns plain data (strings, dicts,
dataclasses); none of it touches ``tkinter.Tk``/``Toplevel``/mainloop.
"""

import unittest
from pathlib import Path

from ovb_rc003 import audio_output, bridge_launcher, hotkey, key_mapping, logging_setup, single_instance
from ovb_rc003.settings_ui import (
    LAUNCH_NOT_STARTED_TEXT,
    SettingsValidationError,
    _VOICE_DISPLAY,
    _action_to_display,
    _display_to_action,
    _endpoint_display,
    _parse_endpoint_display,
    build_save_model,
    default_display_state,
    describe_launch_result,
    describe_log_open_result,
    voice_hotkey_for_input_preset,
    voice_hotkey_for_trigger_mode,
)


class DisplayRoundTripTests(unittest.TestCase):
    def test_disabled_action_round_trips(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.DISABLED)
        self.assertEqual(_action_to_display(action), "禁用")
        self.assertEqual(_display_to_action("禁用").kind, key_mapping.ActionKind.DISABLED)

    def test_key_combo_round_trips(self):
        action = key_mapping.ButtonAction(
            key_mapping.ActionKind.KEY_COMBO, ("ctrl", "shift", "p")
        )
        display = _action_to_display(action)
        restored = _display_to_action(display)
        self.assertEqual(restored.kind, key_mapping.ActionKind.KEY_COMBO)
        self.assertEqual(restored.keys, ("ctrl", "shift", "p"))

    def test_reference_action_labels_round_trip_to_windows_chords(self):
        expected = {
            "Escape": key_mapping.ActionKind.ESCAPE,
            "Return": key_mapping.ActionKind.RETURN,
            "Delete（退格）": key_mapping.ActionKind.DELETE_BACKWARD,
            "方向上": key_mapping.ActionKind.ARROW_UP,
            "方向下": key_mapping.ActionKind.ARROW_DOWN,
            "方向左": key_mapping.ActionKind.ARROW_LEFT,
            "方向右": key_mapping.ActionKind.ARROW_RIGHT,
            "显示桌面": key_mapping.ActionKind.SHOW_DESKTOP,
            "上下文菜单": key_mapping.ActionKind.CONTEXT_MENU,
            "应用切换": key_mapping.ActionKind.APP_SWITCHER,
        }
        for label, action_kind in expected.items():
            restored = _display_to_action(label)
            self.assertEqual(restored.kind, action_kind, label)
            self.assertEqual(restored.keys, (), label)
            self.assertEqual(_action_to_display(restored), label)

    def test_legacy_alt_escape_app_switch_is_displayed_as_reference_action(self):
        action = key_mapping.ButtonAction(
            key_mapping.ActionKind.KEY_COMBO, ("alt", "esc")
        )
        self.assertEqual(_action_to_display(action), "应用切换")

    def test_reference_open_app_labels_round_trip_to_semantic_actions(self):
        expected = {
            "打开无线麦": key_mapping.ActionKind.OPEN_REMOTE_MIC,
            "打开 Codex": key_mapping.ActionKind.OPEN_CODEX,
            "打开 Claude": key_mapping.ActionKind.OPEN_CLAUDE,
            "打开 cmux": key_mapping.ActionKind.OPEN_CMUX,
            "打开 Chrome": key_mapping.ActionKind.OPEN_CHROME,
        }
        for label, action_kind in expected.items():
            restored = _display_to_action(label)
            self.assertEqual(restored.kind, action_kind, label)
            self.assertEqual(_action_to_display(restored), label)

    def test_modifier_only_combo_round_trips_through_button_mapping(self):
        restored = _display_to_action("ctrl+shift")
        self.assertEqual(restored.kind, key_mapping.ActionKind.KEY_COMBO)
        self.assertEqual(restored.keys, ("ctrl", "shift"))

    def test_volume_up_round_trips(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.SYSTEM_VOLUME_UP)
        restored = _display_to_action(_action_to_display(action))
        self.assertEqual(restored.kind, key_mapping.ActionKind.SYSTEM_VOLUME_UP)

    def test_volume_down_round_trips(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.SYSTEM_VOLUME_DOWN)
        restored = _display_to_action(_action_to_display(action))
        self.assertEqual(restored.kind, key_mapping.ActionKind.SYSTEM_VOLUME_DOWN)

    def test_voice_action_display_mentions_hotkey_settings(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE)
        display = _action_to_display(action)
        self.assertIn("专用组合键", display)

    def test_voice_action_round_trips_without_raising(self):
        # Regression test for the exact XRBM-014 review RETRY P1 #7 bug:
        # _display_to_action(_VOICE_DISPLAY) used to fall through to
        # hotkey.HotkeySpec.parse() and raise, so a settings window that
        # displayed the default "mic" mapping and was saved unchanged (or
        # after "restore defaults") could never actually save.
        action = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE)
        display = _action_to_display(action)
        self.assertEqual(display, _VOICE_DISPLAY)
        restored = _display_to_action(display)
        self.assertEqual(restored.kind, key_mapping.ActionKind.VOICE)
        self.assertEqual(restored.keys, ())

    def test_unknown_key_is_rejected_before_it_can_break_runtime_input(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            _display_to_action("ctrl+not_a_real_key")


class VoiceTriggerPresetTests(unittest.TestCase):
    def test_trigger_modes_have_matching_physical_shortcuts(self):
        self.assertEqual(
            voice_hotkey_for_trigger_mode(key_mapping.VoiceTriggerMode.TOGGLE),
            "lctrl+lalt",
        )
        self.assertEqual(
            voice_hotkey_for_trigger_mode(key_mapping.VoiceTriggerMode.HOLD),
            "ralt",
        )

    def test_current_voice_app_presets_expose_their_shortcuts(self):
        self.assertEqual(
            voice_hotkey_for_input_preset(key_mapping.VoiceInputPreset.TYPELESS),
            "lctrl+lalt",
        )
        self.assertEqual(
            voice_hotkey_for_input_preset(key_mapping.VoiceInputPreset.QIANWEN),
            "ralt",
        )


class EndpointDisplayTests(unittest.TestCase):
    def test_endpoint_with_host_api_round_trips(self):
        endpoint = audio_output.AudioEndpoint(name="Speakers", host_api="Windows WASAPI")
        display = _endpoint_display(endpoint)
        name, host_api = _parse_endpoint_display(display)
        self.assertEqual(name, "Speakers")
        self.assertEqual(host_api, "Windows WASAPI")

    def test_endpoint_without_host_api_round_trips_to_empty_host_api(self):
        endpoint = audio_output.AudioEndpoint(name="Speakers", host_api="")
        display = _endpoint_display(endpoint)
        name, host_api = _parse_endpoint_display(display)
        self.assertEqual(name, "Speakers")
        self.assertEqual(host_api, "")

    def test_bare_name_with_no_separator_parses_to_empty_host_api(self):
        name, host_api = _parse_endpoint_display("Just A Name")
        self.assertEqual(name, "Just A Name")
        self.assertEqual(host_api, "")

    def test_empty_string_parses_to_empty_name_and_host_api(self):
        name, host_api = _parse_endpoint_display("")
        self.assertEqual(name, "")
        self.assertEqual(host_api, "")


class BuildSaveModelTests(unittest.TestCase):
    def setUp(self):
        self.base_config = {"voice_hotkey": "win+h", "voice_trigger_mode": "toggle"}
        self.base_bindings = {"schema_version": 1, "bindings": {}}

    def test_default_mic_mapping_saves_without_raising(self):
        # Direct regression test for the P1 #7 bug via the actual save path
        # a user hits when they change nothing (or click "restore defaults").
        new_config, new_bindings = build_save_model(
            button_display_map={"mic": _VOICE_DISPLAY, "power": "escape"},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(new_bindings["bindings"]["mic"]["kind"], "voice")
        self.assertEqual(new_bindings["bindings"]["power"]["kind"], "key_combo")

    def test_mic_is_forced_to_voice_even_if_the_display_map_says_otherwise(self):
        # XRBM-019 In-scope item 6: the settings UI no longer offers an
        # editable mic row at all, but build_save_model() is the
        # authoritative, UI-independent guarantee - even a caller that
        # somehow passes a non-voice "mic" entry must not have it saved.
        new_config, new_bindings = build_save_model(
            button_display_map={"mic": "escape", "power": "escape"},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(new_bindings["bindings"]["mic"], {"kind": "voice", "keys": []})

    def test_mic_is_forced_to_voice_even_when_absent_from_the_display_map(self):
        # Matches the real settings window: "mic" is never in
        # self._mapping_vars at all (see SettingsWindow._build), so the
        # display map it hands to build_save_model() never even mentions
        # "mic" - the save path must still produce a voice entry for it.
        new_config, new_bindings = build_save_model(
            button_display_map={"power": "escape"},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(new_bindings["bindings"]["mic"], {"kind": "voice", "keys": []})

    def test_restore_defaults_state_saves_without_raising(self):
        defaults = default_display_state()
        new_config, new_bindings = build_save_model(
            button_display_map=defaults.button_display_map,
            hotkey_text=defaults.hotkey_text,
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(new_bindings["bindings"]["mic"]["kind"], "voice")
        self.assertEqual(new_config["voice_hotkey"], "lctrl+lalt")

    def test_invalid_hotkey_raises_with_no_button_id(self):
        with self.assertRaises(SettingsValidationError) as ctx:
            build_save_model(
                button_display_map={},
                hotkey_text="ctrl",  # a single generic modifier is invalid
                trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
                endpoint_display_text="",
                base_config=self.base_config,
                base_bindings=self.base_bindings,
            )
        self.assertIsNone(ctx.exception.button_id)

    def test_invalid_button_mapping_raises_with_the_button_id(self):
        with self.assertRaises(SettingsValidationError) as ctx:
            build_save_model(
                button_display_map={"menu": "a+b"},  # two non-modifier keys
                hotkey_text="win+h",
                trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
                endpoint_display_text="",
                base_config=self.base_config,
                base_bindings=self.base_bindings,
            )
        self.assertEqual(ctx.exception.button_id, "menu")

    def test_blank_button_mapping_is_left_unbound(self):
        new_config, new_bindings = build_save_model(
            button_display_map={"volume_mute": ""},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertNotIn("volume_mute", new_bindings["bindings"])

    def test_endpoint_display_text_splits_into_name_and_host_api(self):
        new_config, _ = build_save_model(
            button_display_map={},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.HOLD,
            endpoint_display_text="Speakers — Windows WASAPI",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(new_config["output_endpoint_name"], "Speakers")
        self.assertEqual(new_config["output_endpoint_host_api"], "Windows WASAPI")
        self.assertEqual(new_config["voice_trigger_mode"], "hold")

    def test_does_not_mutate_base_dicts(self):
        base_config_copy = dict(self.base_config)
        base_bindings_copy = {"schema_version": 1, "bindings": dict(self.base_bindings["bindings"])}
        build_save_model(
            button_display_map={"power": "escape"},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(self.base_config, base_config_copy)
        self.assertEqual(self.base_bindings, base_bindings_copy)

    def test_selected_dji_profile_is_persisted_without_overwriting_rc003_bindings(self):
        new_config, new_bindings = build_save_model(
            button_display_map={"power": "escape"},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
            selected_device_profile="dji-mic-2",
        )
        self.assertEqual(new_config["selected_device_profile"], "dji-mic-2")
        self.assertEqual(new_bindings["bindings"]["power"]["keys"], ["escape"])

    def test_unknown_device_profile_falls_back_to_rc003(self):
        new_config, _ = build_save_model(
            button_display_map={},
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
            selected_device_profile="invented-device",
        )
        self.assertEqual(new_config["selected_device_profile"], "xiaomi-rc003")

    def test_secondary_display_map_round_trips_double_and_long_actions(self):
        _, new_bindings = build_save_model(
            button_display_map={"power": "escape"},
            secondary_display_map={
                "power": {
                    "double_click": "f5",
                    "long_press": "系统音量 +",
                }
            },
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(
            new_bindings["secondary_bindings"]["power"]["double_click"],
            {"kind": "key_combo", "keys": ["f5"]},
        )
        self.assertEqual(
            new_bindings["secondary_bindings"]["power"]["long_press"]["kind"],
            "system_volume_up",
        )

    def test_blank_secondary_action_is_not_persisted(self):
        _, new_bindings = build_save_model(
            button_display_map={"power": "escape"},
            secondary_display_map={
                "power": {"double_click": "", "long_press": "禁用"}
            },
            hotkey_text="win+h",
            trigger_mode=key_mapping.VoiceTriggerMode.TOGGLE,
            endpoint_display_text="",
            base_config=self.base_config,
            base_bindings=self.base_bindings,
        )
        self.assertEqual(new_bindings["secondary_bindings"], {})


class DefaultDisplayStateTests(unittest.TestCase):
    def test_covers_every_user_facing_button(self):
        from ovb_rc003 import device_profile
        from ovb_rc003.settings_ui import _USER_FACING_BUTTON_IDS

        state = default_display_state()
        self.assertEqual(set(state.button_display_map.keys()), _USER_FACING_BUTTON_IDS)
        # volume_mute stays a valid protocol-level id (device_profile keeps
        # it), but the RC003 has no physical mute key, so it must not appear
        # in the settings window's own button set at all (XRBM-019 review
        # round 1 P2).
        self.assertIn("volume_mute", device_profile.ALL_BUTTON_IDS)
        self.assertNotIn("volume_mute", _USER_FACING_BUTTON_IDS)

    def test_volume_mute_is_absent_from_the_default_display_map(self):
        state = default_display_state()
        self.assertNotIn("volume_mute", state.button_display_map)

    def test_hotkey_defaults_to_win_plus_h(self):
        state = default_display_state()
        self.assertEqual(state.hotkey_text, hotkey.DEFAULT_VOICE_HOTKEY.serialize())

    def test_trigger_mode_defaults_to_toggle_label(self):
        state = default_display_state()
        self.assertIn("免按住", state.trigger_mode_label)


class DescribeLaunchResultTests(unittest.TestCase):
    """XRBM-029: settings_ui's status text for each required
    stable bridge-launch states, built directly on the same
    bridge_launcher.LaunchResult values tests/test_bridge_launcher.py
    proves get produced - no Tk, no subprocess.
    """

    def test_not_started_text_is_a_fixed_constant_shown_before_any_launch(self):
        self.assertIn("未启动", LAUNCH_NOT_STARTED_TEXT)

    def test_started_never_claims_rc003_is_connected(self):
        result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.STARTED,
            command=("exe",),
            pid=123,
        )
        text = describe_launch_result(result)
        self.assertIn("123", text)
        self.assertNotIn("RC003 已连接", text)
        self.assertNotIn("已连接", text)

    def test_already_running_mentions_the_exit_code_and_is_distinct_from_quick_exit(self):
        result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.ALREADY_RUNNING,
            command=("exe",),
            exit_code=single_instance.DUPLICATE_INSTANCE_EXIT_CODE,
        )
        already_running_text = describe_launch_result(result)
        self.assertIn(str(single_instance.DUPLICATE_INSTANCE_EXIT_CODE), already_running_text)

        quick_exit_result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.QUICK_EXIT,
            command=("exe",),
            exit_code=1,
        )
        quick_exit_text = describe_launch_result(quick_exit_result)
        self.assertNotEqual(already_running_text, quick_exit_text)

    def test_quick_exit_preserves_the_real_exit_code_and_points_at_the_log(self):
        result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.QUICK_EXIT,
            command=("exe",),
            exit_code=9,
        )
        text = describe_launch_result(result)
        self.assertIn("9", text)
        self.assertIn("日志", text)

    def test_launch_failed_surfaces_the_error_and_points_at_the_log(self):
        result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.LAUNCH_FAILED,
            command=("exe",),
            error="[WinError 2] The system cannot find the file specified",
        )
        text = describe_launch_result(result)
        self.assertIn("WinError 2", text)
        self.assertIn("日志", text)

    def test_stop_failure_is_reported_as_a_switch_failure(self):
        result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.STOP_FAILED,
            command=tuple(),
            error="access denied",
        )
        text = describe_launch_result(result)
        self.assertIn("切换失败", text)
        self.assertIn("access denied", text)

    def test_stop_timeout_never_claims_a_replacement_started(self):
        result = bridge_launcher.LaunchResult(
            outcome=bridge_launcher.LaunchOutcome.STOP_TIMEOUT,
            command=tuple(),
        )
        text = describe_launch_result(result)
        self.assertIn("切换失败", text)
        self.assertNotIn("已启动", text)


class DescribeLogOpenResultTests(unittest.TestCase):
    def test_opened_ready_mentions_the_directory(self):
        directory = Path("/tmp/example/logs")
        location = logging_setup.LogLocation(
            status=logging_setup.LogLocationStatus.READY,
            directory=directory,
            file_path=directory / "app.log",
        )
        result = logging_setup.LogOpenResult(
            outcome=logging_setup.LogOpenOutcome.OPENED, location=location
        )
        text = describe_log_open_result(result)
        self.assertIn(str(directory), text)

    def test_opened_but_file_missing_gives_an_honest_note_not_an_error(self):
        directory = Path("/tmp/example/logs")
        location = logging_setup.LogLocation(
            status=logging_setup.LogLocationStatus.FILE_MISSING,
            directory=directory,
            file_path=directory / "app.log",
        )
        result = logging_setup.LogOpenResult(
            outcome=logging_setup.LogOpenOutcome.OPENED, location=location
        )
        text = describe_log_open_result(result)
        self.assertIn("app.log", text)
        self.assertIn("还没有运行", text)

    def test_directory_missing_does_not_claim_a_log_exists(self):
        directory = Path("/tmp/example/logs")
        location = logging_setup.LogLocation(
            status=logging_setup.LogLocationStatus.DIRECTORY_MISSING,
            directory=directory,
            file_path=directory / "app.log",
        )
        result = logging_setup.LogOpenResult(
            outcome=logging_setup.LogOpenOutcome.DIRECTORY_MISSING, location=location
        )
        text = describe_log_open_result(result)
        self.assertIn(str(directory), text)
        self.assertIn("没有运行", text)

    def test_open_failed_surfaces_the_underlying_error(self):
        directory = Path("/tmp/example/logs")
        location = logging_setup.LogLocation(
            status=logging_setup.LogLocationStatus.READY,
            directory=directory,
            file_path=directory / "app.log",
        )
        result = logging_setup.LogOpenResult(
            outcome=logging_setup.LogOpenOutcome.OPEN_FAILED,
            location=location,
            error="no shell association available",
        )
        text = describe_log_open_result(result)
        self.assertIn("no shell association available", text)


if __name__ == "__main__":
    unittest.main()
