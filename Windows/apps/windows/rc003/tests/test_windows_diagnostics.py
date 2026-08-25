import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from collections.abc import Sequence
from unittest import mock

from ovb_rc003 import (
    audio_output,
    ble_transport_winrt,
    identity,
    raw_input_windows,
    windows_diagnostics as diag,
)


class OsVersionCheckTests(unittest.TestCase):
    def test_non_windows_probe_reports_unsupported(self):
        result = diag.check_os_version(probe=lambda: None)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)
        self.assertEqual(result.group, diag.CheckGroup.ORDINARY_BUTTONS)

    def test_32bit_fails(self):
        info = diag.WindowsVersionInfo(major=10, minor=0, build=19045, is_64bit=False)
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_build_below_1809_fails(self):
        info = diag.WindowsVersionInfo(major=10, minor=0, build=17134, is_64bit=True)
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_build_at_or_above_1809_64bit_passes(self):
        info = diag.WindowsVersionInfo(major=10, minor=0, build=19045, is_64bit=True)
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.PASS)

    def test_exact_minimum_build_passes(self):
        info = diag.WindowsVersionInfo(
            major=10, minor=0, build=diag.MIN_SUPPORTED_BUILD, is_64bit=True
        )
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.PASS)


class RawInputCheckTests(unittest.TestCase):
    def test_zero_matches_fails(self):
        result = diag.check_raw_input(enumerate_paths=lambda: [])
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_exactly_one_match_passes(self):
        result = diag.check_raw_input(enumerate_paths=lambda: ["\\\\?\\HID#VID_2717&PID_32B8#..."])
        self.assertEqual(result.status, diag.CheckStatus.PASS)

    def test_ambiguous_matches_fails(self):
        result = diag.check_raw_input(enumerate_paths=lambda: ["path1", "path2"])
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_never_reports_the_device_path_itself(self):
        secret_path = "\\\\?\\HID#VID_2717&PID_32B8#SUPERSECRETSERIAL"
        for paths in ([secret_path], [secret_path, secret_path + "x"]):
            result = diag.check_raw_input(enumerate_paths=lambda p=paths: p)
            self.assertNotIn(secret_path, result.detail)

    def test_unavailable_off_windows_is_unsupported(self):
        def _raise():
            raise raw_input_windows.RawInputUnavailableError("Raw Input is only available on Windows")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "darwin"):
            result = diag.check_raw_input(enumerate_paths=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)

    def test_real_failure_on_windows_is_a_fail_not_unsupported(self):
        def _raise():
            raise raw_input_windows.RawInputUnavailableError("GetRawInputDeviceList failed: 1")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_raw_input(enumerate_paths=_raise)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_real_failure_message_never_echoes_the_raw_exception_text(self):
        # RETRY 3 (independent review): a RawInputUnavailableError raised on
        # a real Windows failure path used to have its str(exc) interpolated
        # directly into the CheckResult detail - a backend/injected
        # exception is capable of carrying a real Raw Input device path.
        # Inject sentinels standing in for exactly that and prove neither
        # ever reaches the user-facing detail text, while the result stays
        # a real, actionable FAIL.
        secret_hid_path = "\\\\?\\HID#VID_2717&PID_32B8#SUPERSECRETSERIAL#{deadbeef-0000}"
        # Deliberately avoids "\Users\" (this project's own boundary-scan
        # personal-path regex, tests/test_boundary_scan_replay.py/
        # build/check-public-boundary.ps1, flags any `<drive>:\Users\...`
        # literal in source, including test fixtures) - a ProgramData-style
        # path still stands in for "a local filesystem path" just as well.
        secret_local_path = r"C:\ProgramData\RemoteMic\RC003\SecretDeviceCache.db"

        def _raise():
            raise raw_input_windows.RawInputUnavailableError(
                f"GetRawInputDeviceList failed for {secret_hid_path} "
                f"(config at {secret_local_path})"
            )

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_raw_input(enumerate_paths=_raise)

        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertNotIn(secret_hid_path, result.detail)
        self.assertNotIn(secret_local_path, result.detail)
        self.assertNotIn("SecretDeviceCache", result.detail)
        self.assertNotIn("SUPERSECRETSERIAL", result.detail)
        self.assertTrue(result.detail.strip())
        self.assertIn("Raw Input", result.detail)


