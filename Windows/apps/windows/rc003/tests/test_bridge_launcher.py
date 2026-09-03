"""Tests bridge_launcher.py's command construction and launch-outcome
detection (XRBM-029) purely via dependency injection - no real subprocess is
ever spawned and no real ``time.sleep`` ever runs, matching this package's
established "never touch a real OS resource in a test" convention (see e.g.
tests/test_single_instance.py's injected ``_create_mutex``/etc.).
"""

import unittest
from unittest import mock

from ovb_rc003 import bridge_control_windows, bridge_launcher, single_instance


class BuildLaunchCommandTests(unittest.TestCase):
    def test_frozen_uses_the_current_executable_with_bridge_flag(self):
        command = bridge_launcher.build_launch_command(
            frozen=True, executable=r"C:\Apps\RemoteMicRC003.exe"
        )
        self.assertEqual(command, [r"C:\Apps\RemoteMicRC003.exe", "--bridge"])

    def test_frozen_command_never_recurses_into_settings(self):
        command = bridge_launcher.build_launch_command(
            frozen=True, executable=r"C:\Apps\RemoteMicRC003.exe"
        )
        self.assertNotIn("--settings", command)

    def test_frozen_settings_mode_still_launches_the_same_executable_with_bridge(self):
        # The single packaged exe handles both modes: no arguments / --settings
        # open the settings window, --bridge starts the bridge. There is no
        # separate settings sibling anymore.
        command = bridge_launcher.build_launch_command(
            frozen=True, executable=r"C:\Apps\RemoteMicRC003.exe"
        )
        self.assertEqual(command, [r"C:\Apps\RemoteMicRC003.exe", "--bridge"])

    def test_source_uses_the_current_interpreter_with_module_flag_and_bridge(self):
        command = bridge_launcher.build_launch_command(
            frozen=False, executable=r"C:\Python312\python.exe"
        )
        self.assertEqual(
            command, [r"C:\Python312\python.exe", "-m", "ovb_rc003", "--bridge"]
        )

    def test_source_command_never_recurses_into_settings(self):
        command = bridge_launcher.build_launch_command(
            frozen=False, executable=r"C:\Python312\python.exe"
        )
        self.assertNotIn("--settings", command)

    def test_empty_executable_fails_closed(self):
        with self.assertRaises(bridge_launcher.BridgeLaunchConfigurationError):
            bridge_launcher.build_launch_command(frozen=False, executable="")

    def test_defaults_read_the_real_sys_module_without_raising(self):
        # Exercises the frozen=None/executable=None default-resolution
        # branch directly (whatever this test process' own sys.executable/
        # sys.frozen happen to be) - just proves it never raises and always
        # returns a non-empty list, since the exact values are host-specific.
        command = bridge_launcher.build_launch_command()
        self.assertTrue(command)


class _FakeProcess:
    """Scripted stand-in for subprocess.Popen: ``poll_results`` is consumed
    one value at a time by each ``.poll()`` call, then the last value
    repeats - so a test can express "alive for N checks, then exit code X"
    as a short list.
    """

    def __init__(self, poll_results, *, pid=4242):
        self.pid = pid
        self._poll_results = list(poll_results)
        self._index = 0

    def poll(self):
        if self._index < len(self._poll_results):
            value = self._poll_results[self._index]
            self._index += 1
            return value
        return self._poll_results[-1] if self._poll_results else None


