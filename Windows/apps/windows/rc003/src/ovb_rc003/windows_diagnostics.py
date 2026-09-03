"""Qt-free "检查与修复" (check-and-repair) diagnostics (XRBM-031).

Every check below is a plain function returning a typed, stable
``CheckResult`` - no Tk/Qt import anywhere in this module, matching this
package's existing convention (``settings_ui.py``, ``remote_layout.py``,
``shell_targets.py``) of keeping business logic directly unit-testable
without constructing a window. ``qt_settings_app.py`` is the only place that
runs ``run_diagnostics()`` off the Qt GUI thread and renders its results.

Every check that touches a real OS/WinRT/PortAudio call accepts an
injectable override (a ``probe``/``discover``/``enumerate_*`` callable) so
its PASS/FAIL/MANUAL branching is exercised directly in tests on any OS,
while the real, uninjected default degrades to ``UNSUPPORTED`` off Windows
or when an optional dependency is missing - it never fabricates a result it
cannot actually observe (In-scope item 2/4's core honesty contract: a live
process or a paired device must never be reported as proof that buttons or
speech are working).

Raw Input and BLE candidate checks deliberately report only a COUNT/status,
never a device path or Bluetooth name/address - this module must not become
a second place that leaks the identifiers ``config.py``/``logging_setup.py``
already refuse to persist.

BLE candidate discovery (XRBM-035 RETRY 1) runs in a separate, disposable OS
process, not merely a background thread of this one - see the "-- BLE
candidate --" section below for why an in-process asyncio cancellation
cannot give a real hard bound against the locked pywinrt wrapper's own
unbounded post-cancel wait, and how process-level termination does.
"""

from __future__ import annotations

import functools
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, List, Optional, Sequence, Tuple

from . import audio_output
from . import ble_transport_winrt
from . import identity
from . import raw_input_windows
from . import rc003_battery_windows

# Windows 10 version 1809's build number - the lowest build this project's
# own README/installer already claim as the supported floor (see
# installer/RemoteMicRC003Setup.iss's ``MinVersion=10.0.17763``).
MIN_SUPPORTED_BUILD = 17763


class CheckStatus(Enum):
    PASS = "pass"
    FAIL = "fail"
    MANUAL = "manual"  # 待手动验证：Windows exposes no reliable automatic verdict
    UNSUPPORTED = "unsupported"  # not Windows, or a required dependency is missing


class CheckGroup(Enum):
    """The four groups In-scope item 4 requires the summary to distinguish
    - never collapsed into one another, since a passing optional-driver
    check must never look like proof that voice or dictation works.
    """

    ORDINARY_BUTTONS = "ordinary_buttons"
    VOICE_BRIDGE = "voice_bridge"
    DICTATION = "dictation"
    OPTIONAL_DRIVER = "optional_driver"
    EXTERNAL_MICROPHONE = "external_microphone"


@dataclass(frozen=True)
class CheckResult:
    check_id: str
    title: str
    group: CheckGroup
    status: CheckStatus
    detail: str


@dataclass(frozen=True)
class DiagnosticsReport:
    checks: Tuple[CheckResult, ...]

    def get(self, check_id: str) -> Optional[CheckResult]:
        for check in self.checks:
            if check.check_id == check_id:
                return check
        return None


# -- OS version/architecture ------------------------------------------------


@dataclass(frozen=True)
class WindowsVersionInfo:
    major: int
    minor: int
    build: int
    is_64bit: bool


def _probe_windows_version() -> Optional[WindowsVersionInfo]:
    """Real probe: None off Windows. Never raises."""

    if sys.platform != "win32":
        return None
    version_info = sys.getwindowsversion()  # type: ignore[attr-defined]
    is_64bit = platform.machine().lower() in ("amd64", "x86_64", "arm64")
    return WindowsVersionInfo(
        major=version_info.major,
        minor=version_info.minor,
        build=version_info.build,
        is_64bit=is_64bit,
    )


def check_os_version(
    *, probe: Callable[[], Optional[WindowsVersionInfo]] = _probe_windows_version
) -> CheckResult:
    version_info = probe()
    if version_info is None:
        return CheckResult(
            "os_version",
            "Windows 版本与 64 位架构",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.UNSUPPORTED,
            "当前不是 Windows，无法核验版本/位数契约。",
        )
    if not version_info.is_64bit:
        return CheckResult(
            "os_version",
            "Windows 版本与 64 位架构",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            "检测到非 64 位系统；本程序需要 64 位 Windows 10 1809 (17763) 或以上。",
        )
    if version_info.build < MIN_SUPPORTED_BUILD:
        return CheckResult(
            "os_version",
            "Windows 版本与 64 位架构",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            f"当前 build {version_info.build} 低于 Windows 10 1809 "
            f"({MIN_SUPPORTED_BUILD}) 的支持下限。",
        )
    return CheckResult(
        "os_version",
        "Windows 版本与 64 位架构",
        CheckGroup.ORDINARY_BUTTONS,
        CheckStatus.PASS,
        f"Windows build {version_info.build}，64 位，满足 1809+ 契约。",
    )


# -- Raw Input (ordinary buttons) -------------------------------------------


def check_raw_input(
    *,
    enumerate_paths: Callable[
        [], Sequence[str]
    ] = raw_input_windows.enumerate_matching_device_paths,
) -> CheckResult:
    try:
        paths = enumerate_paths()
    except raw_input_windows.RawInputUnavailableError:
        if sys.platform != "win32":
            return CheckResult(
                "raw_input",
                "Raw Input 按键设备",
                CheckGroup.ORDINARY_BUTTONS,
                CheckStatus.UNSUPPORTED,
                "当前不是 Windows，无法枚举 Raw Input 设备。",
            )
        # RETRY 3 (independent review): this used to interpolate str(exc)
        # here. RawInputUnavailableError's real production message is
        # API-only today, but nothing stops a future/injected raise from
        # carrying a real Raw Input device path in its message - and this
        # module's own contract (see module docstring) is that Raw Input
        # output never surfaces an identifier, not "never surfaces one
        # unless the exception happens to be safe". Generic and actionable
        # instead, with no exception text at all.
        return CheckResult(
            "raw_input",
            "Raw Input 按键设备",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            "Raw Input 设备枚举失败，出现意外错误；请检查遥控器连接后点击"
            "「重新检测」重试。",
        )

    count = len(paths)
    # Never report the path itself - count/status only (In-scope item 2).
    if count == 0:
        return CheckResult(
            "raw_input",
            "Raw Input 按键设备",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            "未发现匹配 RC003 VID/PID 的 Raw Input 设备；请先在 Windows 蓝牙设置中配对。",
        )
    if count > 1:
        return CheckResult(
            "raw_input",
            "Raw Input 按键设备",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            f"发现 {count} 个匹配设备，无法唯一确定；请仅保留一个已连接设备后重试。",
        )
    return CheckResult(
        "raw_input",
        "Raw Input 按键设备",
        CheckGroup.ORDINARY_BUTTONS,
        CheckStatus.PASS,
        "发现恰好一个匹配的 Raw Input 设备。",
    )


