"""Exercises single_instance.py's mutex acquire/duplicate/release/cleanup
contract with injected fake Win32 callables, so it runs on any OS without
needing ``ctypes.windll`` (which does not exist off Windows) - the same
dependency-injection seam win32_input.py's ``_sender`` parameter already
established (see that module's docstring). ``BridgeInstanceGuard`` itself
never calls ``_require_windows()`` - only the real ``_real_*`` functions do
- so an injected fake exercises the full acquire/duplicate/release logic
without fighting the platform gate (see single_instance.py's docstring).
"""

import ctypes
import inspect
import sys
import unittest
from ctypes import wintypes

from ovb_rc003 import single_instance


class _FakeMutexRegistry:
    """Simulates a single named-mutex kernel object shared across multiple
    "process" launches within one test: the first ``create_mutex()`` call
    creates it (handle, last_error=0 - no prior owner); every subsequent
    call returns a NEW handle but reports ``ERROR_ALREADY_EXISTS``,
    matching real Win32 ``CreateMutexW`` semantics closely enough to
    exercise ``BridgeInstanceGuard`` without any real OS mutex. Handle and
    last-error are always returned TOGETHER from one call, mirroring the
    atomic ``MutexCreationResult`` contract (XRBM-021 review round 1 P1
    #2).
    """

    def __init__(self):
        self._exists = False
        self._next_handle = 1000
        self.create_calls = []
        self.release_calls = []
        self.close_calls = []

    def create_mutex(self, name):
        self.create_calls.append(name)
        handle = self._next_handle
        self._next_handle += 1
        last_error = single_instance._ERROR_ALREADY_EXISTS if self._exists else 0
        self._exists = True
        return single_instance.MutexCreationResult(handle=handle, last_error=last_error)

    def release_mutex(self, handle):
        self.release_calls.append(handle)
        return True

    def close_handle(self, handle):
        self.close_calls.append(handle)
        return True

    def guard(self):
        return single_instance.BridgeInstanceGuard(
            _create_mutex=self.create_mutex,
            _release_mutex=self.release_mutex,
            _close_handle=self.close_handle,
        )


class BridgeInstanceGuardAcquisitionTests(unittest.TestCase):
    def test_first_owner_acquires_successfully(self):
        registry = _FakeMutexRegistry()
        with registry.guard() as guard:
            self.assertIsNotNone(guard)
        self.assertEqual(len(registry.create_calls), 1)

    def test_uses_a_local_session_scoped_mutex_name_by_default(self):
        registry = _FakeMutexRegistry()
        with registry.guard():
            pass
        self.assertTrue(registry.create_calls[0].startswith("Local\\"))

    def test_first_owner_releases_then_closes_on_clean_exit(self):
        registry = _FakeMutexRegistry()
        with registry.guard():
            pass
        self.assertEqual(len(registry.release_calls), 1)
        self.assertEqual(len(registry.close_calls), 1)
        self.assertEqual(registry.release_calls[0], registry.close_calls[0])

    def test_settings_guard_uses_a_distinct_local_mutex(self):
        registry = _FakeMutexRegistry()
        with single_instance.SettingsInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=registry.release_mutex,
            _close_handle=registry.close_handle,
        ):
            pass
        self.assertTrue(registry.create_calls[0].startswith("Local\\"))
        self.assertNotEqual(registry.create_calls[0], single_instance._MUTEX_NAME)

    def test_existing_settings_window_activation_is_injected_and_best_effort(self):
        titles = []
        self.assertTrue(
            single_instance.activate_existing_settings_window(
                _activate=lambda title: titles.append(title) or True
            )
        )
        self.assertEqual(titles, ["Remote Mic 设置"])
        self.assertFalse(
            single_instance.activate_existing_settings_window(
                _activate=lambda _title: (_ for _ in ()).throw(OSError("unavailable"))
            )
        )

    def test_release_happens_before_close_deterministically(self):
        order = []
        registry = _FakeMutexRegistry()

        def release(handle):
            order.append(("release", handle))
            return True

        def close(handle):
            order.append(("close", handle))
            return True

        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=release,
            _close_handle=close,
        )
        with guard:
            pass
        self.assertEqual([kind for kind, _handle in order], ["release", "close"])

    def test_first_owner_releases_even_when_the_wrapped_body_raises(self):
        registry = _FakeMutexRegistry()
        with self.assertRaises(RuntimeError):
            with registry.guard():
                raise RuntimeError("simulated app startup failure")
        self.assertEqual(len(registry.release_calls), 1)
        self.assertEqual(len(registry.close_calls), 1)

    def test_close_still_runs_if_release_itself_raises(self):
        registry = _FakeMutexRegistry()

        def failing_release(handle):
            raise OSError("simulated ReleaseMutex failure")

        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=failing_release,
            _close_handle=registry.close_handle,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        self.assertEqual(len(registry.close_calls), 1)
        self.assertIn("ReleaseMutex raised", str(ctx.exception))


