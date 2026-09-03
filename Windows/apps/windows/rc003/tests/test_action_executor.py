import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ovb_rc003 import action_executor, key_mapping


class SemanticApplicationActionTests(unittest.TestCase):
    def test_wechat_shortcut_lookup_does_not_select_enterprise_wechat(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as tmp2:
            start_menu = (
                Path(tmp)
                / "Microsoft"
                / "Windows"
                / "Start Menu"
                / "Programs"
            )
            start_menu.mkdir(parents=True)
            (start_menu / "企业微信.lnk").write_bytes(b"shortcut")
            with mock.patch.dict(
                os.environ,
                {"APPDATA": tmp, "PROGRAMDATA": tmp2},
                clear=False,
            ):
                shortcuts = list(
                    action_executor._start_menu_shortcuts(
                        ("微信", "WeChat"), exact_only=True
                    )
                )

        self.assertEqual(shortcuts, [])

    def test_resolves_a_reference_application_action_to_a_real_executable(self):
        with tempfile.TemporaryDirectory() as tmp:
            executable = Path(tmp) / "Codex.exe"
            executable.write_bytes(b"not executed by this test")
            action = key_mapping.ButtonAction(key_mapping.ActionKind.OPEN_CODEX)

            with mock.patch.object(
                action_executor, "_candidate_paths", return_value=[executable]
            ):
                command = action_executor.resolve_application_command(action)

        self.assertEqual(command, (str(executable),))

    def test_open_uses_the_resolved_command_and_does_not_start_a_real_process(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.OPEN_CHROME)
        calls = []
        with mock.patch.object(
            action_executor,
            "resolve_application_command",
            return_value=("C:/Apps/Chrome.exe",),
        ):
            started = action_executor.open_configured_application(
                action,
                launcher=lambda command: calls.append(tuple(command)),
            )

        self.assertTrue(started)
        self.assertEqual(calls, [("C:/Apps/Chrome.exe",)])

    def test_missing_application_is_reported_without_launching_anything(self):
        action = key_mapping.ButtonAction(key_mapping.ActionKind.OPEN_CMUX)
        with mock.patch.object(
            action_executor, "resolve_application_command", return_value=None
        ):
            self.assertFalse(action_executor.open_configured_application(action))


if __name__ == "__main__":
    unittest.main()
