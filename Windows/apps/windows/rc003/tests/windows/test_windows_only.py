"""Windows-only integration checks.

These exercise the real Win32/WinRT/PortAudio adapters and therefore cannot
run on macOS/Linux, and cannot run against real hardware anywhere in this
project's CI (no device pairing/control is permitted). Every test here is
skipped outside a genuine Windows environment with the optional runtime
dependencies installed; skip reasons intentionally record this as an
explicit "not verified here" rather than a silent pass.

The bulk of this candidate's actual behavioral logic (ATVV protocol/session,
identity/HID-path fail-closed selection, the WinRT call shape, SendInput
batching/rollback, the connection supervisor, Raw Input body parsing) is
covered by cross-platform tests using fakes/dependency injection instead of
skip-guards - see tests/test_ble_transport_contract.py,
tests/test_raw_input_pure.py, tests/test_win32_input_batching.py, and
tests/test_connection_supervisor.py. What's left here is the genuinely
irreducible Windows-API-surface: does the real syscall succeed at all.

See this package's top-level README.md "Known gaps" section for the
real-machine verification steps that remain outstanding (RC003
pairing/connect/reconnect, per-button behavior including which Raw Input
event shape the device actually produces, ATVV voice playback, back-key
compatibility layer).
"""

import os
import sys
import unittest

_ON_WINDOWS = sys.platform == "win32"
_ALLOW_LIVE_INPUT_TESTS = os.environ.get("RC003_ALLOW_LIVE_INPUT_TESTS") == "1"


def _has_module(name: str) -> bool:
    try:
        __import__(name)
    except ImportError:
        return False
    return True


@unittest.skipUnless(
    _ON_WINDOWS and _ALLOW_LIVE_INPUT_TESTS,
    "live keyboard injection tests are disabled by default; use the isolated sender tests",
)
class Win32InputAvailabilityTests(unittest.TestCase):
    def test_send_key_combo_tap_does_not_raise_on_windows(self):
        from ovb_rc003 import win32_input

        # A harmless no-op combo (both keyup immediately); not asserting any
        # observable OS effect here, only that SendInput itself succeeds.
        win32_input.send_key_combo_tap(("shift",))

    def test_real_sendinput_batch_reports_full_delivery(self):
        """XRBM-018 DoD 3: a real (not fake-sender) SendInput call, using
        the x64 INPUT struct declared in win32_input.py, must actually
        deliver every event it is given - proving ``sizeof(INPUT)``/argtypes
        are correct against the live Win32 ABI, not only against
        ctypes.sizeof() in isolation (see tests/test_win32_input_abi.py for
        the cross-platform struct-shape half of this contract).
        """

        from ovb_rc003 import win32_input, win32_keys

        vk_shift = win32_keys.VK_CODES["shift"]
        sent = win32_input._real_send_input_batch([(vk_shift, False), (vk_shift, True)])
        self.assertEqual(sent, 2)


@unittest.skipUnless(not _ON_WINDOWS, "documents the expected non-Windows failure mode")
class Win32InputUnavailableOffWindowsTests(unittest.TestCase):
    def test_raises_a_clear_error_off_windows(self):
        from ovb_rc003 import win32_input

        with self.assertRaises(win32_input.Win32InputUnavailableError):
            win32_input.send_key_combo_tap(("a",))


@unittest.skipUnless(_ON_WINDOWS, "Windows-only: Raw Input requires the Win32 API")
class RawInputWindowsTests(unittest.TestCase):
    def test_enumerate_matching_device_paths_runs_without_raising(self):
        # No RC003 is paired in CI; this only proves enumeration itself works,
        # not that a real device is found (that's a real-machine 待核验 item).
        from ovb_rc003 import raw_input_windows

        raw_input_windows.enumerate_matching_device_paths()

    def test_listener_reaches_ready_stops_joins_and_can_restart(self):
        """XRBM-018 DoD 3: a real hidden Raw Input listener - a real
        message-only window, RegisterClassW/CreateWindowExW/
        RegisterRawInputDevices, and a real background message-loop thread -
        must reach ready, stop() must actually join the thread (not merely
        return), and start()/stop() must be repeatable without leaking a
        thread. No RC003 needs to be attached for this: the listener scopes
        on VID/PID device paths that simply never match here, so no button
        events are expected - only the window/thread lifecycle itself is
        under test.
        """

        from ovb_rc003 import raw_input_windows

        listener = raw_input_windows.RawInputButtonListener(lambda button, pressed: None)

        # A VID/PID that cannot exist on any real HID device path (using
        # the reserved 0x0000 vendor id) - safe to "select" without a real
        # RC003 attached; only the window/thread lifecycle is under test.
        device_path = r"\\?\HID#VID_0000&PID_0000#0&test#{00000000-0000-0000-0000-000000000000}"

        for attempt in range(2):  # proves repeatable start/stop, not just once
            listener.start(device_path)
            try:
                self.assertTrue(listener.is_running, f"attempt {attempt}: not running after start()")
            finally:
                listener.stop()
            self.assertFalse(listener.is_running, f"attempt {attempt}: still running after stop()")
        # Two full rounds (XRBM-018 RETRY 1 P1 #2) prove the window class
        # registration/unregistration lifecycle actually works across a
        # restart, not just that a single start/stop cycle succeeds: the
        # second round's RegisterClassW would fail with
        # ERROR_CLASS_ALREADY_EXISTS if the first round's class had leaked.

    def test_start_fails_closed_when_already_running(self):
        """A second start() while a listener is already running must raise
        instead of silently overwriting self._thread and orphaning the
        first (still-live) listener/window/thread (XRBM-018 RETRY 1 P1 #2).
        The deterministic, timing-independent version of "start() fails
        closed on a stall" itself (not this "already running" case) is
        covered cross-platform via dependency injection in
        tests/test_raw_input_pure.py.
        """

        from ovb_rc003 import raw_input_windows

        listener = raw_input_windows.RawInputButtonListener(lambda button, pressed: None)
        device_path = r"\\?\HID#VID_0000&PID_0000#0&test#{00000000-0000-0000-0000-000000000000}"
        listener.start(device_path)
        try:
            with self.assertRaises(raw_input_windows.RawInputUnavailableError):
                listener.start(device_path)
        finally:
            listener.stop()


