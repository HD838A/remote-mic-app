"""Replays the XRBM-026 CI hard gate's exact detection logic
(``.github/workflows/windows-rc003-ci.yml``'s "Run test suite" step) in
Python, so its pattern-matching contract is covered by an automated test
that runs on any OS - not just when a real Windows/pwsh runner exercises the
actual step (mirrors this project's existing
``tests/test_boundary_scan_replay.py`` approach for
``build/check-public-boundary.ps1``).

Red evidence this gate exists for (real Windows run 29644660267): 425 tests
completed with "OK (skipped=3)", then the process printed an ignored
ResourceWarning for one unclosed ProactorEventLoop and two unclosed
self-pipe sockets - AFTER unittest's own summary. ``-W error::ResourceWarning``
only turns a warning into an exception at the moment it is raised DURING
normal execution; a ResourceWarning raised inside a ``__del__``/finalizer at
CPython interpreter shutdown is unraisable (Python can only print it via
``sys.unraisablehook``) and can never change unittest's own, already-computed
exit code - so the step still exited 0. The gate below closes that loophole
by scanning the full captured step output for forbidden markers, entirely
independent of the process's exit code.

This deliberately reimplements the gate's forbidden-pattern list rather than
parsing the workflow YAML's embedded PowerShell into Python; if you change
one, change both and re-run this test (plus
``tests.test_build_artifacts.WindowsCiWorkflowTests``, which checks these
same literal strings exist in the real workflow file) to confirm they still
agree.
"""

import re
import unittest
from pathlib import Path

_RC003_ROOT = Path(__file__).resolve().parents[1]
_REPO_ROOT = _RC003_ROOT.parents[2]
_CI_PATH = _REPO_ROOT / ".github" / "workflows" / "windows-rc003-ci.yml"

# Mirrors $forbiddenPatterns in windows-rc003-ci.yml's "Run test suite" step
# exactly - keep both lists in sync. "ResourceWarning:" (colon included, not
# a bare "ResourceWarning") deliberately matches Python's own exact
# warning-output text - unittest's own -v output prints fully-qualified test
# names as "module.ClassName) ... ok", and this suite's own regression
# coverage for THIS gate legitimately names a class
# "ResourceWarningGateReplayTests" (see ResourceWarningGateReplayTests
# below) - a bare substring match would make this gate fail on its own
# passing regression tests. Real CPython warning/exception output always
# renders as "ResourceWarning: <message>" - the colon never appears
# directly after "ResourceWarning" in any test name.
_FORBIDDEN_LOG_PATTERNS = (
    "ResourceWarning:",
    "unclosed event loop",
    "unclosed <socket.socket",
)


def _log_fails_gate(log_text: str) -> bool:
    """Mirrors the PowerShell gate's
    ``$logContent -match [regex]::Escape($pattern)`` check for each
    forbidden pattern, over the FULL captured step output - not conditioned
    on the test process's own exit code, which is exactly the property that
    closes the red evidence's loophole.
    """

    return any(
        re.search(re.escape(pattern), log_text) for pattern in _FORBIDDEN_LOG_PATTERNS
    )


