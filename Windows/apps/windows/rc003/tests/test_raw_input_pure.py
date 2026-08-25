"""Exercises the parts of raw_input_windows.py that don't need ctypes/a real
Windows message loop at all: RawInputButtonListener's body-parsing methods
(``_handle_keyboard_body``, ``_handle_hid_body``) operate on plain bytes,
and ``stop()``/``_release_all()`` only touch ctypes when ``self._hwnd`` is
not None (i.e. only after a real ``start()`` call) - so constructing a
listener and feeding it synthetic buffers directly is safe on any OS.

This is the "at least establish it at the source contract layer" evidence
for the Raw Input adapter (XRBM-014 review RETRY P1 #5/#9): the actual
window creation, RegisterRawInputDevices, and GetRawInputData calls remain
genuinely Windows-only and untested here - see raw_input_windows.py's module
docstring for the honest, disclosed uncertainty about which Raw Input event
shape (RIM_TYPEKEYBOARD vs RIM_TYPEHID) the real device actually produces.
"""

import struct
import threading
import unittest

from ovb_rc003 import hid_identity, raw_input_windows

WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101


def _rawkeyboard_body(vkey: int, message: int = WM_KEYDOWN) -> bytes:
    # RAWKEYBOARD: MakeCode(u16) Flags(u16) Reserved(u16) VKey(u16) Message(u32) ExtraInformation(u32)
    return struct.pack("<HHHHII", 0, 0, 0, vkey, message, 0)


def _rawhid_body(reports) -> bytes:
    size_hid = len(reports[0]) if reports else 0
    body = size_hid.to_bytes(4, "little") + len(reports).to_bytes(4, "little")
    for report in reports:
        body += report
    return body


def _hid_report(usages):
    payload = bytearray(6)
    for index, usage in enumerate(usages[:3]):
        payload[index * 2 : index * 2 + 2] = usage.to_bytes(2, "little")
    return bytes((0x01, 0x00, 0x00)) + bytes(payload)


class RecordingListener:
    def __init__(self):
        self.events = []
        self.raw_events = []
        self.listener = raw_input_windows.RawInputButtonListener(
            self._on_event, self.raw_events.append
        )

    def _on_event(self, button_id, is_pressed):
        self.events.append((button_id, is_pressed))


