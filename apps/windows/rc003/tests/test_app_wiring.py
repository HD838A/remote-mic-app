"""App-wiring/thread-safety tests for app.py's RC003App (XRBM-018 DoD 4).

``RC003App.__init__`` is safe to construct off Windows: config/hotkey/
voice-controller/supervisor setup is pure Python, and the real Win32/WinRT
calls only happen inside ``_connect_once()``/the HID listener, which these
tests never call. Constructing a real ``RC003App`` and substituting its
BLE-session/playback collaborators with lightweight recorders lets these
tests exercise the actual wiring DECISIONS app.py makes - host hotkey
failure suppresses MIC_OPEN, playback write failure fails closed and
requests a reconnect, and that request happens correctly from a real
worker thread - without any Windows API, matching this project's existing
"test contracts, not implementation-mirroring fakes" approach.

The host-hotkey-unavailable case doesn't even need mocking: off Windows,
win32_input.py's ``_require_windows()`` genuinely raises
``Win32InputUnavailableError`` on every call, so it exercises the exact
"hotkey failed to deliver" branch app.py must fail closed on - not a stand-
in for it.
"""

import asyncio
import logging
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from ovb_rc003 import app as app_module
from ovb_rc003 import config, key_mapping, logging_setup, win32_input
from ovb_rc003.atvv_session import AudioStopped


def _run(coro):
    # Explicitly closing the loop (XRBM-018 review round 2 evidence: a
    # ResourceWarning for an unclosed test event loop) rather than letting
    # it be garbage-collected.
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


class _FakeBleSession:
    def __init__(self, close_raises=False):
        self.mic_open_calls = 0
        self.close_raises = close_raises
        self.close_calls = 0

    def send_mic_open_threadsafe(self):
        self.mic_open_calls += 1

    async def close(self):
        self.close_calls += 1
        if self.close_raises:
            raise RuntimeError("simulated BLE worker thread that did not stop")


class _FakeHidListener:
    def __init__(self, stop_raises=False):
        self.stop_raises = stop_raises
        self.stop_calls = 0

    def stop(self):
        self.stop_calls += 1
        if self.stop_raises:
            raise RuntimeError("simulated Raw Input listener thread that did not stop")


class _FakePlaybackSink:
    def __init__(self, fail_write=False, close_raises=False):
        self.fail_write = fail_write
        self.close_raises = close_raises
        self.write_calls = []
        self.closed = False
        self.close_calls = 0

    def write(self, samples):
        self.write_calls.append(samples)
        if self.fail_write:
            raise OSError("simulated PortAudio write failure")

    def close(self):
        self.close_calls += 1
        if self.close_raises:
            raise RuntimeError("simulated PortAudio stream that did not close")
        self.closed = True


class _FakeHidListenerForFailedStart:
    """XRBM-019 review round 1 P1 #3: a fake standing in for
    RawInputButtonListener itself (not just its ``start()`` outcome), so
    ``_start_hid_listener()`` can be exercised end-to-end off Windows -
    ``is_running`` is the source of truth a failed ``start()`` must consult
    before deciding whether to keep or discard the owner reference.
    """

    def __init__(self, is_running_after_failed_start):
        self._is_running_after_failed_start = is_running_after_failed_start
        self.start_calls = 0

    @property
    def is_running(self):
        return self._is_running_after_failed_start

    def start(self, device_path):
        self.start_calls += 1
        raise app_module.raw_input_windows.RawInputUnavailableError("simulated failed start")

    def stop(self):
        pass


def _build_app(tmp_root: Path) -> "app_module.RC003App":
    # Redirect config_root (and therefore logging_setup's log directory) at
    # a throwaway temp directory instead of the real machine's config/log
    # location - RC003App.__init__ always calls config.config_root()/
    # logging_setup.get_logger(), neither of which touch any Windows API.
    original = config.config_root
    config.config_root = lambda: tmp_root
    try:
        return app_module.RC003App()
    finally:
        config.config_root = original


