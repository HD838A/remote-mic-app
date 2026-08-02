import unittest

from ovb_rc003 import hid_identity, raw_input_windows


class RawInputPureTests(unittest.TestCase):
    def test_device_path_requires_exact_rc003_vid_and_pid(self):
        self.assertTrue(
            raw_input_windows.device_path_matches_rc003(
                r"\\?\HID#VID_2717&PID_32B8&REV_00A4#example"
            )
        )
        self.assertFalse(
            raw_input_windows.device_path_matches_rc003(
                r"\\?\HID#VID_2717&PID_0001#example"
            )
        )
        self.assertTrue(
            raw_input_windows.device_path_matches_rc003(
                r"\\?\BTHLEDEVICE#DEV_VID&012717_PID&32B8_REV&00A4#example"
            )
        )

    def test_keyboard_translation_covers_standard_and_scan_code_keys(self):
        self.assertEqual(raw_input_windows.keyboard_button(0x0D, 0), "ok")
        self.assertEqual(raw_input_windows.keyboard_button(0xFF, 0x6A), "back")

    def test_decodes_real_rc003_uint16_usage_slots(self):
        report = b"\x01\x00\x00\x28\x00\x80\x00\x00\x00"

        self.assertEqual(
            hid_identity.decode_active_buttons(report),
            frozenset({"ok", "volume_up"}),
        )


if __name__ == "__main__":
    unittest.main()
