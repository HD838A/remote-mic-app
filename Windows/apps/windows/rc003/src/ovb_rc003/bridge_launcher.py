"""Launches the bridge process from the settings window (XRBM-029), and
reports what actually happened - not just "a process was created". This
module never conflates a launched/still-running process with "RC003 is
connected": that fact is only observable from ``app.log`` (see
``logging_setup.py``), never from process liveness alone.

Command construction (``build_launch_command``) covers exactly the two ways
this package's own entry point (``__main__.py``) is ever invoked, so a
future third mode cannot silently fall through unnoticed:

- **Frozen** (the packaged ``RemoteMicRC003.exe``, built from
  ``src/launcher.py`` - see that module's docstring): ``sys.executable`` IS
  that same exe, and running it again with ``--bridge`` enters
  ``__main__.main()``'s ``_run_bridge()`` branch. The no-argument form now
  opens the settings window, so the bridge is always launched EXPLICITLY -
  never ``--settings``, which would just open a second settings window
  instead of starting the bridge.
- **Source** (``python -m ovb_rc003``): ``sys.executable`` is the
  interpreter itself; ``[sys.executable, "-m", "ovb_rc003", "--bridge"]``
  enters the same bridge branch. This relies on the child inheriting the
  parent process's environment (``subprocess.Popen`` does this by default) -
  in particular ``PYTHONPATH=src``, which the settings window's own process
  needed to have been started with in order to import ``ovb_rc003`` at all
  (see the root README's "Running from source" section).

Both branches deliberately append ``--bridge`` and never ``--settings``:
that argument would recursively open another settings window instead of
starting the bridge (In-scope item 2's "不得递归打开 --settings").

Launch-outcome detection (``launch_bridge``) distinguishes four states by
polling the child for a short grace period rather than assuming
"``Popen()`` did not raise" means "the bridge is running":

- ``STARTED``: the process is still alive once the grace period elapses -
  the best evidence available from process state alone that startup is
  proceeding, NOT proof of an RC003 connection.
- ``ALREADY_RUNNING``: the process exited within the grace period with
  exactly ``single_instance.DUPLICATE_INSTANCE_EXIT_CODE`` - the
  single-instance guard in ``single_instance.py``/``__main__.py`` refused a
  second concurrent bridge instance. Reusing that exact constant (rather
  than redefining a second one here) keeps the two modules from silently
  drifting apart if the exit code is ever renumbered.
- ``QUICK_EXIT``: the process exited within the grace period with any OTHER
  code (including ``GUARD_UNAVAILABLE_EXIT_CODE``/``CLEANUP_FAILED_EXIT_CODE``
  or an unhandled exception's implicit ``1``) - a real failure, whose exact
  code is always surfaced to the caller rather than swallowed, so a user or
  reviewer can distinguish it from a clean exit without guessing.
- ``LAUNCH_FAILED``: ``Popen()`` itself raised ``OSError`` (e.g. the target
  executable is missing or not executable) - no process was ever created at
  all.

Testability: every OS-facing call (``_popen``, ``_sleep``) is injectable, so
tests/test_bridge_launcher.py drives all four outcomes deterministically -
including the grace-period polling loop - without spawning a real process or
sleeping in real wall-clock time, the same dependency-injection pattern this
package's other Win32-facing modules already use (see e.g.
``single_instance.py``'s ``_create_mutex``/``_release_mutex``/
``_close_handle`` parameters).
"""

from __future__ import annotations

import subprocess
import sys
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from . import bridge_control_windows, single_instance

# Reused, not redefined - see module docstring's ALREADY_RUNNING note.
ALREADY_RUNNING_EXIT_CODE = single_instance.DUPLICATE_INSTANCE_EXIT_CODE

DEFAULT_GRACE_CHECKS = 10
DEFAULT_POLL_INTERVAL_SECONDS = 0.15


class BridgeLaunchConfigurationError(Exception):
    """Raised when a launch command cannot be constructed at all (e.g.
    ``sys.executable`` is empty - which CPython documents can happen in some
    embedding scenarios). Fails closed rather than handing ``Popen`` an
    empty/garbage argv[0].
    """


def build_launch_command(
    *,
    frozen: Optional[bool] = None,
    executable: Optional[str] = None,
) -> List[str]:
    """Builds the bridge launch command for the CURRENT process shape.
    Always appends ``--bridge``: the no-argument form of this exe now opens
    the settings window, so the bridge must be requested explicitly.
    ``frozen``/``executable`` are injectable so tests can exercise both
    branches deterministically on any OS - production callers should never
    pass them.
    """

    if frozen is None:
        frozen = bool(getattr(sys, "frozen", False))
    if executable is None:
        executable = sys.executable

    if not executable:
        raise BridgeLaunchConfigurationError(
            "sys.executable is empty; cannot construct a bridge launch command"
        )

    if frozen:
        # The same frozen exe handles both modes: with no arguments (or
        # --settings) it opens the settings window, and with --bridge (as
        # launched here) it starts the bridge - see __main__.py's dispatch.
        return [executable, "--bridge"]
    # The current interpreter, `-m ovb_rc003 --bridge`.
    return [executable, "-m", "ovb_rc003", "--bridge"]


