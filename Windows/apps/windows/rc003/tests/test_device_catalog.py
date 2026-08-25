import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ovb_rc003 import audio_output, device_catalog, resources


class DeviceCatalogTests(unittest.TestCase):
    def test_default_catalog_is_loaded_from_the_repository_json(self):
        self.assertIsNone(device_catalog.CATALOG_ERROR)
        self.assertEqual(
            [profile.device_id for profile in device_catalog.DEVICE_PROFILES],
            [device_catalog.DJI_MIC_2_ID, device_catalog.RC003_ID],
        )
        rc003 = device_catalog.profile_for(device_catalog.RC003_ID)
        dji = device_catalog.profile_for(device_catalog.DJI_MIC_2_ID)
        self.assertEqual(rc003.display_name, "Xiaomi Bluetooth Remote 2 Pro / RC003")
        self.assertEqual(rc003.support_status, "research")
        self.assertEqual(dji.display_name, "DJI Mic 2")
        self.assertEqual(dji.support_status, "research")
        self.assertEqual(
            next(item.status for item in dji.platforms if item.platform == "windows"),
            "planned",
        )

    def test_old_or_unknown_config_defaults_to_rc003(self):
        self.assertEqual(device_catalog.normalize_device_id(None), device_catalog.RC003_ID)
        self.assertEqual(device_catalog.normalize_device_id("unknown"), device_catalog.RC003_ID)

    def test_dji_profile_has_no_editable_button_mapping(self):
        profile = device_catalog.profile_for(device_catalog.DJI_MIC_2_ID)
        self.assertFalse(profile.has_editable_button_mapping)
        self.assertIn("Windows 录音输入", profile.description)

    def test_dji_controls_are_only_the_three_official_hardware_controls(self):
        self.assertEqual(
            [control.control_id for control in device_catalog.DJI_MIC_2_CONTROLS],
            ["record", "link", "power"],
        )
        self.assertTrue(
            all("映射" in control.windows_mapping for control in device_catalog.DJI_MIC_2_CONTROLS)
        )

    def test_dji_input_status_requires_a_real_recording_endpoint(self):
        missing = device_catalog.dji_mic_2_input_status(
            [audio_output.AudioEndpoint("Microphone Array", "Windows WASAPI")]
        )
        present = device_catalog.dji_mic_2_input_status(
            [audio_output.AudioEndpoint("Microphone (DJI-MIC2-ABCDEF Hands-Free)", "Windows WASAPI")]
        )
        self.assertIn("未检测到", missing)
        self.assertIn("已检测到", present)
        self.assertNotIn("ABCDEF", present)

    def test_missing_directory_fails_closed(self):
        missing = Path(tempfile.gettempdir()) / "ovb-catalog-does-not-exist"
        with self.assertRaisesRegex(
            device_catalog.DeviceCatalogLoadError, "directory is unavailable"
        ):
            device_catalog.load_device_catalog(missing)

    def test_missing_field_unknown_status_and_duplicate_id_fail_closed(self):
        source_directory = resources.find_device_profiles_directory()
        self.assertIsNotNone(source_directory)
        source_profile = json.loads(
            (source_directory / "dji-mic-2.json").read_text(encoding="utf-8")
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            missing = dict(source_profile)
            missing.pop("displayName")
            (directory / "missing.json").write_text(json.dumps(missing), encoding="utf-8")
            with self.assertRaisesRegex(
                device_catalog.DeviceCatalogLoadError, "missing required field displayName"
            ):
                device_catalog.load_device_catalog(directory)

        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            unknown = json.loads(json.dumps(source_profile))
            unknown["platforms"][0]["status"] = "beta"
            (directory / "unknown.json").write_text(json.dumps(unknown), encoding="utf-8")
            with self.assertRaisesRegex(
                device_catalog.DeviceCatalogLoadError, "unknown value 'beta'"
            ):
                device_catalog.load_device_catalog(directory)

        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            non_windows = json.loads(json.dumps(source_profile))
            non_windows["platforms"][0]["platform"] = "macos"
            (directory / "non-windows.json").write_text(
                json.dumps(non_windows), encoding="utf-8"
            )
            with self.assertRaisesRegex(
                device_catalog.DeviceCatalogLoadError, "platform is unknown"
            ):
                device_catalog.load_device_catalog(directory)

        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            encoded = json.dumps(source_profile)
            (directory / "one.json").write_text(encoded, encoding="utf-8")
            (directory / "two.json").write_text(encoded, encoding="utf-8")
            with self.assertRaisesRegex(
                device_catalog.DeviceCatalogLoadError, "duplicate device profile id"
            ):
                device_catalog.load_device_catalog(directory)

    def test_frozen_locator_reads_only_the_packaged_device_profiles_directory(self):
        source = resources.find_device_profiles_directory()
        self.assertIsNotNone(source)
        with tempfile.TemporaryDirectory() as temp_dir:
            frozen_root = Path(temp_dir)
            expected = frozen_root / "device-profiles"
            shutil.copytree(source, expected)
            with mock.patch.object(resources.sys, "_MEIPASS", str(frozen_root), create=True):
                self.assertEqual(resources.find_device_profiles_directory(), expected)
                catalog = device_catalog.load_device_catalog()
                self.assertEqual(
                    [profile.device_id for profile in catalog.profiles],
                    [device_catalog.DJI_MIC_2_ID, device_catalog.RC003_ID],
                )

    def test_frozen_locator_does_not_fall_back_to_source_when_bundle_data_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            with mock.patch.object(resources.sys, "_MEIPASS", temp_dir, create=True):
                self.assertIsNone(resources.find_device_profiles_directory())
                with self.assertRaisesRegex(
                    device_catalog.DeviceCatalogLoadError, "directory is unavailable"
                ):
                    device_catalog.load_device_catalog()


if __name__ == "__main__":
    unittest.main()