def check_rc003_battery(
    *,
    probe: Callable[[], Optional[int]] = rc003_battery_windows.read_rc003_battery_percent,
) -> CheckResult:
    """Read the percentage Windows exposes for the paired RC003 device node."""

    try:
        percent = probe()
    except rc003_battery_windows.BatteryProbeUnavailableError:
        return CheckResult(
            "rc003_battery", "RC003 电量", CheckGroup.VOICE_BRIDGE,
            CheckStatus.UNSUPPORTED, "当前系统无法读取 RC003 电量。",
        )
    if percent is None:
        return CheckResult(
            "rc003_battery", "RC003 电量", CheckGroup.VOICE_BRIDGE,
            CheckStatus.MANUAL, "暂时不可用（唤醒遥控器后重新检测）",
        )
    if not 0 <= percent <= 100:
        return CheckResult(
            "rc003_battery", "RC003 电量", CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL, "Windows 返回了无效的电量值，请重新检测。",
        )
    return CheckResult(
        "rc003_battery", "RC003 电量", CheckGroup.VOICE_BRIDGE,
        CheckStatus.PASS, f"{percent}%",
    )


# -- BLE candidate (voice bridge) -------------------------------------------
#
# XRBM-035 RETRY 1: the diagnostics-only BLE discovery below runs in a
# genuinely separate OS PROCESS, not merely a cancellable asyncio Task in
# this process. XRBM-035 round 1 tried the latter (cancel the asyncio Task
# wrapping discover_candidates(), relying on the locked pywinrt >=3.2
# asyncio-cancellation-propagates-to-WinRT documented behaviour) and an
# independent review found the real, locked winrt-runtime==3.2.1
# ``winrt/runtime/_internals.py::wrap_async()`` source:
#
#     except asyncio.CancelledError:
#         op.cancel()
#         await event.wait()   # <-- UNBOUNDED: waits for the native
#         raise                #     completion callback with no timeout
#
# ``IAsyncInfo.cancel()`` only REQUESTS cancellation (Microsoft's own ABI
# docs give no completion-time guarantee) - the Python-level ``await task``
# after calling ``task.cancel()`` can therefore still hang indefinitely
# waiting for a native completion callback that may never fire, which is
# exactly the real Windows CI 0xC0000005 crash this task chases: a
# same-process background thread still executing native WinRT code when the
# interpreter starts finalizing. No in-process asyncio timeout can bound an
# operation whose own cancellation primitive is itself unbounded.
#
# The only way to get a REAL, OS-enforced hard bound is process isolation:
# ``_run_ble_diagnostics_subprocess()`` spawns a disposable child process
# (this same interpreter re-invoked with a hidden flag - see
# ``build_ble_diagnostics_subprocess_command()``) that does the actual WinRT
# call; if it does not report back within ``BLE_DISCOVERY_TIMEOUT_SECONDS``,
# the parent terminates it and, if that alone is not confirmed within
# ``_SUBPROCESS_TERMINATE_WAIT_SECONDS``, escalates to a forceful kill and
# waits again - each step individually bounded, and each step's SUCCESS is
# verified via the child's confirmed exit (``Popen.wait()`` returning), not
# merely "we called terminate()". A forcefully-killed OS process cannot
# leave any native code running that could touch THIS interpreter's memory
# during ITS OWN finalization - the crash's precondition (a still-running
# native WinRT call sharing this process/interpreter) is structurally
# impossible once discovery lives in a separate process. This does NOT
# change ``ble_transport_winrt.discover_candidates()`` or the real BLE
# bridging session (``RC003BleSession``) at all - those still run entirely
# in-process, unchanged, for the actual bridge; only the DIAGNOSTICS-ONLY
# enumeration this module performs is isolated this way.
#
# IPC transport (XRBM-035 RETRY 1 correction - NOT stdout): a real
# PyInstaller ``console=False`` (windowed) build - which is exactly what
# ``build/RemoteMicRC003.spec`` produces - has ``sys.stdout``,
# ``sys.stderr`` AND ``sys.stdin`` set to ``None`` by the bootloader,
# unconditionally, even when a parent process redirects the child's OS-level
# std handles (see PyInstaller's own documentation, "Common issues and
# pitfalls" -> "windowed/noconsole application" section:
# https://pyinstaller.org/en/stable/common-issues-and-pitfalls.html). A
# ``print()``-to-stdout IPC contract - what this section originally shipped
# - would raise ``AttributeError`` inside the FROZEN child the very first
# time it tried to report a result, defeating the whole design silently (the
# parent would just see a nonzero exit / no output and report a generic
# "error", masking that the mechanism never worked in a frozen build at
# all). Every value that crosses the process boundary therefore goes
# through a RESULT FILE instead: the parent creates a private, per-attempt
# temp directory (``tempfile.mkdtemp()`` - restricted to the owning user by
# construction on every platform this runs on) and passes the file path
# inside it to the child as a plain argv value; the child (which never
# touches ``sys.stdout``/``sys.stderr``/``sys.stdin`` anywhere in this
# module) writes ONE small, strictly-allow-listed JSON object to that path
# ATOMICALLY (write to a sibling temp file, then ``os.replace()``), and the
# parent reads it back only after the child's exit has already been
# confirmed. The parent ALWAYS deletes the temp directory afterward
# (``_discover_ble_candidates_sync()``'s own ``finally``), regardless of
# outcome.
#
# Content contract: ``{"verdict": "single_match" | "no_candidate" |
# "winrt_unavailable" | "error"}`` or ``{"verdict": "ambiguous", "count":
# N}`` (2 <= N <= ``_MAX_PLAUSIBLE_AMBIGUOUS_COUNT``) - and NOTHING else;
# the parent's parser (``_sanitize_verdict_payload()``) strictly allow-lists
# every key, type, and value and turns anything else into the same honest
# "error" a real in-child failure would have produced - it never trusts
# arbitrary file content enough to, say, allocate a candidate list sized by
# an attacker/corruption-controlled number. Never a device name, address,
# handle, or raw exception text - the name-matching decision
# (``identity.select_single_candidate()``) runs INSIDE the child, where real
# device names are visible; only the verdict/count ever crosses the process
# boundary. The child's stdout/stderr/stdin are all DEVNULL'd by the parent
# (belt-and-suspenders on top of never being read from in this module), so
# even an unexpected traceback from third-party code can never reach this
# process.