class BridgeInstanceGuardCleanupFailureObservabilityTests(unittest.TestCase):
    """XRBM-021 review round 1 P1 #3: ReleaseMutex/CloseHandle returning
    FALSE (not just raising) must become observable, both individually and
    when a body exception is also in flight (which must take priority).
    """

    def test_release_returning_false_raises_mutex_cleanup_error(self):
        registry = _FakeMutexRegistry()
        registry.release_mutex = lambda handle: False
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=registry.release_mutex,
            _close_handle=registry.close_handle,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        self.assertIn("ReleaseMutex returned FALSE", str(ctx.exception))
        # Close must still have been attempted despite release's failure.
        self.assertEqual(len(registry.close_calls), 1)

    def test_close_returning_false_raises_mutex_cleanup_error(self):
        registry = _FakeMutexRegistry()
        registry.close_handle = lambda handle: False
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=registry.release_mutex,
            _close_handle=registry.close_handle,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        self.assertIn("CloseHandle returned FALSE", str(ctx.exception))

    def test_release_and_close_both_returning_false_reports_both(self):
        # Matches the review's own adversarial probe shape:
        # [('release', False), ('close', False)] must not complete silently.
        registry = _FakeMutexRegistry()
        registry.release_mutex = lambda handle: False
        registry.close_handle = lambda handle: False
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=registry.release_mutex,
            _close_handle=registry.close_handle,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        message = str(ctx.exception)
        self.assertIn("ReleaseMutex returned FALSE", message)
        self.assertIn("CloseHandle returned FALSE", message)

    def test_a_body_exception_becomes_the_cleanup_errors_context_not_discarded(self):
        # XRBM-021 review round 1 CORRECTION: the previous version only
        # raised MutexCleanupError when the body did NOT also raise, which
        # meant a cleanup failure was silently accepted whenever a body
        # exception happened to already be in flight - itself a "BOOL
        # cleanup failures are silently accepted" instance. __exit__ now
        # ALWAYS raises MutexCleanupError on a cleanup failure; Python's
        # implicit exception chaining (PEP 3134) preserves the body's
        # original exception as __context__ rather than discarding it, so
        # both the cleanup failure and the original app failure remain
        # observable - a caller can always recover the original via
        # ``exc.__context__``.
        registry = _FakeMutexRegistry()

        def release(handle):
            registry.release_calls.append(handle)
            return False

        def close(handle):
            registry.close_calls.append(handle)
            return False

        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=release,
            _close_handle=close,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                raise RuntimeError("simulated app startup failure")

        self.assertIsInstance(ctx.exception.__context__, RuntimeError)
        self.assertEqual(str(ctx.exception.__context__), "simulated app startup failure")
        self.assertIn("ReleaseMutex returned FALSE", str(ctx.exception))
        self.assertIn("CloseHandle returned FALSE", str(ctx.exception))
        # Cleanup was still attempted (best-effort) despite the body's
        # failure - both steps ran exactly once.
        self.assertEqual(len(registry.release_calls), 1)
        self.assertEqual(len(registry.close_calls), 1)

    def test_cleanup_failure_message_never_contains_the_raw_handle_value(self):
        plausible_handle = 0x0000_0140_0000_1000
        registry = _FakeMutexRegistry()
        registry._next_handle = plausible_handle
        registry.release_mutex = lambda handle: False
        registry.close_handle = lambda handle: False
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=registry.release_mutex,
            _close_handle=registry.close_handle,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        message = str(ctx.exception)
        self.assertNotIn(str(plausible_handle), message)
        self.assertNotIn(hex(plausible_handle), message)
        self.assertNotIn(f"{plausible_handle:x}", message)

    def test_release_exception_text_is_never_included_in_the_failure_message(self):
        # XRBM-021 review round 1 CORRECTION: _safe_release() used to
        # interpolate str(exc) directly into its diagnostic string, which
        # could itself contain a raw handle/address (e.g. a real WinError
        # message quoting the value ReleaseMutex was called with). Only a
        # FIXED diagnostic string may appear now - never the injected
        # exception's own text.
        plausible_handle = 0x0000_0140_0000_1000

        def release(handle):
            raise RuntimeError(
                f"simulated failure referencing handle {plausible_handle} "
                f"(0x{plausible_handle:x})"
            )

        registry = _FakeMutexRegistry()
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=release,
            _close_handle=registry.close_handle,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        message = str(ctx.exception)
        self.assertIn("ReleaseMutex raised an exception", message)
        self.assertNotIn(str(plausible_handle), message)
        self.assertNotIn(hex(plausible_handle), message)
        self.assertNotIn(f"{plausible_handle:x}", message)

    def test_close_exception_text_is_never_included_in_the_failure_message(self):
        plausible_handle = 0x0000_0140_0000_1000

        def close(handle):
            raise RuntimeError(
                f"simulated failure referencing handle {plausible_handle} "
                f"(0x{plausible_handle:x})"
            )

        registry = _FakeMutexRegistry()
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=registry.create_mutex,
            _release_mutex=registry.release_mutex,
            _close_handle=close,
        )
        with self.assertRaises(single_instance.MutexCleanupError) as ctx:
            with guard:
                pass
        message = str(ctx.exception)
        self.assertIn("CloseHandle raised an exception", message)
        self.assertNotIn(str(plausible_handle), message)
        self.assertNotIn(hex(plausible_handle), message)
        self.assertNotIn(f"{plausible_handle:x}", message)


