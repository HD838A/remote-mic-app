"""Debouncer for the voice microphone key release edge.

The macOS upstream reference (``VoiceFnTapSessionController.swift`` in
``HD838A/remote-mic-app``) solves the same problem with explicit
``generation &+= 1`` tracking plus a 150 ms ``startDelay``.  This module
is the minimal Windows-side equivalent documented in
``docs/decisions/ADR-0003-voice-edge-debounce-and-hook-decoupling.md``:

- **Press** edges dispatch immediately and cancel any pending release.
- **Release** edges are scheduled via a timer; if a press arrives before
  the window expires, the release is cancelled and the host session
  continues uninterrupted.

The window has to be longer than the largest observed RC003 firmware
release/press bounce on real hardware, otherwise the release timer
fires before the worker can dequeue the re-press and cancel it -
which would dispatch a spurious host-side key-up immediately after the
physical key-down, opening and closing a ~50 ms host voice session in
the middle of a single physical hold.  The 2026-08-23 ``app.log``
recordings (06:13:34,914 -> 06:13:34,976 and 06:31:33,421 ->
 06:31:33,486) show 65 ms gaps between F5-up and the following F5-down
during a single physical hold; 50 ms was too short, so the production
window is 200 ms, giving ~3x margin over the observed bounce while
still leaving the intended macOS-style "double-tap within ~350 ms"
gesture usable (the real upstream macOS double-tap window is 350 ms).

The module is pure state plus an injectable ``threading.Timer``
replacement, so it is fully unit-testable on any OS without a real
Windows message loop.
"""

from __future__ import annotations

import threading
import time
from typing import Callable, Optional


TimerFactory = Callable[[float, Callable[[], None]], "threading.Timer"]


def _default_timer_factory(delay: float, callback: Callable[[], None]) -> "threading.Timer":
    timer = threading.Timer(delay, callback)
    timer.daemon = True
    return timer


class VoiceEdgeDebouncer:
    """State machine that schedules release handlers behind a short window.

    Thread-safety: every public method holds ``self._lock`` for the
    duration of its mutation.  A pending ``threading.Timer`` is cancelled
    via ``Timer.cancel()`` before a new release is scheduled.  A monotonic
    sequence counter invalidates any in-flight timer that races with a
    new ``on_release`` call, so a release handler cannot fire after a
    newer release has been scheduled or after ``shutdown()``.
    """

    def __init__(
        self,
        release_window_seconds: float = 0.200,
        timer_factory: Optional[TimerFactory] = None,
    ) -> None:
        if release_window_seconds < 0:
            raise ValueError("release_window_seconds must be >= 0")
        self._release_window = float(release_window_seconds)
        self._timer_factory: TimerFactory = timer_factory or _default_timer_factory
        self._lock = threading.Lock()
        self._timer: Optional["threading.Timer"] = None
        self._release_seq: int = 0

    @property
    def release_window_seconds(self) -> float:
        return self._release_window

    def on_press(self) -> None:
        """Cancel any pending release so the active session continues.

        The press dispatch itself is the caller's responsibility; this
        method only manages debounce state.
        """

        self._cancel_pending_release_locked()

    def on_release(self, handler: Callable[[], None]) -> None:
        """Schedule ``handler`` after ``release_window_seconds``.

        If a new release arrives before the previous timer fires, the
        older schedule is cancelled and the newer handler wins.  If a
        press arrives between scheduling and firing, the release handler
        is cancelled and never runs.
        """

        with self._lock:
            self._cancel_pending_release_locked()
            seq = self._release_seq
            timer = self._timer_factory(self._release_window, self._fire_locked)
            self._timer = timer
            timer.start()
            # Stash the handler on the closure via a small wrapper that
            # holds both the seq check and the user handler, so we don't
            # need an extra instance attribute for it.
            self._pending_handler = (seq, handler)

    def shutdown(self) -> None:
        """Cancel any pending release so the worker thread can exit cleanly."""

        with self._lock:
            self._cancel_pending_release_locked()

    def fire_pending_now_for_test(self) -> bool:
        """Test-only: synchronously fire the pending release handler if any.

        Returns ``True`` if a handler was fired, ``False`` if there was
        no pending release.  Cancels the underlying timer so the same
        handler does not fire twice.  Production code MUST NOT call
        this; the test helper is named with the ``_for_test`` suffix
        to make accidental production use obvious in code review.
        """

        with self._lock:
            if self._timer is None or self._pending_handler is None:
                return False
            self._timer.cancel()
            self._timer = None
            seq, handler = self._pending_handler
            self._pending_handler = None
        handler()
        return True

    def _cancel_pending_release_locked(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        self._release_seq += 1
        self._pending_handler = None

    def _fire_locked(self) -> None:
        with self._lock:
            self._timer = None
            pending = self._pending_handler
            self._pending_handler = None
            if pending is None:
                return
            seq, handler = pending
            if seq != self._release_seq:
                # Cancelled by a newer release or shutdown; drop this firing.
                return
        handler()