def _build_app_with_owned_loop(tmp_root: Path):
    """Like _build_app(), but explicitly creates a fresh event loop and sets
    it as this thread's current loop before constructing the app (XRBM-026).

    RC003App.__init__ builds a ConnectionSupervisor, whose __init__ captures
    ``loop or asyncio.get_event_loop()`` (connection_supervisor.py) - called
    here synchronously, off any running loop. Without an owned loop already
    set, that would silently create-and-cache this thread's implicit default
    loop the first time any test builds an RC003App - a loop nothing then
    ever closes (see EventLoopOwnershipRegressionTests for the exact red
    evidence this reproduces and fixes). Returns ``(app, loop)``; the caller
    owns ``loop`` and must ``asyncio.set_event_loop(None)`` then
    ``loop.close()`` it when done - exactly mirroring the real app's own
    ``asyncio.run(_run())`` construction, which owns and closes its loop too.
    """

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    app = _build_app(tmp_root)
    return app, loop


class _AppWiringTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # XRBM-026 red evidence (real Windows run 29644660267): 425 tests
        # passed, then the process printed an ignored "unclosed event loop"
        # ResourceWarning for a ProactorEventLoop plus two unclosed self-pipe
        # sockets - AFTER unittest's own summary, so -W error::ResourceWarning
        # never sees it and the step still exits 0 (a ResourceWarning-turned-
        # exception raised inside a __del__/finalizer is unraisable; Python
        # can only print it via sys.unraisablehook, never let it change an
        # already-computed exit code - see EventLoopOwnershipRegressionTests
        # below for a deterministic, isolated-subprocess reproduction).
        # _build_app_with_owned_loop() above threads a per-test owned loop
        # into ConnectionSupervisor instead - never the ambient, never-closed
        # default the old bare _build_app() call left behind.
        self.app, self._loop = _build_app_with_owned_loop(Path(self._tmp.name))
        self.app._playback = _FakePlaybackSink()
        self.app._ble_session = _FakeBleSession()

    def tearDown(self):
        # XRBM-023: logging_setup.get_logger() configures its FileHandler
        # exactly once per process (module-global ``_configured``) and never
        # closes it - correct for a real long-running app, but in this suite
        # it leaves an open handle inside THIS test's temp directory. Windows
        # (unlike POSIX, where you can unlink a file while a handle is still
        # open on it) refuses to delete a directory containing an open file
        # handle, so ``self._tmp.cleanup()`` below would raise on Windows
        # once any prior test in this class had already configured the
        # logger. Close/remove the handler and reset the one-time-config
        # flag first so every test starts and ends with no logging state
        # leaked into the next one.
        logger = logging.getLogger(logging_setup.LOGGER_NAME)
        for handler in list(logger.handlers):
            handler.close()
            logger.removeHandler(handler)
        logging_setup._configured = False
        self._tmp.cleanup()
        # XRBM-026: close the loop this test owns (see setUp()) and detach
        # it as the thread's current loop, so its own eventual __del__ finds
        # is_closed() already True and stays silent - and so the NEXT test's
        # setUp() cannot mistake this now-closed loop for a live ambient one.
        asyncio.set_event_loop(None)
        self._loop.close()


