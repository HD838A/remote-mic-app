"""Contract tests for ble_transport_winrt.py against an in-memory fake of
the locked winrt-Windows.*==3.2.1 projection surface (see
tests/fakes/fake_winrt.py), fixed after XRBM-014 review RETRY P1 #1 and
again after review round 2 P1 #2:

- discovery uses BluetoothLEDevice.get_device_selector_from_pairing_state(True)
  passed to DeviceInformation.find_all_async_aqs_filter(selector) - not
  GattDeviceService.get_device_selector_from_uuid(), which enumerates a
  different (GATT service-instance) WinRT ID domain than
  BluetoothLEDevice.from_id_async() requires;
- from_id_async() rejects a GATT service-instance-domain ID outright (see
  RejectsWrongIdDomainTests below);
- every GATT UUID is a real uuid.UUID by the time it reaches the fake;
- write_value_with_result_async's returned object's .status is compared,
  not the object itself;
- add_value_changed/add_connection_status_changed tokens are exactly what
  gets passed back to remove_value_changed/remove_connection_status_changed
  (the fakes themselves assert this - a wrong token raises AssertionError);
- CCCD is written back to NONE and the service/device are closed on cleanup;
- a real BluetoothConnectionStatus.DISCONNECTED callback is observed.

This is not a substitute for running against a live WinRT runtime and real
hardware (still 待核验 - see this package's top-level README.md "Known gaps"
section for the full list of what remains unverified on real hardware), but it
does prove the module's own call shape is internally consistent and matches
the documented 3.2.1 signatures as closely as this project can verify
without one.
"""

import asyncio
import time
import unittest
import uuid

from ovb_rc003 import atvv_protocol as proto
from ovb_rc003 import atvv_session
from ovb_rc003 import identity
from ovb_rc003.ble_transport_winrt import RC003BleSession, discover_candidates

from .fakes.fake_winrt import FakeWinRTEnvironment, gatt_service_instance_id


def _run(coro):
    # Explicitly closing the loop (XRBM-014 review round 2 evidence: a
    # ResourceWarning for an unclosed test event loop) rather than letting
    # it be garbage-collected.
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _wait_until(predicate, timeout=2.0, interval=0.02):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


async def _async_wait_until(predicate, timeout=2.0, interval=0.01):
    """Like _wait_until, but yields control back to the event loop between
    checks (via a real ``asyncio.sleep``) instead of blocking the whole
    thread - required for anything that depends on the event loop itself
    processing a ``call_soon_threadsafe``-scheduled callback (as
    send_mic_open_threadsafe() does), which a synchronous busy-wait would
    starve.
    """

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        await asyncio.sleep(interval)
    return predicate()


def _caps_payload(codec_bit=0x02, frame_size=4):
    return bytes((0x0B, 0x01, 0x00, codec_bit, 0x03)) + frame_size.to_bytes(2, "big")


class DiscoverCandidatesTests(unittest.TestCase):
    def test_uses_the_paired_ble_device_selector_and_returns_a_candidate(self):
        env = FakeWinRTEnvironment(name="MI RC")
        winrt = env.build_winrt_modules()

        candidates = _run(discover_candidates(winrt=winrt))

        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0].name, "MI RC")
        self.assertIs(candidates[0].handle, env.discovered_info)
        # The candidate's handle.id must be the BLE-device-domain ID this
        # environment's paired-device factory would accept - not a GATT
        # service-instance ID (see RejectsWrongIdDomainTests below).
        self.assertEqual(candidates[0].handle.id, env.device_id)

    def test_candidate_is_selectable_via_identity(self):
        env = FakeWinRTEnvironment(name="Xiaomi Bluetooth Remote 2 Pro")
        winrt = env.build_winrt_modules()

        candidates = _run(discover_candidates(winrt=winrt))
        chosen = identity.select_single_candidate(candidates)
        self.assertEqual(chosen.name, "Xiaomi Bluetooth Remote 2 Pro")


class RejectsWrongIdDomainTests(unittest.TestCase):
    """XRBM-018 DoD 2: "the fake no longer accepts a GATT service id as a
    BLE device ID" - proving the two WinRT ID domains XRBM-014 review round
    2 P1 #2 identified are actually distinct in this test double, not just
    in the production code's comments.
    """

    def test_from_id_async_rejects_a_gatt_service_instance_id(self):
        env = FakeWinRTEnvironment()
        winrt = env.build_winrt_modules()
        wrong_domain_id = gatt_service_instance_id(uuid.UUID(proto.VOICE_SERVICE_UUID))
        self.assertNotEqual(wrong_domain_id, env.device_id)

        async def scenario():
            return await winrt.bluetooth_le_device.from_id_async(wrong_domain_id)

        with self.assertRaises(AssertionError):
            _run(scenario())

    def test_from_id_async_accepts_the_real_paired_device_id(self):
        env = FakeWinRTEnvironment()
        winrt = env.build_winrt_modules()

        async def scenario():
            return await winrt.bluetooth_le_device.from_id_async(env.device_id)

        device = _run(scenario())
        self.assertIs(device, env.device)