class BleCandidateCheckTests(unittest.TestCase):
    def test_no_candidates_fails(self):
        result = diag.check_ble_candidate(discover=lambda: [])
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertEqual(result.group, diag.CheckGroup.VOICE_BRIDGE)

    def test_exactly_one_matching_candidate_passes(self):
        candidates = [identity.RC003Candidate(name="Mi RC", hardware_match=False)]
        result = diag.check_ble_candidate(discover=lambda: candidates)
        self.assertEqual(result.status, diag.CheckStatus.PASS)

    def test_ambiguous_candidates_fails(self):
        candidates = [
            identity.RC003Candidate(name="Mi RC", hardware_match=False),
            identity.RC003Candidate(name="MI RC", hardware_match=False),
        ]
        result = diag.check_ble_candidate(discover=lambda: candidates)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_non_matching_candidate_is_treated_as_no_candidate(self):
        candidates = [identity.RC003Candidate(name="Some Other Device", hardware_match=False)]
        result = diag.check_ble_candidate(discover=lambda: candidates)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_winrt_unavailable_off_windows_is_unsupported(self):
        def _raise():
            raise ble_transport_winrt.WinRTUnavailableError("winrt not installed")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "darwin"):
            result = diag.check_ble_candidate(discover=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)

    def test_winrt_unavailable_on_windows_is_still_unsupported_not_fail(self):
        # A missing optional dependency is not a real hardware/config
        # failure - it means this Windows machine never installed the
        # winrt packages at all, which the diagnostics page cannot fix.
        def _raise():
            raise ble_transport_winrt.WinRTUnavailableError("winrt not installed")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_ble_candidate(discover=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)

    def test_unexpected_exception_is_a_fail_not_a_crash(self):
        def _raise():
            raise RuntimeError("boom")

        result = diag.check_ble_candidate(discover=_raise)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_winrt_unavailable_message_never_echoes_the_raw_exception_text(self):
        # RETRY 3 (independent review): WinRTUnavailableError's real
        # production message is API-only today, but a dependency-
        # unavailable exception must not be trusted to stay that way
        # forever - inject a sentinel standing in for a leaked identifier
        # and prove it never reaches the detail text, status unchanged.
        #
        # Uses this project's own established MAC-address placeholder
        # ("AA:BB:CC:DD:EE:FF" - see tests/test_config.py and
        # tests/test_boundary_scan_replay.py's _MAC_ADDRESS_PLACEHOLDER)
        # rather than an arbitrary MAC-shaped literal: any OTHER
        # MAC-address-shaped string here would itself trip this project's
        # own public-boundary privacy scan on this test file - the exact
        # kind of accidental-identifier-in-source mistake that scan exists
        # to catch, which a test about NOT leaking identifiers should
        # obviously not commit either.
        secret_ble_address = "AA:BB:CC:DD:EE:FF (小米蓝牙遥控器 2 Pro)"

        def _raise():
            raise ble_transport_winrt.WinRTUnavailableError(
                f"winrt lookup failed for paired device {secret_ble_address}"
            )

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_ble_candidate(discover=_raise)

        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)
        self.assertNotIn(secret_ble_address, result.detail)
        self.assertNotIn("AA:BB:CC:DD:EE:FF", result.detail)
        self.assertTrue(result.detail.strip())
        self.assertIn("WinRT", result.detail)

    def test_cancellation_is_reported_honestly_without_leaking_an_identifier(self):
        # XRBM-035: cancellation (settings window closing) or a timeout is
        # neither a real hardware/config problem NOR an "unexpected error" -
        # it is an honest "did not complete", and (like every other branch
        # in this method) must never leak a device identifier.
        def _raise():
            raise diag.BleDiscoveryCancelledError("BLE discovery cancelled")

        result = diag.check_ble_candidate(discover=_raise)

        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertEqual(result.group, diag.CheckGroup.VOICE_BRIDGE)
        self.assertIn("取消", result.detail)
        self.assertIn("重新检测", result.detail)

    def test_subprocess_shutdown_unconfirmed_is_a_distinct_honest_failure(self):
        # XRBM-035 RETRY 1 P1: distinct from a normal cancellation - this
        # means even a forceful kill could not be confirmed, so this must
        # never be worded the same as a routine "please retry" cancel/
        # timeout, and must never leak an identifier either.
        def _raise_unconfirmed():
            raise diag.BleDiscoverySubprocessShutdownUnconfirmedError("could not confirm exit")

        def _raise_cancelled():
            raise diag.BleDiscoveryCancelledError("cancelled")

        unconfirmed_result = diag.check_ble_candidate(discover=_raise_unconfirmed)
        cancelled_result = diag.check_ble_candidate(discover=_raise_cancelled)

        self.assertEqual(unconfirmed_result.status, diag.CheckStatus.FAIL)
        self.assertEqual(unconfirmed_result.group, diag.CheckGroup.VOICE_BRIDGE)
        self.assertIn("未能确认", unconfirmed_result.detail)
        self.assertNotEqual(unconfirmed_result.detail, cancelled_result.detail)

    def test_unexpected_exception_message_never_echoes_the_raw_exception_text(self):
        # RETRY 3 (independent review): an unexpected exception surfacing
        # from WinRT/BLE plumbing could carry a real Bluetooth address,
        # device name, or local path in its own message - inject sentinels
        # for all three and prove none of them reach the detail text. See
        # the sibling WinRT test above for why the MAC-shaped sentinel is
        # this project's own established placeholder value, and why the
        # local-path sentinel avoids "\Users\" (this project's own
        # boundary-scan personal-path regex).
        secret_ble_address = "AA:BB:CC:DD:EE:FF"
        secret_device_name = "小米蓝牙遥控器 2 Pro"
        secret_local_path = r"C:\ProgramData\RemoteMic\RC003\SecretDeviceCache.db"

        def _raise():
            raise RuntimeError(
                f"failed to open device {secret_ble_address} "
                f"({secret_device_name}) using config at {secret_local_path}"
            )

        result = diag.check_ble_candidate(discover=_raise)

        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertNotIn(secret_ble_address, result.detail)
        self.assertNotIn(secret_device_name, result.detail)
        self.assertNotIn(secret_local_path, result.detail)
        self.assertNotIn("SecretDeviceCache", result.detail)
        self.assertTrue(result.detail.strip())
        self.assertIn("BLE", result.detail)


