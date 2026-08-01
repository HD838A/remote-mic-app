"""Exercises connection_supervisor.ConnectionSupervisor with fake async
connect/cleanup/sleep callables - no real BLE/HID/audio backend needed (see
XRBM-014 review RETRY P1 #2).
"""

import asyncio
import threading
import unittest

from ovb_rc003.connection_supervisor import ConnectionSupervisor


def _run(coro):
    # Explicitly closing the loop (XRBM-014 review round 2 evidence: a
    # ResourceWarning for an unclosed test event loop) rather than letting
    # it be garbage-collected.
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


class _Recorder:
    def __init__(self):
        self.events = []

    def record(self, name):
        self.events.append(name)


class CleanupAlwaysRunsTests(unittest.TestCase):
    def test_cleanup_runs_after_a_successful_connect_once_stopped(self):
        recorder = _Recorder()

        async def connect():
            recorder.record("connect")

        async def cleanup():
            recorder.record("cleanup")

        async def fake_sleep(_seconds):
            recorder.record("sleep")

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup, sleep=fake_sleep)
            task = asyncio.ensure_future(supervisor.run_forever())
            await asyncio.sleep(0)  # let run_forever reach connect() + wait()
            await supervisor.stop()
            await task

        _run(scenario())
        self.assertEqual(recorder.events, ["connect", "cleanup"])

    def test_cleanup_runs_even_when_connect_raises(self):
        recorder = _Recorder()
        attempts = []

        async def connect():
            attempts.append(1)
            recorder.record("connect")
            raise RuntimeError("simulated connect failure")

        async def cleanup():
            recorder.record("cleanup")

        async def fake_sleep(_seconds):
            recorder.record("sleep")
            if len(attempts) >= 2:
                raise asyncio.CancelledError()  # stop the test after 2 attempts

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup, sleep=fake_sleep)
            with self.assertRaises(asyncio.CancelledError):
                await supervisor.run_forever()
            return supervisor

        supervisor = _run(scenario())
        self.assertEqual(supervisor.attempt_count, 2)
        self.assertEqual(supervisor.cleanup_count, 2)
        # Both attempts fully connect->cleanup before the second sleep call
        # is the one that raises CancelledError (ending the test scenario).
        self.assertEqual(
            recorder.events,
            ["connect", "cleanup", "sleep", "connect", "cleanup", "sleep"],
        )

    def test_request_reconnect_ends_the_wait_and_triggers_fresh_cleanup(self):
        recorder = _Recorder()
        connect_count = 0
        supervisor_ref = {}

        async def connect():
            nonlocal connect_count
            connect_count += 1
            recorder.record(f"connect{connect_count}")

        async def cleanup():
            recorder.record("cleanup")

        async def fake_sleep(_seconds):
            recorder.record("sleep")

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup, sleep=fake_sleep)
            supervisor_ref["supervisor"] = supervisor
            task = asyncio.ensure_future(supervisor.run_forever())
            await asyncio.sleep(0)
            supervisor.request_reconnect()  # simulate a BLE disconnect callback
            await asyncio.sleep(0)
            await asyncio.sleep(0)
            await supervisor.stop()
            await task

        _run(scenario())
        self.assertGreaterEqual(connect_count, 2)
        self.assertGreaterEqual(supervisor_ref["supervisor"].cleanup_count, 2)


class ThreadSafetyTests(unittest.TestCase):
    """XRBM-014 review round 2 P1 #5: request_reconnect() must be safe to
    call from a thread other than the one running the event loop - exactly
    how WinRT/ATVV-worker-thread callbacks actually call it in app.py.
    """

    def test_request_reconnect_from_a_real_foreign_thread_wakes_the_loop(self):
        recorder = _Recorder()
        connect_count = 0

        async def connect():
            nonlocal connect_count
            connect_count += 1
            recorder.record(f"connect{connect_count}")

        async def cleanup():
            recorder.record("cleanup")

        async def fake_sleep(_seconds):
            recorder.record("sleep")

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup, sleep=fake_sleep)
            task = asyncio.ensure_future(supervisor.run_forever())
            await asyncio.sleep(0)  # let run_forever reach connect() + wait()

            called_from_another_thread = threading.Event()

            def call_from_a_real_os_thread():
                self.assertNotEqual(
                    threading.current_thread(), threading.main_thread(),
                    "this call must not happen on the event-loop thread itself, "
                    "or it would not exercise the call_soon_threadsafe path at all",
                )
                supervisor.request_reconnect()
                called_from_another_thread.set()

            worker = threading.Thread(target=call_from_a_real_os_thread)
            worker.start()
            worker.join(timeout=2.0)
            self.assertTrue(called_from_another_thread.is_set())

            # Give the loop a few ticks to run the call_soon_threadsafe
            # callback and let run_forever() react to it.
            for _ in range(10):
                await asyncio.sleep(0)

            await supervisor.stop()
            await task

        _run(scenario())
        self.assertGreaterEqual(connect_count, 2)


