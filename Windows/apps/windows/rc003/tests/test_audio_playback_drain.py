"""Tests for ``EndpointPlaybackSink.drain`` (Fix C of ADR-0003).

The drain implementation polls ``OutputStream.write_available`` until the
value stops changing for a few polls (meaning the PortAudio output buffer
has caught up with what we wrote).  These tests use a fake stream whose
``write_available`` value is controlled by the test so the polling loop
terminates deterministically without any real audio hardware or wall-clock
sleeps beyond the small ones built into the drain loop itself.
"""

from __future__ import annotations

import threading
import time
import unittest

from ovb_rc003 import audio_output
from ovb_rc003.audio_playback import EndpointPlaybackSink


class FakeStream:
    """Stand-in for ``sounddevice.OutputStream`` for the drain loop.

    ``write_available`` is whatever the test set most recently.  If
    ``raise_on_query`` is True, every ``write_available`` access raises,
    mirroring the post-``close()```` behaviour real sounddevice exhibits.
    """

    def __init__(self, available: int = 4800, raise_on_query: bool = False) -> None:
        self._available = available
        self._raise_on_query = raise_on_query
        self.queries = 0
        self.stop_called = False
        self.close_called = False

    @property
    def write_available(self) -> int:
        self.queries += 1
        if self._raise_on_query:
            raise RuntimeError("stream closed")
        return self._available

    def stop(self) -> None:
        self.stop_called = True

    def close(self) -> None:
        self.close_called = True


class _StubSink(EndpointPlaybackSink):
    """Subclass that swaps ``self._stream`` for a fake so we never touch PortAudio."""

    def __init__(self, stream: FakeStream | None) -> None:
        super().__init__("CABLE Input", host_api="Windows WASAPI")
        self._stream = stream


class DrainTests(unittest.TestCase):
    def test_drain_returns_true_when_stream_is_not_open(self) -> None:
        sink = _StubSink(stream=None)
        self.assertTrue(sink.drain())

    def test_drain_returns_true_when_write_available_is_already_max(self) -> None:
        # write_available never decreases: the buffer is empty from the start.
        stream = FakeStream(available=4800)
        sink = _StubSink(stream=stream)
        self.assertTrue(sink.drain(timeout_seconds=0.100))

    def test_drain_returns_true_when_write_available_stabilises_within_timeout(self) -> None:
        # Simulates PortAudio consuming buffered samples: the polled
        # ``write_available`` climbs toward the maximum and then plateaus.
        stream = FakeStream(available=2400)
        sink = _StubSink(stream=stream)
        # Override the fake to expose a counter that grows on each query.
        state = {"value": 2400, "queries": 0}

        class GrowingStream(FakeStream):
            @property
            def write_available(self) -> int:  # type: ignore[override]
                state["queries"] += 1
                # Climb toward 4800 every query (one poll interval).
                if state["value"] < 4800:
                    state["value"] = min(4800, state["value"] + 600)
                return state["value"]

        sink._stream = GrowingStream()
        self.assertTrue(sink.drain(timeout_seconds=0.500))

    def test_drain_returns_false_when_buffer_keeps_draining_below_max(self) -> None:
        # write_available never stops decreasing - simulate a never-finishing drain.
        # The drain loop must time out and return False rather than spin forever.
        state = {"value": 2400}

        class EndlessDrainStream(FakeStream):
            @property
            def write_available(self) -> int:  # type: ignore[override]
                # Always return a value below the maximum and never stabilise.
                state["value"] = (state["value"] + 1) % 2400
                return state["value"]

        sink = _StubSink(stream=EndlessDrainStream())
        started = time.monotonic()
        result = sink.drain(timeout_seconds=0.100)
        elapsed = time.monotonic() - started
        self.assertFalse(result)
        # Sanity: the loop respected the timeout rather than hanging.
        self.assertLess(elapsed, 0.500)

    def test_drain_returns_true_when_stream_already_closed(self) -> None:
        # After close(), write_available raises.  The drain method must
        # not propagate this and must return True so the caller can
        # continue the host session lifecycle.
        stream = FakeStream(available=0, raise_on_query=True)
        sink = _StubSink(stream=stream)
        self.assertTrue(sink.drain(timeout_seconds=0.100))


class CloseInteractionTests(unittest.TestCase):
    def test_close_uses_safe_stop_and_close(self) -> None:
        stream = FakeStream(available=4800)
        sink = _StubSink(stream=stream)
        sink.close()
        self.assertTrue(stream.stop_called)
        self.assertTrue(stream.close_called)
        self.assertIsNone(sink._stream)


if __name__ == "__main__":
    unittest.main()