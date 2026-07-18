"""Tests the pure display<->action/save-model helper functions in
settings_ui.py without constructing any real Tk widget or window - see
XRBM-014 review RETRY P1 #7/#8 boundary ("不启动 Tk 或任何可见窗口"). Every
function under test here takes and returns plain data (strings, dicts,
dataclasses); none of it touches ``tkinter.Tk``/``Toplevel``/mainloop.
"""

import unittest

from ovb_rc003 import audio_output, hotkey, key_mapping
from ovb_rc003.settings_ui import (
    SettingsValidationError,
    _VOICE_DISPLAY,
    _action_to_display,
    _display_to_action,
    _endpoint_display,
    _parse_endpoint_display,
    build_save_model,
    default_display_state,
)


class DisplayRoundTripTests(unittest.TestCase):
    def test_key_combo_round_trips(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.KEY_COMBO, ("win", "d"))
        display = _action_to_display(action)
        restored = _display_to_action(display)
        self.assertEqual(restored.kind, key_mapping.ActionKind.KEY_COMBO)
        self.assertEqual(restored.keys, ("win", "d"))

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
        self.assertIn("Win+H", display)

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
        self.assertEqual(new_config["voice_hotkey"], "win+h")

    def test_invalid_hotkey_raises_with_no_button_id(self):
        with self.assertRaises(SettingsValidationError) as ctx:
            build_save_model(
                button_display_map={},
                hotkey_text="ctrl+shift",  # modifiers only - invalid
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
        self.assertIn("toggle", state.trigger_mode_label)


if __name__ == "__main__":
    unittest.main()