class HostHotkeyFailureSuppressesMicOpenTests(_AppWiringTestCase):
    """XRBM-014 review round 2 P1 #6: MIC_OPEN must never be sent unless the
    host hotkey actually, fully delivered.
    """

    @unittest.skipIf(
        sys.platform == "win32",
        "only exercises the off-Windows win32_input._require_windows() gate "
        "(no injected sender); on a real Windows runner the real SendInput "
        "call fully delivers instead, so this would assert the opposite of "
        "what actually happens there (XRBM-023) - "
        "test_hotkey_partial_delivery_suppresses_mic_open below covers the "
        "same suppression contract cross-platform via dependency injection",
    )
    def test_hotkey_unavailable_off_windows_suppresses_mic_open(self):
        self.app._handle_mic_button_pressed()

        self.assertEqual(self.app._ble_session.mic_open_calls, 0)
        self.assertFalse(self.app._voice.active)

    def test_hotkey_partial_delivery_suppresses_mic_open(self):
        def _raise(tokens):
            raise OSError("simulated partial SendInput delivery")

        original = win32_input.send_key_combo_tap
        win32_input.send_key_combo_tap = _raise
        try:
            self.app._handle_mic_button_pressed()
        finally:
            win32_input.send_key_combo_tap = original

        self.assertEqual(self.app._ble_session.mic_open_calls, 0)
        self.assertFalse(self.app._voice.active)

    def test_hotkey_success_sends_mic_open(self):
        original = win32_input.send_key_combo_tap
        win32_input.send_key_combo_tap = lambda tokens: None
        try:
            self.app._handle_mic_button_pressed()
        finally:
            win32_input.send_key_combo_tap = original

        self.assertEqual(self.app._ble_session.mic_open_calls, 1)
        self.assertTrue(self.app._voice.active)

    def test_no_usable_endpoint_suppresses_hotkey_and_mic_open(self):
        self.app._playback = None
        self.app._config["output_endpoint_name"] = "some endpoint that is not open"

        hotkey_calls = []
        original = win32_input.send_key_combo_tap
        win32_input.send_key_combo_tap = lambda tokens: hotkey_calls.append(tokens)
        try:
            self.app._handle_mic_button_pressed()
        finally:
            win32_input.send_key_combo_tap = original

        self.assertEqual(hotkey_calls, [])
        self.assertEqual(self.app._ble_session.mic_open_calls, 0)

    def test_windows_actually_delivers_the_hotkey_unlike_the_off_windows_case(self):
        """Regression for XRBM-023 outcome 9: on a real Windows runner,
        win32_input._require_windows() does NOT raise, so the un-mocked
        send_key_combo_tap() call inside _handle_mic_button_pressed()
        reaches the real SendInput batch sender - simulated here as a full
        delivery - and MIC_OPEN IS sent. This is exactly why the skipped
        test_hotkey_unavailable_off_windows_suppresses_mic_open above would
        have failed (not errored) on the real Windows CI runner: it asserts
        the opposite of what actually happens there.
        """
        original_platform = sys.platform
        original_sender = win32_input._real_send_input_batch
        sys.platform = "win32"
        win32_input._real_send_input_batch = lambda events: len(events)
        try:
            self.app._handle_mic_button_pressed()
        finally:
            sys.platform = original_platform
            win32_input._real_send_input_batch = original_sender

        self.assertEqual(self.app._ble_session.mic_open_calls, 1)
        self.assertTrue(self.app._voice.active)


class PlaybackWriteFailureTests(_AppWiringTestCase):
    """XRBM-014 review round 2 P1 #6: a playback write failure must fail
    closed (discard the sink) and request a reconnect, not log indefinitely
    while the device keeps streaming.
    """

    def test_write_failure_closes_sink_and_requests_reconnect(self):
        sink = _FakePlaybackSink(fail_write=True)
        self.app._playback = sink
        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(1)

        self.app._on_pcm_frame([0, 0])

        self.assertTrue(sink.closed)
        self.assertIsNone(self.app._playback)
        self.assertEqual(reconnect_calls, [1])

    def test_write_success_does_not_touch_playback_or_reconnect(self):
        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(1)

        self.app._on_pcm_frame([0, 0])

        self.assertIsNotNone(self.app._playback)
        self.assertEqual(reconnect_calls, [])

    def test_no_playback_open_is_a_silent_no_op(self):
        self.app._playback = None
        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(1)

        self.app._on_pcm_frame([0, 0])  # must not raise

        self.assertEqual(reconnect_calls, [])


class CrossThreadReconnectTests(_AppWiringTestCase):
    """ble_transport_winrt.py invokes _on_pcm_frame on its own dedicated
    worker thread, never the event-loop thread - a playback failure there
    must still correctly reach request_reconnect().
    """

    def test_on_pcm_frame_failure_from_a_real_worker_thread_requests_reconnect(self):
        self.app._playback = _FakePlaybackSink(fail_write=True)
        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(
            threading.current_thread()
        )

        worker = threading.Thread(target=self.app._on_pcm_frame, args=([0, 0],))
        worker.start()
        worker.join(timeout=2.0)

        self.assertEqual(len(reconnect_calls), 1)
        self.assertNotEqual(reconnect_calls[0], threading.main_thread())