BLE_DIAGNOSTICS_SUBPROCESS_FLAG = "--diagnose-ble-candidates"

# Absolute upper bound on how long the parent waits for the child to report
# a verdict ON ITS OWN before beginning forced termination. Generous enough
# for real BLE enumeration (a handful of seconds at most).
BLE_DISCOVERY_TIMEOUT_SECONDS = 10.0

# How often the parent re-checks cancel_event/the child's exit status while
# a discovery attempt is still in flight.
_SUBPROCESS_POLL_SECONDS = 0.1

# Individually-bounded wait after each escalating termination step
# (terminate() then, if still alive, kill()) - see
# _terminate_and_confirm_exit()'s docstring. On Windows both map to the same
# TerminateProcess() call (Python's subprocess module aliases kill() to
# terminate() there - there is no SIGKILL/SIGTERM distinction on Windows),
# so this escalation is mainly meaningful cross-platform (POSIX dev/test
# hosts, where a process CAN choose to ignore SIGTERM but never SIGKILL);
# on Windows the first wait already confirms exit in virtually all cases.
_SUBPROCESS_TERMINATE_WAIT_SECONDS = 2.0
_SUBPROCESS_KILL_WAIT_SECONDS = 2.0

# Public (not underscore-prefixed) on purpose: the worst-case wall-clock
# time _run_ble_diagnostics_subprocess() can spend AFTER deciding to cancel
# (poll-detection latency + both escalating termination waits) before it
# raises either BleDiscoveryCancelledError or
# BleDiscoverySubprocessShutdownUnconfirmedError. qt_settings_app.py's own
# worker-thread join timeout is DERIVED from this value (XRBM-035 RETRY 1 P1
# #2: the previous flat 2.0s join guess was independent of, and smaller
# than, this module's own termination bound - aligning them by construction
# means they can never silently drift apart again).
BLE_DISCOVERY_MAX_CANCELLATION_SECONDS = (
    _SUBPROCESS_POLL_SECONDS + _SUBPROCESS_TERMINATE_WAIT_SECONDS + _SUBPROCESS_KILL_WAIT_SECONDS
)

# Defensive ceiling on a reported ambiguous count (XRBM-035 RETRY 1 P2/D):
# this module never trusts an unbounded or implausible number from a result
# file it did not fully control the writer of - a real RC003 candidate list
# can never plausibly reach even double digits, and this also stops
# _candidates_from_verdict() from ever being tricked into allocating an
# unbounded placeholder-candidate list.
_MAX_PLAUSIBLE_AMBIGUOUS_COUNT = 64


class BleDiscoveryCancelledError(Exception):
    """Raised by ``_discover_ble_candidates_sync()`` when the diagnostics
    subprocess did not report a verdict within ``BLE_DISCOVERY_TIMEOUT_
    SECONDS`` (or ``cancel_event`` was set first) and was terminated - the
    parent CONFIRMED the child process actually exited before raising this
    (see ``_terminate_and_confirm_exit()``). Carries no device identifier -
    matches this module's never-leak-an-identifier contract (see module
    docstring).
    """


class BleDiscoverySubprocessShutdownUnconfirmedError(Exception):
    """Raised by ``_discover_ble_candidates_sync()`` in the (expected to be
    extremely rare) case where even a forceful kill could not be confirmed
    to have actually stopped the diagnostics subprocess within its own
    bounded wait. This must never be silently treated as equivalent to a
    normal cancellation/timeout - the caller could not verify the isolation
    boundary this whole design exists for actually held, and must say so
    honestly rather than claim a safe outcome it cannot prove.
    """


class BleDiagnosticsVerdict(Enum):
    """The complete, closed set of outcomes the diagnostics subprocess can
    ever legitimately report - see this section's module-level comment for
    the full IPC contract. Any raw file content that does not map cleanly
    onto exactly one of these becomes ``ERROR`` (see
    ``_sanitize_verdict_payload()``), never a fabricated success.
    """

    SINGLE_MATCH = "single_match"
    NO_CANDIDATE = "no_candidate"
    AMBIGUOUS = "ambiguous"
    WINRT_UNAVAILABLE = "winrt_unavailable"
    ERROR = "error"


@dataclass(frozen=True)
class BleDiagnosticsResult:
    """The parent's fully-validated, in-memory representation of what the
    diagnostics subprocess reported - never constructed directly from raw
    file content anywhere except ``_sanitize_verdict_payload()``.
    """

    verdict: BleDiagnosticsVerdict
    count: Optional[int] = None


_ERROR_RESULT = BleDiagnosticsResult(verdict=BleDiagnosticsVerdict.ERROR)


def build_ble_diagnostics_subprocess_command(
    result_path: str, *, frozen: Optional[bool] = None, executable: Optional[str] = None
) -> List[str]:
    """Builds the argv for the diagnostics-only BLE-discovery child process,
    for BOTH ways this package is ever run (XRBM-035 RETRY 1 In-scope item
    1): a source/dev checkout (``python -m ovb_rc003``) and the frozen
    PyInstaller ``console=False`` build (a single windowed .exe - see
    ``build/RemoteMicRC003.spec``, whose ``sys.executable`` at runtime
    IS that .exe itself, not a separate Python interpreter). ``frozen``/
    ``executable`` are injectable purely so both shapes are covered by a
    deterministic test without needing an actual frozen build.

    ``result_path`` is passed as a plain positional argv value right after
    the flag - the ONLY thing the child ever learns about where to write its
    result (see this section's module-level "IPC transport" comment for why
    this replaced a stdout-based contract). ``__main__.py``'s own dispatch
    reads it the same way regardless of which shape below was used to spawn
    it.

    Real defaults: ``frozen`` from the standard PyInstaller runtime
    attribute ``sys.frozen`` (see ``resources.py``/``qt_settings_app.py``'s
    own ``sys._MEIPASS`` checks for the same frozen-detection idiom already
    used elsewhere in this package), ``executable`` from ``sys.executable``.
    """

    is_frozen = frozen if frozen is not None else bool(getattr(sys, "frozen", False))
    exe = executable if executable is not None else sys.executable
    if is_frozen:
        # The frozen .exe IS the interpreter+entry point combined - no `-m`
        # module name to give it (there is no separate `ovb_rc003` package
        # visible to invoke by name outside the frozen bundle's own import
        # machinery); __main__.py's own argv dispatch (see that module)
        # recognizes this flag identically either way.
        return [exe, BLE_DIAGNOSTICS_SUBPROCESS_FLAG, result_path]
    return [exe, "-m", "ovb_rc003", BLE_DIAGNOSTICS_SUBPROCESS_FLAG, result_path]