class VbCableEndpointsCheckTests(unittest.TestCase):
    def test_both_present_passes(self):
        result = diag.check_vb_cable_endpoints(
            list_playback=lambda: [audio_output.AudioEndpoint(name="CABLE Input")],
            list_recording=lambda: [audio_output.AudioEndpoint(name="CABLE Output")],
        )
        self.assertEqual(result.status, diag.CheckStatus.PASS)
        self.assertEqual(result.group, diag.CheckGroup.OPTIONAL_DRIVER)

    def test_neither_present_fails_but_is_optional(self):
        result = diag.check_vb_cable_endpoints(
            list_playback=lambda: [audio_output.AudioEndpoint(name="Speakers")],
            list_recording=lambda: [audio_output.AudioEndpoint(name="Microphone")],
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("可选", result.detail)

    def test_only_playback_present_fails_with_specific_missing_note(self):
        result = diag.check_vb_cable_endpoints(
            list_playback=lambda: [audio_output.AudioEndpoint(name="CABLE Input")],
            list_recording=lambda: [],
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("CABLE Output", result.detail)

    def test_enumeration_failure_is_unsupported(self):
        def _raise():
            raise audio_output.AudioOutputUnavailableError("no sounddevice")

        result = diag.check_vb_cable_endpoints(list_playback=_raise, list_recording=lambda: [])
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)


class OutputEndpointResolutionCheckTests(unittest.TestCase):
    def test_resolves_to_cable_input_passes_with_positive_note(self):
        result = diag.check_output_endpoint_resolution(
            "CABLE Input", "",
            list_playback=lambda: [audio_output.AudioEndpoint(name="CABLE Input")],
        )
        self.assertEqual(result.status, diag.CheckStatus.PASS)
        self.assertIn("CABLE Input", result.detail)

    def test_resolves_to_non_cable_endpoint_fails_with_actionable_text(self):
        # RETRY 1 (independent review): this used to assert PASS here - a
        # false green readiness signal for the bundled VB-CABLE workflow
        # (taskbook line 77 requires the saved endpoint to point to CABLE
        # Input for that workflow). A real, present, non-CABLE endpoint is
        # a legitimate FAIL for this check, not a quieter kind of success.
        result = diag.check_output_endpoint_resolution(
            "Speakers", "",
            list_playback=lambda: [audio_output.AudioEndpoint(name="Speakers")],
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("不是 CABLE Input", result.detail)
        self.assertIn("选择检测到的", result.detail)

    def test_empty_selection_fails(self):
        result = diag.check_output_endpoint_resolution(
            "", "", list_playback=lambda: [audio_output.AudioEndpoint(name="Speakers")]
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_missing_endpoint_fails_closed(self):
        result = diag.check_output_endpoint_resolution(
            "Gone Device", "", list_playback=lambda: []
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_enumeration_failure_is_unsupported(self):
        def _raise():
            raise audio_output.AudioOutputUnavailableError("no sounddevice")

        result = diag.check_output_endpoint_resolution("x", "", list_playback=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)


class DjiMic2InputCheckTests(unittest.TestCase):
    def test_present_recording_endpoint_passes(self):
        result = diag.check_dji_mic_2_input(
            list_recording=lambda: [
                audio_output.AudioEndpoint(
                    name="DJI-MIC2-ABCDEF Hands-Free", host_api="Windows WASAPI"
                )
            ]
        )
        self.assertEqual(result.status, diag.CheckStatus.PASS)
        self.assertEqual(result.group, diag.CheckGroup.EXTERNAL_MICROPHONE)
        self.assertNotIn("ABCDEF", result.detail)

    def test_pairing_without_recording_endpoint_fails(self):
        result = diag.check_dji_mic_2_input(
            list_recording=lambda: [audio_output.AudioEndpoint(name="Microphone Array")]
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("已连接", result.detail)

    def test_enumeration_failure_is_unsupported_without_exception_detail(self):
        def _raise():
            raise audio_output.AudioOutputUnavailableError("secret endpoint")

        result = diag.check_dji_mic_2_input(list_recording=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)
        self.assertNotIn("secret endpoint", result.detail)


class DictationCheckTests(unittest.TestCase):
    def test_always_manual_never_fabricates_a_verdict(self):
        result = diag.check_dictation_manual()
        self.assertEqual(result.status, diag.CheckStatus.MANUAL)
        self.assertEqual(result.group, diag.CheckGroup.DICTATION)
        self.assertIn("Win+H", result.detail)


class Rc003BatteryCheckTests(unittest.TestCase):
    def test_valid_percentage_passes(self):
        result = diag.check_rc003_battery(probe=lambda: 73)
        self.assertEqual(result.status, diag.CheckStatus.PASS)
        self.assertEqual(result.detail, "73%")

    def test_temporarily_missing_value_is_manual_not_failure(self):
        result = diag.check_rc003_battery(probe=lambda: None)
        self.assertEqual(result.status, diag.CheckStatus.MANUAL)
        self.assertIn("唤醒", result.detail)

    def test_invalid_percentage_fails(self):
        result = diag.check_rc003_battery(probe=lambda: 101)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)


class RunDiagnosticsOrchestrationTests(unittest.TestCase):
    def test_returns_all_eight_checks_with_stable_ids(self):
        report = diag.run_diagnostics()
        ids = {check.check_id for check in report.checks}
        self.assertEqual(
            ids,
            {
                "os_version",
                "raw_input",
                "ble_candidate",
                "rc003_battery",
                "vb_cable_endpoints",
                "output_endpoint",
                "dji_mic_2_input",
                "dictation",
            },
        )

    def test_get_looks_up_by_id(self):
        report = diag.run_diagnostics()
        self.assertIsNotNone(report.get("dictation"))
        self.assertIsNone(report.get("nonexistent"))

    def test_source_environment_checks_degrade_to_unsupported_not_pass(self):
        # This test suite's own host is not Windows (or, even if it somehow
        # were, has no RC003/VB-CABLE attached) - the real, uninjected
        # checks must never claim PASS for something they cannot observe.
        report = diag.run_diagnostics()
        allowed_statuses = (diag.CheckStatus.UNSUPPORTED, diag.CheckStatus.FAIL)
        # This test runs on the developer's machine. On Windows a real RC003
        # may be connected, in which case PASS is the correct result rather
        # than evidence of a false positive.
        if sys.platform == "win32":
            allowed_statuses += (diag.CheckStatus.PASS,)
        for check_id in ("ble_candidate", "raw_input"):
            result = report.get(check_id)
            self.assertIn(
                result.status,
                allowed_statuses,
                f"{check_id} unexpectedly reported {result.status} on a non-real-hardware host",
            )


class RunDiagnosticsIsolationTests(unittest.TestCase):
    """XRBM-031 RETRY 1 item 2: an unexpected exception from any ONE check
    function must never abort run_diagnostics() or leave the other seven
    checks missing - it becomes only that check's own honest FAIL result.
    """

    def test_unexpected_exception_in_one_check_isolates_to_that_check_only(self):
        import unittest.mock as mock

        from ovb_rc003 import windows_diagnostics as module

        with mock.patch.object(
            module, "check_ble_candidate", side_effect=RuntimeError("boom")
        ):
            report = module.run_diagnostics()

        self.assertEqual(len(report.checks), 8)
        failed = report.get("ble_candidate")
        self.assertEqual(failed.status, diag.CheckStatus.FAIL)
        self.assertEqual(failed.group, diag.CheckGroup.VOICE_BRIDGE)
        self.assertNotIn("boom", failed.detail)
        # The other seven checks still render their own real result -
        # nothing else was aborted or left missing.
        other_ids = {
            "os_version", "raw_input", "rc003_battery", "vb_cable_endpoints", "output_endpoint",
            "dji_mic_2_input", "dictation"
        }
        self.assertEqual({c.check_id for c in report.checks} - {"ble_candidate"}, other_ids)
        for check_id in other_ids:
            result = report.get(check_id)
            self.assertIsNotNone(result)
            self.assertIsInstance(result.status, diag.CheckStatus)

    def test_unexpected_exception_never_leaks_into_the_detail_text(self):
        import unittest.mock as mock

        from ovb_rc003 import windows_diagnostics as module

        secret = "\\\\?\\HID#VID_2717&PID_32B8#SUPERSECRETSERIAL"

        with mock.patch.object(
            module, "check_raw_input", side_effect=RuntimeError(secret)
        ):
            report = module.run_diagnostics()

        self.assertNotIn(secret, report.get("raw_input").detail)
        self.assertEqual(report.get("raw_input").status, diag.CheckStatus.FAIL)

    def test_multiple_simultaneous_unexpected_failures_each_isolate_independently(self):
        import unittest.mock as mock

        from ovb_rc003 import windows_diagnostics as module

        with mock.patch.object(module, "check_os_version", side_effect=RuntimeError("a")):
            with mock.patch.object(module, "check_dictation_manual", side_effect=RuntimeError("b")):
                report = module.run_diagnostics()

        self.assertEqual(len(report.checks), 8)
        self.assertEqual(report.get("os_version").status, diag.CheckStatus.FAIL)
        self.assertEqual(report.get("dictation").status, diag.CheckStatus.FAIL)
        # Untouched checks are unaffected.
        self.assertIsNotNone(report.get("ble_candidate"))


class BuildBleDiagnosticsSubprocessCommandTests(unittest.TestCase):
    """XRBM-035 RETRY 1 In-scope item 1: the command-contract test the
    review required - both ways this package is ever run, and the
    result-path argument that replaced the (broken in a real frozen
    ``console=False`` build - see windows_diagnostics.py's own "IPC
    transport" comment) stdout contract.
    """

    def test_source_mode_uses_dash_m_ovb_rc003(self):
        command = diag.build_ble_diagnostics_subprocess_command(
            "/tmp/result.json", frozen=False, executable="/usr/bin/python3"
        )
        self.assertEqual(
            command,
            ["/usr/bin/python3", "-m", "ovb_rc003", diag.BLE_DIAGNOSTICS_SUBPROCESS_FLAG, "/tmp/result.json"],
        )

    def test_frozen_mode_reinvokes_the_exe_directly_with_no_dash_m(self):
        command = diag.build_ble_diagnostics_subprocess_command(
            "/tmp/result.json",
            frozen=True,
            executable=r"C:\Program Files\RemoteMicRC003\RemoteMicRC003.exe",
        )
        self.assertEqual(
            command,
            [
                r"C:\Program Files\RemoteMicRC003\RemoteMicRC003.exe",
                diag.BLE_DIAGNOSTICS_SUBPROCESS_FLAG,
                "/tmp/result.json",
            ],
        )
        self.assertNotIn("-m", command)

    def test_result_path_is_always_the_final_argument(self):
        for frozen in (True, False):
            command = diag.build_ble_diagnostics_subprocess_command(
                "/some/result/path.json", frozen=frozen, executable="exe"
            )
            self.assertEqual(command[-1], "/some/result/path.json")

    def test_real_defaults_reflect_this_process_not_hardcoded_values(self):
        command = diag.build_ble_diagnostics_subprocess_command("/tmp/r.json")
        self.assertEqual(command[0], sys.executable)


class SanitizeVerdictPayloadTests(unittest.TestCase):
    """XRBM-035 RETRY 1 P2/D: the strict-allow-list parser is the ONLY place
    raw, untrusted result-file content is allowed to influence this
    process - every test here proves something OUTSIDE the exact expected
    shape becomes ``ERROR``, never a fabricated success or an unbounded
    allocation.
    """

    def test_accepts_every_real_non_ambiguous_verdict(self):
        for verdict in ("single_match", "no_candidate", "winrt_unavailable", "error"):
            with self.subTest(verdict=verdict):
                result = diag._sanitize_verdict_payload({"verdict": verdict})
                self.assertEqual(result.verdict.value, verdict)
                self.assertIsNone(result.count)

    def test_accepts_a_well_formed_ambiguous_verdict(self):
        result = diag._sanitize_verdict_payload({"verdict": "ambiguous", "count": 3})
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.AMBIGUOUS)
        self.assertEqual(result.count, 3)

    def test_rejects_non_dict_content(self):
        for bad in (None, "single_match", 42, ["single_match"]):
            with self.subTest(bad=bad):
                result = diag._sanitize_verdict_payload(bad)
                self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_an_unknown_verdict_string(self):
        result = diag._sanitize_verdict_payload({"verdict": "totally_made_up"})
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_extra_keys_on_a_simple_verdict(self):
        result = diag._sanitize_verdict_payload(
            {"verdict": "single_match", "extra": "should not be here"}
        )
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_extra_keys_on_an_ambiguous_verdict(self):
        result = diag._sanitize_verdict_payload(
            {"verdict": "ambiguous", "count": 3, "device_name": "should never appear"}
        )
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_ambiguous_missing_count(self):
        result = diag._sanitize_verdict_payload({"verdict": "ambiguous"})
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_non_integer_count(self):
        for bad_count in ("3", 3.0, None, [3]):
            with self.subTest(bad_count=bad_count):
                result = diag._sanitize_verdict_payload({"verdict": "ambiguous", "count": bad_count})
                self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_a_bool_count_despite_bool_being_an_int_subclass(self):
        result = diag._sanitize_verdict_payload({"verdict": "ambiguous", "count": True})
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_count_below_two(self):
        for bad_count in (-1, 0, 1):
            with self.subTest(bad_count=bad_count):
                result = diag._sanitize_verdict_payload({"verdict": "ambiguous", "count": bad_count})
                self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_rejects_an_implausibly_large_count(self):
        result = diag._sanitize_verdict_payload(
            {"verdict": "ambiguous", "count": diag._MAX_PLAUSIBLE_AMBIGUOUS_COUNT + 1}
        )
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_accepts_the_maximum_plausible_count(self):
        result = diag._sanitize_verdict_payload(
            {"verdict": "ambiguous", "count": diag._MAX_PLAUSIBLE_AMBIGUOUS_COUNT}
        )
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.AMBIGUOUS)
        self.assertEqual(result.count, diag._MAX_PLAUSIBLE_AMBIGUOUS_COUNT)


class ReadSubprocessVerdictTests(unittest.TestCase):
    """Parent-side file read+parse, exercised against a REAL temp file (not
    a mock) - nonzero exit codes and missing/malformed files must never be
    trusted, even if a stray file happens to exist.
    """

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp()

    def tearDown(self):

        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _write(self, content: str) -> str:
        path = os.path.join(self._tmpdir, "verdict.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        return path

    def test_nonzero_returncode_is_error_even_if_the_file_has_valid_content(self):
        path = self._write(json.dumps({"verdict": "single_match"}))
        result = diag._read_subprocess_verdict(path, returncode=1)
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_missing_file_is_error(self):
        missing_path = os.path.join(self._tmpdir, "does-not-exist.json")
        result = diag._read_subprocess_verdict(missing_path, returncode=0)
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_malformed_json_is_error(self):
        path = self._write("{not valid json")
        result = diag._read_subprocess_verdict(path, returncode=0)
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_valid_content_with_zero_returncode_is_accepted(self):
        path = self._write(json.dumps({"verdict": "no_candidate"}))
        result = diag._read_subprocess_verdict(path, returncode=0)
        self.assertEqual(result.verdict, diag.BleDiagnosticsVerdict.NO_CANDIDATE)


class BleDiagnosticsSubprocessEntrypointTests(unittest.TestCase):
    """XRBM-035 RETRY 1 In-scope item 6/F: exercises
    ``run_ble_diagnostics_subprocess_entrypoint()`` DIRECTLY, in-process
    (never spawning a real subprocess) - the fast, deterministic layer that
    proves the child-side contract itself, independent of process
    spawning/termination (covered separately below).
    """

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp()
        self._result_path = os.path.join(self._tmpdir, "verdict.json")

    def tearDown(self):

        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _read_result(self) -> dict:
        with open(self._result_path, "r", encoding="utf-8") as handle:
            return json.loads(handle.read())

    def test_missing_result_path_fails_closed_without_writing_anything(self):
        exit_code = diag.run_ble_diagnostics_subprocess_entrypoint(None)
        self.assertEqual(exit_code, 1)
        self.assertFalse(os.path.exists(self._result_path))

    def test_empty_result_path_fails_closed(self):
        exit_code = diag.run_ble_diagnostics_subprocess_entrypoint("")
        self.assertEqual(exit_code, 1)

    def test_never_touches_stdout_stderr_stdin_even_when_all_three_are_none(self):
        # XRBM-035 RETRY 1 In-scope item 6/F - the exact condition a real
        # PyInstaller console=False build produces (see windows_diagnostics.
        # py's own "IPC transport" comment and the PyInstaller docs it
        # cites). If this function ever touched any of these three, this
        # test would raise AttributeError before reaching the assertions
        # below - proving it instead of merely asserting it.
        with mock.patch.object(sys, "stdout", None), mock.patch.object(
            sys, "stderr", None
        ), mock.patch.object(sys, "stdin", None):
            exit_code = diag.run_ble_diagnostics_subprocess_entrypoint(self._result_path)

        self.assertEqual(exit_code, 0)
        # XRBM-035 RETRY 2 (Windows CI red evidence, run 29683435697): this
        # host's real, unmocked ble_transport_winrt.discover_candidates()
        # call (In-scope item 5: never mock/skip real BLE inside this
        # function itself) can legitimately land on more than one verdict
        # depending on the platform it actually runs on - macOS/Linux CI
        # has no winrt packages at all ("winrt_unavailable"), while a real
        # Windows runner has WinRT installed and, per this exact red
        # evidence, no paired RC003 ("no_candidate"); a real paired device
        # would give "single_match"/"ambiguous" instead. The true, platform-
        # independent contract this test exists to prove is narrower than
        # any one of those: stdout/stderr/stdin being None never stops this
        # function from writing a real, strictly-whitelisted IPC result
        # (see _sanitize_verdict_payload()) - re-validating the file's raw
        # content through that same parser both proves it is well-formed
        # AND excludes "error" (an unexpected real discovery failure this
        # test must still catch, never silently accept as a stand-in for
        # any of the legitimate outcomes above).
        payload = self._read_result()
        sanitized = diag._sanitize_verdict_payload(payload)
        self.assertNotEqual(sanitized.verdict, diag.BleDiagnosticsVerdict.ERROR)

    def test_no_candidate_verdict_is_written_for_an_empty_candidate_list(self):
        async def _empty_discover():
            return []

        with mock.patch.object(ble_transport_winrt, "discover_candidates", _empty_discover):
            exit_code = diag.run_ble_diagnostics_subprocess_entrypoint(self._result_path)

        self.assertEqual(exit_code, 0)
        self.assertEqual(self._read_result(), {"verdict": "no_candidate"})

    def test_single_match_verdict_never_includes_the_real_device_name(self):
        secret_name = "小米蓝牙遥控器 2 Pro"

        async def _one_match():
            return [identity.RC003Candidate(name=secret_name, hardware_match=True)]

        with mock.patch.object(ble_transport_winrt, "discover_candidates", _one_match):
            exit_code = diag.run_ble_diagnostics_subprocess_entrypoint(self._result_path)

        self.assertEqual(exit_code, 0)
        payload = self._read_result()
        self.assertEqual(payload, {"verdict": "single_match"})
        with open(self._result_path, "r", encoding="utf-8") as handle:
            raw_text = handle.read()
        self.assertNotIn(secret_name, raw_text)

    def test_ambiguous_verdict_carries_only_a_count_never_names(self):
        async def _two_matches():
            return [
                identity.RC003Candidate(name="Mi RC", hardware_match=False),
                identity.RC003Candidate(name="MI RC", hardware_match=False),
            ]

        with mock.patch.object(ble_transport_winrt, "discover_candidates", _two_matches):
            exit_code = diag.run_ble_diagnostics_subprocess_entrypoint(self._result_path)

        self.assertEqual(exit_code, 0)
        self.assertEqual(self._read_result(), {"verdict": "ambiguous", "count": 2})

    def test_unexpected_exception_becomes_the_sanitized_error_verdict(self):
        async def _raise():
            raise RuntimeError("boom with a secret AA:BB:CC:DD:EE:FF inside")

        with mock.patch.object(ble_transport_winrt, "discover_candidates", _raise):
            exit_code = diag.run_ble_diagnostics_subprocess_entrypoint(self._result_path)

        self.assertEqual(exit_code, 0)
        self.assertEqual(self._read_result(), {"verdict": "error"})
        with open(self._result_path, "r", encoding="utf-8") as handle:
            raw_text = handle.read()
        self.assertNotIn("AA:BB:CC:DD:EE:FF", raw_text)
        self.assertNotIn("boom", raw_text)


class _FakeProc:
    """A minimal ``Popen``-like double for exercising
    ``_attempt_termination_step()``'s own process-control exception
    handling in isolation from any real OS process/timing (XRBM-035 RETRY
    1, Codex red evidence: ``terminate()``/``kill()``/``wait()`` each
    raising ``PermissionError``, and ``poll()`` also raising after
    ``wait()`` already did) - real subprocesses cannot be made to raise
    these deterministically, so a real ``Popen`` is the wrong tool for
    these specific tests (see ``RunBleDiagnosticsSubprocessTests`` below
    for the REAL-process coverage of the happy/race/escalation paths this
    class does not attempt to duplicate).
    """

    def __init__(
        self,
        *,
        terminate_raises=None,
        kill_raises=None,
        wait_raises=None,
        poll_raises=None,
        poll_returns=None,
    ):
        self.terminate_calls = 0
        self.kill_calls = 0
        self.wait_calls = 0
        self.poll_calls = 0
        self._terminate_raises = terminate_raises
        self._kill_raises = kill_raises
        self._wait_raises = wait_raises
        self._poll_raises = poll_raises
        self._poll_returns = poll_returns

    def terminate(self):
        self.terminate_calls += 1
        if self._terminate_raises is not None:
            raise self._terminate_raises

    def kill(self):
        self.kill_calls += 1
        if self._kill_raises is not None:
            raise self._kill_raises

    def wait(self, timeout=None):
        self.wait_calls += 1
        if self._wait_raises is not None:
            raise self._wait_raises

    def poll(self):
        self.poll_calls += 1
        if self._poll_raises is not None:
            raise self._poll_raises
        return self._poll_returns


class AttemptTerminationStepTests(unittest.TestCase):
    """XRBM-035 RETRY 1: deterministic, process-free coverage of
    ``_attempt_termination_step()``'s own exception handling - every
    process-control call (``terminate()``/``kill()``/``wait()``/
    ``poll()``) can independently raise an ``OSError``
    (``PermissionError`` was the exact case Codex's own probe reproduced),
    and none of them may ever escape this function as a raw,
    undifferentiated ``OSError`` - only a real ``wait()``/``poll()``
    observation of the process having actually exited may ever return
    True; anything this function cannot confirm returns False.
    """

    def test_terminate_raising_still_confirms_via_a_successful_wait(self):
        # A race: terminate() failed (e.g. PermissionError), but the
        # process happens to have already exited on its own by the time
        # wait() is called - wait() succeeding is a REAL confirmation and
        # must still return True, not be treated as a terminate() failure.
        proc = _FakeProc(terminate_raises=PermissionError("denied"))
        result = diag._attempt_termination_step(proc, proc.terminate, 1.0)
        self.assertTrue(result)
        self.assertEqual(proc.wait_calls, 1)

    def test_wait_raising_falls_back_to_a_successful_poll_confirmation(self):
        # wait() itself fails, but poll() independently observes the
        # process has a real exit status - still a genuine confirmation.
        proc = _FakeProc(wait_raises=PermissionError("denied"), poll_returns=0)
        result = diag._attempt_termination_step(proc, proc.terminate, 1.0)
        self.assertTrue(result)
        self.assertEqual(proc.poll_calls, 1)

    def test_wait_raising_and_poll_showing_still_running_returns_false(self):
        proc = _FakeProc(wait_raises=PermissionError("denied"), poll_returns=None)
        result = diag._attempt_termination_step(proc, proc.terminate, 1.0)
        self.assertFalse(result)

    def test_wait_raising_and_poll_also_raising_returns_false_not_raise(self):
        # XRBM-035 RETRY 1 (this round's own fix): poll() is not trusted to
        # never raise either - a second raw OSError from the poll()
        # fallback must never escape this function; it is just another
        # "cannot confirm" outcome.
        proc = _FakeProc(
            wait_raises=PermissionError("wait denied"),
            poll_raises=OSError("poll denied too"),
        )
        result = diag._attempt_termination_step(proc, proc.terminate, 1.0)
        self.assertFalse(result)

    def test_kill_raising_still_confirms_via_a_successful_wait(self):
        proc = _FakeProc(kill_raises=PermissionError("denied"))
        result = diag._attempt_termination_step(proc, proc.kill, 1.0)
        self.assertTrue(result)

    def test_timeout_expired_returns_false_without_touching_poll(self):
        proc = _FakeProc(wait_raises=subprocess.TimeoutExpired(cmd="x", timeout=1.0))
        result = diag._attempt_termination_step(proc, proc.terminate, 1.0)
        self.assertFalse(result)
        self.assertEqual(proc.poll_calls, 0)

    def test_every_failure_path_stays_bounded_no_retry_loop(self):
        # None of the OSError fallback branches may loop/sleep - each is a
        # single wait() plus at most one poll() call, never retried.
        proc = _FakeProc(
            wait_raises=PermissionError("denied"), poll_raises=OSError("denied too")
        )
        started = time.monotonic()
        diag._attempt_termination_step(proc, proc.terminate, 1.0)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 0.5)
        self.assertEqual(proc.wait_calls, 1)
        self.assertEqual(proc.poll_calls, 1)

    def test_full_escalation_confirms_via_wait_after_terminate_and_kill_both_raise(self):
        # Full _terminate_and_confirm_exit() escalation: terminate() raises,
        # its wait() times out (still running), kill() ALSO raises, but the
        # kill-step wait() succeeds - a real race-confirmed death after the
        # forceful step, even though both signal calls themselves failed.
        proc = _FakeProc(
            terminate_raises=PermissionError("denied"),
            kill_raises=PermissionError("denied too"),
        )
        # First wait() (after terminate) times out; second wait() (after
        # kill) succeeds - simulate via a stateful override.
        wait_calls = {"n": 0}

        def _wait(timeout=None):
            wait_calls["n"] += 1
            if wait_calls["n"] == 1:
                raise subprocess.TimeoutExpired(cmd="x", timeout=timeout)
            return None

        proc.wait = _wait
        result = diag._terminate_and_confirm_exit(proc, terminate_wait=0.1, kill_wait=0.1)
        self.assertTrue(result)
        self.assertEqual(proc.terminate_calls, 1)
        self.assertEqual(proc.kill_calls, 1)


def _spawn_ovb_rc003(*args: str) -> "list[str]":
    env = dict(os.environ)
    repo_src = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
    env["PYTHONPATH"] = repo_src
    return [sys.executable, "-m", "ovb_rc003", *args], env


class RunBleDiagnosticsSubprocessTests(unittest.TestCase):
    """XRBM-035 RETRY 1: exercises ``_run_ble_diagnostics_subprocess()``
    against REAL OS child processes (never mocked ``Popen`` internals for
    the termination logic itself) - this is the layer the independent
    review's own red probe (an uncooperative-cancel child still hanging
    after 2 seconds) targeted, so it is proven here against a genuine
    process, not merely asserted.
    """

    def test_a_well_behaved_child_reports_its_verdict_and_is_never_killed(self):
        tmpdir = tempfile.mkdtemp()
        try:
            result_path = os.path.join(tmpdir, "verdict.json")
            command, env = _spawn_ovb_rc003(
                diag.BLE_DIAGNOSTICS_SUBPROCESS_FLAG, result_path
            )
            popen = lambda cmd, **kwargs: subprocess.Popen(cmd, env=env, **kwargs)  # noqa: E731
            result = diag._run_ble_diagnostics_subprocess(
                command,
                result_path=result_path,
                cancel_event=threading.Event(),
                timeout=30.0,
                popen=popen,
            )
            # XRBM-035 RETRY 2 (Windows CI red evidence, run 29683435697):
            # the real child process's actual verdict depends on what
            # platform it genuinely runs on - macOS/Linux CI has no winrt
            # packages ("winrt_unavailable"), while a real Windows runner
            # has WinRT installed and, per this exact red evidence, no
            # paired RC003 ("no_candidate"); a real paired device would
            # give "single_match"/"ambiguous" instead. Every one of those
            # is proof of the same real spawn -> real discovery attempt ->
            # real file write -> parent read round-trip this test exists
            # to exercise, so none of them may be hardcoded as THE expected
            # result. "error" is deliberately excluded - it would mean the
            # real child hit an unexpected failure, which this test must
            # still catch, never silently accept.
            self.assertNotEqual(result.verdict, diag.BleDiagnosticsVerdict.ERROR)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def test_cancel_event_already_set_never_spawns_a_process_at_all(self):
        spawn_calls = []

        def _counting_popen(cmd, **kwargs):
            spawn_calls.append(cmd)
            raise AssertionError("must never spawn once cancel_event is already set")

        cancel_event = threading.Event()
        cancel_event.set()
        with self.assertRaises(diag.BleDiscoveryCancelledError):
            diag._run_ble_diagnostics_subprocess(
                ["irrelevant"],
                result_path="/irrelevant",
                cancel_event=cancel_event,
                timeout=5.0,
                popen=_counting_popen,
            )
        self.assertEqual(spawn_calls, [])

    def test_a_hanging_child_is_terminated_and_confirmed_dead_within_bound(self):
        # A genuine child process that never exits on its own (no
        # cooperative-cancel handling of any kind - this is the exact
        # "uncooperative cancel" shape the independent review's own red
        # probe used) - proves the parent's terminate()+wait() escalation
        # actually confirms a REAL OS process's death, not merely that
        # Python-level bookkeeping believes it did.
        script = "import time\ntime.sleep(120)\n"
        process_holder = {}

        def _spawning_popen(cmd, **kwargs):
            proc = subprocess.Popen([sys.executable, "-c", script], **kwargs)
            process_holder["proc"] = proc
            return proc

        cancel_event = threading.Event()
        started = time.monotonic()
        with self.assertRaises(diag.BleDiscoveryCancelledError):
            diag._run_ble_diagnostics_subprocess(
                ["irrelevant - replaced by _spawning_popen above"],
                result_path="/irrelevant",
                cancel_event=cancel_event,
                timeout=0.2,
                poll_interval=0.05,
                terminate_wait=1.0,
                kill_wait=1.0,
                popen=_spawning_popen,
            )
        elapsed = time.monotonic() - started

        self.assertLess(
            elapsed, 5.0, "termination must be bounded, not left to the 120s child sleep"
        )
        proc = process_holder["proc"]
        # Independently confirm the OS process is REALLY gone (not just
        # that _run_ble_diagnostics_subprocess() believes so) - poll()
        # after a confirmed wait() must report a real exit status.
        self.assertIsNotNone(proc.poll(), "the child process must actually be dead")

    @unittest.skipIf(sys.platform == "win32", "SIGTERM-ignoring is a POSIX-only scenario")
    def test_a_child_that_ignores_sigterm_is_escalated_to_sigkill_and_confirmed_dead(self):
        # The exact "uncooperative cancel" scenario the independent review
        # cited (its own probe: a child that survives a first cancellation
        # attempt and is still alive 2 seconds later) - only reproducible
        # on POSIX, where a process can choose to ignore SIGTERM (Popen.
        # terminate()) but never SIGKILL (Popen.kill()). On Windows both
        # calls map to the same TerminateProcess() (see _terminate_and_
        # confirm_exit()'s own docstring), so there is nothing to ignore -
        # this is exactly why _terminate_and_confirm_exit() (exercised
        # directly here) always escalates rather than trusting terminate()
        # alone.
        script = (
            "import signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "time.sleep(120)\n"
        )
        proc = subprocess.Popen([sys.executable, "-c", script])
        try:
            time.sleep(0.2)  # let the child install its SIGTERM handler
            started = time.monotonic()
            confirmed_dead = diag._terminate_and_confirm_exit(
                proc, terminate_wait=0.5, kill_wait=2.0
            )
            elapsed = time.monotonic() - started
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5.0)

        self.assertTrue(
            confirmed_dead, "kill() must have been confirmed even though terminate() was ignored"
        )
        self.assertGreater(
            elapsed, 0.5, "must actually have waited out terminate_wait before escalating to kill()"
        )
        self.assertLess(elapsed, 3.0, "the whole escalation must still be bounded")
        self.assertIsNotNone(proc.poll(), "the child process must actually be dead")

    @unittest.skipIf(sys.platform == "win32", "SIGTERM-ignoring is a POSIX-only scenario")
    def test_run_ble_diagnostics_subprocess_kills_an_uncooperative_child_end_to_end(self):
        # Same scenario, but driven through the full
        # _run_ble_diagnostics_subprocess() orchestration (poll loop +
        # cancel_event + escalation), matching the independent review's own
        # red probe shape more closely than the lower-level test above.
        script = (
            "import signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "time.sleep(120)\n"
        )

        def _spawning_popen(cmd, **kwargs):
            return subprocess.Popen([sys.executable, "-c", script], **kwargs)

        cancel_event = threading.Event()
        threading.Timer(0.1, cancel_event.set).start()

        started = time.monotonic()
        with self.assertRaises(diag.BleDiscoveryCancelledError):
            diag._run_ble_diagnostics_subprocess(
                ["irrelevant - _spawning_popen ignores this"],
                result_path="/irrelevant",
                cancel_event=cancel_event,
                timeout=30.0,
                poll_interval=0.05,
                terminate_wait=1.0,
                kill_wait=2.0,
                popen=_spawning_popen,
            )
        elapsed = time.monotonic() - started

        self.assertLess(elapsed, 5.0, "the whole kill sequence must still be bounded")


class DiscoverBleCandidatesSyncTests(unittest.TestCase):
    """End-to-end coverage of ``_discover_ble_candidates_sync()`` - the real
    production default ``check_ble_candidate()`` uses - including the temp
    result-directory's own cleanup contract (XRBM-035 RETRY 1 P3).
    """

    def test_real_subprocess_round_trip_returns_a_legitimate_result_on_this_host(self):
        # No mocking anywhere in this test - a REAL subprocess is spawned
        # (via the real build_ble_diagnostics_subprocess_command()), so this
        # proves the entire real pipeline (spawn, write, confirm-exit,
        # read, sanitize, reconstruct) end-to-end.
        #
        # XRBM-035 RETRY 2 (Windows CI red evidence, run 29683435697): the
        # real, correct result depends on what platform this genuinely runs
        # on, not on this test's NAME - macOS/Linux CI has no winrt
        # packages at all, so _candidates_from_verdict() raises
        # WinRTUnavailableError; a real Windows runner has WinRT installed
        # and, per this exact red evidence, no paired RC003, so the same
        # real pipeline instead returns an (empty) candidate list - both
        # are honest, correct outcomes of this module's own contract
        # (windows_diagnostics.py's "-- BLE candidate --" section), not a
        # test failure. Only WinRTUnavailableError is caught here - any
        # OTHER exception (e.g. the RuntimeError _candidates_from_verdict()
        # raises for a real "error" verdict) still fails this test, exactly
        # as before.
        try:
            candidates = diag._discover_ble_candidates_sync(timeout=30.0)
        except ble_transport_winrt.WinRTUnavailableError:
            return

        # XRBM-035 RETRY 2 (independent review): `assertIsInstance(list(x),
        # list)` is vacuously true for ANY iterable and proves nothing about
        # the real production contract - assert that shape directly
        # instead. `_candidates_from_verdict()` only ever returns a real
        # Sequence (never an arbitrary iterable/generator), bounded by
        # `_MAX_PLAUSIBLE_AMBIGUOUS_COUNT` (the same strict cap
        # `_sanitize_verdict_payload()` already enforces on the raw IPC
        # count before any candidate is ever reconstructed from it), and
        # every reconstructed placeholder candidate has an EMPTY name and
        # `hardware_match=True` (see `_candidates_from_verdict()`'s own
        # docstring) - proving the real device name from this host's real
        # WinRT/BLE stack never crossed the subprocess IPC boundary into
        # this process, not just that "some list-like thing came back". An
        # empty list (the real "no_candidate" outcome the RETRY 2 red
        # evidence's Windows runner actually hit) trivially satisfies every
        # assertion below - nothing here forces a specific non-empty shape.
        self.assertIsInstance(candidates, Sequence)
        self.assertLessEqual(len(candidates), diag._MAX_PLAUSIBLE_AMBIGUOUS_COUNT)
        for candidate in candidates:
            self.assertEqual(candidate.name, "")
            self.assertIs(candidate.hardware_match, True)

    def test_result_directory_is_always_removed_afterward(self):
        created_dirs = []
        real_mkdtemp = tempfile.mkdtemp

        def _tracking_mkdtemp(*args, **kwargs):
            path = real_mkdtemp(*args, **kwargs)
            created_dirs.append(path)
            return path

        # XRBM-035 RETRY 2: the temp result directory must be removed
        # whether this host's real discovery attempt raises
        # WinRTUnavailableError (macOS/Linux CI) or returns normally with a
        # real candidate list (a real Windows runner - see the sibling test
        # above for the full platform rationale) - cleanup is not
        # conditional on which of those two legitimate outcomes occurs.
        with mock.patch.object(tempfile, "mkdtemp", _tracking_mkdtemp):
            try:
                diag._discover_ble_candidates_sync(timeout=30.0)
            except ble_transport_winrt.WinRTUnavailableError:
                pass

        self.assertEqual(len(created_dirs), 1)
        self.assertFalse(os.path.exists(created_dirs[0]), "the temp result directory must be cleaned up")

    def test_a_cleanup_failure_other_than_missing_propagates_never_silently_discarded(self):
        # XRBM-035 RETRY 1 P3: only FileNotFoundError may ever be ignored
        # during cleanup - anything else (simulated here) must be visible,
        # either to a caller or, as here, directly to the test - never a
        # bare `except Exception: pass`. This is also this file's "unrelated
        # original exception still loses to a cleanup failure" case (the
        # real original here is WinRTUnavailableError, from this host
        # genuinely having no winrt packages) - see the two more explicit,
        # mocked-original tests below for the full narrowing this priority
        # rule is scoped to.

        def _raise_permission_error(path):
            raise PermissionError("simulated: child still held this file open")

        with mock.patch.object(shutil, "rmtree", _raise_permission_error):
            with self.assertRaises(PermissionError):
                diag._discover_ble_candidates_sync(timeout=30.0)

    def test_unconfirmed_shutdown_survives_a_cleanup_failure_with_it_chained_as_cause(self):
        # XRBM-035 RETRY 1: the ONE narrow case where the original exception
        # must win over a cleanup failure - BleDiscoverySubprocessShutdownUnconfirmedError
        # is the one honest "the subprocess might still be alive" signal
        # this whole design exists to surface; a cleanup failure on top of
        # it must never silently replace it with a plain OSError.
        def _raise_unconfirmed(*args, **kwargs):
            raise diag.BleDiscoverySubprocessShutdownUnconfirmedError("could not confirm exit")

        def _raise_permission_error(path):
            raise PermissionError("simulated: cleanup also failed")

        with mock.patch.object(diag, "_run_ble_diagnostics_subprocess", _raise_unconfirmed):
            with mock.patch.object(shutil, "rmtree", _raise_permission_error):
                with self.assertRaises(
                    diag.BleDiscoverySubprocessShutdownUnconfirmedError
                ) as ctx:
                    diag._discover_ble_candidates_sync(timeout=30.0)

        self.assertIsInstance(ctx.exception.__cause__, PermissionError)
        self.assertIsInstance(ctx.exception.__context__, PermissionError)

    def test_an_unrelated_original_exception_still_loses_to_a_cleanup_failure(self):
        # Confirms the narrowing is exact: this priority rule applies ONLY
        # to BleDiscoverySubprocessShutdownUnconfirmedError - every OTHER
        # original exception (here BleDiscoveryCancelledError, a routine
        # cancel/timeout outcome, not "might still be alive") keeps this
        # module's pre-existing "a cleanup failure must still propagate,
        # never be silently discarded" contract, even though it means the
        # cleanup OSError is what a caller ultimately sees, not the
        # original exception.
        def _raise_cancelled(*args, **kwargs):
            raise diag.BleDiscoveryCancelledError("cancelled")

        def _raise_permission_error(path):
            raise PermissionError("simulated: cleanup also failed")

        with mock.patch.object(diag, "_run_ble_diagnostics_subprocess", _raise_cancelled):
            with mock.patch.object(shutil, "rmtree", _raise_permission_error):
                with self.assertRaises(PermissionError):
                    diag._discover_ble_candidates_sync(timeout=30.0)


class RunDiagnosticsStopsAfterCancellationTests(unittest.TestCase):
    """XRBM-035 RETRY 1 P1 #2: once cancel_event becomes set, run_diagnostics()
    must not continue running checks after whichever one just completed -
    continuing would only prolong worker shutdown for a report that is about
    to be discarded unemitted anyway.
    """

    def test_no_cancel_event_still_runs_all_eight_checks(self):
        report = diag.run_diagnostics()
        self.assertEqual(len(report.checks), 8)

    def test_stops_immediately_after_the_check_during_which_cancellation_was_observed(self):
        cancel_event = threading.Event()

        def _fake_check_ble_candidate(*, discover):
            # Simulates cancel_event becoming set WHILE the BLE check was
            # running (e.g. the settings window started closing during
            # discovery) - discover() itself is never called here since
            # this replaces check_ble_candidate() entirely.
            cancel_event.set()
            return diag.CheckResult(
                "ble_candidate",
                "已配对的 RC003 (BLE)",
                diag.CheckGroup.VOICE_BRIDGE,
                diag.CheckStatus.FAIL,
                "cancelled",
            )

        with mock.patch.object(diag, "check_ble_candidate", side_effect=_fake_check_ble_candidate):
            report = diag.run_diagnostics(cancel_event=cancel_event)

        ids = [c.check_id for c in report.checks]
        self.assertEqual(ids, ["os_version", "raw_input", "ble_candidate"])

    def test_cancel_event_already_set_before_the_first_check_stops_after_just_one(self):
        cancel_event = threading.Event()
        cancel_event.set()

        report = diag.run_diagnostics(cancel_event=cancel_event)

        self.assertEqual([c.check_id for c in report.checks], ["os_version"])


if __name__ == "__main__":
    unittest.main()