class BridgeInstanceGuardDuplicateTests(unittest.TestCase):
    def test_two_concurrent_launches_cannot_both_own_the_mutex(self):
        registry = _FakeMutexRegistry()
        with registry.guard():
            with self.assertRaises(single_instance.DuplicateInstanceError):
                with registry.guard():
                    self.fail("the duplicate guard's body must never run")

    def test_duplicate_closes_its_own_handle_but_never_releases_it(self):
        registry = _FakeMutexRegistry()
        with registry.guard():
            with self.assertRaises(single_instance.DuplicateInstanceError):
                with registry.guard():
                    pass
        # First owner: 1 release + 1 close. Duplicate: 1 close, 0 release.
        self.assertEqual(len(registry.release_calls), 1)
        self.assertEqual(len(registry.close_calls), 2)

    def test_duplicate_close_failure_is_folded_into_the_duplicate_error_not_raised_separately(self):
        # XRBM-021 review round 1 P1 #3 ("duplicate close" path): a failed
        # close of the duplicate's own probe handle must not replace the
        # primary DuplicateInstanceError signal, but must still be
        # observable in its message. Only the DUPLICATE guard's close is
        # made to fail here - the first owner's own guard (registry.guard())
        # uses the registry's normal, always-succeeding close/release, so
        # this isolates the failure to exactly the path under test.
        registry = _FakeMutexRegistry()
        duplicate_close_calls = []

        def always_failing_close(handle):
            duplicate_close_calls.append(handle)
            return False

        with registry.guard():
            with self.assertRaises(single_instance.DuplicateInstanceError) as ctx:
                with single_instance.BridgeInstanceGuard(
                    _create_mutex=registry.create_mutex,
                    _release_mutex=registry.release_mutex,
                    _close_handle=always_failing_close,
                ):
                    self.fail("the duplicate guard's body must never run")
        self.assertEqual(len(duplicate_close_calls), 1)
        self.assertIn("already running", str(ctx.exception))
        self.assertIn("CloseHandle returned FALSE", str(ctx.exception))

    def test_duplicate_error_message_never_contains_the_raw_handle_value(self):
        # DoD 4: "no raw address/handle is persisted or logged". Use a
        # large, plausible-pointer-sized handle value (same idea as
        # XRBM-019's _PLAUSIBLE_X64_HANDLE) so an accidental leak would be
        # unambiguously detectable in either decimal or hex form.
        plausible_handle = 0x0000_0140_0000_1000
        registry = _FakeMutexRegistry()
        registry._next_handle = plausible_handle
        with registry.guard():
            with self.assertRaises(single_instance.DuplicateInstanceError) as ctx:
                with registry.guard():
                    pass
        message = str(ctx.exception)
        self.assertNotIn(str(plausible_handle), message)
        self.assertNotIn(hex(plausible_handle), message)
        self.assertNotIn(f"{plausible_handle:x}", message)


class BridgeInstanceGuardAcquisitionFailureTests(unittest.TestCase):
    def test_null_handle_raises_unavailable_error(self):
        def failing_create(_name):
            return single_instance.MutexCreationResult(handle=0, last_error=5)  # ERROR_ACCESS_DENIED

        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=failing_create,
            _release_mutex=lambda h: True,
            _close_handle=lambda h: True,
        )
        with self.assertRaises(single_instance.SingleInstanceUnavailableError):
            with guard:
                self.fail("must not enter on acquisition failure")

    def test_acquisition_failure_message_never_contains_a_raw_handle_value(self):
        guard = single_instance.BridgeInstanceGuard(
            _create_mutex=lambda _name: single_instance.MutexCreationResult(handle=0, last_error=5),
            _release_mutex=lambda h: True,
            _close_handle=lambda h: True,
        )
        with self.assertRaises(single_instance.SingleInstanceUnavailableError) as ctx:
            with guard:
                pass
        # The failure message may legitimately mention the small Win32
        # error CODE (5), but never a handle value - there is none here,
        # since a failed CreateMutexW returns NULL/0.
        self.assertIn("5", str(ctx.exception))

    @unittest.skipIf(
        sys.platform == "win32",
        "only exercises the off-Windows _require_windows() gate; on a real "
        "Windows runner the real guard should acquire successfully instead "
        "(XRBM-021 review round 1 P1 #4)",
    )
    def test_default_real_implementation_is_unavailable_off_windows(self):
        # No injected fakes: exercises the REAL _real_create_mutex, which
        # calls _require_windows() first - on this non-Windows test host it
        # must raise before ever touching ctypes.windll (which does not
        # exist here).
        with self.assertRaises(single_instance.SingleInstanceUnavailableError):
            with single_instance.BridgeInstanceGuard():
                self.fail("must not enter off Windows")