def _write_verdict_atomically(result_path: str, payload: dict) -> None:
    """Writes ``payload`` to ``result_path`` atomically: write to a sibling
    temp file in the SAME directory, then ``os.replace()`` it into place.
    The parent only ever reads ``result_path`` after confirming this
    process's exit, but this still guarantees it can never observe a
    partially-written file even under an unlucky signal/kill timing.
    """

    directory = os.path.dirname(result_path) or "."
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".ble-verdict-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp_path, result_path)
    except BaseException:
        try:
            os.remove(tmp_path)
        except FileNotFoundError:
            pass
        raise


def run_ble_diagnostics_subprocess_entrypoint(result_path: Optional[str]) -> int:
    """Runs ONLY inside the child process spawned by
    ``_run_ble_diagnostics_subprocess()`` below (dispatched from
    ``__main__.py`` on ``BLE_DIAGNOSTICS_SUBPROCESS_FLAG`` - never called
    directly by any GUI/bridge code path in THIS process, and never part of
    this program's public CLI surface - see ``__main__.py``'s own docstring
    for why it is deliberately absent from ``--help``). Does the exact same
    discovery + identity-matching the in-process path used to do directly -
    ``ble_transport_winrt.discover_candidates()`` (completely unchanged) and
    ``identity.select_single_candidate()`` - but writes only a minimal,
    strictly-shaped verdict to ``result_path`` as its LAST action, via
    ``_write_verdict_atomically()``, never a device name/address/handle/raw
    exception text (see this section's module-level comment for the full
    IPC contract). NEVER touches ``sys.stdout``/``sys.stderr``/``sys.stdin``
    anywhere in this function - a real frozen ``console=False`` build has
    all three set to ``None`` (see the module-level comment); this function
    is exercised directly against that exact condition by this file's own
    tests.

    Fails CLOSED on a missing/invalid ``result_path`` (XRBM-035 RETRY 1
    In-scope item 6): returns a nonzero exit code immediately, before ever
    attempting discovery, rather than guessing a fallback location - the
    caller (``__main__.py``) already guarantees this path never falls
    through to starting the bridge regardless, but this function does not
    rely on that alone.

    Returns 0 for every OUTCOME this module can itself observe and report
    (a real discovery failure is a valid, honestly-reported verdict -
    "error"/"winrt_unavailable" - not a process-exit-code-level failure);
    only a genuinely unwritable result file, or an exception this function's
    own top-level safety net had to catch, produces a nonzero exit. The
    PARENT treats any nonzero exit, or a missing/unparsable/non-allow-listed
    result file, as its own separate "error" verdict either way.
    """

    if not result_path:
        return 1

    import asyncio

    def _write(payload: dict) -> bool:
        try:
            _write_verdict_atomically(result_path, payload)
            return True
        except OSError:
            return False

    try:
        try:
            candidates = asyncio.run(ble_transport_winrt.discover_candidates())
        except ble_transport_winrt.WinRTUnavailableError:
            return 0 if _write({"verdict": BleDiagnosticsVerdict.WINRT_UNAVAILABLE.value}) else 1
        except Exception:  # noqa: BLE001 - sanitize at the process boundary; see module comment
            return 0 if _write({"verdict": BleDiagnosticsVerdict.ERROR.value}) else 1

        try:
            identity.select_single_candidate(candidates)
        except identity.NoCandidateFoundError:
            return 0 if _write({"verdict": BleDiagnosticsVerdict.NO_CANDIDATE.value}) else 1
        except identity.AmbiguousCandidateError as exc:
            payload = {"verdict": BleDiagnosticsVerdict.AMBIGUOUS.value, "count": exc.count}
            return 0 if _write(payload) else 1
        return 0 if _write({"verdict": BleDiagnosticsVerdict.SINGLE_MATCH.value}) else 1
    except Exception:  # noqa: BLE001 - deliberate, narrowly-scoped last-resort
        # safety net (distinct from the two INNER except-Exception branches
        # above, which are this module's normal, documented "sanitize a
        # real discovery failure" path): catches something unexpected
        # OUTSIDE those two calls - e.g. the exact PyInstaller windowed-
        # build hazard this whole RETRY exists to fix, if any third-party
        # code this function transitively calls ever tries to write to
        # sys.stderr/sys.stdout when they are None. Always produces the
        # SAME sanitized "error" verdict the documented paths above already
        # produce - never raw exception text - so this is not the kind of
        # broad exception-swallowing an independent review already flagged
        # elsewhere in this design (that finding was about the PARENT
        # silently discarding a cleanup failure it could act on; this is
        # the CHILD's own last chance to report anything at all before it
        # exits, with nothing else able to observe it).
        return 0 if _write({"verdict": BleDiagnosticsVerdict.ERROR.value}) else 1


def _popen_kwargs() -> dict:
    kwargs: dict = dict(
        # No IPC ever crosses stdout/stderr/stdin (see this section's
        # module-level "IPC transport" comment) - DEVNULL'd for all three
        # so nothing produced by this process or anything it transitively
        # runs can ever reach this one, not merely "produced but never
        # read".
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
    )
    if sys.platform == "win32":
        # Prevents a console window flash from a real console-less
        # (console=False) frozen .exe re-invoking itself, or from `python`
        # in a source checkout - CREATE_NO_WINDOW only exists on Windows.
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW  # type: ignore[attr-defined]
    return kwargs


def _attempt_termination_step(
    proc: "subprocess.Popen", signal_fn: Callable[[], None], wait_timeout: float
) -> bool:
    """Runs ONE escalating termination attempt (``signal_fn`` is
    ``proc.terminate`` or ``proc.kill``) and returns True ONLY if the
    child's exit is CONFIRMED afterward via a real ``wait()``/``poll()``
    observation - never merely because ``signal_fn()`` didn't raise.

    XRBM-035 RETRY 1 (Codex red evidence): ``proc.terminate()``/
    ``proc.kill()``/``proc.wait()`` can each raise an ``OSError``
    (``PermissionError`` was the exact case reproduced) that is neither a
    confirmed exit nor a ``TimeoutExpired`` - the previous version let such
    an exception escape this function as a raw, undifferentiated
    ``OSError``, which meant ``_run_ble_diagnostics_subprocess()`` could
    never reach its own honest ``BleDiscoverySubprocessShutdownUnconfirmedError``
    contract for exactly the case that contract exists for: "this process
    could not confirm the diagnostics subprocess actually stopped".

    Every process-control exception here is therefore treated
    conservatively as "not yet confirmed", never as "must have failed" or
    "must have succeeded": ``signal_fn()`` raising is swallowed (the
    process may already have exited in a race - ``ProcessLookupError`` on
    POSIX - or this process may simply lack permission to signal it either
    way, only a real ``wait()``/``poll()`` observation ever counts), and
    ``wait()`` raising anything other than ``TimeoutExpired`` falls back to
    one single, non-blocking ``poll()`` check (never a second unbounded
    wait) so a process that happens to have already exited despite
    ``wait()`` itself failing is still correctly recognized as confirmed.
    ``poll()`` itself is ALSO not trusted to never raise (it makes the same
    kind of OS process-query call as ``wait()``): if it does, that is
    ANOTHER "cannot confirm" outcome, not a crash - this function returns
    False rather than letting a second raw ``OSError`` escape. Still
    individually bounded by ``wait_timeout`` either way.
    """

    try:
        signal_fn()
    except OSError:
        pass

    try:
        proc.wait(timeout=wait_timeout)
        return True
    except subprocess.TimeoutExpired:
        return False
    except OSError:
        try:
            return proc.poll() is not None
        except OSError:
            return False