class ConnectTests(unittest.TestCase):
    def _connect_session(self, env, **kwargs):
        winrt = env.build_winrt_modules()
        session = RC003BleSession(winrt=winrt, loop=asyncio.get_event_loop(), **kwargs)
        candidate = identity.RC003Candidate(
            name=env.name, hardware_match=False, handle=env.discovered_info
        )
        return session, candidate

    def test_connect_subscribes_notify_on_audio_and_control(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            session, candidate = self._connect_session(
                env, on_pcm_frame=lambda samples: None
            )
            await session.connect(candidate)
            return session

        session = _run(scenario())
        try:
            self.assertIn(1, env.audio_characteristic.cccd_history)  # NOTIFY == 1
            self.assertIn(1, env.control_characteristic.cccd_history)
        finally:
            _run(session.close())

    def test_connect_sends_get_capabilities_to_tx(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            session, candidate = self._connect_session(
                env, on_pcm_frame=lambda samples: None
            )
            await session.connect(candidate)
            return session

        session = _run(scenario())
        try:
            self.assertEqual(env.tx_characteristic.write_history[-1], proto.GET_CAPABILITIES_V10)
        finally:
            _run(session.close())

    def test_connect_subscribes_to_connection_status(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            session, candidate = self._connect_session(
                env, on_pcm_frame=lambda samples: None
            )
            await session.connect(candidate)
            return session

        session = _run(scenario())
        try:
            self.assertEqual(len(env.device._connection_status_handlers), 1)
        finally:
            _run(session.close())


class NotificationProcessingTests(unittest.TestCase):
    def test_caps_then_audio_start_then_audio_notification_yields_pcm(self):
        env = FakeWinRTEnvironment()
        pcm_batches = []
        control_events = []

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=pcm_batches.append,
                on_control_event=control_events.append,
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)
            return session

        session = _run(scenario())
        try:
            env.control_characteristic.fire(_caps_payload(frame_size=2))
            env.control_characteristic.fire(bytes((proto.OPCODE_AUDIO_START, 0, 0, 1)))
            env.audio_characteristic.fire(bytes((0x00, 0x00)))  # 2 zero bytes -> 4 samples

            self.assertTrue(_wait_until(lambda: len(pcm_batches) > 0))
            self.assertTrue(
                _wait_until(
                    lambda: any(
                        isinstance(e, atvv_session.AudioStarted) for e in control_events
                    )
                )
            )
        finally:
            _run(session.close())

    def test_malformed_control_payload_calls_on_error_not_raise(self):
        env = FakeWinRTEnvironment()
        errors = []

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=lambda samples: None,
                on_error=errors.append,
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)
            return session

        session = _run(scenario())
        try:
            # Empty control payload: handle_control() raises ATVVProtocolError.
            env.control_characteristic.fire(b"")
            self.assertTrue(_wait_until(lambda: len(errors) > 0))
            self.assertIsInstance(errors[0], atvv_session.ATVVProtocolError)
        finally:
            _run(session.close())

    def test_disconnect_callback_fires_on_status_change(self):
        env = FakeWinRTEnvironment()
        disconnected = []

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=lambda samples: None,
                on_disconnected=lambda: disconnected.append(True),
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)
            return session

        session = _run(scenario())
        try:
            env.device.simulate_disconnect()
            self.assertEqual(disconnected, [True])
        finally:
            _run(session.close())


