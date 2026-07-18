import unittest

from ovb_rc003 import device_profile, key_mapping


class DefaultButtonActionsTests(unittest.TestCase):
    def setUp(self):
        self.defaults = key_mapping.default_button_actions()

    def test_covers_exactly_the_defined_default_button_ids(self):
        self.assertEqual(set(self.defaults.keys()), key_mapping.DEFAULT_BUTTON_IDS)

    def test_volume_mute_has_no_default_binding(self):
        self.assertNotIn("volume_mute", self.defaults)
        self.assertIn("volume_mute", device_profile.ALL_BUTTON_IDS)

    def test_matches_task_table_exactly(self):
        expected = {
            "mic": (key_mapping.ActionKind.VOICE, ()),
            "power": (key_mapping.ActionKind.KEY_COMBO, ("escape",)),
            "up": (key_mapping.ActionKind.KEY_COMBO, ("up",)),
            "down": (key_mapping.ActionKind.KEY_COMBO, ("down",)),
            "left": (key_mapping.ActionKind.KEY_COMBO, ("left",)),
            "right": (key_mapping.ActionKind.KEY_COMBO, ("right",)),
            "ok": (key_mapping.ActionKind.KEY_COMBO, ("enter",)),
            "back": (key_mapping.ActionKind.KEY_COMBO, ("backspace",)),
            "volume_up": (key_mapping.ActionKind.SYSTEM_VOLUME_UP, ()),
            "volume_down": (key_mapping.ActionKind.SYSTEM_VOLUME_DOWN, ()),
            "home": (key_mapping.ActionKind.KEY_COMBO, ("win", "d")),
            "menu": (key_mapping.ActionKind.KEY_COMBO, ("shift", "f10")),
            "tv": (key_mapping.ActionKind.KEY_COMBO, ("alt", "esc")),
        }
        for button_id, (kind, keys) in expected.items():
            action = self.defaults[button_id]
            self.assertEqual(action.kind, kind, msg=button_id)
            self.assertEqual(action.keys, keys, msg=button_id)

    def test_all_default_button_ids_are_known_buttons(self):
        self.assertTrue(key_mapping.DEFAULT_BUTTON_IDS.issubset(device_profile.ALL_BUTTON_IDS))


class ButtonActionSerializationTests(unittest.TestCase):
    def test_round_trip_key_combo(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.KEY_COMBO, ("win", "d"))
        restored = key_mapping.ButtonAction.from_dict(action.to_dict())
        self.assertEqual(action, restored)

    def test_round_trip_voice_action_has_empty_keys(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE)
        data = action.to_dict()
        self.assertEqual(data["keys"], [])
        restored = key_mapping.ButtonAction.from_dict(data)
        self.assertEqual(restored.keys, ())


if __name__ == "__main__":
    unittest.main()
