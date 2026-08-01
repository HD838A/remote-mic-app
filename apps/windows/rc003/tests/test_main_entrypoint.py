import unittest
from unittest import mock

from ovb_rc003 import single_instance
from ovb_rc003 import __main__ as entrypoint


class _RaisingGuard:
    error = None

    def __enter__(self):
        raise self.error

    def __exit__(self, _exc_type, _exc, _tb):
        return None


class BridgeExitCodeTests(unittest.TestCase):
    def _run_with(self, error):
        _RaisingGuard.error = error
        with mock.patch.object(single_instance, "BridgeInstanceGuard", _RaisingGuard), mock.patch.object(
            single_instance, "show_bridge_startup_blocked_notice"
        ):
            return entrypoint._run_bridge()

    def test_duplicate_instance_has_its_own_exit_code(self):
        self.assertEqual(
            self._run_with(single_instance.DuplicateInstanceError("duplicate")),
            single_instance.DUPLICATE_INSTANCE_EXIT_CODE,
        )

    def test_unavailable_guard_has_its_own_exit_code(self):
        self.assertEqual(
            self._run_with(single_instance.SingleInstanceUnavailableError("unavailable")),
            single_instance.GUARD_UNAVAILABLE_EXIT_CODE,
        )

    def test_mutex_cleanup_failure_has_its_own_exit_code(self):
        class _CleanupGuard:
            def __enter__(self):
                return self

            def __exit__(self, _exc_type, _exc, _tb):
                raise single_instance.MutexCleanupError("cleanup")

        def close_without_running(coroutine):
            coroutine.close()

        with mock.patch.object(single_instance, "BridgeInstanceGuard", _CleanupGuard), mock.patch.object(
            entrypoint.asyncio, "run", side_effect=close_without_running
        ), mock.patch.object(single_instance, "show_bridge_startup_blocked_notice"):
            self.assertEqual(
                entrypoint._run_bridge(), single_instance.CLEANUP_FAILED_EXIT_CODE
            )


if __name__ == "__main__":
    unittest.main()