def _terminate_and_confirm_exit(
    proc: "subprocess.Popen",
    *,
    terminate_wait: float,
    kill_wait: float,
) -> bool:
    """Escalating, individually-bounded hard termination. Returns True ONLY
    if the child's exit was actually CONFIRMED (see
    ``_attempt_termination_step()``) - never merely because ``terminate()``
    /``kill()`` was called, which only REQUESTS termination (XRBM-035 RETRY
    1 P1: the same "requested, not confirmed" gap that made the previous
    asyncio-cancellation approach insufficient applies just as much to a
    single unconfirmed ``terminate()`` call here - that is why this function
    always confirms via ``.wait()``/``.poll()`` afterward and reports
    failure honestly if even ``kill()`` could not be confirmed).
    """

    if _attempt_termination_step(proc, proc.terminate, terminate_wait):
        return True
    return _attempt_termination_step(proc, proc.kill, kill_wait)


def _sanitize_verdict_payload(parsed: object) -> BleDiagnosticsResult:
    """Strictly allow-lists ``parsed`` (already-``json.loads()``-decoded
    result-file content) into a ``BleDiagnosticsResult`` (XRBM-035 RETRY 1
    P2/D). ANY deviation from the exact expected shape - an unknown verdict
    string, an unexpected/missing/extra key, a non-integer or out-of-range
    ``count``, ``count`` present when it should not be (or vice versa) -
    becomes ``ERROR``. Never raises; this is the single place raw,
    untrusted file content is allowed to influence this process's behaviour
    at all, and it is deliberately conservative rather than lenient.
    """

    if not isinstance(parsed, dict):
        return _ERROR_RESULT

    verdict_value = parsed.get("verdict")
    if not isinstance(verdict_value, str):
        return _ERROR_RESULT
    try:
        verdict = BleDiagnosticsVerdict(verdict_value)
    except ValueError:
        return _ERROR_RESULT

    keys = set(parsed.keys())
    if verdict is BleDiagnosticsVerdict.AMBIGUOUS:
        if keys != {"verdict", "count"}:
            return _ERROR_RESULT
        count = parsed.get("count")
        # bool is an int subclass in Python - True/False must never be
        # accepted as a candidate count.
        if (
            not isinstance(count, int)
            or isinstance(count, bool)
            or count < 2
            or count > _MAX_PLAUSIBLE_AMBIGUOUS_COUNT
        ):
            return _ERROR_RESULT
        return BleDiagnosticsResult(verdict=verdict, count=count)

    if keys != {"verdict"}:
        return _ERROR_RESULT
    return BleDiagnosticsResult(verdict=verdict)


