import unittest

from ovb_rc003 import hotkey


class HotkeySpecTests(unittest.TestCase):
    def test_default_voice_hotkey_serializes_to_win_plus_h(self):
        self.assertEqual(hotkey.DEFAULT_VOICE_HOTKEY.serialize(), "win+h")

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

    def test_parse_rejects_modifiers_only(self):
        with self.assertRaises(hotkey.HotkeyParseError):
            hotkey.HotkeySpec.parse("ctrl+shift")

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
