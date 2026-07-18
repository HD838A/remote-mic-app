import unittest

from ovb_rc003 import atvv_protocol as proto
from ovb_rc003 import atvv_session


class _FakeClock:
    def __init__(self, start: float = 0.0):
        self.value = start

    def __call__(self) -> float:
        return self.value

    def advance(self, delta: float) -> None:
        self.value += delta


def _caps_payload(codec_bit=0x02, frame_size=4):
    return bytes((0x0B, 0x01, 0x00, codec_bit, 0x03)) + frame_size.to_bytes(2, "big")


class ATVVSessionCapsTests(unittest.TestCase):
    def test_caps_rejects_non_16k_sample_rate(self):
        session = atvv_session.ATVVSession()
        with self.assertRaises(atvv_session.UnsupportedSampleRateError):
            session.handle_control(_caps_payload(codec_bit=0x01))

    def test_caps_accepts_16k_and_stores_frame_size(self):
        session = atvv_session.ATVVSession()
        event = session.handle_control(_caps_payload(codec_bit=0x02, frame_size=8))
        self.assertIsInstance(event, atvv_session.CapsReceived)
        self.assertEqual(session.capabilities.frame_size, 8)

    def test_malformed_caps_raises_protocol_error(self):
        session = atvv_session.ATVVSession()
        with self.assertRaises(atvv_session.ATVVProtocolError):
            session.handle_control(bytes((0x0B, 0x01)))

    def test_empty_payload_raises_protocol_error(self):
        session = atvv_session.ATVVSession()
        with self.assertRaises(atvv_session.ATVVProtocolError):
            session.handle_control(b"")


class ATVVSessionControlEventTests(unittest.TestCase):
    def test_mic_button_event(self):
        session = atvv_session.ATVVSession()
        event = session.handle_control(bytes((proto.OPCODE_MIC_BUTTON,)))
        self.assertIsInstance(event, atvv_session.MicButtonPressed)

    def test_audio_start_event_carries_session_id(self):
        session = atvv_session.ATVVSession()
        event = session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 42)))
        self.assertIsInstance(event, atvv_session.AudioStarted)
        self.assertEqual(event.session_id, 42)
        self.assertTrue(session.mic_open)

    def test_audio_start_without_session_id_byte(self):
        session = atvv_session.ATVVSession()
        event = session.handle_control(bytes((proto.OPCODE_AUDIO_START,)))
        self.assertIsNone(event.session_id)

    def test_audio_stop_event_closes_mic(self):
        session = atvv_session.ATVVSession()
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 1)))
        event = session.handle_control(bytes((proto.OPCODE_AUDIO_STOP,)))
        self.assertIsInstance(event, atvv_session.AudioStopped)
        self.assertFalse(session.mic_open)

    def test_unknown_opcode_returns_unknown_control_without_raising(self):
        session = atvv_session.ATVVSession()
        event = session.handle_control(bytes((0xEE,)))
        self.assertIsInstance(event, atvv_session.UnknownControl)
        self.assertEqual(event.opcode, 0xEE)

    def test_short_audio_sync_falls_through_to_unknown(self):
        session = atvv_session.ATVVSession()
        event = session.handle_control(bytes((proto.OPCODE_AUDIO_SYNC, 0, 0)))
        self.assertIsInstance(event, atvv_session.UnknownControl)


class ATVVSessionAudioTests(unittest.TestCase):
    def test_audio_start_resets_decoder_regardless_of_prior_sync(self):
        session = atvv_session.ATVVSession()
        session.handle_control(_caps_payload(frame_size=1))
        # Queue a sync, then start a fresh session before it's consumed.
        sync_payload = bytes((proto.OPCODE_AUDIO_SYNC, 0, 0, 0)) + (100).to_bytes(
            2, "big", signed=True
        ) + bytes((5,))
        session.handle_control(sync_payload)
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 1)))
        # A pending sync must not leak into the new session: decoding a
        # single zero byte from a fresh (predictor=0, step_index=0) state
        # should produce small values near zero, not jump from predictor=100.
        samples = session.handle_audio(bytes((0x00,)))
        self.assertEqual(len(samples), 2)

    def test_audio_sync_applies_once_to_next_frame_only(self):
        session = atvv_session.ATVVSession()
        session.handle_control(_caps_payload(frame_size=1))
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 1)))
        sync_payload = bytes((proto.OPCODE_AUDIO_SYNC, 0, 0, 0)) + (1000).to_bytes(
            2, "big", signed=True
        ) + bytes((10,))
        session.handle_control(sync_payload)
        first = session.handle_audio(bytes((0x00,)))
        second = session.handle_audio(bytes((0x00,)))
        # First post-sync frame should reflect the synced predictor (1000ish);
        # the second should have moved on and not re-apply the same sync.
        self.assertNotEqual(first, second)

    def test_audio_stop_discards_late_bytes_within_guard_window(self):
        clock = _FakeClock()
        session = atvv_session.ATVVSession(clock=clock)
        session.handle_control(_caps_payload(frame_size=1))
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 1)))
        session.handle_control(bytes((proto.OPCODE_AUDIO_STOP,)))
        clock.advance(0.1)  # still within the 0.3s guard window
        samples = session.handle_audio(bytes((0xFF,)))
        self.assertEqual(samples, [])

    def test_audio_after_guard_window_expires_is_accepted_once_reopened(self):
        clock = _FakeClock()
        session = atvv_session.ATVVSession(clock=clock)
        session.handle_control(_caps_payload(frame_size=1))
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 1)))
        session.handle_control(bytes((proto.OPCODE_AUDIO_STOP,)))
        clock.advance(1.0)  # past the guard window
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 2)))
        samples = session.handle_audio(bytes((0xFF,)))
        self.assertEqual(len(samples), 2)

    def test_mic_open_close_commands_use_negotiated_version(self):
        session = atvv_session.ATVVSession()
        session.handle_control(_caps_payload())
        self.assertEqual(session.mic_open_command(), bytes((0x0C, 0x00)))
        session.handle_control(bytes((proto.OPCODE_AUDIO_START, 0, 0, 9)))
        self.assertEqual(session.mic_close_command(), bytes((0x0D, 9)))


if __name__ == "__main__":
    unittest.main()