class KeyboardBodyTests(unittest.TestCase):
    def test_recognized_vk_down_emits_press(self):
        rec = RecordingListener()
        vk_right = 0x27
        rec.listener._handle_keyboard_body(_rawkeyboard_body(vk_right, WM_KEYDOWN))
        self.assertEqual(rec.events, [("right", True)])

    def test_recognized_vk_up_emits_release(self):
        rec = RecordingListener()
        vk_right = 0x27
        rec.listener._handle_keyboard_body(_rawkeyboard_body(vk_right, WM_KEYDOWN))
        rec.listener._handle_keyboard_body(_rawkeyboard_body(vk_right, WM_KEYUP))
        self.assertEqual(rec.events, [("right", True), ("right", False)])

    def test_repeated_keyboard_keydown_is_one_logical_press(self):
        rec = RecordingListener()
        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYDOWN))
        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYDOWN))
        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYUP))
        self.assertEqual(rec.events, [("up", True), ("up", False)])

    def test_distinct_press_after_release_is_not_debounced(self):
        rec = RecordingListener()
        for _ in range(2):
            rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYDOWN))
            rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYUP))
        self.assertEqual(
            rec.events,
            [("up", True), ("up", False), ("up", True), ("up", False)],
        )

    def test_unrecognized_vk_emits_nothing(self):
        rec = RecordingListener()
        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x99, WM_KEYDOWN))
        self.assertEqual(rec.events, [])

    def test_real_rc003_mic_vk_f5_emits_mic_press(self):
        rec = RecordingListener()
        vk_f5 = 0x74
        rec.listener._handle_keyboard_body(_rawkeyboard_body(vk_f5, WM_KEYDOWN))
        self.assertEqual(rec.events, [("mic", True)])

    def test_tv_oem3_translation_emits_tv_press(self):
        rec = RecordingListener()
        vk_oem_3 = 0xC0
        rec.listener._handle_keyboard_body(_rawkeyboard_body(vk_oem_3, WM_KEYDOWN))
        self.assertEqual(rec.events, [("tv", True)])

    def test_keyboard_power_translation_emits_power_press(self):
        rec = RecordingListener()
        vk_sleep = 0x5F
        rec.listener._handle_keyboard_body(_rawkeyboard_body(vk_sleep, WM_KEYDOWN))
        self.assertEqual(rec.events, [("power", True)])

    def test_keyboard_event_exposes_observed_values_to_learning_ui(self):
        rec = RecordingListener()
        rec.listener._handle_keyboard_body(
            struct.pack("<HHHHII", 0x5E, 0x0002, 0, 0xFF, WM_KEYDOWN, 0)
        )
        self.assertEqual(len(rec.raw_events), 1)
        self.assertEqual(rec.raw_events[0].button_id, "power")
        self.assertEqual(rec.raw_events[0].vkey, 0xFF)
        self.assertEqual(rec.raw_events[0].make_code, 0x5E)

    def test_untranslated_power_scan_code_emits_power_press(self):
        rec = RecordingListener()
        rec.listener._handle_keyboard_body(
            struct.pack("<HHHHII", 0x5E, 0x0002, 0, 0xFF, WM_KEYDOWN, 0)
        )
        self.assertEqual(rec.events, [("power", True)])

    def test_untranslated_remote_scan_codes_map_back_and_volume(self):
        expected = ((0x6A, "back"), (0x30, "volume_up"), (0x2E, "volume_down"))
        for make_code, button in expected:
            rec = RecordingListener()
            rec.listener._handle_keyboard_body(
                struct.pack("<HHHHII", make_code, 0x0002, 0, 0xFF, WM_KEYDOWN, 0)
            )
            self.assertEqual(rec.events, [(button, True)], msg=hex(make_code))

    def test_too_short_body_is_ignored_without_raising(self):
        rec = RecordingListener()
        rec.listener._handle_keyboard_body(b"\x00\x00")
        self.assertEqual(rec.events, [])

    def test_every_table_entry_resolves_to_a_known_button(self):
        from ovb_rc003 import device_profile

        for vk, button in raw_input_windows.KEYBOARD_VK_TO_BUTTON.items():
            self.assertIn(button, device_profile.ALL_BUTTON_IDS, msg=f"vk={vk:#x}")


class HidBodyTests(unittest.TestCase):
    def test_single_report_press_emits_event(self):
        rec = RecordingListener()
        rec.listener._handle_hid_body(_rawhid_body([_hid_report([0x0028])]))
        self.assertEqual(rec.events, [("ok", True)])

    def test_release_emitted_when_usage_disappears(self):
        rec = RecordingListener()
        rec.listener._handle_hid_body(_rawhid_body([_hid_report([0x0028])]))
        rec.listener._handle_hid_body(_rawhid_body([_hid_report([])]))
        self.assertEqual(rec.events, [("ok", True), ("ok", False)])

    def test_malformed_rawhid_body_is_ignored_without_raising(self):
        rec = RecordingListener()
        rec.listener._handle_hid_body(b"\x00\x00")
        self.assertEqual(rec.events, [])

    def test_multiple_reports_in_one_body_both_processed(self):
        rec = RecordingListener()
        rec.listener._handle_hid_body(
            _rawhid_body([_hid_report([0x0028]), _hid_report([0x0028, 0x0052])])
        )
        self.assertEqual(rec.events, [("ok", True), ("up", True)])

    def test_real_rc003_mic_usage_f5_emits_mic_press(self):
        rec = RecordingListener()
        rec.listener._handle_hid_body(_rawhid_body([_hid_report([0x003E])]))
        self.assertEqual(rec.events, [("mic", True)])

    def test_keyboard_and_hid_sources_share_one_logical_edge(self):
        rec = RecordingListener()
        # The same physical Up key may be surfaced once as a translated
        # keyboard event and once as a raw HID usage.  They must not invoke
        # the mapped action twice, and release only after both sources clear.
        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYDOWN))
        rec.listener._handle_hid_body(_rawhid_body([_hid_report([0x0052])]))
        self.assertEqual(rec.events, [("up", True)])

        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x26, WM_KEYUP))
        self.assertEqual(rec.events, [("up", True)])

        rec.listener._handle_hid_body(_rawhid_body([_hid_report([])]))
        self.assertEqual(rec.events, [("up", True), ("up", False)])