class LaunchBridgeTests(unittest.TestCase):
    def setUp(self):
        self._sleep_calls = []

    def _fake_sleep(self, seconds):
        self._sleep_calls.append(seconds)

    def test_process_still_alive_after_grace_period_is_started(self):
        process = _FakeProcess([None] * 20, pid=111)
        popen_calls = []

        def fake_popen(command):
            popen_calls.append(command)
            return process

        result = bridge_launcher.launch_bridge(
            ["exe"],
            grace_checks=3,
            poll_interval_seconds=0.01,
            _popen=fake_popen,
            _sleep=self._fake_sleep,
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.STARTED)
        self.assertEqual(result.pid, 111)
        self.assertIsNone(result.exit_code)
        self.assertEqual(popen_calls, [["exe"]])
        # Grace period exhausted (3 checks), never a real sleep.
        self.assertEqual(len(self._sleep_calls), 3)

    def test_exact_duplicate_instance_exit_code_is_already_running(self):
        process = _FakeProcess([single_instance.DUPLICATE_INSTANCE_EXIT_CODE])

        result = bridge_launcher.launch_bridge(
            ["exe"],
            _popen=lambda command: process,
            _sleep=self._fake_sleep,
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.ALREADY_RUNNING)
        self.assertEqual(result.exit_code, single_instance.DUPLICATE_INSTANCE_EXIT_CODE)
        # Detected on the very first poll - no grace-period sleeping needed.
        self.assertEqual(self._sleep_calls, [])

    def test_other_nonzero_exit_code_is_a_quick_exit_with_the_real_code_preserved(self):
        process = _FakeProcess([7])

        result = bridge_launcher.launch_bridge(
            ["exe"], _popen=lambda command: process, _sleep=self._fake_sleep
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.QUICK_EXIT)
        self.assertEqual(result.exit_code, 7)

    def test_clean_zero_exit_within_grace_period_is_still_a_quick_exit(self):
        # A bridge that exits 0 almost immediately did not stay up to run
        # the bridge - "0" must not be silently treated as "started" just
        # because it isn't an error code.
        process = _FakeProcess([0])

        result = bridge_launcher.launch_bridge(
            ["exe"], _popen=lambda command: process, _sleep=self._fake_sleep
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.QUICK_EXIT)
        self.assertEqual(result.exit_code, 0)

    def test_guard_unavailable_exit_code_is_a_distinct_quick_exit_not_already_running(self):
        process = _FakeProcess([single_instance.GUARD_UNAVAILABLE_EXIT_CODE])

        result = bridge_launcher.launch_bridge(
            ["exe"], _popen=lambda command: process, _sleep=self._fake_sleep
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.QUICK_EXIT)
        self.assertEqual(result.exit_code, single_instance.GUARD_UNAVAILABLE_EXIT_CODE)

    def test_popen_oserror_is_reported_as_launch_failed_not_raised(self):
        def raising_popen(command):
            raise OSError("[WinError 2] The system cannot find the file specified")

        result = bridge_launcher.launch_bridge(
            ["missing.exe"], _popen=raising_popen, _sleep=self._fake_sleep
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.LAUNCH_FAILED)
        self.assertIsNone(result.exit_code)
        self.assertIn("WinError 2", result.error)
        self.assertEqual(self._sleep_calls, [])

    def test_process_exits_partway_through_the_grace_period(self):
        # Alive for the first two checks, then exits - proves the polling
        # loop keeps checking rather than only ever looking once. Uses code
        # 9, deliberately distinct from single_instance.
        # DUPLICATE_INSTANCE_EXIT_CODE (3), to stay in the QUICK_EXIT branch.
        process = _FakeProcess([None, None, 9])

        result = bridge_launcher.launch_bridge(
            ["exe"],
            grace_checks=5,
            _popen=lambda command: process,
            _sleep=self._fake_sleep,
        )

        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.QUICK_EXIT)
        self.assertEqual(result.exit_code, 9)
        self.assertEqual(len(self._sleep_calls), 2)

    def test_no_command_argument_falls_back_to_build_launch_command(self):
        popen_calls = []

        def fake_popen(command):
            popen_calls.append(command)
            return _FakeProcess([None] * 5)

        bridge_launcher.launch_bridge(
            grace_checks=1,
            _popen=fake_popen,
            _sleep=self._fake_sleep,
        )

        self.assertEqual(len(popen_calls), 1)
        self.assertTrue(popen_calls[0])  # non-empty, host-dependent contents


class RestartBridgeTests(unittest.TestCase):
    def test_no_running_bridge_launches_immediately(self):
        expected = bridge_launcher.LaunchResult(
            bridge_launcher.LaunchOutcome.STARTED, ("exe",), pid=7
        )
        launch = mock.Mock(return_value=expected)
        result = bridge_launcher.restart_bridge(
            _request_stop=lambda: bridge_control_windows.StopRequestResult(
                bridge_control_windows.StopRequestOutcome.NOT_RUNNING
            ),
            _is_running=lambda: False,
            _launch=launch,
            _sleep=lambda _seconds: None,
        )
        self.assertEqual(result, expected)
        launch.assert_called_once_with()

    def test_running_bridge_is_waited_out_before_relaunch(self):
        states = iter((True, True, False))
        expected = bridge_launcher.LaunchResult(
            bridge_launcher.LaunchOutcome.STARTED, ("exe",), pid=8
        )
        launch = mock.Mock(return_value=expected)
        result = bridge_launcher.restart_bridge(
            stop_timeout_seconds=10.0,
            _request_stop=lambda: bridge_control_windows.StopRequestResult(
                bridge_control_windows.StopRequestOutcome.REQUESTED
            ),
            _is_running=lambda: next(states),
            _launch=launch,
            _sleep=lambda _seconds: None,
        )
        self.assertEqual(result, expected)
        launch.assert_called_once_with()

    def test_stop_failure_never_launches_a_second_bridge(self):
        launch = mock.Mock()
        result = bridge_launcher.restart_bridge(
            _request_stop=lambda: bridge_control_windows.StopRequestResult(
                bridge_control_windows.StopRequestOutcome.FAILED, "denied"
            ),
            _is_running=lambda: True,
            _launch=launch,
            _sleep=lambda _seconds: None,
        )
        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.STOP_FAILED)
        launch.assert_not_called()

    def test_stop_timeout_never_launches_a_second_bridge(self):
        launch = mock.Mock()
        result = bridge_launcher.restart_bridge(
            stop_timeout_seconds=0.0,
            _request_stop=lambda: bridge_control_windows.StopRequestResult(
                bridge_control_windows.StopRequestOutcome.REQUESTED
            ),
            _is_running=lambda: True,
            _launch=launch,
            _sleep=lambda _seconds: None,
        )
        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.STOP_TIMEOUT)
        launch.assert_not_called()

    def test_running_probe_failure_never_launches_a_second_bridge(self):
        launch = mock.Mock()

        def probe_failure():
            raise bridge_control_windows.BridgeControlUnavailableError("access denied")

        result = bridge_launcher.restart_bridge(
            _request_stop=lambda: bridge_control_windows.StopRequestResult(
                bridge_control_windows.StopRequestOutcome.REQUESTED
            ),
            _is_running=probe_failure,
            _launch=launch,
            _sleep=lambda _seconds: None,
        )
        self.assertEqual(result.outcome, bridge_launcher.LaunchOutcome.STOP_FAILED)
        self.assertIn("access denied", result.error)
        launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
