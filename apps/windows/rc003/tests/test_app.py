import asyncio
import logging
import unittest

from ovb_rc003 import atvv_session, audio_output
from ovb_rc003.app import RC003VoiceBridge


SETTINGS = {
    "output_endpoint_name": "CABLE Input",
    "output_endpoint_host_api": "Windows WASAPI",
    "gain_db": 10.0,
    "retry_delay": 2.0,
    "max_retry_delay": 30.0,
}


class _Session:
    def __init__(self, *, close_error=None):
        self.close_error = close_error
        self.close_calls = 0
        self.mic_open_calls = 0

    async def close(self):
        self.close_calls += 1
        if self.close_error is not None:
            raise self.close_error

    def send_mic_open_threadsafe(self):
        self.mic_open_calls += 1


class _Sink:
    def __init__(self, *, open_error=None, close_error=None):
        self.open_error = open_error
        self.close_error = close_error
        self.open_calls = 0
        self.close_calls = 0
        self.writes = []

    def open(self):
        self.open_calls += 1
        if self.open_error is not None:
            raise self.open_error

    def close(self):
        self.close_calls += 1
        if self.close_error is not None:
            raise self.close_error

    def write(self, samples):
        self.writes.append(samples)


def _bridge(loop, sink):
    endpoint = audio_output.AudioEndpoint("CABLE Input", "Windows WASAPI")
    logger = logging.getLogger(f"test_app.{id(sink)}")
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    return RC003VoiceBridge(
        SETTINGS,
        logger=logger,
        enumerate_output_fn=lambda: [endpoint],
        playback_factory=lambda _name, _host_api: sink,
        loop=loop,
    )


class CleanupOwnershipTests(unittest.TestCase):
    def test_successful_cleanup_releases_ble_and_audio_owners(self):
        loop = asyncio.new_event_loop()
        try:
            sink = _Sink()
            bridge = _bridge(loop, sink)
            session = _Session()
            bridge._ble_session = session
            bridge._playback = sink

            loop.run_until_complete(bridge._cleanup_once())

            self.assertIsNone(bridge._ble_session)
            self.assertIsNone(bridge._playback)
            self.assertEqual(session.close_calls, 1)
            self.assertEqual(sink.close_calls, 1)
        finally:
            loop.close()

    def test_failed_cleanup_retains_owner_references_and_fails_closed(self):
        loop = asyncio.new_event_loop()
        try:
            sink = _Sink(close_error=RuntimeError("audio close failed"))
            bridge = _bridge(loop, sink)
            session = _Session(close_error=RuntimeError("BLE close failed"))
            bridge._ble_session = session
            bridge._playback = sink

            with self.assertRaises(RuntimeError):
                loop.run_until_complete(bridge._cleanup_once())

            self.assertIs(bridge._ble_session, session)
            self.assertIs(bridge._playback, sink)
        finally:
            loop.close()


class PlaybackLifecycleTests(unittest.TestCase):
    def test_mic_button_opens_selected_endpoint_then_requests_mic_audio(self):
        loop = asyncio.new_event_loop()
        try:
            sink = _Sink()
            bridge = _bridge(loop, sink)
            session = _Session()
            bridge._ble_session = session

            bridge._on_control_event(atvv_session.MicButtonPressed())

            self.assertIs(bridge._playback, sink)
            self.assertEqual(sink.open_calls, 1)
            self.assertEqual(session.mic_open_calls, 1)
        finally:
            loop.close()

    def test_failed_open_attempts_best_effort_sink_cleanup(self):
        loop = asyncio.new_event_loop()
        try:
            sink = _Sink(open_error=RuntimeError("open failed"))
            bridge = _bridge(loop, sink)

            self.assertFalse(bridge._open_playback())

            self.assertIsNone(bridge._playback)
            self.assertEqual(sink.close_calls, 1)
        finally:
            loop.close()


if __name__ == "__main__":
    unittest.main()
