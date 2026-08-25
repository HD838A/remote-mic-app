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
            "power": (key_mapping.ActionKind.ESCAPE, ()),
            "up": (key_mapping.ActionKind.ARROW_UP, ()),
            "down": (key_mapping.ActionKind.ARROW_DOWN, ()),
            "left": (key_mapping.ActionKind.ARROW_LEFT, ()),
            "right": (key_mapping.ActionKind.ARROW_RIGHT, ()),
            "ok": (key_mapping.ActionKind.RETURN, ()),
            "back": (key_mapping.ActionKind.DELETE_BACKWARD, ()),
            "volume_up": (key_mapping.ActionKind.SYSTEM_VOLUME_UP, ()),
            "volume_down": (key_mapping.ActionKind.SYSTEM_VOLUME_DOWN, ()),
            "home": (key_mapping.ActionKind.SHOW_DESKTOP, ()),
            "menu": (key_mapping.ActionKind.CONTEXT_MENU, ()),
            "tv": (key_mapping.ActionKind.APP_SWITCHER, ()),
        }
        for button_id, (kind, keys) in expected.items():
            action = self.defaults[button_id]
            self.assertEqual(action.kind, kind, msg=button_id)
            self.assertEqual(action.keys, keys, msg=button_id)

    def test_all_default_button_ids_are_known_buttons(self):
        self.assertTrue(key_mapping.DEFAULT_BUTTON_IDS.issubset(device_profile.ALL_BUTTON_IDS))


class ButtonActionSerializationTests(unittest.TestCase):
    def test_round_trip_disabled_action(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.DISABLED)
        self.assertEqual(key_mapping.ButtonAction.from_dict(action.to_dict()), action)

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

    def test_reference_actions_are_semantic_and_not_key_combos(self):
        for action_kind in (
            key_mapping.ActionKind.ESCAPE,
            key_mapping.ActionKind.RETURN,
            key_mapping.ActionKind.ARROW_UP,
            key_mapping.ActionKind.DELETE_BACKWARD,
            key_mapping.ActionKind.SHOW_DESKTOP,
            key_mapping.ActionKind.CONTEXT_MENU,
            key_mapping.ActionKind.APP_SWITCHER,
        ):
            action = key_mapping.ButtonAction(action_kind)
            self.assertEqual(action.keys, ())
            self.assertEqual(
                key_mapping.ButtonAction.from_dict(action.to_dict()), action
            )

    def test_reference_open_app_actions_are_first_class_actions(self):
        for action_kind in (
            key_mapping.ActionKind.OPEN_CODEX,
            key_mapping.ActionKind.OPEN_CLAUDE,
            key_mapping.ActionKind.OPEN_CMUX,
            key_mapping.ActionKind.OPEN_CHROME,
        ):
            action = key_mapping.ButtonAction(action_kind)
            self.assertEqual(action.keys, ())
            self.assertEqual(
                key_mapping.ButtonAction.from_dict(action.to_dict()), action
            )


class GestureBindingLookupTests(unittest.TestCase):
    def test_legacy_flat_binding_is_single_click_only(self):
        bindings = {
            "bindings": {
                "up": {"kind": "key_combo", "keys": ["up"]},
            }
        }

        self.assertEqual(
            key_mapping.button_action_for(
                bindings, "up", key_mapping.ButtonTrigger.SINGLE_CLICK
            ).keys,
            ("up",),
        )
        self.assertEqual(
            key_mapping.button_action_for(
                bindings, "up", key_mapping.ButtonTrigger.DOUBLE_CLICK
            ).kind,
            key_mapping.ActionKind.DISABLED,
        )

    def test_secondary_actions_are_read_independently(self):
        bindings = {
            "bindings": {
                "power": {"kind": "key_combo", "keys": ["escape"]},
            },
            "secondary_bindings": {
                "power": {
                    "double_click": {
                        "kind": "key_combo",
                        "keys": ["f5"],
                    },
                    "long_press": {
                        "kind": "system_volume_up",
                        "keys": [],
                    },
                }
            },
        }

        self.assertEqual(
            key_mapping.button_action_for(
                bindings, "power", key_mapping.ButtonTrigger.DOUBLE_CLICK
            ).keys,
            ("f5",),
        )
        self.assertEqual(
            key_mapping.button_action_for(
                bindings, "power", key_mapping.ButtonTrigger.LONG_PRESS
            ).kind,
            key_mapping.ActionKind.SYSTEM_VOLUME_UP,
        )
        self.assertTrue(key_mapping.has_secondary_action(bindings, "power"))


if __name__ == "__main__":
    unittest.main()