class LaunchOutcome(Enum):
    STARTED = "started"
    ALREADY_RUNNING = "already_running"
    QUICK_EXIT = "quick_exit"
    LAUNCH_FAILED = "launch_failed"
    STOP_FAILED = "stop_failed"
    STOP_TIMEOUT = "stop_timeout"


@dataclass(frozen=True)
class LaunchResult:
    outcome: LaunchOutcome
    command: Tuple[str, ...]
    pid: Optional[int] = None
    exit_code: Optional[int] = None
    error: Optional[str] = None


def launch_bridge(
    command: Optional[Sequence[str]] = None,
    *,
    grace_checks: int = DEFAULT_GRACE_CHECKS,
    poll_interval_seconds: float = DEFAULT_POLL_INTERVAL_SECONDS,
    _popen: Callable[..., "subprocess.Popen"] = subprocess.Popen,
    _sleep: Callable[[float], None] = time.sleep,
    _popen_kwargs: Optional[Dict[str, object]] = None,
) -> LaunchResult:
    """Starts the bridge and watches it for a short grace period to tell a
    process that is actually running apart from one that merely got created
    and then immediately died. Never raises for an ordinary launch failure
    (``OSError`` from ``_popen``) - that is reported as ``LAUNCH_FAILED``
    instead, since this is called directly from a Tk button handler that
    must not crash the settings window over a failed launch.
    """

    resolved_command: Tuple[str, ...] = (
        tuple(command) if command is not None else tuple(build_launch_command())
    )

    popen_kwargs = dict(_popen_kwargs) if _popen_kwargs is not None else {}
    if _popen is subprocess.Popen and sys.platform == "win32":
        # A bridge subprocess is a console subsystem program (python.exe in a
        # source checkout) or a frozen ``console=False`` exe; without this
        # flag Windows flashes a black console window for the child even when
        # the parent is a GUI app. CREATE_NO_WINDOW only exists on Windows.
        popen_kwargs.setdefault(
            "creationflags", getattr(subprocess, "CREATE_NO_WINDOW", 0)
        )

    try:
        process = _popen(list(resolved_command), **popen_kwargs)
    except OSError as exc:
        return LaunchResult(
            outcome=LaunchOutcome.LAUNCH_FAILED,
            command=resolved_command,
            error=str(exc),
        )

    pid = getattr(process, "pid", None)
    exit_code = process.poll()
    checks = 0
    while exit_code is None and checks < grace_checks:
        _sleep(poll_interval_seconds)
        exit_code = process.poll()
        checks += 1

    if exit_code is None:
        return LaunchResult(outcome=LaunchOutcome.STARTED, command=resolved_command, pid=pid)
    if exit_code == ALREADY_RUNNING_EXIT_CODE:
        return LaunchResult(
            outcome=LaunchOutcome.ALREADY_RUNNING,
            command=resolved_command,
            pid=pid,
            exit_code=exit_code,
        )
    return LaunchResult(
        outcome=LaunchOutcome.QUICK_EXIT,
        command=resolved_command,
        pid=pid,
        exit_code=exit_code,
    )


def restart_bridge(
    *,
    stop_timeout_seconds: float = 8.0,
    poll_interval_seconds: float = 0.100,
    _request_stop=None,
    _is_running=None,
    _launch=None,
    _sleep: Callable[[float], None] = time.sleep,
) -> LaunchResult:
    """Gracefully replace the current bridge so saved settings take effect."""

    request_stop = _request_stop or bridge_control_windows.request_bridge_stop
    is_running = _is_running or bridge_control_windows.bridge_is_running
    launch = _launch or launch_bridge
    stop_result = request_stop()
    if stop_result.outcome is bridge_control_windows.StopRequestOutcome.FAILED:
        return LaunchResult(
            outcome=LaunchOutcome.STOP_FAILED,
            command=tuple(),
            error=stop_result.error,
        )
    if stop_result.outcome is bridge_control_windows.StopRequestOutcome.REQUESTED:
        deadline = time.monotonic() + max(0.0, stop_timeout_seconds)
        while True:
            try:
                running = is_running()
            except bridge_control_windows.BridgeControlUnavailableError as exc:
                return LaunchResult(
                    outcome=LaunchOutcome.STOP_FAILED,
                    command=tuple(),
                    error=str(exc),
                )
            if not running:
                break
            if time.monotonic() >= deadline:
                return LaunchResult(
                    outcome=LaunchOutcome.STOP_TIMEOUT,
                    command=tuple(),
                    error="the previous bridge did not stop within the timeout",
                )
            _sleep(max(0.0, poll_interval_seconds))
    return launch()