# XRBM-024: every WinRT projection module ble_transport_winrt.py's real call
# path depends on at runtime - the four it imports by name inside
# _import_winrt(), plus winrt.windows.foundation/winrt.windows.foundation.
# collections, which it never imports by name but which
# find_all_async_aqs_filter()'s returned IAsyncOperation and the resulting
# DeviceInformationCollection's iterator both require (see
# ble_transport_winrt.py's module docstring and requirements.txt's XRBM-024
# comment for the exact red evidence this closes).
_REQUIRED_WINRT_PROJECTIONS = (
    "winrt.windows.devices.bluetooth",
    "winrt.windows.devices.bluetooth.genericattributeprofile",
    "winrt.windows.devices.enumeration",
    "winrt.windows.storage.streams",
    "winrt.windows.foundation",
    "winrt.windows.foundation.collections",
)


@unittest.skipUnless(
    _ON_WINDOWS,
    "Windows-only: this IS the hard-fail projection-import gate, not a "
    "skip-if-unavailable check (see the class docstring)",
)
class WinRTProjectionImportClosureTests(unittest.TestCase):
    """XRBM-024: proves every WinRT projection ble_transport_winrt.py's real
    call path needs actually imports on a genuine Windows runner - a hard
    FAIL here, never a skip, if any one of them is missing.

    Deliberately NOT gated on ``_has_module(...)`` the way
    BleTransportWinrtTests below is: that class's skip condition exists so
    the *behavioral* BLE test itself does not run at all off-Windows or when
    winrt is not installed there. This class's whole purpose is the
    opposite - to make "on Windows but a required projection failed to
    import" an unambiguous test FAILURE, since converting that into a
    silent skip is exactly how XRBM-024's red evidence (a
    source-test-green, first-real-use ``ModuleNotFoundError`` on
    ``winrt.windows.foundation``) slipped through the frozen-build gate
    undetected.
    """

    def test_every_projection_ble_transport_winrt_needs_actually_imports(self):
        import importlib

        missing = []
        for module_name in _REQUIRED_WINRT_PROJECTIONS:
            try:
                importlib.import_module(module_name)
            except ImportError as exc:
                missing.append(f"{module_name}: {exc!r}")

        self.assertEqual(
            missing,
            [],
            "required WinRT projection(s) failed to import on this Windows "
            "runner; install every exact pin in requirements.txt - a "
            "missing required projection must fail this test, not silently "
            "skip it: " + "; ".join(missing),
        )


@unittest.skipUnless(
    _ON_WINDOWS and _has_module("winrt.windows.devices.bluetooth"),
    "Windows-only: requires the winrt Bluetooth packages",
)
class BleTransportWinrtTests(unittest.TestCase):
    def test_discover_candidates_runs_without_raising(self):
        import asyncio

        from ovb_rc003 import ble_transport_winrt

        asyncio.run(ble_transport_winrt.discover_candidates())


@unittest.skipUnless(
    _ON_WINDOWS and _has_module("sounddevice"), "Windows-only: requires the 'sounddevice' package"
)
class AudioOutputWindowsTests(unittest.TestCase):
    def test_enumerate_output_endpoints_runs_without_raising(self):
        from ovb_rc003 import audio_output

        audio_output.enumerate_output_endpoints()


if __name__ == "__main__":
    unittest.main()
