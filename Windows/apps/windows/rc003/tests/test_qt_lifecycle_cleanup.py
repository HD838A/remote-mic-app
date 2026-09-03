"""Regression test (XRBM-030 RETRY 1 blocker 3): proves the REAL Windows CI
command this package's test-suite step actually runs produces NO
"ResourceWarning:" output at interpreter shutdown, with PySide6-Essentials
installed.

Red evidence this guards against: before ``qt_settings_app.py`` gained
``_release_qt_classes_cache()`` (an ``atexit``-registered hook that drops
this module's cached dynamically-created ``QObject``/``QAbstractListModel``
subclasses and calls ``gc.collect()`` while the interpreter is still fully
alive), running

    PYTHONPATH=apps/windows/rc003/src QT_QPA_PLATFORM=offscreen \\
      QML_DISABLE_DISK_CACHE=1 python -W default::ResourceWarning \\
      -m unittest discover -s apps/windows/rc003/tests -t apps/windows/rc003 \\
      -p "test_*.py"

ended with exactly::

    gc:0: ResourceWarning: gc: 13 uncollectable objects at shutdown; use gc.set_debug(gc.DEBUG_UNCOLLECTABLE) to list them

- root-caused to ``PySide6.QtCore.Property`` descriptors participating in a
Python-level reference cycle that shiboken's C extension type does not fully
support ``tp_clear`` for (reproduced with a minimal, completely unrelated
repro: a single trivial ``Property``-having ``QObject`` subclass, module-
level, no closures, no caching). ``.github/workflows/windows-rc003-ci.yml``'s
test-suite step explicitly greps its captured output for the literal
substring ``"ResourceWarning:"`` and fails the whole job if it appears
anywhere - this substring match, not the process exit code, is what a
finalizer-time warning like this actually threatens (an exception raised
inside a finalizer at interpreter shutdown is unraisable and never changes
an already-computed exit code - see tests/test_resourcewarning_gate_replay.py
and tests/test_build_artifacts.py's XRBM-026 tests for that same fact
established for a different warning shape).

This test does NOT weaken, suppress, or edit that CI gate - it proves the
exact command the gate runs is actually clean, by literally invoking it (as
a subprocess, so this test's own process is never place at risk of the
recursion that discovering and re-running this very test file would
otherwise cause - guarded below).
"""

import os
import subprocess
import sys
import unittest
from pathlib import Path

_RC003_ROOT = Path(__file__).resolve().parents[1]

# Sentinel env var: sets guard against the subprocess's own `unittest
# discover` (deliberately scoped to the WHOLE tests/ directory, matching
# the real CI command exactly) re-discovering and re-running THIS test,
# which would otherwise recurse (a subprocess spawning a subprocess
# spawning a subprocess...) forever.
_RECURSION_GUARD_ENV_VAR = "_OVB_RC003_RESOURCEWARNING_PROBE_RUNNING"


def _has_pyside6() -> bool:
    try:
        import PySide6.QtCore  # noqa: F401
    except ImportError:
        return False
    return True


@unittest.skipUnless(
    _has_pyside6(), "PySide6-Essentials not installed - nothing Qt-related to prove clean here"
)
@unittest.skipIf(
    os.environ.get(_RECURSION_GUARD_ENV_VAR) == "1",
    "already running inside this test's own subprocess - see module docstring",
)
class NoResourceWarningAtShutdownTests(unittest.TestCase):
    def test_full_test_suite_command_produces_no_resourcewarning_at_shutdown(self):
        env = dict(os.environ)
        env["PYTHONPATH"] = str(_RC003_ROOT / "src")
        env.setdefault("QT_QPA_PLATFORM", "offscreen")
        env["QML_DISABLE_DISK_CACHE"] = "1"
        env[_RECURSION_GUARD_ENV_VAR] = "1"

        # The exact real command windows-rc003-ci.yml's test-suite step
        # runs (see that workflow's "Run test suite" step and
        # tests/test_build_artifacts.py's WindowsCiWorkflowTests asserting
        # its exact shape) - `-W default::ResourceWarning` (not `error::`)
        # matches the task's own reproduction command: this is about the
        # literal printed text a content-scan gate greps for, not about
        # turning the warning into a raised exception.
        result = subprocess.run(
            [
                sys.executable,
                "-W", "default::ResourceWarning",
                "-m", "unittest", "discover",
                "-s", str(_RC003_ROOT / "tests"),
                "-t", str(_RC003_ROOT),
                "-p", "test_*.py",
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )

        self.assertEqual(
            result.returncode,
            0,
            f"full test suite subprocess failed:\nSTDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}",
        )
        self.assertNotIn(
            "ResourceWarning:",
            result.stdout,
            "the real CI command's stdout contains a forbidden "
            "'ResourceWarning:' substring",
        )
        self.assertNotIn(
            "ResourceWarning:",
            result.stderr,
            "the real CI command's stderr contains a forbidden "
            "'ResourceWarning:' substring",
        )


if __name__ == "__main__":
    unittest.main()
