import unittest

from ovb_rc003 import key_mapping


class KeyMappingTests(unittest.TestCase):
    def test_defaults_cover_all_visible_remote_buttons(self):
        bindings = key_mapping.default_button_bindings()

        self.assertEqual(set(bindings), key_mapping.BUTTON_IDS)
        self.assertEqual(bindings["ok"]["single_click"], "return")
        self.assertEqual(bindings["mic"]["single_click"], "voice")

    def test_custom_shortcut_round_trips_through_display_text(self):
        action = key_mapping.display_to_action("Ctrl + Shift + P")

        self.assertEqual(action, "shortcut:ctrl+shift+p")
        self.assertEqual(key_mapping.action_to_display(action), "快捷键：ctrl+shift+p")

    def test_unknown_custom_shortcut_is_rejected_before_save(self):
        with self.assertRaises(ValueError):
            key_mapping.display_to_action("Ctrl + not-a-key")

    def test_secondary_action_lookup_is_independent(self):
        settings = {"button_bindings": key_mapping.default_button_bindings()}
        settings["button_bindings"]["ok"]["double_click"] = "open_codex"

        self.assertEqual(
            key_mapping.configured_action(settings, "ok", "double_click"),
            "open_codex",
        )
        self.assertTrue(key_mapping.has_secondary_action(settings, "ok"))


if __name__ == "__main__":
    unittest.main()
