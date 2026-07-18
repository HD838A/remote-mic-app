"""Argument-mode routing tests for ``ovb_rc003.__main__.main()`` (XRBM-021
In-scope items 3-4). Monkeypatches module-level attributes on the real
``ovb_rc003.app``/``ovb_rc003.single_instance`` modules - the same pattern
test_app_wiring.py already uses for win32_input.py - rather than
constructing a real ``BridgeInstanceGuard``/calling the real
``app.main()``, matching this project's established "never touch real
BLE/HID/audio/Tk in a test" convention. ``main()`` reads ``sys.argv``
internally rather than taking a parameter, so each test temporarily
replaces ``sys.argv`` and restores it in ``finally``.
"""

import sys
import unittest

from ovb_rc003 import __main__ as main_module
from ovb_rc003 import app, single_instance


def _make_guard_class(*, raise_on_enter=None, enter_calls=None):
    """Builds a fake BridgeInstanceGuard CLASS (not instance) - _run_bridge()
    constructs it with no arguments (``single_instance.BridgeInstanceGuard()``),
    matching real usage exactly.
    """

    class _ScriptedGuard:
        def __enter__(self):
            if enter_calls is not None:
                enter_calls.append(1)
            if raise_on_enter is not None:
                raise raise_on_enter
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    return _ScriptedGuard


class _ArgvRestoringTestCase(unittest.TestCase):
    def setUp(self):
        self._original_argv = sys.argv
        self._original_guard_cls = single_instance.BridgeInstanceGuard
        self._original_app_main = app.main
        self._original_notice = single_instance.show_bridge_startup_blocked_notice
        # XRBM-023: default every test in this suite to a safe no-op stub for
        # the visible-notice callable. show_bridge_startup_blocked_notice's
        # real implementation opens a real, SYSTEMMODAL Win32 MessageBoxW -
        # a test that deliberately triggers a blocked startup but forgets to
        # override this explicitly would otherwise open that real dialog and
        # hang the whole headless CI runner waiting for user input (the
        # test_duplicate_launch_never_calls_app_main defect this task fixes).
        # Tests that need to assert on the exact notice text/call count still
        # override this in their own body, same as before.
        single_instance.show_bridge_startup_blocked_notice = lambda message: None

    def tearDown(self):
        sys.argv = self._original_argv
        single_instance.BridgeInstanceGuard = self._original_guard_cls
        app.main = self._original_app_main
        single_instance.show_bridge_startup_blocked_notice = self._original_notice