def _read_subprocess_verdict(result_path: str, returncode: Optional[int]) -> BleDiagnosticsResult:
    """Reads and strictly validates the child's result file - ONLY called
    after the child's exit has already been confirmed (see
    ``_run_ble_diagnostics_subprocess()``). Never raises: a nonzero exit, a
    missing file, unreadable/undecodable content, or content that fails
    ``_sanitize_verdict_payload()``'s allow-list all become the same honest
    ``ERROR`` result a real in-child failure would have produced.
    """

    if returncode != 0:
        return _ERROR_RESULT
    try:
        with open(result_path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except (FileNotFoundError, OSError):
        return _ERROR_RESULT
    text = text.strip()
    if not text:
        return _ERROR_RESULT
    try:
        parsed = json.loads(text)
    except ValueError:
        return _ERROR_RESULT
    return _sanitize_verdict_payload(parsed)


def _candidates_from_verdict(result: BleDiagnosticsResult) -> Sequence[identity.RC003Candidate]:
    """Reconstructs the exact ``Sequence[RC003Candidate]`` shape
    ``check_ble_candidate()`` already knows how to turn into the right
    PASS/FAIL/ambiguous ``CheckResult`` via its existing, unchanged
    ``identity.select_single_candidate()`` call - WITHOUT ever having seen a
    real device name (the child already did that matching internally; only
    the verdict/count crossed the process boundary, and only after strict
    validation - see ``_sanitize_verdict_payload()``). Every reconstructed
    candidate uses an empty name and ``hardware_match=True`` purely so
    ``select_single_candidate()`` counts it as qualifying - the name is
    never read or displayed anywhere past this point, and the count is
    already bounded by ``_MAX_PLAUSIBLE_AMBIGUOUS_COUNT``.
    """

    if result.verdict is BleDiagnosticsVerdict.SINGLE_MATCH:
        return [identity.RC003Candidate(name="", hardware_match=True)]
    if result.verdict is BleDiagnosticsVerdict.NO_CANDIDATE:
        return []
    if result.verdict is BleDiagnosticsVerdict.AMBIGUOUS:
        count = result.count if result.count is not None else 2
        return [identity.RC003Candidate(name="", hardware_match=True) for _ in range(count)]
    if result.verdict is BleDiagnosticsVerdict.WINRT_UNAVAILABLE:
        raise ble_transport_winrt.WinRTUnavailableError(
            "winrt Bluetooth packages are not installed in the diagnostics subprocess"
        )
    # ERROR (or, defensively, anything else) - honest, generic failure,
    # never a fabricated success (check_ble_candidate()'s own except
    # Exception branch turns this into the existing sanitized FAIL detail).
    raise RuntimeError("BLE diagnostics subprocess reported an internal error")


def _run_ble_diagnostics_subprocess(
    command: Sequence[str],
    *,
    result_path: str,
    cancel_event: threading.Event,
    timeout: float,
    poll_interval: float = _SUBPROCESS_POLL_SECONDS,
    terminate_wait: float = _SUBPROCESS_TERMINATE_WAIT_SECONDS,
    kill_wait: float = _SUBPROCESS_KILL_WAIT_SECONDS,
    popen: Callable[..., "subprocess.Popen"] = subprocess.Popen,
) -> BleDiagnosticsResult:
    """Spawns ``command`` (see ``build_ble_diagnostics_subprocess_command()``)
    and returns its validated verdict once it has exited ON ITS OWN within
    ``timeout`` (and ``cancel_event`` was never set) - never reading
    ``result_path`` before that. If ``cancel_event`` is set or ``timeout``
    elapses first, forcibly terminates it (see
    ``_terminate_and_confirm_exit()``) and either raises
    ``BleDiscoveryCancelledError`` (termination CONFIRMED) or
    ``BleDiscoverySubprocessShutdownUnconfirmedError`` (termination could
    not be confirmed even after escalating to a forceful kill) - never
    silently returns as if discovery had actually completed, and never
    reads ``result_path`` in either case (a killed child's partially-written
    file, if any, is simply never looked at).

    Owns spawning and waiting only - NOT the temp directory ``result_path``
    lives in, which the caller (``_discover_ble_candidates_sync()``) creates
    and always cleans up regardless of outcome. This function therefore
    holds no cleanup-worthy resource of its own (no stdout pipe is ever
    opened - see ``_popen_kwargs()``) and needs no ``finally`` block.

    A short-circuit before ever spawning: if ``cancel_event`` is already set
    (e.g. the settings window began closing between this worker starting
    and reaching the BLE check), raises ``BleDiscoveryCancelledError``
    immediately rather than paying for a spawn only to kill it right away.
    """

    if cancel_event.is_set():
        raise BleDiscoveryCancelledError("BLE discovery cancelled before it could start")

    proc = popen(list(command), **_popen_kwargs())

    deadline = time.monotonic() + timeout
    while True:
        if proc.poll() is not None:
            break
        if cancel_event.is_set():
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(poll_interval)

    if proc.poll() is None:
        confirmed_dead = _terminate_and_confirm_exit(
            proc, terminate_wait=terminate_wait, kill_wait=kill_wait
        )
        if not confirmed_dead:
            raise BleDiscoverySubprocessShutdownUnconfirmedError(
                "BLE diagnostics subprocess could not be confirmed to have exited"
            )
        raise BleDiscoveryCancelledError("BLE discovery cancelled or timed out")

    # The child has been CONFIRMED to have exited on its own - only now is
    # its result file ever read.
    return _read_subprocess_verdict(result_path, proc.returncode)


def _discover_ble_candidates_sync(
    *,
    cancel_event: Optional[threading.Event] = None,
    timeout: float = BLE_DISCOVERY_TIMEOUT_SECONDS,
) -> Sequence[identity.RC003Candidate]:
    """Real probe: runs discovery in a disposable child process (see this
    section's module-level comment for why) and reconstructs the
    ``Sequence[RC003Candidate]`` shape ``check_ble_candidate()`` already
    knows how to turn into a real PASS/FAIL/ambiguous result. Bounded by
    ``timeout`` and cancellable early via ``cancel_event`` with a REAL,
    OS-confirmed hard bound on how long a caller ever waits.

    Owns the private result-file directory's full lifecycle: created here,
    BEFORE spawning, and always removed in ``finally`` - regardless of
    whether discovery succeeded, failed, was cancelled, or the subprocess
    had to be killed. Only ``FileNotFoundError`` (the directory already
    being gone) is ever treated as ignorable here (XRBM-035 RETRY 1 P3): any
    OTHER cleanup failure (e.g. a still-open file handle on a child whose
    death this process could not even confirm) propagates - through
    ``check_ble_candidate()``'s own existing, sanitized generic-exception
    branch - rather than being silently discarded.

    Cleanup-vs-original-exception priority (XRBM-035 RETRY 1, Codex red
    evidence) - narrowly scoped to ONE specific case, not "any original
    exception wins": if the ``try`` block above is ALREADY propagating
    ``BleDiscoverySubprocessShutdownUnconfirmedError`` - the one honest
    signal this whole design exists to surface, meaning the diagnostics
    subprocess might genuinely still be alive - and cleanup itself also
    fails, a bare ``except ...: raise`` here would let Python's normal
    finally-block semantics silently REPLACE that signal with the cleanup
    failure, exactly backwards ("the subprocess might still be alive" is
    strictly more important than "its now-orphaned temp directory could not
    be removed"). ONLY that one exception type is captured before cleanup
    runs and re-raised as itself, with the cleanup failure chained onto it
    via ``__cause__``/``__context__`` (Python 3.10 compatible -
    ``Exception.add_note()`` is 3.11+ only and this project's own
    ``requires-python`` floor is 3.10, so it is never used here) rather than
    being replaced by it. Every OTHER original exception (including
    ``WinRTUnavailableError``, ``BleDiscoveryCancelledError``, or none at
    all - the otherwise-successful path) leaves this module's existing,
    unrelated "a cleanup failure must still propagate, never be silently
    discarded" contract untouched: a cleanup ``OSError`` there is raised as
    itself, exactly as before this RETRY, reaching
    ``check_ble_candidate()``'s own existing, sanitized generic-exception
    branch the same way any other unexpected failure already does.
    """

    event = cancel_event if cancel_event is not None else threading.Event()
    result_dir = tempfile.mkdtemp(prefix="ovb-rc003-ble-diag-")
    result_path = os.path.join(result_dir, "verdict.json")
    try:
        command = build_ble_diagnostics_subprocess_command(result_path)
        result = _run_ble_diagnostics_subprocess(
            command, result_path=result_path, cancel_event=event, timeout=timeout
        )
        return _candidates_from_verdict(result)
    finally:
        # Captured BEFORE the cleanup attempt below, which - if it also
        # raises - runs inside its OWN except clause where sys.exc_info()
        # would otherwise reflect the cleanup failure, not this one.
        original_exc = sys.exc_info()[1]
        try:
            shutil.rmtree(result_dir)
        except FileNotFoundError:
            pass
        except OSError as cleanup_exc:
            if isinstance(original_exc, BleDiscoverySubprocessShutdownUnconfirmedError):
                # The ONE narrow exception this priority rule applies to -
                # see this function's own docstring. Re-raising the SAME
                # original exception OBJECT with `from cleanup_exc` keeps
                # its type and identity as the one a caller's `except`
                # clause sees, while making the cleanup failure visible via
                # both `original_exc.__cause__` (explicit, via `from`) and
                # `original_exc.__context__` (Python sets this
                # automatically for any exception raised inside an
                # `except` block, regardless of `from`) - never discarded.
                raise original_exc from cleanup_exc
            # Every other case (a different original exception, or none at
            # all) - the cleanup OSError itself propagates unchanged, the
            # same explicit-propagation contract this module already had.
            raise


def check_ble_candidate(
    *,
    discover: Callable[
        [], Sequence[identity.RC003Candidate]
    ] = _discover_ble_candidates_sync,
) -> CheckResult:
    try:
        candidates = list(discover())
    except ble_transport_winrt.WinRTUnavailableError:
        if sys.platform != "win32":
            return CheckResult(
                "ble_candidate",
                "已配对的 RC003 (BLE)",
                CheckGroup.VOICE_BRIDGE,
                CheckStatus.UNSUPPORTED,
                "当前不是 Windows，无法枚举已配对的 BLE 候选。",
            )
        # RETRY 3 (independent review): this used to interpolate str(exc)
        # here. The real production message this raises today is API-only,
        # but a dependency-unavailable exception must never be trusted to
        # stay that way forever - use a fixed, generic message so a future
        # change to that exception's text can never smuggle a Bluetooth
        # address/name/identifier into this module's own output (the one
        # thing its docstring promises never happens).
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.UNSUPPORTED,
            "WinRT 蓝牙依赖不可用；请确认已按 requirements.txt 安装 winrt 组件后重试。",
        )
    except BleDiscoverySubprocessShutdownUnconfirmedError:
        # XRBM-035 RETRY 1: distinct from a normal cancel/timeout below -
        # this means even a forceful kill of the isolated diagnostics
        # subprocess could not be confirmed, so this module cannot honestly
        # claim the isolation boundary held. Never worded the same as a
        # routine "please retry" cancellation.
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            "BLE 检测子进程未能确认已退出，可能仍在后台运行；建议重启应用后再试。",
        )
    except BleDiscoveryCancelledError:
        # XRBM-035: an honest "did not complete" result - never a FAIL
        # implying a real hardware/config problem, and never leaking a
        # device name/address, matching this module's contract. Reached
        # either when the settings window is closing (cancel_event set) or
        # when discovery itself exceeded BLE_DISCOVERY_TIMEOUT_SECONDS -
        # in both cases the isolated diagnostics subprocess was CONFIRMED
        # terminated before this was raised (see
        # _run_ble_diagnostics_subprocess()).
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            "BLE 候选检测被取消或超时，未能得到结果；请点击「重新检测」重试。",
        )
    except Exception:  # noqa: BLE001 - report, never crash the diagnostics page
        # RETRY 3 (independent review): a genuinely unexpected exception
        # here could be raised by WinRT/BLE plumbing carrying a real
        # Bluetooth address, device name, or other identifier in its
        # message - never interpolate it, matching this module's own
        # never-surface-an-identifier contract.
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            "BLE 候选枚举失败，出现意外错误；请点击「重新检测」重试。",
        )

    try:
        identity.select_single_candidate(candidates)
    except identity.NoCandidateFoundError:
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            "未发现已配对的 RC003；请在 Windows 蓝牙设置中完成配对后重试。",
        )
    except identity.AmbiguousCandidateError as exc:
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            f"发现 {exc.count} 个候选，无法唯一确定；请仅保留一个已配对设备后重试。",
        )
    return CheckResult(
        "ble_candidate",
        "已配对的 RC003 (BLE)",
        CheckGroup.VOICE_BRIDGE,
        CheckStatus.PASS,
        "发现恰好一个已配对的 RC003 候选。",
    )