class StopWithoutStartTests(unittest.TestCase):
    """stop() must be safe to call, and must release stuck buttons, even
    though start() (which touches ctypes/ a real window) was never called -
    self._hwnd stays None, so stop()'s ctypes branch is skipped, exercising
    only pure Python cleanup logic.
    """

    def test_stop_releases_stuck_hid_usages(self):
        rec = RecordingListener()
        rec.listener._handle_hid_body(_rawhid_body([_hid_report([0x0028, 0x0052])]))
        rec.events.clear()
        rec.listener.stop()
        self.assertEqual(set(rec.events), {("ok", False), ("up", False)})

    def test_stop_releases_stuck_keyboard_buttons(self):
        rec = RecordingListener()
        rec.listener._handle_keyboard_body(_rawkeyboard_body(0x27, WM_KEYDOWN))
        rec.events.clear()
        rec.listener.stop()
        self.assertEqual(rec.events, [("right", False)])

    def test_stop_is_a_no_op_when_nothing_is_active(self):
        rec = RecordingListener()
        rec.listener.stop()
        self.assertEqual(rec.events, [])

    def test_is_running_is_false_before_start(self):
        rec = RecordingListener()
        self.assertFalse(rec.listener.is_running)


class StartTimeoutInjectionTests(unittest.TestCase):
    """XRBM-018 RETRY 1 P2 #5: exercises start()'s timeout/fail-closed path
    via the ``_run_target`` injection seam (the same dependency-injection
    pattern win32_input.py's ``_sender`` already uses), rather than racing
    ``start_timeout=0.0`` against how fast a real window/thread would start
    on an actual Windows machine - a race that can flip either way depending
    on OS scheduling. This runs on every OS: the injected target never
    touches ctypes/a real window/``ctypes.windll`` at all, so it also never
    needs the Windows-only skip guard.
    """

    def test_a_target_that_never_signals_ready_times_out_deterministically(self):
        rec = RecordingListener()

        def _blocked_target():
            # Never calls self._ready_event.set() - the timeout below is
            # therefore guaranteed to fire, not a race against real work.
            # Polls _stop_event (which _abandon_failed_start() sets first
            # thing) so this test doesn't have to wait out the full
            # stop-join timeout once start() gives up - see
            # ThreadNeverStopsHonestyTests below for that scenario.
            while not rec.listener._stop_event.wait(timeout=0.01):
                pass

        with self.assertRaises(raw_input_windows.RawInputUnavailableError):
            rec.listener.start(
                "some-device-path", start_timeout=0.05, _run_target=_blocked_target
            )
        self.assertFalse(rec.listener.is_running)


class ThreadNeverStopsHonestyTests(unittest.TestCase):
    """XRBM-018 RETRY 1 P1 #2: a timed join that does NOT actually stop the
    background thread must never be reported as "stopped" - is_running must
    keep telling the truth, and a subsequent start() must fail closed
    instead of silently orphaning the still-running thread.
    """

    def test_abandon_after_failed_start_does_not_hide_a_thread_that_wont_stop(self):
        rec = RecordingListener()
        release = threading.Event()

        def _truly_stuck_target():
            # Deliberately ignores _stop_event entirely, unlike the target
            # above - simulates a thread that genuinely will not exit
            # within the join timeout (e.g. blocked deep inside a real
            # Win32 call in production), which is exactly the scenario
            # is_running must not lie about.
            release.wait()

        with self.assertRaises(raw_input_windows.RawInputUnavailableError):
            rec.listener.start(
                "some-device-path", start_timeout=0.05, _run_target=_truly_stuck_target
            )

        # Honest state: the thread really is still alive, so is_running
        # must say so instead of pretending the listener stopped.
        self.assertTrue(rec.listener.is_running)
        self.assertIsNotNone(rec.listener._thread)

        # start() while already (still) running must fail closed instead of
        # silently overwriting self._thread and orphaning the stuck one.
        with self.assertRaises(raw_input_windows.RawInputUnavailableError):
            rec.listener.start("some-other-device-path")

        release.set()  # let the stuck thread exit so it doesn't leak
        rec.listener._thread.join(timeout=2.0)
        self.assertFalse(rec.listener._thread.is_alive())


if __name__ == "__main__":
    unittest.main()