class SendMicOpenThreadsafeTests(unittest.TestCase):
    """XRBM-018 DoD 4: send_mic_open_threadsafe()'s scheduled write has a
    generation/closing gate, and any write failure that does make it
    through is observed and reported via on_error - not silently dropped as
    an un-awaited fire-and-forget task would be.
    """

    def _connected_session(self, env, **kwargs):
        winrt = env.build_winrt_modules()
        session = RC003BleSession(winrt=winrt, loop=asyncio.get_event_loop(), **kwargs)
        candidate = identity.RC003Candidate(
            name=env.name, hardware_match=False, handle=env.discovered_info
        )
        return session, candidate

    def test_generation_gate_drops_a_write_scheduled_before_a_reconnect(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            session, candidate = self._connected_session(env, on_pcm_frame=lambda samples: None)
            await session.connect(candidate)
            writes_before = len(env.tx_characteristic.write_history)

            session.send_mic_open_threadsafe()  # scheduled with the current generation
            session._generation += 1  # simulate a reconnect bumping generation first
            await asyncio.sleep(0.05)  # give the loop a chance to run the (gated) callback

            self.assertEqual(len(env.tx_characteristic.write_history), writes_before)
            await session.close()

        _run(scenario())

    def test_closing_gate_drops_a_write_scheduled_after_close_started(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            session, candidate = self._connected_session(env, on_pcm_frame=lambda samples: None)
            await session.connect(candidate)
            writes_before = len(env.tx_characteristic.write_history)

            session.send_mic_open_threadsafe()
            session._closing = True  # simulate close() having already started
            await asyncio.sleep(0.05)

            self.assertEqual(len(env.tx_characteristic.write_history), writes_before)
            session._closing = False  # let the real close() below run normally

        _run(scenario())

    def test_a_normal_scheduled_write_lands(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            session, candidate = self._connected_session(env, on_pcm_frame=lambda samples: None)
            await session.connect(candidate)
            writes_before = len(env.tx_characteristic.write_history)

            session.send_mic_open_threadsafe()
            self.assertTrue(
                await _async_wait_until(lambda: len(env.tx_characteristic.write_history) > writes_before)
            )
            self.assertEqual(
                env.tx_characteristic.write_history[-1], session.session.mic_open_command()
            )

            await session.close()

        _run(scenario())

    def test_a_failed_scheduled_write_is_reported_via_on_error(self):
        env = FakeWinRTEnvironment()
        errors = []
        boom = ConnectionError("simulated GATT write failure")

        async def scenario():
            session, candidate = self._connected_session(
                env, on_pcm_frame=lambda samples: None, on_error=errors.append
            )
            await session.connect(candidate)

            def _raise(_payload):
                raise boom

            env.tx_characteristic._on_write = _raise

            session.send_mic_open_threadsafe()
            self.assertTrue(await _async_wait_until(lambda: len(errors) > 0))
            self.assertIs(errors[0], boom)

            env.tx_characteristic._on_write = None
            await session.close()

        _run(scenario())


class CloseCancelsInFlightMicOpenTests(unittest.TestCase):
    """XRBM-018 RETRY 1 P1 #3: close() must cancel/await an ALREADY IN-
    FLIGHT MIC_OPEN write, not merely refuse to schedule a new one. The
    earlier gate-before-scheduling fix (SendMicOpenThreadsafeTests above)
    does nothing once a write has actually started - this proves close()
    now also wins that race, using a controllable blocking write (see
    FakeGattCharacteristic._write_gate) instead of a timing-based sleep.
    """

    def _connected_session(self, env, **kwargs):
        winrt = env.build_winrt_modules()
        session = RC003BleSession(winrt=winrt, loop=asyncio.get_event_loop(), **kwargs)
        candidate = identity.RC003Candidate(
            name=env.name, hardware_match=False, handle=env.discovered_info
        )
        return session, candidate

    def test_close_cancels_and_drains_a_write_already_in_flight(self):
        env = FakeWinRTEnvironment()
        errors = []

        async def scenario():
            session, candidate = self._connected_session(
                env, on_pcm_frame=lambda samples: None, on_error=errors.append
            )
            await session.connect(candidate)
            writes_before = len(env.tx_characteristic.write_history)

            gate = asyncio.Event()  # never set - the write blocks until cancelled
            env.tx_characteristic._write_gate = gate

            session.send_mic_open_threadsafe()
            # Deterministically wait until the write coroutine has actually
            # reached (and is blocked at) the gate - not a fixed sleep.
            self.assertTrue(
                await _async_wait_until(lambda: env.tx_characteristic.write_started_count > 0)
            )
            self.assertEqual(len(session._mic_open_tasks), 1)

            # close() runs while the write is still genuinely in flight.
            await session.close()

            # The write never completed (cancelled before recording it),
            # and close() still fully tore down the GATT resources below -
            # neither raced nor got stuck waiting on it.
            self.assertEqual(len(env.tx_characteristic.write_history), writes_before)
            self.assertEqual(len(session._mic_open_tasks), 0)

        _run(scenario())

        # A routine cancellation during an intentional close() is not a
        # reportable failure - on_error must stay silent for it (it's not
        # actionable: there is nothing left to reconnect).
        self.assertEqual(errors, [])
        self.assertTrue(env.service.closed)
        self.assertTrue(env.device.closed)
        self.assertEqual(env.audio_characteristic.cccd_history[-1], 0)  # NONE == 0
        self.assertEqual(env.control_characteristic.cccd_history[-1], 0)


class CloseWorkerJoinTimeoutTests(unittest.TestCase):
    """XRBM-019 P1 #3: a worker-thread join timeout inside close() must be a
    real close() failure (raised), not merely reported via on_error while
    close() itself returns normally - the previous "report and keep going"
    behavior let app.py's cleanup silently drop the session owner over a
    still-live worker thread anyway (XRBM-018's independent review
    round 2 finding #2). Every other independent GATT cleanup step must
    still be attempted before that raise.
    """

    class _NeverStopsThread:
        """A minimal thread-like stand-in whose join() always returns
        immediately without the thread actually having stopped -
        deterministically exercises the "still alive after join" branch
        without waiting out a real timeout.
        """

        def join(self, timeout=None):
            return None

        def is_alive(self):
            return True

    def test_a_worker_that_never_stops_raises_after_completing_other_cleanup(self):
        env = FakeWinRTEnvironment()
        errors = []

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=lambda samples: None,
                on_error=errors.append,
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)

            stuck_thread = self._NeverStopsThread()
            session._worker_thread = stuck_thread

            with self.assertRaises(RuntimeError) as ctx:
                await session.close()
            self.assertIn("did not stop", str(ctx.exception))

            # Not hidden: the still-alive thread reference is left in place
            # rather than cleared to pretend it stopped.
            self.assertIs(session._worker_thread, stuck_thread)
            # This specific failure is now surfaced via the raise itself,
            # not (redundantly/confusingly) via on_error too.
            self.assertEqual(errors, [])

        _run(scenario())

        # Every other independent GATT cleanup step still ran despite the
        # worker not stopping: CCCD written back to NONE, tokens removed,
        # service/device closed.
        self.assertEqual(env.audio_characteristic.cccd_history[-1], 0)  # NONE == 0
        self.assertEqual(env.control_characteristic.cccd_history[-1], 0)
        self.assertTrue(env.service.closed)
        self.assertTrue(env.device.closed)
        self.assertEqual(len(env.audio_characteristic._handlers), 0)
        self.assertEqual(len(env.control_characteristic._handlers), 0)


class CloseTests(unittest.TestCase):
    def test_close_writes_cccd_none_and_closes_service_and_device(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=lambda samples: None,
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)
            await session.close()

        _run(scenario())

        self.assertEqual(env.audio_characteristic.cccd_history[-1], 0)  # NONE == 0
        self.assertEqual(env.control_characteristic.cccd_history[-1], 0)
        self.assertTrue(env.service.closed)
        self.assertTrue(env.device.closed)
        # Both characteristics' tokens must have been removed (fakes assert
        # the exact token on remove_value_changed - if this didn't raise,
        # the tokens matched).
        self.assertEqual(len(env.audio_characteristic._handlers), 0)
        self.assertEqual(len(env.control_characteristic._handlers), 0)
        self.assertEqual(len(env.device._connection_status_handlers), 0)

    def test_close_sends_mic_close_if_a_mic_session_was_open(self):
        env = FakeWinRTEnvironment()

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=lambda samples: None,
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)
            env.control_characteristic.fire(_caps_payload())
            env.control_characteristic.fire(bytes((proto.OPCODE_AUDIO_START, 0, 0, 5)))
            self.assertTrue(_wait_until(lambda: session.session.mic_open))
            await session.close()

        _run(scenario())
        self.assertEqual(env.tx_characteristic.write_history[-1][0], 0x0D)  # MIC_CLOSE opcode

    def test_a_mic_close_write_failure_still_lets_the_rest_of_cleanup_run(self):
        """XRBM-018 RETRY 1 item 6: the MIC_CLOSE write's except clause must
        catch more than just ConnectionError - any exception the write
        raises must never abort the unsubscribe/service/device cleanup
        after it.
        """

        env = FakeWinRTEnvironment()

        async def scenario():
            winrt = env.build_winrt_modules()
            session = RC003BleSession(
                on_pcm_frame=lambda samples: None,
                winrt=winrt,
                loop=asyncio.get_event_loop(),
            )
            candidate = identity.RC003Candidate(
                name=env.name, hardware_match=False, handle=env.discovered_info
            )
            await session.connect(candidate)
            env.control_characteristic.fire(_caps_payload())
            env.control_characteristic.fire(bytes((proto.OPCODE_AUDIO_START, 0, 0, 5)))
            self.assertTrue(_wait_until(lambda: session.session.mic_open))

            def _raise(_payload):
                raise RuntimeError("simulated non-ConnectionError MIC_CLOSE failure")

            env.tx_characteristic._on_write = _raise
            await session.close()  # must not raise

        _run(scenario())

        self.assertTrue(env.service.closed)
        self.assertTrue(env.device.closed)
        self.assertEqual(env.audio_characteristic.cccd_history[-1], 0)  # NONE == 0
        self.assertEqual(env.control_characteristic.cccd_history[-1], 0)
        self.assertEqual(len(env.audio_characteristic._handlers), 0)
        self.assertEqual(len(env.control_characteristic._handlers), 0)


if __name__ == "__main__":
    unittest.main()
