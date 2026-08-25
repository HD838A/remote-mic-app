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
from ovb_rc003 import app, config, device_catalog, single_instance, windows_diagnostics


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
        self._original_settings_guard_cls = single_instance.SettingsInstanceGuard
        self._original_activate_settings = single_instance.activate_existing_settings_window
        self._original_app_main = app.main
        self._original_notice = single_instance.show_bridge_startup_blocked_notice
        self._original_load_config = config.load_config
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
        single_instance.activate_existing_settings_window = lambda: True
        config.load_config = lambda path: {
            "selected_device_profile": device_catalog.RC003_ID
        }

    def tearDown(self):
        sys.argv = self._original_argv
        single_instance.BridgeInstanceGuard = self._original_guard_cls
        single_instance.SettingsInstanceGuard = self._original_settings_guard_cls
        single_instance.activate_existing_settings_window = self._original_activate_settings
        app.main = self._original_app_main
        single_instance.show_bridge_startup_blocked_notice = self._original_notice
        config.load_config = self._original_load_config


class BridgeModeRoutingTests(_ArgvRestoringTestCase):
    def test_dji_profile_never_starts_the_rc003_bridge(self):
        app.main = lambda: self.fail("DJI Mic 2 must not start the RC003 bridge")
        config.load_config = lambda path: {
            "selected_device_profile": device_catalog.DJI_MIC_2_ID
        }
        notice_calls = []
        single_instance.show_bridge_startup_blocked_notice = (
            lambda message, **kwargs: notice_calls.append((message, kwargs))
        )
        sys.argv = ["ovb_rc003", "--bridge"]

        main_module.main()

        self.assertEqual(len(notice_calls), 1)
        self.assertIn("DJI Mic 2", notice_calls[0][0])
        self.assertEqual(notice_calls[0][1]["title"], "Remote Mic")

    def test_bridge_flag_calls_app_main_exactly_once_on_first_owner(self):
        app_main_calls = []
        app.main = lambda stop_signal=None: app_main_calls.append(stop_signal)
        single_instance.BridgeInstanceGuard = _make_guard_class()
        sys.argv = ["ovb_rc003", "--bridge"]

        main_module.main()  # must not raise

        self.assertEqual(len(app_main_calls), 1)
        self.assertIsNotNone(app_main_calls[0])

    def test_duplicate_launch_never_calls_app_main(self):
        app_main_calls = []
        app.main = lambda stop_signal=None: app_main_calls.append(stop_signal)
        single_instance.BridgeInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.DuplicateInstanceError("already running")
        )
        sys.argv = ["ovb_rc003", "--bridge"]

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
        sys.argv = ["ovb_rc003", "--bridge"]

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
        sys.argv = ["ovb_rc003", "--bridge"]

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
        sys.argv = ["ovb_rc003", "--bridge"]

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
        app.main = lambda stop_signal=None: app_main_calls.append(stop_signal)

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
        sys.argv = ["ovb_rc003", "--bridge"]

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(len(app_main_calls), 1)  # app.main() DID run to completion
        self.assertIsNotNone(app_main_calls[0])
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
    """Bridge and settings use independent locks; inspection modes use none."""

    def test_no_arguments_opens_settings_with_only_the_settings_guard(self):
        from ovb_rc003 import settings_ui

        enter_calls = []
        single_instance.BridgeInstanceGuard = _make_guard_class(enter_calls=enter_calls)
        settings_enter_calls = []
        single_instance.SettingsInstanceGuard = _make_guard_class(
            enter_calls=settings_enter_calls
        )
        app.main = lambda: self.fail("no-argument launch must never start the bridge")
        original_settings_main = settings_ui.main
        settings_ui.main = lambda: None
        sys.argv = ["ovb_rc003"]

        try:
            main_module.main()  # returns normally, no SystemExit
        finally:
            settings_ui.main = original_settings_main

        self.assertEqual(enter_calls, [])
        self.assertEqual(settings_enter_calls, [1])

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

    def test_settings_uses_its_own_guard_not_the_bridge_guard(self):
        from ovb_rc003 import settings_ui

        enter_calls = []
        single_instance.BridgeInstanceGuard = _make_guard_class(enter_calls=enter_calls)
        settings_enter_calls = []
        single_instance.SettingsInstanceGuard = _make_guard_class(
            enter_calls=settings_enter_calls
        )
        app.main = lambda: self.fail("--settings must never call app.main()")
        original_settings_main = settings_ui.main
        settings_ui.main = lambda: None
        sys.argv = ["ovb_rc003", "--settings"]

        try:
            main_module.main()  # returns normally, no SystemExit
        finally:
            settings_ui.main = original_settings_main

        self.assertEqual(enter_calls, [])
        self.assertEqual(settings_enter_calls, [1])

    def test_duplicate_settings_activates_existing_window_without_opening_another(self):
        from ovb_rc003 import settings_ui

        original_settings_main = settings_ui.main
        settings_ui.main = lambda: self.fail("duplicate must not create another window")
        single_instance.SettingsInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.DuplicateInstanceError("already open")
        )
        activation_calls = []
        single_instance.activate_existing_settings_window = (
            lambda: activation_calls.append(1) or True
        )
        sys.argv = ["ovb_rc003", "--settings"]

        try:
            main_module.main()
        finally:
            settings_ui.main = original_settings_main

        self.assertEqual(activation_calls, [1])

    def test_duplicate_settings_shows_notice_when_existing_window_cannot_activate(self):
        from ovb_rc003 import settings_ui

        original_settings_main = settings_ui.main
        settings_ui.main = lambda: self.fail("duplicate must not create another window")
        single_instance.SettingsInstanceGuard = _make_guard_class(
            raise_on_enter=single_instance.DuplicateInstanceError("already open")
        )
        single_instance.activate_existing_settings_window = lambda: False
        notice_calls = []
        single_instance.show_bridge_startup_blocked_notice = (
            lambda message, **kwargs: notice_calls.append((message, kwargs))
        )
        sys.argv = ["ovb_rc003", "--settings"]

        try:
            main_module.main()
        finally:
            settings_ui.main = original_settings_main

        self.assertEqual(len(notice_calls), 1)
        self.assertEqual(notice_calls[0][1]["title"], "Remote Mic 设置")

    def test_diagnose_ble_candidates_never_touches_the_guard(self):
        enter_calls = []
        single_instance.BridgeInstanceGuard = _make_guard_class(enter_calls=enter_calls)
        app.main = lambda: self.fail("--diagnose-ble-candidates must never call app.main()")
        sys.argv = ["ovb_rc003", "--diagnose-ble-candidates", "/tmp/result.json"]

        original_entrypoint = windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint
        windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint = lambda result_path: 0
        try:
            with self.assertRaises(SystemExit):
                main_module.main()
        finally:
            windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint = original_entrypoint

        self.assertEqual(enter_calls, [])


