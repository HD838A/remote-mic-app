import json
import tempfile
import unittest
from datetime import date
from pathlib import Path

from ovb_rc003 import usage_statistics


class UsageStatisticsStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.today = date(2026, 8, 22)
        self.store = usage_statistics.UsageStatisticsStore(
            self.root, today=lambda: self.today
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_records_only_daily_aggregates(self):
        self.store.record_button_press()
        self.store.record_voice_session(62.4)

        payload = json.loads(
            usage_statistics.statistics_path(self.root).read_text(encoding="utf-8")
        )
        self.assertEqual(
            payload["days"]["2026-08-22"],
            {"button_presses": 1, "voice_seconds": 62.4, "voice_sessions": 1},
        )
        serialized = json.dumps(payload).lower()
        for forbidden in ("text", "audio", "device", "application"):
            self.assertNotIn(forbidden, serialized)

    def test_snapshot_contains_current_calendar_year_month_grid(self):
        self.store.record_button_press()
        snapshot = self.store.snapshot()

        self.assertEqual(len(snapshot["cells"]), 365)
        self.assertEqual(snapshot["cells"][0]["date"], "2026-01-01")
        self.assertEqual(snapshot["cells"][-1]["date"], "2026-12-31")
        self.assertEqual(len(snapshot["monthBlocks"]), 12)
        self.assertEqual(
            [block["label"] for block in snapshot["monthBlocks"]],
            [f"{month} 月" for month in range(1, 13)],
        )
        self.assertEqual(snapshot["currentMonthIndex"], 7)
        self.assertEqual(snapshot["yearLabel"], "2026")
        today_cell = next(cell for cell in snapshot["cells"] if cell["date"] == "2026-08-22")
        self.assertEqual(today_cell["usageCount"], 1)
        self.assertEqual(today_cell["frequencyLevel"], 4)
        self.assertEqual(snapshot["activeDays"], "1 天")

    def test_each_month_uses_monday_to_sunday_rows(self):
        snapshot = self.store.snapshot()
        january = snapshot["monthBlocks"][0]
        first = january["cells"][0]
        self.assertEqual(first["date"], "2026-01-01")
        self.assertEqual(first["dayIndex"], 3)  # Thursday on a Monday-first axis.
        self.assertEqual(first["weekIndex"], 0)
        self.assertTrue(all(0 <= cell["dayIndex"] <= 6 for cell in snapshot["cells"]))

    def test_corrupt_file_degrades_to_empty_snapshot(self):
        path = usage_statistics.statistics_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("not-json", encoding="utf-8")

        snapshot = self.store.snapshot()

        self.assertEqual(snapshot["todayDuration"], "0 秒")
        self.assertEqual(snapshot["todayFrequency"], "0 次触发")

    def test_invalid_or_zero_voice_duration_is_not_recorded(self):
        self.store.record_voice_session(0)
        self.store.record_voice_session(float("nan"))
        self.assertFalse(usage_statistics.statistics_path(self.root).exists())


class DurationFormattingTests(unittest.TestCase):
    def test_formats_seconds_minutes_and_hours(self):
        self.assertEqual(usage_statistics.format_duration(8), "8 秒")
        self.assertEqual(usage_statistics.format_duration(65), "1 分 5 秒")
        self.assertEqual(usage_statistics.format_duration(7322), "2 小时 2 分")


if __name__ == "__main__":
    unittest.main()
