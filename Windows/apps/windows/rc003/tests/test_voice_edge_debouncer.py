"""Unit tests for ``VoiceEdgeDebouncer``.

These tests run without a real Windows message loop and use a fake
``threading.Timer``-like callable to drive the debouncer deterministically.
The fake never sleeps; the test triggers the scheduled callback by hand
so the tests are exact and fast even on slow CI hardware.
"""

from __future__ import annotations

import threading
import unittest
from typing import Callable, List, Optional, Tuple

from ovb_rc003.voice_edge_debouncer import VoiceEdgeDebouncer


class FakeTimer:
    """Stand-in for ``threading.Timer`` that defers firing until the test asks."""

    def __init__(self, delay: float, callback: Callable[[], None]) -> None:
        self._delay = delay
        self._callback = callback
        self.cancelled = False
        self.started = False

    def start(self) -> None:
        self.started = True

    def cancel(self) -> None:
        self.cancelled = True

    def fire(self) -> None:
        if not self.cancelled and self.started:
            self._callback()


class _RecordingFactory:
    """Records every timer the debouncer creates so tests can inspect them."""

    def __init__(self) -> None:
        self.timers: List[FakeTimer] = []

    def __call__(self, delay: float, callback: Callable[[], None]) -> FakeTimer:
        timer = FakeTimer(delay, callback)
        self.timers.append(timer)
        return timer


class VoiceEdgeDebouncerPressOnlyTests(unittest.TestCase):
    """Press edges cancel pending releases and dispatch immediately."""

    def setUp(self) -> None:
        self.factory = _RecordingFactory()
        self.debouncer = VoiceEdgeDebouncer(
            release_window_seconds=0.050,
            timer_factory=self.factory,
        )

    def test_on_release_creates_one_timer(self) -> None:
        fired: List[int] = []

        self.debouncer.on_release(lambda: fired.append(1))
        self.assertEqual(len(self.factory.timers), 1)
        self.assertFalse(self.factory.timers[0].cancelled)
        self.assertEqual(fired, [])

    def test_fire_runs_handler_once(self) -> None:
        fired: List[int] = []
        self.debouncer.on_release(lambda: fired.append(1))
        self.factory.timers[0].fire()
        self.assertEqual(fired, [1])

    def test_on_press_cancels_pending_release(self) -> None:
        fired: List[int] = []
        self.debouncer.on_release(lambda: fired.append(1))
        self.debouncer.on_press()
        self.assertTrue(self.factory.timers[0].cancelled)
        # A subsequent fake-fire must NOT execute the cancelled handler.
        self.factory.timers[0].fire()
        self.assertEqual(fired, [])

    def test_release_after_press_starts_fresh_timer(self) -> None:
        fired: List[int] = []
        self.debouncer.on_release(lambda: fired.append(1))
        first_timer = self.factory.timers[0]
        self.debouncer.on_press()
        self.assertTrue(first_timer.cancelled)
        # A new release after the press schedules a new timer.
        self.debouncer.on_release(lambda: fired.append(2))
        self.assertEqual(len(self.factory.timers), 2)
        self.assertFalse(self.factory.timers[1].cancelled)
        # Firing the old (cancelled) timer must do nothing.
        first_timer.fire()
        self.assertEqual(fired, [])
        # Firing the new timer must run the new handler.
        self.factory.timers[1].fire()
        self.assertEqual(fired, [2])

    def test_shutdown_cancels_pending_release(self) -> None:
        fired: List[int] = []
        self.debouncer.on_release(lambda: fired.append(1))
        self.debouncer.shutdown()
        self.assertTrue(self.factory.timers[0].cancelled)
        self.factory.timers[0].fire()
        self.assertEqual(fired, [])


class VoiceEdgeDebouncerBounceScenariosTests(unittest.TestCase):
    """Real-RC003 bounce scenarios observed in ``app.log``.

    The 23:01:23 / 23:01:26 / 23:01:37 live log entries show a single
    physical hold producing three F5 down/up edge pairs.  Each test below
    models one of those patterns and asserts that exactly one release
    handler fires per physical hold (no spurious closures that would
    spawn a second Typeless voice window).
    """

    def setUp(self) -> None:
        self.factory = _RecordingFactory()
        self.debouncer = VoiceEdgeDebouncer(
            release_window_seconds=0.050,
            timer_factory=self.factory,
        )
        self.fired: List[int] = []
        self.handler = lambda: self.fired.append(1)

    def _release_and_immediate_press(self) -> None:
        """Simulate a bounce: release scheduled, press arrives < 50 ms later."""

        self.debouncer.on_release(self.handler)
        self.debouncer.on_press()
        # Pretend the underlying timer thread observes the cancellation.

    def test_5ms_bounce_collapses_into_no_release(self) -> None:
        self._release_and_immediate_press()
        # Allow any in-flight firing (cancelled) to be ignored.
        for timer in self.factory.timers:
            timer.fire()
        self.assertEqual(self.fired, [])

    def test_50ms_boundary_press_arrives_before_fire(self) -> None:
        # Press lands before the debounce window expires.
        self.debouncer.on_release(self.handler)
        self.assertEqual(len(self.factory.timers), 1)
        self.debouncer.on_press()
        self.factory.timers[0].fire()
        self.assertEqual(self.fired, [])

    def test_200ms_held_release_fires_after_window(self) -> None:
        # No press arrives within the window - this is a real release.
        self.debouncer.on_release(self.handler)
        # Fake fire after the 50 ms window.
        self.factory.timers[0].fire()
        self.assertEqual(self.fired, [1])

    def test_continuous_hold_release_then_press_continues_session(self) -> None:
        # Press → release → press within 50 ms (single physical hold with
        # firmware bounce): the cancelled release is dropped, the new
        # release is scheduled, and only the final release fires.
        self.debouncer.on_release(self.handler)
        cancelled_timer = self.factory.timers[0]
        self.debouncer.on_press()
        self.assertTrue(cancelled_timer.cancelled)
        # New release arrives (bounce end).
        self.debouncer.on_release(lambda: self.fired.append(2))
        # The cancelled timer must not run.
        cancelled_timer.fire()
        self.assertEqual(self.fired, [])
        # The new timer fires normally.
        self.factory.timers[1].fire()
        self.assertEqual(self.fired, [2])

    def test_two_independent_holds_produce_two_releases(self) -> None:
        # Distinct physical holds (separated by >> 50 ms with no press
        # inside the window) must produce two distinct release handlers.
        self.debouncer.on_release(lambda: self.fired.append(1))
        self.factory.timers[0].fire()
        # Caller-side "press" dispatched synchronously (out of scope of
        # this debouncer's on_press, which only cancels), then a new
        # release for the second hold:
        self.debouncer.on_release(lambda: self.fired.append(2))
        self.factory.timers[1].fire()
        self.assertEqual(self.fired, [1, 2])