class CleanupOwnershipTests(_AppWiringTestCase):
    """XRBM-019 P1 #2/#5: _cleanup_once() must attempt every one of the
    four steps (voice, HID, BLE, playback) regardless of any single step's
    outcome, must retain (not clear) the owner reference for a step whose
    resource reports it is still alive, and must aggregate and raise once
    every step has been attempted - so ConnectionSupervisor.run_forever()
    fails the whole retry loop closed instead of starting a fresh connect()
    generation over resources that might still be live.
    """

    def test_cleanup_clears_every_owner_on_full_success(self):
        self.app._hid_listener = _FakeHidListener()
        self.app._ble_session = _FakeBleSession()
        self.app._playback = _FakePlaybackSink()

        _run(self.app._cleanup_once())  # must not raise

        self.assertIsNone(self.app._hid_listener)
        self.assertIsNone(self.app._ble_session)
        self.assertIsNone(self.app._playback)

    def test_hid_stop_failure_retains_hid_owner_but_still_completes_ble_and_playback(self):
        hid = _FakeHidListener(stop_raises=True)
        ble = _FakeBleSession()
        playback = _FakePlaybackSink()
        self.app._hid_listener = hid
        self.app._ble_session = ble
        self.app._playback = playback

        with self.assertRaises(app_module.CleanupIncompleteError) as ctx:
            _run(self.app._cleanup_once())
        self.assertIn("Raw Input listener", str(ctx.exception))

        # Retained, not hidden:
        self.assertIs(self.app._hid_listener, hid)
        # Every other step still ran and cleared normally:
        self.assertEqual(ble.close_calls, 1)
        self.assertIsNone(self.app._ble_session)
        self.assertTrue(playback.closed)
        self.assertIsNone(self.app._playback)

    def test_ble_close_failure_retains_ble_owner_but_still_completes_hid_and_playback(self):
        hid = _FakeHidListener()
        ble = _FakeBleSession(close_raises=True)
        playback = _FakePlaybackSink()
        self.app._hid_listener = hid
        self.app._ble_session = ble
        self.app._playback = playback

        with self.assertRaises(app_module.CleanupIncompleteError) as ctx:
            _run(self.app._cleanup_once())
        self.assertIn("BLE session", str(ctx.exception))

        # Retained, not hidden:
        self.assertIs(self.app._ble_session, ble)
        self.assertEqual(ble.close_calls, 1)
        # Every other step still ran and cleared normally:
        self.assertEqual(hid.stop_calls, 1)
        self.assertIsNone(self.app._hid_listener)
        self.assertTrue(playback.closed)
        self.assertIsNone(self.app._playback)

    def test_both_hid_and_ble_failures_retain_both_owners_and_aggregate(self):
        hid = _FakeHidListener(stop_raises=True)
        ble = _FakeBleSession(close_raises=True)
        playback = _FakePlaybackSink()
        self.app._hid_listener = hid
        self.app._ble_session = ble
        self.app._playback = playback

        with self.assertRaises(app_module.CleanupIncompleteError) as ctx:
            _run(self.app._cleanup_once())
        message = str(ctx.exception)
        self.assertIn("Raw Input listener", message)
        self.assertIn("BLE session", message)

        self.assertIs(self.app._hid_listener, hid)
        self.assertIs(self.app._ble_session, ble)
        # Playback is unconditionally attempted/cleared even though both
        # owner-retaining steps failed.
        self.assertTrue(playback.closed)
        self.assertIsNone(self.app._playback)

    def test_cleanup_failure_propagates_out_of_run_forever_without_a_second_connect(self):
        """End-to-end: wires _cleanup_once() as the real
        ConnectionSupervisor.cleanup callable and proves a retained-owner
        failure ends run_forever() entirely - no second connect()
        generation is ever attempted over the still-live HID listener.
        """

        hid = _FakeHidListener(stop_raises=True)
        self.app._hid_listener = hid
        self.app._ble_session = _FakeBleSession()
        self.app._playback = _FakePlaybackSink()

        connect_calls = []

        async def scenario():
            # ConnectionSupervisor.__init__ captured its ``_loop`` at
            # construction time (setUp() built self.app synchronously,
            # off any running loop - see connection_supervisor.py's module
            # docstring). Rebind it to the loop this coroutine is actually
            # running on before calling request_reconnect(), exactly as
            # the real app does by constructing everything inside one
            # asyncio.run(); otherwise request_reconnect()'s
            # call_soon_threadsafe hop lands on a loop nothing drives and
            # run_forever() hangs forever on _disconnect_event.wait()
            # (XRBM-019 review round 1 P1 #1 - the prior version of this
            # test only "passed" because that loop mismatch raised into
            # the cleanup path, never proving the intended behavior).
            self.app._supervisor._loop = asyncio.get_running_loop()
            self.app._supervisor._connect = lambda: _record_connect(connect_calls)

            task = asyncio.ensure_future(self.app._supervisor.run_forever())
            # Let run_forever() run its first connect() and reach the
            # disconnect_event.wait() suspension point before we end the
            # attempt explicitly - request_reconnect() is what a real BLE
            # disconnect/protocol-error/playback-failure callback would
            # call; nothing here relies on an accidental cross-loop
            # exception to unblock the wait.
            await asyncio.sleep(0)
            self.app._supervisor.request_reconnect()

            # Bounded so a real regression (e.g. cleanup ownership lost
            # again, or the wait never unblocking) fails the test instead
            # of hanging the whole suite.
            with self.assertRaises(app_module.CleanupIncompleteError):
                await asyncio.wait_for(task, timeout=5.0)

        _run(scenario())

        self.assertEqual(connect_calls, [1])  # only the first attempt ever ran
        self.assertEqual(self.app._supervisor.attempt_count, 1)
        # Still retained after the whole supervisor loop ended:
        self.assertIs(self.app._hid_listener, hid)