class ResourceWarningGateReplayTests(unittest.TestCase):
    def test_clean_log_passes(self):
        log = (
            "test_something (tests.test_x.XTests) ... ok\n\n"
            "----------------------------------------------------------------------\n"
            "Ran 425 tests in 5.059s\n\n"
            "OK (skipped=3)\n"
        )
        self.assertFalse(_log_fails_gate(log))

    def test_red_evidence_shaped_log_fails(self):
        # Real Windows run 29644660267's exact shape: 425 tests pass, THEN
        # the late warning prints after unittest's own summary.
        log = (
            "test_something (tests.test_x.XTests) ... ok\n\n"
            "----------------------------------------------------------------------\n"
            "Ran 425 tests in 5.059s\n\n"
            "OK (skipped=3)\n"
            "Exception ignored in: <function BaseEventLoop.__del__ at 0x00000123>\n"
            "Traceback (most recent call last):\n"
            "  File \"...\\asyncio\\base_events.py\", line 681, in __del__\n"
            "ResourceWarning: unclosed event loop "
            "<ProactorEventLoop running=False closed=False>\n"
            "Exception ignored in: <socket.socket fd=4, family=AddressFamily.AF_INET,"
            " type=SocketKind.SOCK_STREAM, proto=0>\n"
            "ResourceWarning: unclosed <socket.socket fd=4, "
            "family=AddressFamily.AF_INET, type=SocketKind.SOCK_STREAM, proto=0>\n"
            "Exception ignored in: <socket.socket fd=5, family=AddressFamily.AF_INET,"
            " type=SocketKind.SOCK_STREAM, proto=0>\n"
            "ResourceWarning: unclosed <socket.socket fd=5, "
            "family=AddressFamily.AF_INET, type=SocketKind.SOCK_STREAM, proto=0>\n"
        )
        self.assertTrue(_log_fails_gate(log))

    def test_resourcewarning_with_colon_fails(self):
        self.assertTrue(
            _log_fails_gate("ResourceWarning: unclosed transport <...>")
        )

    def test_bare_resourcewarning_word_without_a_colon_does_not_false_positive(self):
        # A bare mention (no colon immediately after) must NOT trip the
        # gate - this is exactly the shape of this test module's own class
        # name below, not a real Python warning/exception line.
        self.assertFalse(_log_fails_gate("some prose mentions ResourceWarning here"))

    def test_this_modules_own_test_class_name_does_not_false_positive(self):
        # Regression for the exact collision this gate design originally
        # had: unittest's -v output prints
        # "test_x (tests.test_resourcewarning_gate_replay.
        # ResourceWarningGateReplayTests) ... ok" for every test in THIS
        # class - a bare "ResourceWarning" substring match would have made
        # the gate fail on its own passing regression suite.
        log = (
            "test_resourcewarning_with_colon_fails "
            "(tests.test_resourcewarning_gate_replay."
            "ResourceWarningGateReplayTests) ... ok\n"
            "OK (skipped=0)\n"
        )
        self.assertFalse(_log_fails_gate(log))

    def test_unclosed_event_loop_alone_fails(self):
        self.assertTrue(
            _log_fails_gate("unclosed event loop <_UnixSelectorEventLoop>")
        )

    def test_unclosed_socket_alone_fails(self):
        self.assertTrue(_log_fails_gate("unclosed <socket.socket fd=9>"))

    def test_gate_ignores_exit_code_and_only_inspects_log_content(self):
        # The whole point of this gate: a log ending in "OK" (what a green
        # exit code implies) must still fail if a forbidden pattern appears
        # anywhere in it - the gate never conditions on exit-code-derived
        # success, only on the captured text itself.
        log = "OK (skipped=3)\nunclosed <socket.socket fd=5, family=AF_UNIX>\n"
        self.assertTrue(_log_fails_gate(log))

    def test_unrelated_use_of_the_word_socket_does_not_false_positive(self):
        log = (
            "test_socket_selection_matches_by_name_and_host_api ... ok\n"
            "OK (skipped=3)\n"
        )
        self.assertFalse(_log_fails_gate(log))


class WorkflowGateTextConsistencyTests(unittest.TestCase):
    """Keeps this replay's forbidden-pattern list in sync with the actual
    workflow file's PowerShell ``$forbiddenPatterns`` array - a hand-authored
    Python constant silently drifting out of sync with the real gate would
    make every test above prove nothing about the real CI step.
    """

    def setUp(self):
        self.ci_text = _CI_PATH.read_text(encoding="utf-8")

    def test_every_forbidden_pattern_appears_in_the_workflow_gate(self):
        for pattern in _FORBIDDEN_LOG_PATTERNS:
            self.assertIn(f'"{pattern}"', self.ci_text)

    def test_gate_scans_captured_log_content_not_just_exit_code(self):
        self.assertIn("Tee-Object -FilePath", self.ci_text)
        self.assertIn("Get-Content -Path $logPath -Raw", self.ci_text)
        self.assertIn("[regex]::Escape($pattern)", self.ci_text)

    def test_gate_runs_after_the_test_suite_but_still_fails_the_step(self):
        run_step_start = self.ci_text.index("- name: Run test suite")
        next_step_start = self.ci_text.index("- name:", run_step_start + 1)
        run_step_text = self.ci_text[run_step_start:next_step_start]
        unittest_index = run_step_text.index("-m unittest discover")
        gate_index = run_step_text.index("$forbiddenPatterns")
        self.assertLess(unittest_index, gate_index)
        self.assertIn("exit 1", run_step_text[gate_index:])

    def test_test_step_exit_code_is_still_checked_before_the_gate_runs(self):
        # The gate is a SECOND, independent layer - it must not replace the
        # existing $LASTEXITCODE check (a real test FAILURE must still fail
        # the step immediately, before ever reaching the log-content scan).
        run_step_start = self.ci_text.index("- name: Run test suite")
        next_step_start = self.ci_text.index("- name:", run_step_start + 1)
        run_step_text = self.ci_text[run_step_start:next_step_start]
        exitcode_index = run_step_text.index("$testExitCode")
        gate_index = run_step_text.index("$forbiddenPatterns")
        self.assertLess(exitcode_index, gate_index)


if __name__ == "__main__":
    unittest.main()
