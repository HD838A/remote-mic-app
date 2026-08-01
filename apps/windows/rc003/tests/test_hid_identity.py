import unittest

from ovb_rc003 import hid_identity


def _report(usages):
    payload = bytearray(6)
    for index, usage in enumerate(usages[:3]):
        payload[index * 2 : index * 2 + 2] = usage.to_bytes(2, "little")
    return bytes((0x01, 0x00, 0x00)) + bytes(payload)


class DevicePathMatchTests(unittest.TestCase):
    def test_matches_rc003_vid_pid(self):
        path = r"\\?\HID#VID_2717&PID_32B8&REV_00A4#7&abc#{guid}"
        self.assertTrue(hid_identity.device_path_matches_rc003(path))

    def test_matches_case_insensitively(self):
        path = r"\\?\hid#vid_2717&pid_32b8#7&abc#{guid}"
        self.assertTrue(hid_identity.device_path_matches_rc003(path))

    def test_matches_windows_ble_hid_dev_vid_pid_path(self):
        # Windows exposes this BLE HID collection as
        # ``..._Dev_VID&012717_PID&32B8...`` rather than the classic
        # ``VID_2717&PID_32B8`` spelling. This is the real path shape observed
        # on the RC003 machine during diagnosis.
        path = (
            r"\\?\HID#{00001812-0000-1000-8000-00805f9b34fb}_Dev_"
            r"VID&012717_PID&32B8_REV&00A4_device#instance#{guid}"
        )
        self.assertTrue(hid_identity.device_path_matches_rc003(path))

    def test_rejects_other_vendor(self):
        path = r"\\?\HID#VID_0001&PID_0002#7&abc#{guid}"
        self.assertFalse(hid_identity.device_path_matches_rc003(path))

    def test_rejects_matching_vid_wrong_pid(self):
        path = r"\\?\HID#VID_2717&PID_0000#7&abc#{guid}"
        self.assertFalse(hid_identity.device_path_matches_rc003(path))


class NormalizeDevicePathTests(unittest.TestCase):
    """XRBM-018: raw_input_windows.py enforces the exact selected device
    path (not just a VID/PID re-match) on every Raw Input event - this is
    the normalization the equality check is built on.
    """

    def test_normalizes_case(self):
        path = r"\\?\HID#VID_2717&PID_32B8#7&ABC#{guid}"
        self.assertEqual(
            hid_identity.normalize_device_path(path), hid_identity.normalize_device_path(path.lower())
        )

    def test_strips_surrounding_whitespace(self):
        path = r"\\?\HID#VID_2717&PID_32B8#7&abc#{guid}"
        self.assertEqual(hid_identity.normalize_device_path(f"  {path}\n"), hid_identity.normalize_device_path(path))

    def test_a_second_matching_vid_pid_device_normalizes_to_a_different_path(self):
        # Two distinct physical RC003s (different instance suffix) must not
        # normalize to the same value - the whole point of exact-path
        # scoping is to distinguish them, unlike a VID/PID-only match.
        first = r"\\?\HID#VID_2717&PID_32B8#7&aaa#{guid}"
        second = r"\\?\HID#VID_2717&PID_32B8#7&bbb#{guid}"
        self.assertNotEqual(
            hid_identity.normalize_device_path(first), hid_identity.normalize_device_path(second)
        )


class ReportDecodeTests(unittest.TestCase):
    def test_decode_extracts_active_usage_set(self):
        report = _report([0x0028, 0x0052])  # ok + up
        active = hid_identity.decode_active_usages(report)
        self.assertEqual(active, frozenset({0x0028, 0x0052}))

    def test_decode_ignores_zero_slots(self):
        report = _report([0x0028])
        active = hid_identity.decode_active_usages(report)
        self.assertEqual(active, frozenset({0x0028}))

    def test_decode_rejects_wrong_length(self):
        with self.assertRaises(ValueError):
            hid_identity.decode_active_usages(b"\x01\x00\x00\x00")

    def test_decode_rejects_wrong_prefix(self):
        with self.assertRaises(ValueError):
            hid_identity.decode_active_usages(bytes((0x02, 0x00, 0x00)) + bytes(6))

    def test_decode_ignores_unknown_usage_ids(self):
        report = _report([0xFFFF])
        active = hid_identity.decode_active_usages(report)
        self.assertEqual(active, frozenset())

    def test_back_usage_is_tracked(self):
        report = _report([0x00F1])
        active = hid_identity.decode_active_usages(report)
        self.assertIn(0x00F1, active)
        self.assertEqual(hid_identity.usage_to_button(0x00F1), "back")

    def test_real_rc003_mic_f5_usage_is_tracked(self):
        report = _report([0x003E])
        active = hid_identity.decode_active_usages(report)
        self.assertIn(0x003E, active)
        self.assertEqual(hid_identity.usage_to_button(0x003E), "mic")