# -- VB-CABLE endpoints (optional driver) -----------------------------------


def check_vb_cable_endpoints(
    *,
    list_playback: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_output_endpoints,
    list_recording: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_input_endpoints,
) -> CheckResult:
    try:
        playback = list(list_playback())
        recording = list(list_recording())
    except audio_output.AudioOutputUnavailableError as exc:
        return CheckResult(
            "vb_cable_endpoints",
            "VB-CABLE 虚拟音频端点（可选）",
            CheckGroup.OPTIONAL_DRIVER,
            CheckStatus.UNSUPPORTED,
            f"无法枚举音频端点：{exc}",
        )

    has_input = any(audio_output.is_cable_input_endpoint(e.name) for e in playback)
    has_output = any(audio_output.is_cable_output_endpoint(e.name) for e in recording)

    if has_input and has_output:
        return CheckResult(
            "vb_cable_endpoints",
            "VB-CABLE 虚拟音频端点（可选）",
            CheckGroup.OPTIONAL_DRIVER,
            CheckStatus.PASS,
            "已发现 CABLE Input（播放）与 CABLE Output（录音）两个端点。",
        )
    missing = []
    if not has_input:
        missing.append("CABLE Input（播放）")
    if not has_output:
        missing.append("CABLE Output（录音）")
    return CheckResult(
        "vb_cable_endpoints",
        "VB-CABLE 虚拟音频端点（可选）",
        CheckGroup.OPTIONAL_DRIVER,
        CheckStatus.FAIL,
        "尚未发现：" + "、".join(missing) + "。这是可选项——不安装 VB-CABLE 时，"
        "普通按键仍然正常工作，只有把 RC003 语音当作系统麦克风使用时才需要它。",
    )


def check_dji_mic_2_input(
    *,
    list_recording: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_input_endpoints,
) -> CheckResult:
    """A paired Bluetooth device is not sufficient evidence. PASS only when
    PortAudio can see a usable DJI Mic 2 recording endpoint right now.
    """

    try:
        recording = list(list_recording())
    except audio_output.AudioOutputUnavailableError:
        return CheckResult(
            "dji_mic_2_input",
            "DJI Mic 2 录音输入",
            CheckGroup.EXTERNAL_MICROPHONE,
            CheckStatus.UNSUPPORTED,
            "无法枚举 Windows 录音端点，暂不能核验 DJI Mic 2。",
        )
    matches = [e for e in recording if audio_output.is_dji_mic_2_input_endpoint(e.name)]
    if not matches:
        return CheckResult(
            "dji_mic_2_input",
            "DJI Mic 2 录音输入",
            CheckGroup.EXTERNAL_MICROPHONE,
            CheckStatus.FAIL,
            "未发现可用的 DJI Mic 2 录音端点；请确认发射器已开机并在蓝牙设置中处于已连接状态。",
        )
    host_apis = {e.host_api for e in matches if e.host_api}
    detail = "已发现可用的 DJI Mic 2 录音端点"
    if host_apis:
        detail += f"（{len(host_apis)} 个音频接口视图）"
    return CheckResult(
        "dji_mic_2_input",
        "DJI Mic 2 录音输入",
        CheckGroup.EXTERNAL_MICROPHONE,
        CheckStatus.PASS,
        detail + "；未修改 Windows 默认麦克风。",
    )


# -- Output endpoint resolution (voice bridge) ------------------------------


