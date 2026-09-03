import unittest

from ovb_rc003 import win32_keys


class ResolveVkCodesTests(unittest.TestCase):
    def test_resolves_letters_and_digits(self):
        self.assertEqual(win32_keys.resolve_vk_codes(["a"]), [0x41])
        self.assertEqual(win32_keys.resolve_vk_codes(["0"]), [0x30])

    def test_resolves_named_keys_in_order(self):
        self.assertEqual(
            win32_keys.resolve_vk_codes(["win", "d"]),
            [win32_keys.VK_CODES["win"], win32_keys.VK_CODES["d"]],
        )

    def test_is_case_insensitive_and_trims_whitespace(self):
        self.assertEqual(win32_keys.resolve_vk_codes([" H "]), [win32_keys.VK_CODES["h"]])

    def test_unknown_token_raises(self):
        with self.assertRaises(win32_keys.UnknownKeyTokenError):
            win32_keys.resolve_vk_codes(["not_a_real_key"])

    def test_full_function_and_navigation_key_range_resolves(self):
        self.assertEqual(win32_keys.resolve_vk_codes(["f1", "f24"]), [0x70, 0x87])
        for token in ("home", "end", "page_up", "page_down", "insert", "delete"):
            self.assertIn(token, win32_keys.VK_CODES)

    def test_all_default_mapping_tokens_resolve(self):
        # Every key token used by key_mapping.default_button_actions() and the
        # default voice hotkey must be resolvable, or button/voice actions
        # would silently fail to inject on Windows.
        from ovb_rc003 import key_mapping

        for action in key_mapping.default_button_actions().values():
            if action.keys:
                win32_keys.resolve_vk_codes(action.keys)  # raises on failure
        win32_keys.resolve_vk_codes(("ralt", "space"))

    def test_right_alt_alias_and_code_are_available(self):
        self.assertEqual(win32_keys.resolve_vk_codes(("right_alt",)), [0xA5])


if __name__ == "__main__":
    unittest.main()