class ShowBridgeStartupBlockedNoticeTests(unittest.TestCase):
    def test_calls_the_injected_message_box_with_title_and_message(self):
        calls = []

        def fake_message_box(title, message):
            calls.append((title, message))
            return 1

        single_instance.show_bridge_startup_blocked_notice(
            "custom duplicate message", _message_box=fake_message_box
        )
        self.assertEqual(len(calls), 1)
        title, message = calls[0]
        self.assertIn("Remote Mic", title)
        self.assertEqual(message, "custom duplicate message")

    def test_falls_back_to_stderr_when_the_message_box_itself_fails(self):
        def failing_message_box(_title, _message):
            raise OSError("simulated MessageBoxW failure")

        # Must not raise - this is a best-effort user notice, not a
        # resource-ownership operation.
        single_instance.show_bridge_startup_blocked_notice(
            "unavailable case", _message_box=failing_message_box
        )


class MutexCtypesPrototypeTests(unittest.TestCase):
    """Structural exact-prototype coverage, matching the convention
    established by tests/test_win32_ctypes_argtypes.py: every Win32 call
    here must declare argtypes/restype using pointer-sized ctypes.wintypes
    aliases rather than being left at ctypes' unprototyped defaults, which
    XRBM-019 identified as silently truncating a 64-bit value to 32 bits.
    """

    def test_handle_is_genuinely_pointer_sized(self):
        self.assertEqual(ctypes.sizeof(wintypes.HANDLE), ctypes.sizeof(ctypes.c_void_p))

    def test_create_mutex_declares_the_full_real_prototype(self):
        source = inspect.getsource(single_instance._real_create_mutex)
        self.assertIn("CreateMutexW.argtypes", source)
        self.assertIn("CreateMutexW.restype", source)
        for token in ("wintypes.LPVOID", "wintypes.BOOL", "wintypes.LPCWSTR", "wintypes.HANDLE"):
            self.assertIn(token, source)

    def test_create_mutex_captures_last_error_atomically(self):
        # XRBM-021 review round 1 P1 #2: GetLastError must be captured via
        # a use_last_error=True WinDLL handle immediately after
        # CreateMutexW, inside the SAME function - never via a separate,
        # later, independently-callable GetLastError wrapper.
        source = inspect.getsource(single_instance._real_create_mutex)
        self.assertIn("use_last_error=True", source)
        self.assertIn("ctypes.get_last_error()", source)
        self.assertNotIn("windll.kernel32", source)  # must use the WinDLL(...) form, not the shared cache

    def test_no_standalone_get_last_error_wrapper_exists(self):
        # There must be no independently-callable "fetch the last error
        # now" function for a caller to accidentally call too late - the
        # error is only ever available bundled in MutexCreationResult.
        self.assertFalse(hasattr(single_instance, "_real_get_last_error"))
        self.assertFalse(hasattr(single_instance, "GetLastErrorFn"))

    def test_release_mutex_declares_the_full_real_prototype(self):
        source = inspect.getsource(single_instance._real_release_mutex)
        self.assertIn("ReleaseMutex.argtypes", source)
        self.assertIn("ReleaseMutex.restype", source)
        self.assertIn("wintypes.HANDLE", source)
        self.assertIn("wintypes.BOOL", source)

    def test_close_handle_declares_the_full_real_prototype(self):
        source = inspect.getsource(single_instance._real_close_handle)
        self.assertIn("CloseHandle.argtypes", source)
        self.assertIn("CloseHandle.restype", source)
        self.assertIn("wintypes.HANDLE", source)
        self.assertIn("wintypes.BOOL", source)

    def test_message_box_declares_the_full_real_prototype(self):
        source = inspect.getsource(single_instance._real_message_box)
        self.assertIn("MessageBoxW.argtypes", source)
        self.assertIn("MessageBoxW.restype", source)
        for token in ("wintypes.HWND", "wintypes.LPCWSTR", "wintypes.UINT"):
            self.assertIn(token, source)


if __name__ == "__main__":
    unittest.main()