class StartHidListenerOwnershipTests(_AppWiringTestCase):
    """XRBM-019 review round 1 P1 #3: RawInputButtonListener intentionally
    retains its thread/window when its own bounded failed-start cleanup
    cannot stop them (see raw_input_windows.py's ``_abandon_failed_start``).
    ``_start_hid_listener()`` must consult ``is_running`` rather than
    unconditionally clearing ``self._hid_listener`` to ``None`` on any
    failed ``start()`` - doing so would lose the owner and let a later
    ``_connect_once()`` generation start a second listener over a still-
    live one (the exact defect class XRBM-019 exists to eliminate; see
    also CleanupOwnershipTests' end-to-end supervisor test above, which
    proves no second connect() generation is ever reached once cleanup
    itself fails on a retained owner).
    """

    def _patch_device_discovery(self, fake_listener):
        original_enumerate = app_module.raw_input_windows.enumerate_matching_device_paths
        original_select = app_module.hid_identity.select_single_device_path
        original_listener_cls = app_module.raw_input_windows.RawInputButtonListener
        app_module.raw_input_windows.enumerate_matching_device_paths = lambda: ["fake-path"]
        app_module.hid_identity.select_single_device_path = lambda paths: paths[0]
        app_module.raw_input_windows.RawInputButtonListener = lambda callback: fake_listener

        def _restore():
            app_module.raw_input_windows.enumerate_matching_device_paths = original_enumerate
            app_module.hid_identity.select_single_device_path = original_select
            app_module.raw_input_windows.RawInputButtonListener = original_listener_cls

        return _restore

    def test_a_failed_start_that_is_still_running_retains_the_owner_and_raises(self):
        fake_listener = _FakeHidListenerForFailedStart(is_running_after_failed_start=True)
        restore = self._patch_device_discovery(fake_listener)
        try:
            with self.assertRaises(app_module.raw_input_windows.RawInputUnavailableError):
                self.app._start_hid_listener()
        finally:
            restore()

        self.assertIs(self.app._hid_listener, fake_listener)
        self.assertEqual(fake_listener.start_calls, 1)

    def test_a_failed_start_confirmed_stopped_clears_the_owner(self):
        fake_listener = _FakeHidListenerForFailedStart(is_running_after_failed_start=False)
        restore = self._patch_device_discovery(fake_listener)
        try:
            self.app._start_hid_listener()  # must not raise
        finally:
            restore()

        self.assertIsNone(self.app._hid_listener)
        self.assertEqual(fake_listener.start_calls, 1)


