"""Tests shell_targets.py (XRBM-030): the "权限" page's open-Settings-page
adapter, exercised entirely via an injected opener - no real OS shell call
is ever made, mirroring tests/test_logging_setup_location.py's
dependency-injection pattern for logging_setup.open_log_location().
"""

import unittest

from ovb_rc003 import shell_targets


class OpenExternalTargetTests(unittest.TestCase):
    def test_successful_open_reports_opened_and_the_exact_target(self):
        calls = []
        result = shell_targets.open_external_target(
            shell_targets.BLUETOOTH_SETTINGS_URI,
            _opener=lambda target: calls.append(target),
        )
        self.assertEqual(result.outcome, shell_targets.ExternalTargetOutcome.OPENED)
        self.assertEqual(result.target, shell_targets.BLUETOOTH_SETTINGS_URI)
        self.assertEqual(calls, [shell_targets.BLUETOOTH_SETTINGS_URI])

    def test_opener_raising_is_reported_as_open_failed_not_raised(self):
        def raising_opener(target):
            raise OSError("no URI handler registered")

        result = shell_targets.open_external_target(
            shell_targets.MICROPHONE_PRIVACY_SETTINGS_URI, _opener=raising_opener
        )

        self.assertEqual(result.outcome, shell_targets.ExternalTargetOutcome.OPEN_FAILED)
        self.assertIn("no URI handler registered", result.error)
        self.assertEqual(result.target, shell_targets.MICROPHONE_PRIVACY_SETTINGS_URI)

    def test_speech_settings_uri_is_opened_and_reported(self):
        calls = []
        result = shell_targets.open_external_target(
            shell_targets.SPEECH_SETTINGS_URI,
            _opener=lambda target: calls.append(target),
        )
        self.assertEqual(result.outcome, shell_targets.ExternalTargetOutcome.OPENED)
        self.assertEqual(calls, [shell_targets.SPEECH_SETTINGS_URI])

    def test_default_opener_raises_cleanly_when_startfile_is_unavailable(self):
        # Proves the off-Windows fallback path (os.startfile does not exist
        # on macOS/Linux) raises a clear OSError rather than an
        # AttributeError - exercised via the real _default_opener, with
        # os.startfile itself monkeypatched away for this one test (mirrors
        # test_logging_setup_location.py's equivalent check).
        import os

        had_startfile = hasattr(os, "startfile")
        original = getattr(os, "startfile", None)
        if had_startfile:
            del os.startfile
        try:
            with self.assertRaises(OSError):
                shell_targets._default_opener(shell_targets.BLUETOOTH_SETTINGS_URI)
        finally:
            if had_startfile:
                os.startfile = original


    def test_sound_settings_uri_is_opened_and_reported(self):
        calls = []
        result = shell_targets.open_external_target(
            shell_targets.SOUND_SETTINGS_URI,
            _opener=lambda target: calls.append(target),
        )
        self.assertEqual(result.outcome, shell_targets.ExternalTargetOutcome.OPENED)
        self.assertEqual(calls, [shell_targets.SOUND_SETTINGS_URI])

    def test_apps_settings_uri_is_opened_and_reported(self):
        calls = []
        result = shell_targets.open_external_target(
            shell_targets.APPS_SETTINGS_URI,
            _opener=lambda target: calls.append(target),
        )
        self.assertEqual(result.outcome, shell_targets.ExternalTargetOutcome.OPENED)
        self.assertEqual(calls, [shell_targets.APPS_SETTINGS_URI])


class MsSettingsUriConstantsTests(unittest.TestCase):
    """These must stay real, Microsoft-documented ms-settings: deep links -
    never invented placeholders (see module docstring)."""

    def test_all_five_uris_use_the_ms_settings_scheme(self):
        for uri in (
            shell_targets.BLUETOOTH_SETTINGS_URI,
            shell_targets.MICROPHONE_PRIVACY_SETTINGS_URI,
            shell_targets.SPEECH_SETTINGS_URI,
            shell_targets.SOUND_SETTINGS_URI,
            shell_targets.APPS_SETTINGS_URI,
        ):
            self.assertTrue(uri.startswith("ms-settings:"))

    def test_the_five_uris_are_distinct(self):
        uris = {
            shell_targets.BLUETOOTH_SETTINGS_URI,
            shell_targets.MICROPHONE_PRIVACY_SETTINGS_URI,
            shell_targets.SPEECH_SETTINGS_URI,
            shell_targets.SOUND_SETTINGS_URI,
            shell_targets.APPS_SETTINGS_URI,
        }
        self.assertEqual(len(uris), 5)


if __name__ == "__main__":
    unittest.main()