class CleanupFailureFailsClosedTests(unittest.TestCase):
    """XRBM-019 In-scope item 5 / changed threat model: "A cleanup timeout
    is an ownership failure, not a log-only event ... no replacement
    generation may start." A cleanup() failure (e.g. app.py's
    _cleanup_once() raising CleanupIncompleteError because it could not
    release a still-live HID listener or BLE session) must end
    run_forever() entirely, not be swallowed with the loop continuing to a
    fresh connect() over resources that might still be live.

    No change to connection_supervisor.py itself was needed for this: a
    cleanup() exception raised inside run_forever()'s `finally` block
    already propagates out of the whole loop by ordinary Python semantics -
    this test is the standing regression proof of that existing structural
    guarantee, since nothing previously exercised a raising cleanup().
    """

    def test_cleanup_raising_ends_run_forever_without_a_second_connect(self):
        recorder = _Recorder()
        boom = RuntimeError("simulated retained-owner cleanup failure")

        async def connect():
            recorder.record("connect")

        async def cleanup():
            recorder.record("cleanup")
            raise boom

        async def fake_sleep(_seconds):
            recorder.record("sleep")  # must never be reached

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup, sleep=fake_sleep)
            task = asyncio.ensure_future(supervisor.run_forever())
            await asyncio.sleep(0)  # let run_forever reach connect() + wait()
            # Unblock the wait() (a disconnect/protocol-error notification
            # in production) so the loop actually reaches its finally block
            # and calls cleanup() - request_reconnect() itself never raises.
            supervisor.request_reconnect()
            with self.assertRaises(RuntimeError) as ctx:
                await task
            self.assertIs(ctx.exception, boom)
            return supervisor

        supervisor = _run(scenario())
        self.assertEqual(supervisor.attempt_count, 1)
        # Exactly one connect, one cleanup, and critically no "sleep" (which
        # would have preceded a second connect attempt) - the loop ended
        # the instant cleanup() raised, never looping back around.
        self.assertEqual(recorder.events, ["connect", "cleanup"])


class StopBehaviorTests(unittest.TestCase):
    def test_stop_before_run_forever_starts_means_nothing_happens(self):
        recorder = _Recorder()

        async def connect():
            recorder.record("connect")

        async def cleanup():
            recorder.record("cleanup")

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup)
            await supervisor.stop()
            await supervisor.run_forever()

        _run(scenario())
        self.assertEqual(recorder.events, [])

    def test_last_error_is_recorded_for_diagnostics(self):
        boom = RuntimeError("boom")

        async def connect():
            raise boom

        async def cleanup():
            pass

        async def fake_sleep(_seconds):
            raise asyncio.CancelledError()

        async def scenario():
            supervisor = ConnectionSupervisor(connect, cleanup, sleep=fake_sleep)
            with self.assertRaises(asyncio.CancelledError):
                await supervisor.run_forever()
            return supervisor

        supervisor = _run(scenario())
        self.assertIs(supervisor.last_error, boom)


class RetryBackoffTests(unittest.TestCase):
    def test_consecutive_connect_failures_back_off_until_the_configured_cap(self):
        attempts = []
        delays = []

        async def connect():
            attempts.append(1)
            raise RuntimeError("simulated connect failure")

        async def cleanup():
            pass

        async def fake_sleep(seconds):
            delays.append(seconds)
            if len(delays) >= 4:
                raise asyncio.CancelledError()

        async def scenario():
            supervisor = ConnectionSupervisor(
                connect,
                cleanup,
                retry_delay=5.0,
                max_retry_delay=20.0,
                sleep=fake_sleep,
            )
            with self.assertRaises(asyncio.CancelledError):
                await supervisor.run_forever()

        _run(scenario())
        self.assertEqual(delays, [5.0, 10.0, 20.0, 20.0])

    def test_successful_connection_resets_the_next_retry_delay_to_base(self):
        delays = []
        supervisor_ref = {}
        connect_count = 0

        async def connect():
            nonlocal connect_count
            connect_count += 1
            if connect_count <= 2:
                raise RuntimeError("simulated connect failure")
            supervisor_ref["supervisor"].request_reconnect()

        async def cleanup():
            pass

        async def fake_sleep(seconds):
            delays.append(seconds)
            if len(delays) >= 4:
                raise asyncio.CancelledError()

        async def scenario():
            supervisor = ConnectionSupervisor(
                connect,
                cleanup,
                retry_delay=5.0,
                max_retry_delay=20.0,
                sleep=fake_sleep,
            )
            supervisor_ref["supervisor"] = supervisor
            with self.assertRaises(asyncio.CancelledError):
                await supervisor.run_forever()

        _run(scenario())
        self.assertEqual(delays, [5.0, 10.0, 20.0, 5.0])


if __name__ == "__main__":
    unittest.main()