class BridgeModeRoutingTests(_ArgvRestoringTestCase):
    def test_no_args_calls_app_main_exactly_once_on_first_owner(self):
        app_main_calls = []
        app.main = lambda: app_main_calls.append(1)
        single_instance.BridgeInstanceGuard = _make_guard_class()
        sys.argv = ["ovb_rc003"]

        main_module.main()  # must not raise

        self.assertEqual(app_main_calls, [1])

    def test_duplicate_launch_never_calls_app_main(self):
        app_main_calls = []
        app.main = lambda: app_main_calls.append(1)
        single_instance.BridgeInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.DuplicateInstanceError("already running")
        )
        sys.argv = ["ovb_rc003"]

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(app_main_calls, [])
        self.assertEqual(ctx.exception.code, single_instance.DUPLICATE_INSTANCE_EXIT_CODE)
        self.assertNotEqual(single_instance.DUPLICATE_INSTANCE_EXIT_CODE, 0)

    def test_duplicate_launch_without_an_explicit_notice_override_reaches_the_real_notice_function(self):
        """Regression for XRBM-023 test 245: reproduces exactly why the
        original test_duplicate_launch_never_calls_app_main hung the real
        Windows CI runner - it left the REAL show_bridge_startup_blocked_
        notice wired up, which by default calls single_instance's real
        SYSTEMMODAL Win32 MessageBoxW, and a headless runner then blocks
        waiting for user input on that dialog forever.

        This drives that same REAL notice function (self._original_notice,
        undoing setUp's safety-net no-op stub) through main()'s exact
        duplicate-launch path, proving it does get called - but with its
        own ``_message_box`` collaborator swapped for a safe recorder, so
        this regression test itself never risks opening a real dialog on
        any OS/CI runner, including a real Windows one.
        """
        message_box_calls = []

        def _spy_notice(message):
            self._original_notice(
                message,
                _message_box=lambda title, msg: message_box_calls.append((title, msg)) or 1,
            )

        single_instance.show_bridge_startup_blocked_notice = _spy_notice
        app.main = lambda: self.fail("app.main() must never run on a duplicate launch")
        single_instance.BridgeInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.DuplicateInstanceError("already running")
        )
        sys.argv = ["ovb_rc003"]

        with self.assertRaises(SystemExit):
            main_module.main()

        self.assertEqual(len(message_box_calls), 1)

    def test_duplicate_launch_shows_the_visible_notice_exactly_once(self):
        app.main = lambda: self.fail("app.main() must never run on a duplicate launch")
        single_instance.BridgeInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.DuplicateInstanceError("already running")
        )
        notice_calls = []
        single_instance.show_bridge_startup_blocked_notice = lambda msg: notice_calls.append(msg)
        sys.argv = ["ovb_rc003"]

        with self.assertRaises(SystemExit):
            main_module.main()

        self.assertEqual(len(notice_calls), 1)
        self.assertIn("already running", notice_calls[0])

    def test_guard_unavailable_fails_closed_and_never_calls_app_main(self):
        # XRBM-021 review round 1 P1 #1: the guard FAILS CLOSED - an
        # acquisition failure it cannot resolve is treated the same as a
        # proven duplicate, not as license to start anyway.
        app.main = lambda: self.fail(
            "app.main() must never run when the guard is unavailable"
        )
        single_instance.BridgeInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.SingleInstanceUnavailableError("not on windows")
        )
        notice_calls = []
        single_instance.show_bridge_startup_blocked_notice = lambda msg: notice_calls.append(msg)
        sys.argv = ["ovb_rc003"]

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(ctx.exception.code, single_instance.GUARD_UNAVAILABLE_EXIT_CODE)
        self.assertNotEqual(single_instance.GUARD_UNAVAILABLE_EXIT_CODE, 0)
        self.assertNotEqual(
            single_instance.GUARD_UNAVAILABLE_EXIT_CODE,
            single_instance.DUPLICATE_INSTANCE_EXIT_CODE,
        )
        self.assertEqual(len(notice_calls), 1)

    def test_mutex_cleanup_failure_after_a_clean_run_shows_a_sanitized_notice(self):
        # MutexCleanupError surfaces from the guard's __exit__, i.e. AFTER
        # app.main() already ran (here: to a clean, immediate return) - it
        # must still produce a visible notice and a deterministic nonzero
        # exit, since the packaged executable is windowed (console=False)
        # and an unhandled exception's traceback is otherwise never seen.
        app_main_calls = []
        app.main = lambda: app_main_calls.append(1)

        class _CleanupFailingGuard:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                raise single_instance.MutexCleanupError(
                    "mutex cleanup did not fully succeed: "
                    "ReleaseMutex returned FALSE; CloseHandle returned FALSE"
                )

        single_instance.BridgeInstanceGuard = lambda: _CleanupFailingGuard()
        notice_calls = []
        single_instance.show_bridge_startup_blocked_notice = lambda msg: notice_calls.append(msg)
        sys.argv = ["ovb_rc003"]

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(app_main_calls, [1])  # app.main() DID run to completion
        self.assertEqual(ctx.exception.code, single_instance.CLEANUP_FAILED_EXIT_CODE)
        self.assertNotEqual(single_instance.CLEANUP_FAILED_EXIT_CODE, 0)
        self.assertEqual(len(notice_calls), 1)
        # The user-visible notice must be sanitized - never the raw
        # MutexCleanupError text (which itself is already sanitized, but
        # the notice text is deliberately a separate, fixed sentence, not
        # str(exc), so it can never regress even if the exception message
        # shape changes).
        self.assertNotIn("ReleaseMutex", notice_calls[0])
        self.assertNotIn("CloseHandle", notice_calls[0])


class ArgumentModeBypassTests(_ArgvRestoringTestCase):
    """XRBM-021 In-scope item 3: --settings/--dry-run/--help must bypass
    the single-instance guard entirely - none of them may even construct
    it, let alone touch the mutex.
    """

    def test_dry_run_never_touches_the_guard(self):
        enter_calls = []
        single_instance.BridgeInstanceGuard = _make_guard_class(enter_calls=enter_calls)
        app.main = lambda: self.fail("--dry-run must never call app.main()")
        sys.argv = ["ovb_rc003", "--dry-run"]

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(ctx.exception.code, 0)
        self.assertEqual(enter_calls, [])

    def test_help_never_touches_the_guard(self):
        enter_calls = []
        single_instance.BridgeInstanceGuard = _make_guard_class(enter_calls=enter_calls)
        app.main = lambda: self.fail("--help must never call app.main()")
        sys.argv = ["ovb_rc003", "--help"]

        main_module.main()  # returns normally, no SystemExit

        self.assertEqual(enter_calls, [])

    def test_settings_never_touches_the_guard(self):
        from ovb_rc003 import settings_ui

        enter_calls = []
        single_instance.BridgeInstanceGuard = _make_guard_class(enter_calls=enter_calls)
        app.main = lambda: self.fail("--settings must never call app.main()")
        original_settings_main = settings_ui.main
        settings_ui.main = lambda: None
        sys.argv = ["ovb_rc003", "--settings"]

        try:
            main_module.main()  # returns normally, no SystemExit
        finally:
            settings_ui.main = original_settings_main

        self.assertEqual(enter_calls, [])


if __name__ == "__main__":
    unittest.main()