class DiffUsagesTests(unittest.TestCase):
    def test_pressed_and_released_edges(self):
        previous = frozenset({0x0028})
        current = frozenset({0x0052})
        pressed, released = hid_identity.diff_usages(previous, current)
        self.assertEqual(pressed, frozenset({0x0052}))
        self.assertEqual(released, frozenset({0x0028}))

    def test_no_change_yields_empty_edges(self):
        state = frozenset({0x0028})
        pressed, released = hid_identity.diff_usages(state, state)
        self.assertEqual(pressed, frozenset())
        self.assertEqual(released, frozenset())

    def test_all_released_on_empty_current(self):
        previous = frozenset({0x0028, 0x0052})
        pressed, released = hid_identity.diff_usages(previous, frozenset())
        self.assertEqual(pressed, frozenset())
        self.assertEqual(released, previous)


class UsageToButtonTests(unittest.TestCase):
    def test_known_usage_maps_to_name(self):
        self.assertEqual(hid_identity.usage_to_button(0x0066), "power")

    def test_unknown_usage_returns_none(self):
        self.assertIsNone(hid_identity.usage_to_button(0x1234))


class SelectSingleDevicePathTests(unittest.TestCase):
    """Fixed after XRBM-014 review RETRY P1 #5: HID device-path selection
    must fail closed on ambiguity, not "return the first match".
    """

    def test_selects_the_sole_matching_path(self):
        paths = [r"\\?\HID#VID_2717&PID_32B8#7&abc#{guid}"]
        self.assertEqual(hid_identity.select_single_device_path(paths), paths[0])

    def test_ignores_non_matching_paths(self):
        paths = [
            r"\\?\HID#VID_0001&PID_0002#7&abc#{guid}",
            r"\\?\HID#VID_2717&PID_32B8#7&def#{guid}",
        ]
        self.assertEqual(hid_identity.select_single_device_path(paths), paths[1])

    def test_no_match_raises_no_device_path_found(self):
        paths = [r"\\?\HID#VID_0001&PID_0002#7&abc#{guid}"]
        with self.assertRaises(hid_identity.NoDevicePathFoundError):
            hid_identity.select_single_device_path(paths)

    def test_empty_list_raises_no_device_path_found(self):
        with self.assertRaises(hid_identity.NoDevicePathFoundError):
            hid_identity.select_single_device_path([])

    def test_multiple_matches_fail_closed(self):
        paths = [
            r"\\?\HID#VID_2717&PID_32B8#7&abc#{guid}",
            r"\\?\HID#VID_2717&PID_32B8#7&def#{guid}",
        ]
        with self.assertRaises(hid_identity.AmbiguousDevicePathError) as ctx:
            hid_identity.select_single_device_path(paths)
        self.assertEqual(ctx.exception.count, 2)

    def test_never_silently_picks_the_first_of_several_matches(self):
        # Regression guard for the exact behavior being replaced: even
        # though callers might expect index-0 to "win", ambiguity must
        # always raise instead.
        paths = ["A" + r"\HID#VID_2717&PID_32B8#1#{g}", "B" + r"\HID#VID_2717&PID_32B8#2#{g}"]
        with self.assertRaises(hid_identity.AmbiguousDevicePathError):
            hid_identity.select_single_device_path(paths)


class ParseRawInputHidPayloadTests(unittest.TestCase):
    def test_single_report_round_trips(self):
        report = _report([0x0028])
        body = (9).to_bytes(4, "little") + (1).to_bytes(4, "little") + report
        reports = hid_identity.parse_rawinput_hid_payload(body)
        self.assertEqual(reports, (report,))

    def test_multiple_reports_in_one_rawhid_body(self):
        report_a = _report([0x0028])
        report_b = _report([0x0052])
        body = (
            (9).to_bytes(4, "little")
            + (2).to_bytes(4, "little")
            + report_a
            + report_b
        )
        reports = hid_identity.parse_rawinput_hid_payload(body)
        self.assertEqual(reports, (report_a, report_b))

    def test_too_short_body_raises(self):
        with self.assertRaises(ValueError):
            hid_identity.parse_rawinput_hid_payload(b"\x00\x00\x00")

    def test_truncated_body_raises(self):
        # Claims 9-byte reports x1 but only supplies 4 bytes of report data.
        body = (9).to_bytes(4, "little") + (1).to_bytes(4, "little") + b"\x00" * 4
        with self.assertRaises(ValueError):
            hid_identity.parse_rawinput_hid_payload(body)

    def test_zero_size_hid_raises(self):
        body = (0).to_bytes(4, "little") + (1).to_bytes(4, "little")
        with self.assertRaises(ValueError):
            hid_identity.parse_rawinput_hid_payload(body)


if __name__ == "__main__":
    unittest.main()
