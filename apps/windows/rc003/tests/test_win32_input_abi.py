"""Cross-platform assertions on the real x64 Win32 ``INPUT`` struct shape
declared in win32_input.py (XRBM-018, fixing XRBM-014 review round 2 P1 #1
and P1 #8).

These do not need ``ctypes.windll`` (Windows-only) at all - only
``ctypes.sizeof()``/``ctypes.offsetof()`` on plain ``ctypes.Structure``
classes, which works on any host. See win32_input.py's module-level comment
for why the struct fields use explicit fixed-width ctypes types
(``c_uint32``/``c_int32``/``c_uint16``) rather than ``ctypes.wintypes``
aliases: the latter track the *host* C ``long`` width (8 bytes on 64-bit
macOS/Linux) rather than the Windows ABI's ``long`` (always 4 bytes), which
would make a size assertion here meaningless off Windows.

The genuinely Windows-only half of this contract (a real ``SendInput`` call
with this struct actually succeeding) is covered separately in
tests/windows/test_windows_only.py.
"""

import ctypes
import unittest

from ovb_rc003 import win32_input


class InputStructShapeTests(unittest.TestCase):
    def test_sizeof_input_matches_the_documented_x64_win32_abi(self):
        # Microsoft's own SendInput documentation and headers put
        # sizeof(INPUT) at 40 bytes on x64 - this is the exact value
        # SendInput's cbSize parameter must receive; the XRBM-014 round-2
        # regression (a union with only KEYBDINPUT) produced 32 instead.
        self.assertEqual(ctypes.sizeof(win32_input.INPUT), 40)

    def test_union_is_sized_by_its_largest_member_mouseinput(self):
        self.assertEqual(
            ctypes.sizeof(win32_input._INPUT_UNION), ctypes.sizeof(win32_input.MOUSEINPUT)
        )
        self.assertGreater(
            ctypes.sizeof(win32_input.MOUSEINPUT), ctypes.sizeof(win32_input.KEYBDINPUT)
        )

    def test_union_declares_all_three_real_members(self):
        field_names = {name for name, _type in win32_input._INPUT_UNION._fields_}
        self.assertEqual(field_names, {"mi", "ki", "hi"})

    def test_keybdinput_extra_info_is_pointer_sized_ulong_ptr(self):
        # ULONG_PTR is an integer the same width as a pointer, not
        # POINTER(ULONG) - a NULL pointer and a zero ULONG_PTR happen to be
        # bit-identical, which is what let the previous (wrong-typed) field
        # hide this bug on x64.
        field_type = dict(win32_input.KEYBDINPUT._fields_)["dwExtraInfo"]
        self.assertIs(field_type, ctypes.c_size_t)
        self.assertEqual(ctypes.sizeof(field_type), ctypes.sizeof(ctypes.c_void_p))

    def test_input_type_field_is_first_and_four_bytes(self):
        self.assertEqual(win32_input.INPUT.type.offset, 0)
        self.assertEqual(ctypes.sizeof(dict(win32_input.INPUT._fields_)["type"]), 4)

    def test_sendinput_argtypes_use_a_pointer_to_the_real_input_struct(self):
        # _build_input_array is the only place production code constructs
        # the array SendInput receives; assert it hands back the same INPUT
        # type this module declares (not some other ad-hoc struct).
        array, input_type = win32_input._build_input_array([(0x41, False)])
        self.assertIs(input_type, win32_input.INPUT)
        self.assertEqual(ctypes.sizeof(array), ctypes.sizeof(win32_input.INPUT))

    def test_right_alt_uses_the_extended_physical_scan_code(self):
        array, _ = win32_input._build_input_array(
            [(win32_input.win32_keys.VK_CODES["ralt"], False)]
        )
        keybd = array[0].union.ki
        self.assertEqual(keybd.wVk, 0)
        self.assertEqual(keybd.wScan, 0x38)
        self.assertEqual(
            keybd.dwFlags,
            win32_input._KEYEVENTF_SCANCODE | win32_input._KEYEVENTF_EXTENDEDKEY,
        )

    def test_left_ctrl_uses_a_non_extended_physical_scan_code(self):
        array, _ = win32_input._build_input_array(
            [(win32_input.win32_keys.VK_CODES["lctrl"], False)]
        )
        keybd = array[0].union.ki
        self.assertEqual(keybd.wVk, 0)
        self.assertEqual(keybd.wScan, 0x1D)
        self.assertEqual(keybd.dwFlags, win32_input._KEYEVENTF_SCANCODE)

    def test_left_win_uses_the_extended_physical_scan_code(self):
        array, _ = win32_input._build_input_array(
            [(win32_input.win32_keys.VK_CODES["win"], False)]
        )
        keybd = array[0].union.ki
        self.assertEqual(keybd.wVk, 0)
        self.assertEqual(keybd.wScan, 0x5B)
        self.assertEqual(
            keybd.dwFlags,
            win32_input._KEYEVENTF_SCANCODE | win32_input._KEYEVENTF_EXTENDEDKEY,
        )


if __name__ == "__main__":
    unittest.main()
