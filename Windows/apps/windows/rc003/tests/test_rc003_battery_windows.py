import unittest

from ovb_rc003 import rc003_battery_windows as battery


class BatterySelectionTests(unittest.TestCase):
    def test_selects_exact_rc003_name_case_and_whitespace_insensitively(self):
        self.assertEqual(
            battery.read_rc003_battery_percent(
                enumerate_rows=lambda: [("  小米蓝牙语音遥控器  ", 87)]
            ),
            87,
        )

    def test_does_not_fuzzy_match_an_unrelated_xiaomi_device(self):
        self.assertIsNone(
            battery.read_rc003_battery_percent(
                enumerate_rows=lambda: [("Xiaomi Headphones", 55)]
            )
        )

    def test_missing_or_out_of_range_values_are_unavailable(self):
        for value in (None, -1, 101):
            with self.subTest(value=value):
                self.assertIsNone(
                    battery.read_rc003_battery_percent(
                        enumerate_rows=lambda value=value: [("mi rc", value)]
                    )
                )

    def test_conflicting_matching_device_values_fail_closed(self):
        self.assertIsNone(
            battery.read_rc003_battery_percent(
                enumerate_rows=lambda: [("mi rc", 80), ("小米蓝牙语音遥控器", 40)]
            )
        )


if __name__ == "__main__":
    unittest.main()
