import json
import tempfile
import unittest
from pathlib import Path

from ovb_rc003 import config


class ConfigTests(unittest.TestCase):
    def test_missing_file_returns_independent_defaults(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            first = config.load_config(path)
            first["gain_db"] = -10

            self.assertEqual(config.load_config(path), config.DEFAULT_CONFIG)

    def test_save_is_versioned_and_round_trips_utf8(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested" / "config.json"
            saved = config.save_config(
                {
                    **config.DEFAULT_CONFIG,
                    "output_endpoint_name": "扬声器",
                    "output_endpoint_host_api": "Windows WASAPI",
                    "gain_db": 6,
                },
                path,
            )

            self.assertEqual(config.load_config(path), saved)
            raw = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(raw["version"], config.CONFIG_VERSION)
            self.assertFalse(list(path.parent.glob("config.*.tmp")))

    def test_unknown_version_and_invalid_gain_fail_closed(self):
        with self.assertRaises(config.ConfigError):
            config.save_config({**config.DEFAULT_CONFIG, "version": 999})
        with self.assertRaises(config.ConfigError):
            config.save_config({**config.DEFAULT_CONFIG, "gain_db": 25})


if __name__ == "__main__":
    unittest.main()
