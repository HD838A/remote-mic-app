import unittest

from ovb_rc003 import hotkey, key_mapping


class HotkeySpecTests(unittest.TestCase):
    def test_default_voice_hotkey_uses_the_uncommon_configurable_chord(self):
        self.assertEqual(hotkey.DEFAULT_VOICE_HOTKEY.serialize(), "lctrl+lalt")

    def test_voice_hotkey_presets_are_owned_by_the_trigger_mode_model(self):
        self.assertEqual(
            key_mapping.voice_hotkey_for_trigger_mode(key_mapping.VoiceTriggerMode.TOGGLE),
            "lctrl+lalt",
        )
        self.assertEqual(
            key_mapping.voice_hotkey_for_trigger_mode(key_mapping.VoiceTriggerMode.HOLD),
            "ralt",
        )

    def test_right_alt_can_be_used_as_a_hold_trigger(self):
        spec = hotkey.HotkeySpec.parse("right_alt")
        self.assertEqual(spec.modifiers, ())
        self.assertEqual(spec.key, "ralt")
        self.assertEqual(spec.serialize(), "ralt")

    def test_right_alt_space_round_trips_for_toggle_trigger(self):
        spec = hotkey.HotkeySpec.parse("right_alt+space")
        self.assertEqual(spec.modifiers, ("ralt",))
        self.assertEqual(spec.key, "space")
        self.assertEqual(spec.serialize(), "ralt+space")

    def test_left_ctrl_win_round_trips_as_a_modifier_only_chord(self):
        spec = hotkey.HotkeySpec.parse("left_ctrl+win")
        self.assertEqual(spec.modifiers, ("lctrl",))
        self.assertEqual(spec.key, "win")
        self.assertEqual(spec.serialize(), "lctrl+win")

    def test_recorded_voice_chords_infer_their_required_trigger_mode(self):
        self.assertEqual(
            key_mapping.voice_trigger_mode_for_hotkey("lctrl+lwin"),
            key_mapping.VoiceTriggerMode.HOLD,
        )
        self.assertEqual(
            key_mapping.voice_trigger_mode_for_hotkey("space+ralt"),
            key_mapping.VoiceTriggerMode.TOGGLE,
        )
        self.assertEqual(
            key_mapping.voice_trigger_mode_for_hotkey("lctrl+lalt"),
            key_mapping.VoiceTriggerMode.TOGGLE,
        )
        self.assertEqual(
            key_mapping.voice_trigger_mode_for_hotkey("ralt"),
            key_mapping.VoiceTriggerMode.TOGGLE,
        )
        self.assertIsNone(key_mapping.voice_trigger_mode_for_hotkey("win+h"))

    def test_voice_app_presets_have_distinct_shortcuts(self):
        self.assertEqual(
            key_mapping.voice_hotkey_for_input_preset(
                key_mapping.VoiceInputPreset.TYPELESS
            ),
            "lctrl+lalt",
        )
        self.assertEqual(
            key_mapping.voice_hotkey_for_input_preset(
                key_mapping.VoiceInputPreset.QIANWEN
            ),
            "ralt",
        )
        self.assertEqual(
            key_mapping.voice_input_preset_for_hotkey("lalt+lctrl"),
            key_mapping.VoiceInputPreset.TYPELESS,
        )
        self.assertEqual(
            key_mapping.voice_trigger_mode_for_input_preset(
                key_mapping.VoiceInputPreset.TYPELESS
            ),
            key_mapping.VoiceTriggerMode.TOGGLE,
        )
        self.assertEqual(
            key_mapping.voice_trigger_mode_for_input_preset(
                key_mapping.VoiceInputPreset.QIANWEN
            ),
            key_mapping.VoiceTriggerMode.TOGGLE,
        )

    def test_duplicate_modifiers_are_normalized(self):
        self.assertEqual(hotkey.HotkeySpec.parse("ctrl+ctrl+shift+p").serialize(), "ctrl+shift+p")

    def test_parse_and_serialize_round_trip(self):
        spec = hotkey.HotkeySpec.parse("win+h")
        self.assertEqual(spec.modifiers, ("win",))
        self.assertEqual(spec.key, "h")
        self.assertEqual(spec.serialize(), "win+h")

    def test_parse_orders_modifiers_canonically_on_serialize(self):
        spec = hotkey.HotkeySpec.parse("alt+ctrl+shift+v")
        self.assertEqual(spec.serialize(), "ctrl+shift+alt+v")

    def test_parse_rejects_empty_string(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            hotkey.HotkeySpec.parse("")

    def test_modifier_only_chord_is_accepted(self):
        spec = hotkey.HotkeySpec.parse("ctrl+shift")
        self.assertEqual(spec.modifiers, ("ctrl",))
        self.assertEqual(spec.key, "shift")
        self.assertEqual(spec.serialize(), "ctrl+shift")

    def test_parse_rejects_a_single_generic_modifier(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            hotkey.HotkeySpec.parse("ctrl")

    def test_parse_rejects_two_non_modifier_keys(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            hotkey.HotkeySpec.parse("a+b")

    def test_construct_rejects_unknown_modifier(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            hotkey.HotkeySpec(modifiers=("meta",), key="a")

    def test_construct_rejects_empty_key(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            hotkey.HotkeySpec(modifiers=(), key="")


if __name__ == "__main__":
    unittest.main()