class VoiceCleanupFailurePreservesPendingStateTests(_AppWiringTestCase):
    """XRBM-019 review round 1 P1 #4: reset()/on_audio_stopped() clear
    VoiceController's owed state before the caller has confirmed the
    closing action (HOLD's KEY_UP, TOGGLE's closing TAP) actually
    delivered. A failed delivery must not be recorded as a clean close -
    _cleanup_once() must restore the pending state and aggregate the
    failure (after still attempting HID/BLE/playback), and the AudioStopped
    control-event path must restore the pending state and request a
    reconnect instead of silently treating the close as successful.
    """

    def test_cleanup_once_preserves_hold_mode_key_up_on_failure(self):
        self.app._voice.trigger_mode = key_mapping.VoiceTriggerMode.HOLD
        self.app._voice.on_mic_button_pressed()
        self.assertTrue(self.app._voice.holding)

        def _raise(tokens):
            raise OSError("simulated key-up delivery failure")

        original = win32_input.send_key_combo_up
        win32_input.send_key_combo_up = _raise
        try:
            with self.assertRaises(app_module.CleanupIncompleteError) as ctx:
                _run(self.app._cleanup_once())
        finally:
            win32_input.send_key_combo_up = original

        self.assertIn("voice hotkey", str(ctx.exception))
        # Restored, not left thinking the key-up landed:
        self.assertTrue(self.app._voice.holding)
        self.assertTrue(self.app._voice.active)

    def test_cleanup_once_preserves_toggle_mode_closing_tap_on_failure(self):
        self.app._voice.trigger_mode = key_mapping.VoiceTriggerMode.TOGGLE
        self.app._voice.on_mic_button_pressed()
        self.assertTrue(self.app._voice.active)

        def _raise(tokens):
            raise OSError("simulated closing-tap delivery failure")

        original = win32_input.send_key_combo_tap
        win32_input.send_key_combo_tap = _raise
        try:
            with self.assertRaises(app_module.CleanupIncompleteError) as ctx:
                _run(self.app._cleanup_once())
        finally:
            win32_input.send_key_combo_tap = original

        self.assertIn("voice hotkey", str(ctx.exception))
        self.assertTrue(self.app._voice.active)

    def test_audio_stopped_preserves_hold_mode_key_up_on_failure_and_reconnects(self):
        self.app._voice.trigger_mode = key_mapping.VoiceTriggerMode.HOLD
        self.app._voice.on_mic_button_pressed()

        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(1)

        def _raise(tokens):
            raise OSError("simulated key-up delivery failure")

        original = win32_input.send_key_combo_up
        win32_input.send_key_combo_up = _raise
        try:
            self.app._on_control_event(AudioStopped())
        finally:
            win32_input.send_key_combo_up = original

        self.assertTrue(self.app._voice.holding)
        self.assertEqual(reconnect_calls, [1])

    def test_audio_stopped_preserves_toggle_mode_closing_tap_on_failure_and_reconnects(self):
        self.app._voice.trigger_mode = key_mapping.VoiceTriggerMode.TOGGLE
        self.app._voice.on_mic_button_pressed()

        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(1)

        def _raise(tokens):
            raise OSError("simulated closing-tap delivery failure")

        original = win32_input.send_key_combo_tap
        win32_input.send_key_combo_tap = _raise
        try:
            self.app._on_control_event(AudioStopped())
        finally:
            win32_input.send_key_combo_tap = original

        self.assertTrue(self.app._voice.active)
        self.assertEqual(reconnect_calls, [1])


class PlaybackCleanupOwnershipTests(_AppWiringTestCase):
    """XRBM-019 review round 1 P1 #5: both _cleanup_once() and
    _on_pcm_frame() must retain (not discard) the playback sink owner when
    its own close() call fails - EndpointPlaybackSink owns a PortAudio
    stream, and clearing the reference would hide an incompletely closed
    resource and let a reconnect open a second sink over it.
    """

    def test_cleanup_once_retains_playback_owner_on_close_failure(self):
        sink = _FakePlaybackSink(close_raises=True)
        self.app._hid_listener = None
        self.app._ble_session = _FakeBleSession()
        self.app._playback = sink

        with self.assertRaises(app_module.CleanupIncompleteError) as ctx:
            _run(self.app._cleanup_once())
        self.assertIn("audio playback", str(ctx.exception))

        self.assertIs(self.app._playback, sink)
        self.assertEqual(sink.close_calls, 1)
        self.assertFalse(sink.closed)

    def test_on_pcm_frame_write_fail_then_close_raise_retains_owner(self):
        sink = _FakePlaybackSink(fail_write=True, close_raises=True)
        self.app._playback = sink
        reconnect_calls = []
        self.app._supervisor.request_reconnect = lambda: reconnect_calls.append(1)

        self.app._on_pcm_frame([0, 0])  # must not raise

        # Retained, not discarded - close() also failed:
        self.assertIs(self.app._playback, sink)
        self.assertEqual(sink.close_calls, 1)
        # Still fails closed via reconnect either way:
        self.assertEqual(reconnect_calls, [1])