class DiagnoseBleCandidatesDispatchTests(_ArgvRestoringTestCase):
    """XRBM-035 RETRY 1 In-scope item 6: the hidden child-process entry
    point dispatch - fail-closed on a missing result path, never falls
    through to _run_bridge(), and stays absent from the public --help
    surface.
    """

    def setUp(self):
        super().setUp()
        self._original_entrypoint = windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint

    def tearDown(self):
        windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint = self._original_entrypoint
        super().tearDown()

    def test_dispatches_with_the_result_path_argument_and_propagates_its_exit_code(self):
        received_paths = []
        windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint = (
            lambda result_path: received_paths.append(result_path) or 7
        )
        app.main = lambda: self.fail("must never call app.main()")
        sys.argv = ["ovb_rc003", "--diagnose-ble-candidates", "/tmp/result-path.json"]

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(received_paths, ["/tmp/result-path.json"])
        self.assertEqual(ctx.exception.code, 7)

    def test_missing_result_path_argument_passes_none_through_fail_closed(self):
        # __main__.py itself never guesses a fallback path or falls through
        # to _run_bridge() - it is run_ble_diagnostics_subprocess_
        # entrypoint()'s own job to fail closed on None (see
        # windows_diagnostics.py's own tests for that contract).
        received_paths = []
        windows_diagnostics.run_ble_diagnostics_subprocess_entrypoint = (
            lambda result_path: received_paths.append(result_path) or 1
        )
        app.main = lambda: self.fail("must never call app.main()")
        sys.argv = ["ovb_rc003", "--diagnose-ble-candidates"]  # no path follows the flag

        with self.assertRaises(SystemExit) as ctx:
            main_module.main()

        self.assertEqual(received_paths, [None])
        self.assertEqual(ctx.exception.code, 1)

    def test_flag_constant_stays_in_sync_with_windows_diagnostics_module(self):
        # __main__.py's own argv dispatch uses a literal string (kept that
        # way deliberately - see __main__.py's own comment - rather than
        # eagerly importing windows_diagnostics at module level just for
        # this one check, which would add sounddevice/numpy/winrt to every
        # --help/bare invocation's import graph). This regression test is
        # what keeps that literal from silently drifting out of sync with
        # the module that actually owns the IPC contract.
        import inspect

        source = inspect.getsource(main_module)
        self.assertIn(
            f'"{windows_diagnostics.BLE_DIAGNOSTICS_SUBPROCESS_FLAG}" in args', source
        )

    def test_help_text_never_mentions_the_hidden_diagnostics_flag(self):
        # XRBM-035 RETRY 1 In-scope item 6: not part of this program's
        # public CLI surface.
        import io
        import contextlib

        sys.argv = ["ovb_rc003", "--help"]
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            main_module.main()  # returns normally, no SystemExit

        self.assertNotIn("--diagnose-ble-candidates", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