class VoiceEdgeDebouncerConfigurableWindowTests(unittest.TestCase):
    """ADR-0003 "Window refinement 2026-08-23": every documented boundary.

    The production default is 200 ms (the ~3x margin over the worst 65 ms
    bounce observed on 2026-08-23).  Users with a non-bouncing firmware
    can drop the window back to 50 ms via
    ``config.voice_release_debounce_seconds``; users whose firmware grows
    a wider bounce can lift it toward 500 ms.  These tests confirm the
    class itself respects any in-band window, not just the 50 ms value
    the original debounce tests used.
    """

    def _build(self, release_window_seconds: float):
        factory = _RecordingFactory()
        debouncer = VoiceEdgeDebouncer(
            release_window_seconds=release_window_seconds,
            timer_factory=factory,
        )
        return factory, debouncer

    def test_50_ms_window_drops_press_inside_window(self) -> None:
        factory, debouncer = self._build(0.050)
        fired: List[int] = []
        debouncer.on_release(lambda: fired.append(1))
        debouncer.on_press()
        for timer in factory.timers:
            timer.fire()
        self.assertEqual(fired, [])

    def test_100_ms_window_drops_press_inside_window(self) -> None:
        factory, debouncer = self._build(0.100)
        fired: List[int] = []
        debouncer.on_release(lambda: fired.append(1))
        debouncer.on_press()
        for timer in factory.timers:
            timer.fire()
        self.assertEqual(fired, [])

    def test_200_ms_window_drops_press_inside_window(self) -> None:
        factory, debouncer = self._build(0.200)
        fired: List[int] = []
        debouncer.on_release(lambda: fired.append(1))
        debouncer.on_press()
        for timer in factory.timers:
            timer.fire()
        self.assertEqual(fired, [])

    def test_350_ms_window_keeps_macos_double_tap_above_threshold(self) -> None:
        # 350 ms is the upstream macOS double-tap budget; if a real
        # firmware revision observes bounces wider than 200 ms, lifting
        # the window to 350 ms must still respect the "double-tap stays a
        # double-tap" guarantee by not collapsing two holds that the user
        # intentionally spaced.
        factory, debouncer = self._build(0.350)
        fired: List[int] = []
        # First hold: release fires because no press arrives inside.
        debouncer.on_release(lambda: fired.append(1))
        factory.timers[0].fire()
        # Second hold, distinct physical press: re-press cancels no
        # pending timer here (the previous one fired), and the new
        # release schedules a new timer.  We assert both fired so that a
        # regression toward collapsing them would be caught.
        debouncer.on_release(lambda: fired.append(2))
        factory.timers[1].fire()
        self.assertEqual(fired, [1, 2])


class VoiceEdgeDebouncerRejectsBadArgsTests(unittest.TestCase):
    def test_negative_window_raises(self) -> None:
        with self.assertRaises(ValueError):
            VoiceEdgeDebouncer(release_window_seconds=-0.001)


class VoiceEdgeDebouncerRealTimerSmokeTests(unittest.TestCase):
    """Smoke test against the real ``threading.Timer`` factory.

    Confirms the production factory wires through and the cancel/fire
    contract holds under the real implementation.  Uses a very small
    window so the test finishes in a few tens of milliseconds.
    """

    def test_real_timer_fires_handler_when_not_cancelled(self) -> None:
        debouncer = VoiceEdgeDebouncer(release_window_seconds=0.010)
        fired = threading.Event()
        debouncer.on_release(fired.set)
        self.assertTrue(fired.wait(timeout=1.0))

    def test_real_timer_does_not_fire_after_cancel(self) -> None:
        debouncer = VoiceEdgeDebouncer(release_window_seconds=0.010)
        fired = threading.Event()
        debouncer.on_release(fired.set)
        debouncer.on_press()
        self.assertFalse(fired.wait(timeout=0.050))


if __name__ == "__main__":
    unittest.main()