class LoggingHandlerCleanupRegressionTests(unittest.TestCase):
    """Regression for XRBM-023 outcome 1: proves _AppWiringTestCase's
    tearDown fix (close/remove the FileHandler, reset ``_configured``)
    actually decouples one app build's logging handler from the next -
    the exact defect that made a real Windows CI runner's
    ``tempfile.TemporaryDirectory().cleanup()`` raise a PermissionError
    on the very first test the suite's discovery order ever runs
    (``CleanupOwnershipTests.test_ble_close_failure_retains_ble_owner_but_
    still_completes_hid_and_playback``): ``logging_setup.get_logger()``
    configures its FileHandler exactly once per process and never closes
    it, so without this cleanup the handle stays open inside that first
    test's temp directory for the rest of the run - and Windows, unlike
    POSIX, refuses to delete a directory containing a still-open handle.
    """

    def test_a_second_app_build_gets_its_own_fresh_handler_after_cleanup(self):
        tmp1 = tempfile.TemporaryDirectory()
        loop1 = None
        try:
            # _build_app_with_owned_loop() (not the bare _build_app()): this
            # test constructs RC003App synchronously, same as
            # _AppWiringTestCase.setUp() - see XRBM-026's
            # EventLoopOwnershipRegressionTests for why a bare
            # asyncio.get_event_loop() call here would leak too.
            _, loop1 = _build_app_with_owned_loop(Path(tmp1.name))
            logger = logging.getLogger(logging_setup.LOGGER_NAME)
            self.assertEqual(len(logger.handlers), 1)
            handler1 = logger.handlers[0]
            self.assertEqual(
                Path(handler1.baseFilename).parent, Path(tmp1.name) / "logs"
            )
            self.assertIsNotNone(handler1.stream)

            # Exactly what _AppWiringTestCase.tearDown now does.
            handler1.close()
            logger.removeHandler(handler1)
            logging_setup._configured = False

            self.assertIsNone(handler1.stream)
            self.assertEqual(logger.handlers, [])
        finally:
            asyncio.set_event_loop(None)
            if loop1 is not None:
                loop1.close()
            # Must not raise: on Windows this would be the PermissionError
            # from outcome 1 if the handle above were still open.
            tmp1.cleanup()

        tmp2 = tempfile.TemporaryDirectory()
        loop2 = None
        try:
            _, loop2 = _build_app_with_owned_loop(Path(tmp2.name))
            logger = logging.getLogger(logging_setup.LOGGER_NAME)
            self.assertEqual(len(logger.handlers), 1)
            handler2 = logger.handlers[0]
            self.assertIsNot(handler2, handler1)
            self.assertEqual(
                Path(handler2.baseFilename).parent, Path(tmp2.name) / "logs"
            )

            handler2.close()
            logger.removeHandler(handler2)
            logging_setup._configured = False
        finally:
            asyncio.set_event_loop(None)
            if loop2 is not None:
                loop2.close()
            tmp2.cleanup()


