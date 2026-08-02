import ctypes
import sys
import unittest

from ovb_rc003 import win32_input


class Win32InputPureTests(unittest.TestCase):
    def test_parses_custom_shortcut_without_windows_api(self):
        self.assertEqual(
            win32_input.parse_shortcut("Ctrl + Shift + P"),
            ("ctrl", "shift", "P"),
        )

    def test_unknown_key_fails_closed(self):
        with self.assertRaises(ValueError):
            win32_input.parse_shortcut("ctrl+not-a-key")

    @unittest.skipUnless(sys.platform == "win32", "Windows ABI only")
    def test_send_input_structure_matches_windows_x64_abi(self):
        self.assertEqual(ctypes.sizeof(ctypes.c_void_p), 8)
        self.assertEqual(ctypes.sizeof(win32_input.INPUT), 40)


if __name__ == "__main__":
    unittest.main()
