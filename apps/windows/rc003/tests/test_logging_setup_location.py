"""Tests logging_setup.py's log-location helpers (XRBM-029): the canonical
path functions must never create anything as a side effect of merely being
asked a question, and open_log_location() must give an honest answer for a
directory/file that does not exist yet rather than fabricating one - all
exercised against real tmp directories (no mocking needed for pure
filesystem checks) plus an injected ``_open_directory`` for the one actual
OS-facing call, the same dependency-injection pattern
tests/test_bridge_launcher.py uses for subprocess.Popen.
"""

import tempfile
import unittest
from pathlib import Path

from ovb_rc003 import logging_setup


class LogPathHelpersTests(unittest.TestCase):
    def test_log_dir_is_logs_under_the_given_root(self):
        root = Path("/tmp/example-root")
        self.assertEqual(logging_setup.log_dir(root), root / "logs")

    def test_log_file_path_is_app_log_under_log_dir(self):
        root = Path("/tmp/example-root")
        self.assertEqual(
            logging_setup.log_file_path(root), root / "logs" / "app.log"
        )

    def test_log_dir_does_not_create_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "not-created-yet"
            logging_setup.log_dir(root)
            logging_setup.log_file_path(root)
            self.assertFalse(root.exists())


class DescribeLogLocationTests(unittest.TestCase):
    def test_directory_missing_when_root_never_existed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "never-run"
            location = logging_setup.describe_log_location(root)
            self.assertEqual(
                location.status, logging_setup.LogLocationStatus.DIRECTORY_MISSING
            )
            self.assertEqual(location.directory, root / "logs")

    def test_file_missing_when_directory_exists_but_no_app_log_yet(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "logs").mkdir()
            location = logging_setup.describe_log_location(root)
            self.assertEqual(
                location.status, logging_setup.LogLocationStatus.FILE_MISSING
            )

    def test_ready_when_both_directory_and_file_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_dir = root / "logs"
            log_dir.mkdir()
            (log_dir / "app.log").write_text("hello\n", encoding="utf-8")
            location = logging_setup.describe_log_location(root)
            self.assertEqual(location.status, logging_setup.LogLocationStatus.READY)

    def test_never_creates_the_directory_it_is_only_describing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "still-never-run"
            logging_setup.describe_log_location(root)
            self.assertFalse(root.exists())


class OpenLogLocationTests(unittest.TestCase):
    def test_directory_missing_never_calls_open_and_is_reported_honestly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "never-run"
            open_calls = []

            result = logging_setup.open_log_location(
                root, _open_directory=lambda directory: open_calls.append(directory)
            )

            self.assertEqual(
                result.outcome, logging_setup.LogOpenOutcome.DIRECTORY_MISSING
            )
            self.assertEqual(open_calls, [])
            # No fake log/directory was fabricated to make this "succeed".
            self.assertFalse(root.exists())

    def test_existing_directory_is_opened_and_reports_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_dir = root / "logs"
            log_dir.mkdir()
            (log_dir / "app.log").write_text("hello\n", encoding="utf-8")
            open_calls = []

            result = logging_setup.open_log_location(
                root, _open_directory=lambda directory: open_calls.append(directory)
            )

            self.assertEqual(result.outcome, logging_setup.LogOpenOutcome.OPENED)
            self.assertEqual(open_calls, [log_dir])
            self.assertEqual(
                result.location.status, logging_setup.LogLocationStatus.READY
            )

    def test_directory_exists_without_app_log_still_opens_and_flags_file_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "logs").mkdir()
            open_calls = []

            result = logging_setup.open_log_location(
                root, _open_directory=lambda directory: open_calls.append(directory)
            )

            self.assertEqual(result.outcome, logging_setup.LogOpenOutcome.OPENED)
            self.assertEqual(len(open_calls), 1)
            self.assertEqual(
                result.location.status, logging_setup.LogLocationStatus.FILE_MISSING
            )

    def test_open_call_raising_is_reported_as_open_failed_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "logs").mkdir()

            def raising_open(directory):
                raise OSError("no shell association available")

            result = logging_setup.open_log_location(root, _open_directory=raising_open)

            self.assertEqual(result.outcome, logging_setup.LogOpenOutcome.OPEN_FAILED)
            self.assertIn("no shell association available", result.error)

    def test_default_open_directory_raises_cleanly_when_startfile_is_unavailable(self):
        # Proves the off-Windows fallback path (os.startfile does not exist
        # on macOS/Linux) raises a clear OSError rather than an
        # AttributeError - exercised via the real _default_open_directory,
        # with os.startfile itself monkeypatched away for this one test.
        import os

        from ovb_rc003 import logging_setup as module_under_test

        had_startfile = hasattr(os, "startfile")
        original = getattr(os, "startfile", None)
        if had_startfile:
            del os.startfile
        try:
            with self.assertRaises(OSError):
                module_under_test._default_open_directory(Path("/tmp"))
        finally:
            if had_startfile:
                os.startfile = original


if __name__ == "__main__":
    unittest.main()