class EventLoopOwnershipRegressionTests(unittest.TestCase):
    """Regression for XRBM-026 red evidence (real Windows run 29644660267):
    425 tests passed ("OK (skipped=3)"), then the process printed an ignored
    "unclosed event loop" ResourceWarning for a ProactorEventLoop plus two
    unclosed self-pipe sockets - AFTER unittest's own summary, so
    -W error::ResourceWarning never saw it and the step still exited 0.

    Root cause: RC003App.__init__ builds a ConnectionSupervisor, whose
    __init__ captures ``loop or asyncio.get_event_loop()``
    (connection_supervisor.py). _build_app() runs synchronously in
    _AppWiringTestCase.setUp(), off any running loop - unlike the real app,
    which only ever constructs RC003App inside ``asyncio.run(_run())``
    (app.py), where get_event_loop() correctly returns asyncio.run()'s own
    loop. With no running loop and nothing set for this thread,
    asyncio.get_event_loop() silently creates and caches an implicit
    default loop - shared by every _AppWiringTestCase subclass's setUp() -
    that nothing in the old test suite ever closed.

    These tests prove both halves of the fix: (1) the fixed setUp()/
    tearDown() pattern threads a per-test OWNED loop into ConnectionSupervisor
    instead of that ambient default, and (2) deterministically forcing the
    exact condition real interpreter shutdown eventually creates (every
    strong reference to a loop dropped, including asyncio's own thread-local
    cache, then a GC pass) reproduces the red evidence exactly for the OLD
    pattern while the FIXED pattern never reproduces it - in an isolated
    subprocess, so this test process's own asyncio/event-loop state is never
    touched either way.
    """

    def test_build_app_under_the_fixed_setup_pattern_captures_the_owned_loop(self):
        tmp = tempfile.TemporaryDirectory()
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            app = _build_app(Path(tmp.name))
            self.assertIs(app._supervisor._loop, loop)
        finally:
            logger = logging.getLogger(logging_setup.LOGGER_NAME)
            for handler in list(logger.handlers):
                handler.close()
                logger.removeHandler(handler)
            logging_setup._configured = False
            tmp.cleanup()
            asyncio.set_event_loop(None)
            loop.close()

        self.assertTrue(loop.is_closed())

    def test_unowned_default_loop_pattern_reproduces_the_exact_red_evidence(self):
        # The OLD (pre-fix) construction pattern - asyncio.get_event_loop()
        # with no owned/running loop - run in an isolated subprocess, then
        # forced through the exact condition real interpreter shutdown
        # eventually creates. This deterministically reproduces the red
        # evidence's exact shape: one "unclosed event loop" plus two
        # "unclosed <socket.socket" warnings, both printed as unraisable
        # exceptions from inside __del__, while the script's own exit code
        # still reports 0 - proving why -W error::ResourceWarning alone
        # could never have caught it.
        script = (
            "import asyncio, gc\n"
            "class _Sup:\n"
            "    def __init__(self):\n"
            "        self._loop = asyncio.get_event_loop()\n"
            "objs = [_Sup() for _ in range(3)]\n"
            "assert all(o._loop is objs[0]._loop for o in objs)\n"
            "del objs\n"
            "asyncio.get_event_loop_policy()._local._loop = None\n"
            "gc.collect()\n"
            "print('done')\n"
        )
        result = subprocess.run(
            [sys.executable, "-W", "error::ResourceWarning", "-c", script],
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("unclosed event loop", result.stderr)
        self.assertEqual(result.stderr.count("unclosed <socket.socket"), 2)

    def test_owned_and_closed_loop_pattern_never_reproduces_the_red_evidence(self):
        # Same forced-shutdown stress as the test above, but using the FIXED
        # pattern (_AppWiringTestCase.setUp()/tearDown()'s own approach: a
        # fresh loop is created, set current, then explicitly closed)
        # instead of the bare default-loop getter - proving the fix, not
        # just the bug.
        script = (
            "import asyncio, gc\n"
            "class _Sup:\n"
            "    def __init__(self, loop=None):\n"
            "        self._loop = loop or asyncio.get_event_loop()\n"
            "def _build_owned():\n"
            "    loop = asyncio.new_event_loop()\n"
            "    asyncio.set_event_loop(loop)\n"
            "    sup = _Sup()\n"
            "    asyncio.set_event_loop(None)\n"
            "    loop.close()\n"
            "    return sup\n"
            "objs = [_build_owned() for _ in range(3)]\n"
            "del objs\n"
            "asyncio.get_event_loop_policy()._local._loop = None\n"
            "gc.collect()\n"
            "print('done')\n"
        )
        result = subprocess.run(
            [sys.executable, "-W", "error::ResourceWarning", "-c", script],
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0)
        self.assertNotIn("ResourceWarning", result.stderr)
        self.assertNotIn("unclosed", result.stderr)


async def _record_connect(connect_calls):
    connect_calls.append(1)


if __name__ == "__main__":
    unittest.main()