def check_output_endpoint_resolution(
    saved_name: str,
    saved_host_api: str,
    *,
    list_playback: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_output_endpoints,
) -> CheckResult:
    try:
        endpoints = list(list_playback())
    except audio_output.AudioOutputUnavailableError as exc:
        return CheckResult(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.UNSUPPORTED,
            f"无法枚举播放端点：{exc}",
        )

    try:
        endpoint = audio_output.resolve_selected_endpoint(
            endpoints, saved_name, saved_host_api
        )
    except audio_output.AudioOutputUnavailableError as exc:
        if not saved_name:
            detail = "尚未选择语音输出端点；请在“连接与语音”页选择 CABLE Input。"
        else:
            detail = (
                "已保存的语音输出端点当前不可用；请在“连接与语音”页重新选择，"
                "原始错误已保留在应用日志中。"
            )
        return CheckResult(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            detail,
        )

    if audio_output.is_cable_input_endpoint(endpoint.name):
        return CheckResult(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.PASS,
            f"已选择端点 {endpoint.name!r} 存在，且为 CABLE Input（VB-CABLE 语音链路）。",
        )
    # RETRY 1 (independent review): resolving to a real but non-CABLE-Input
    # endpoint used to still return PASS here - a false green readiness
    # signal for the bundled VB-CABLE workflow this page exists to support
    # (taskbook line 77: "...points to CABLE Input when the bundled driver
    # workflow is used"). This check exists specifically to gate that
    # workflow's readiness, so anything other than CABLE Input is FAIL with
    # actionable text, not a second, quieter kind of success.
    return CheckResult(
        "output_endpoint",
        "语音输出端点",
        CheckGroup.VOICE_BRIDGE,
        CheckStatus.FAIL,
        f"已选择端点 {endpoint.name!r} 存在，但不是 CABLE Input——如果计划使用"
        "本页的 VB-CABLE 语音链路，需要在「检查与修复」页点击「选择检测到的 "
        "CABLE Input 作为输出」，或在「连接」页手动改选 CABLE Input。",
    )


# -- Windows dictation / Win+H (always manual) ------------------------------


def check_dictation_manual() -> CheckResult:
    return CheckResult(
        "dictation",
        "Windows 听写 (Win+H)",
        CheckGroup.DICTATION,
        CheckStatus.MANUAL,
        "Windows 未公开一个可核验听写是否可用的 API，这里不能给出自动结论。"
        "请手动验证：打开记事本等可编辑文本框并点入光标，确认已启用「联机语音"
        "识别」（Windows 11：设置 → 隐私和安全性 → 语音；Windows 10：设置 → "
        "隐私 → 语音），按一次 Win+H，说话后确认文字被输入。",
    )


# -- Orchestration -----------------------------------------------------------


def _isolated(
    check_id: str, title: str, group: CheckGroup, run: Callable[[], CheckResult]
) -> CheckResult:
    """Runs one check function, isolated from every other one (XRBM-031
    RETRY 1 item 2): each ``check_*`` function above already anticipates
    and handles its own documented failure modes (``AudioOutputUnavailableError``,
    ``WinRTUnavailableError``, etc.), but this is the outer safety net for
    whatever it does NOT anticipate - a genuinely unexpected exception type
    must become this ONE check's own honest ``FAIL`` result, with a generic
    detail that never echoes the raw exception text (which could otherwise
    leak a device identifier/path this project's privacy contract forbids
    surfacing), rather than aborting ``run_diagnostics()`` entirely and
    leaving every OTHER check's result missing/stale.
    """

    try:
        return run()
    except Exception:  # noqa: BLE001 - the entire purpose of this wrapper
        return CheckResult(
            check_id,
            title,
            group,
            CheckStatus.FAIL,
            "该检测项出现意外错误，未能得出结论；其他检测项结果不受影响，可点击"
            "「重新检测」重试。",
        )


def run_diagnostics(
    *,
    saved_output_name: str = "",
    saved_output_host_api: str = "",
    cancel_event: Optional[threading.Event] = None,
) -> DiagnosticsReport:
    """Runs every check and returns a stable report. Pure aside from the
    real OS/WinRT/PortAudio calls each check function makes on Windows;
    intended to be called from a background thread (see
    ``qt_settings_app.DiagnosticsController``), never on the Qt GUI thread.

    ``cancel_event`` (XRBM-035), when given, is forwarded only to the BLE
    candidate check's discovery call (the one real check with a native
    async WinRT call that can run long/hang - see
    ``_run_ble_diagnostics_subprocess()``): setting it from another thread
    (e.g. the settings window closing) cancels an in-flight discovery
    attempt in bounded time - via a real, OS-confirmed process termination,
    not merely an in-process asyncio cancellation request - instead of
    leaving it to run to completion or to an unbounded process exit.

    Every check is isolated (see ``_isolated()``): one check's unexpected
    failure can never prevent the other seven from rendering their own real
    result - UNLESS ``cancel_event`` becomes set (XRBM-035 RETRY 1 P1 #2):
    once shutdown has been requested, this function stops running any
    FURTHER checks after whichever one just completed and returns
    immediately with only the checks completed so far. This report is about
    to be discarded unemitted anyway once shutdown has begun (see
    ``qt_settings_app.py``'s ``_run_in_background()``, which skips the emit
    entirely once ``_diagnostics_shutdown_event`` is set) - continuing to
    run the remaining checks after that point would only prolong how long
    the background worker thread takes to actually finish, for no
    observable benefit, working directly against the whole point of a
    bounded shutdown. With no ``cancel_event`` (the default), this early
    stop never triggers and all eight checks always run.
    """

    ble_discover = functools.partial(
        _discover_ble_candidates_sync, cancel_event=cancel_event
    )
    check_specs = (
        ("os_version", "Windows 版本与 64 位架构", CheckGroup.ORDINARY_BUTTONS, check_os_version),
        ("raw_input", "Raw Input 按键设备", CheckGroup.ORDINARY_BUTTONS, check_raw_input),
        (
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            lambda: check_ble_candidate(discover=ble_discover),
        ),
        (
            "rc003_battery",
            "RC003 电量",
            CheckGroup.VOICE_BRIDGE,
            check_rc003_battery,
        ),
        (
            "vb_cable_endpoints",
            "VB-CABLE 虚拟音频端点（可选）",
            CheckGroup.OPTIONAL_DRIVER,
            check_vb_cable_endpoints,
        ),
        (
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            lambda: check_output_endpoint_resolution(saved_output_name, saved_output_host_api),
        ),
        (
            "dji_mic_2_input",
            "DJI Mic 2 录音输入",
            CheckGroup.EXTERNAL_MICROPHONE,
            check_dji_mic_2_input,
        ),
        ("dictation", "Windows 听写 (Win+H)", CheckGroup.DICTATION, check_dictation_manual),
    )
    checks: "list[CheckResult]" = []
    for check_id, title, group, run in check_specs:
        checks.append(_isolated(check_id, title, group, run))
        if cancel_event is not None and cancel_event.is_set():
            break
    return DiagnosticsReport(checks=tuple(checks))
