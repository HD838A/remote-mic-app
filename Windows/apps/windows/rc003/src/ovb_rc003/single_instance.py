"""Windows named-mutex single-instance guards for bridge and settings modes.

The no-argument bridge (``python -m ovb_rc003`` / the packaged
``RemoteMicRC003.exe``) is a long-lived, mostly invisible owner of
BLE, Raw Input, synthetic key and audio resources. Starting a second
instance in the same Windows logon session would race both instances over
those resources - so at most one bridge instance may hold them at a time.
``--settings`` remains independent from the bridge lock, so settings can be
opened while the bridge is running. It has its own mutex, however, because
two settings processes can overwrite the same configuration files. A second
settings launch activates the existing window and exits. ``--dry-run`` and
help/version inspection touch neither mutex.

Fail-closed contract (XRBM-021 review round 1 P1 #1): a caller that cannot
PROVE it is the sole owner - whether because another instance already owns
the mutex (``DuplicateInstanceError``) or because the Win32 API itself
could not be used to check at all (``SingleInstanceUnavailableError``) -
must never fall through to starting the bridge anyway. Both exceptions are
therefore handled identically by ``__main__.py``'s ``_run_bridge()``: show
a visible notice, exit with a deterministic nonzero code, and never call
``app.main()``.

Ctypes ABI: every Win32 call here (``CreateMutexW``, ``ReleaseMutex``,
``CloseHandle``, ``MessageBoxW``) declares an explicit ``argtypes``/
``restype`` using ``ctypes.wintypes`` before it is ever invoked - the same
"never leave a handle/pointer-sized argument at ctypes' unprototyped
default" rule XRBM-019 established for ``PostMessageW`` (see
raw_input_windows.py) and XRBM-020 established for ``SendInput``'s
INPUT-array pointer (see win32_input.py). ``wintypes.HANDLE`` is
pointer-sized on every host (backed by ``c_void_p``), so it is never
truncated on 64-bit Windows the way an unprototyped bare ``int`` argument
would be.

Last-error capture (XRBM-021 review round 1 P1 #2): Win32's last-error
value is thread-local state that ANY subsequent Win32 call can overwrite -
so it must be read immediately adjacent to ``CreateMutexW`` itself, inside
the same ``_real_create_mutex()`` call, never via a separate later call.
``_real_create_mutex()`` therefore uses a ``ctypes.WinDLL(...,
use_last_error=True)`` handle (ctypes caches the error value itself, right
after the call returns) and returns the handle and that error code together
as one ``MutexCreationResult`` - there is no standalone, independently
callable "get the last error now" function for callers to accidentally
call too late.

Testability: the real Win32 calls are isolated in module-level
``_real_*`` functions, each individually injectable via
``BridgeInstanceGuard``'s keyword-only ``_create_mutex``/``_release_mutex``/
``_close_handle`` parameters - the same dependency-injection seam
``win32_input.py``'s ``_sender`` parameter already established, letting
tests/test_single_instance.py exercise the full acquire/duplicate/release/
cleanup contract deterministically on any OS without ``ctypes.windll``
(which does not exist off Windows). Only the ``_real_*`` functions
themselves call ``_require_windows()`` - the guard class never does - so an
injected fake never has to fight a platform gate that has nothing to do
with the logic under test.
"""

from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from typing import Callable, List, NamedTuple, Optional

# Local\ (not Global\) scopes the mutex to the current Terminal Services /
# Windows logon session, matching the task's "per-session/local name"
# requirement - a second bridge started by a different logged-in user (or
# in a different session) is not this guard's concern.
_MUTEX_NAME = r"Local\RemoteMicRC003_BridgeInstance"
_SETTINGS_MUTEX_NAME = r"Local\RemoteMicRC003_SettingsInstance"
_SETTINGS_WINDOW_TITLE = "Remote Mic 设置"

# https://learn.microsoft.com/windows/win32/debug/system-error-codes--0-499-
_ERROR_ALREADY_EXISTS = 183

# Deterministic, documented nonzero exit codes (DoD 2's "deterministic
# nonzero exit"), distinct from Python's generic ``1`` (an unhandled
# exception) so they are unambiguous in logs/scripts, and from each other so
# a duplicate launch is distinguishable from a guard that could not be used
# at all, and from a cleanup-only failure on the way out.
DUPLICATE_INSTANCE_EXIT_CODE = 3
GUARD_UNAVAILABLE_EXIT_CODE = 4
CLEANUP_FAILED_EXIT_CODE = 5


class SingleInstanceUnavailableError(Exception):
    """Raised when the Win32 mutex API itself could not be used to prove
    single ownership: either this is not Windows, or ``CreateMutexW``
    failed for a reason OTHER than "already exists" (e.g. access denied).
    Distinguishable from ``DuplicateInstanceError`` for logging/diagnostic
    purposes only - both are handled identically (fail closed) by
    ``__main__.py``'s ``_run_bridge()``.
    """


class DuplicateInstanceError(Exception):
    """Raised when another bridge-mode instance already owns the named
    mutex in this Windows logon session."""


class MutexCleanupError(RuntimeError):
    """Raised by ``BridgeInstanceGuard.__exit__`` whenever releasing/closing
    the mutex handle did not fully succeed (``ReleaseMutex``/
    ``CloseHandle`` returned FALSE, or either call itself raised) -
    unconditionally, even when the wrapped body ALSO raised (XRBM-021
    review round 1 correction: a cleanup failure that only surfaces when
    the body happened not to raise is still a silently-accepted failure the
    rest of the time). Cleanup (release then close, best-effort - one
    failing never skips the other) is always attempted first regardless.

    When the body already raised, this exception's ``__context__`` is that
    body exception - ordinary Python behavior for raising a new exception
    while another is propagating (`PEP 3134
    <https://peps.python.org/pep-3134/>`_), requiring no special handling
    here. A caller can always recover the original failure via
    ``mutex_cleanup_error.__context__`` - it is never discarded, only no
    longer the exception type that continues propagating.
    """


class MutexCreationResult(NamedTuple):
    """The handle and last-error code from ONE ``CreateMutexW`` call,
    captured together - see the module docstring's "Last-error capture"
    note for why these must never be split across two separate calls.
    """

    handle: int
    last_error: int


CreateMutexFn = Callable[[str], MutexCreationResult]
ReleaseMutexFn = Callable[[int], bool]
CloseHandleFn = Callable[[int], bool]


def _require_windows() -> None:
    if sys.platform != "win32":
        raise SingleInstanceUnavailableError(
            "the bridge single-instance mutex is only available on Windows"
        )


def _real_create_mutex(name: str) -> MutexCreationResult:
    """Calls the real ``CreateMutexW`` and captures ``GetLastError()``
    immediately afterward, via the same ``use_last_error=True`` WinDLL
    handle - see the module docstring. Returns handle 0 (NULL) on failure;
    never raises for that case, so ``BridgeInstanceGuard`` can distinguish
    "failed outright" from "succeeded but the object already existed" using
    only this one result.
    """

    _require_windows()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    # HANDLE CreateMutexW(LPSECURITY_ATTRIBUTES, BOOL bInitialOwner, LPCWSTR lpName)
    kernel32.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    ctypes.set_last_error(0)
    raw_handle = kernel32.CreateMutexW(None, True, name)
    last_error = ctypes.get_last_error()
    handle = int(raw_handle) if raw_handle else 0
    return MutexCreationResult(handle=handle, last_error=last_error)


def _real_release_mutex(handle: int) -> bool:
    kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
    # BOOL ReleaseMutex(HANDLE hMutex)
    kernel32.ReleaseMutex.argtypes = (wintypes.HANDLE,)
    kernel32.ReleaseMutex.restype = wintypes.BOOL
    return bool(kernel32.ReleaseMutex(handle))


def _real_close_handle(handle: int) -> bool:
    kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
    # BOOL CloseHandle(HANDLE hObject)
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    return bool(kernel32.CloseHandle(handle))


class BridgeInstanceGuard:
    """Owns (or fails to own) the per-session bridge single-instance mutex.

    Use as a context manager around bridge-mode startup::

        with BridgeInstanceGuard():
            app.main()

    - First owner: ``__enter__`` returns normally; ``__exit__`` always
      attempts ``ReleaseMutex`` THEN ``CloseHandle`` (best-effort - one
      failing never skips the other), INCLUDING when the wrapped body
      raises (ordinary context-manager semantics: ``__exit__`` always runs
      on the way out of a ``with`` block - this is what gives the "release
      in finally" guarantee without an explicit ``try/finally`` here). A
      cleanup failure (FALSE return or a raised exception from either call)
      ALWAYS raises ``MutexCleanupError`` - even when the wrapped body
      itself also raised. This never discards the body's exception: Python
      chains it onto ``MutexCleanupError.__context__`` automatically (see
      that class's docstring), so both are observable rather than the
      cleanup failure being silently accepted whenever a body exception
      happened to already be in flight.
    - Duplicate owner: ``CreateMutexW`` still hands back a valid handle to
      the EXISTING object (Win32 semantics - the caller does not become the
      owner), so ``__enter__`` closes that handle immediately (never
      releases a mutex it never owned) and raises ``DuplicateInstanceError``
      before the ``with`` block's body ever runs - a close failure here is
      folded into that same exception's message rather than raised
      separately, since the duplicate signal is the primary, more
      actionable event. Note that ``__exit__`` is NOT invoked when
      ``__enter__`` raises (a plain Python ``with``-statement guarantee),
      which is exactly why the duplicate path must close its own handle
      right here rather than relying on ``__exit__``.
    - Acquisition failure (``CreateMutexW`` itself failed, e.g. access
      denied): ``__enter__`` raises ``SingleInstanceUnavailableError``.
      There is no handle to close in this case (a failed ``CreateMutexW``
      returns NULL).

    Every raised message deliberately omits the raw handle value (DoD 4:
    "no raw address/handle is persisted or logged") - only Win32 error
    codes (small integers, not addresses) and fixed diagnostic strings like
    "ReleaseMutex returned FALSE" ever appear in them.
    """

    def __init__(
        self,
        *,
        name: str = _MUTEX_NAME,
        _create_mutex: CreateMutexFn = _real_create_mutex,
        _release_mutex: ReleaseMutexFn = _real_release_mutex,
        _close_handle: CloseHandleFn = _real_close_handle,
    ) -> None:
        self._name = name
        self._create_mutex = _create_mutex
        self._release_mutex = _release_mutex
        self._close_handle = _close_handle
        self._handle: Optional[int] = None

    def __enter__(self) -> "BridgeInstanceGuard":
        result = self._create_mutex(self._name)
        if not result.handle:
            raise SingleInstanceUnavailableError(
                f"CreateMutexW failed (GetLastError={result.last_error})"
            )
        if result.last_error == _ERROR_ALREADY_EXISTS:
            close_failure = self._safe_close(result.handle)
            message = (
                "another Remote Mic RC003 instance is already "
                "running in this Windows session"
            )
            if close_failure:
                message += f" (additionally, {close_failure})"
            raise DuplicateInstanceError(message)
        self._handle = result.handle
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        handle = self._handle
        self._handle = None
        if not handle:
            return None

        failures: List[str] = []
        release_failure = self._safe_release(handle)
        if release_failure:
            failures.append(release_failure)
        # Always attempted, regardless of whether release itself raised or
        # returned FALSE - one cleanup step's failure must never skip the
        # other (XRBM-021 review round 1 P1 #3).
        close_failure = self._safe_close(handle)
        if close_failure:
            failures.append(close_failure)

        if failures:
            # Unconditional - even if the body (exc_type is not None) also
            # raised. Python automatically chains that body exception onto
            # __context__ (see MutexCleanupError's docstring) rather than
            # discarding it, so this never has to choose between the two;
            # a cleanup failure must never go silently accepted just
            # because a body exception happened to already be in flight.
            raise MutexCleanupError(
                "mutex cleanup did not fully succeed: " + "; ".join(failures)
            )
        return None

    def _safe_release(self, handle: int) -> Optional[str]:
        # Fixed diagnostic text only (DoD 4: "no raw address/handle is
        # persisted or logged") - the underlying exception's own message is
        # deliberately NEVER interpolated here, since it could itself
        # contain a raw handle/address (e.g. a WinError message quoting the
        # value ReleaseMutex was called with).
        try:
            released = self._release_mutex(handle)
        except Exception:  # noqa: BLE001 - must not skip the close step below
            return "ReleaseMutex raised an exception"
        return None if released else "ReleaseMutex returned FALSE"

    def _safe_close(self, handle: int) -> Optional[str]:
        try:
            closed = self._close_handle(handle)
        except Exception:  # noqa: BLE001
            return "CloseHandle raised an exception"
        return None if closed else "CloseHandle returned FALSE"


class SettingsInstanceGuard(BridgeInstanceGuard):
    """Uses a separate per-session mutex for the settings window.

    The bridge and settings guards deliberately use different names: a
    running bridge must never prevent the user from opening settings, while
    a second settings process must not race the first one when saving the
    shared configuration files.
    """

    def __init__(
        self,
        *,
        _create_mutex: CreateMutexFn = _real_create_mutex,
        _release_mutex: ReleaseMutexFn = _real_release_mutex,
        _close_handle: CloseHandleFn = _real_close_handle,
    ) -> None:
        super().__init__(
            name=_SETTINGS_MUTEX_NAME,
            _create_mutex=_create_mutex,
            _release_mutex=_release_mutex,
            _close_handle=_close_handle,
        )


def _real_activate_settings_window(title: str) -> bool:
    _require_windows()
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.FindWindowW.argtypes = (wintypes.LPCWSTR, wintypes.LPCWSTR)
    user32.FindWindowW.restype = wintypes.HWND
    user32.ShowWindow.argtypes = (wintypes.HWND, ctypes.c_int)
    user32.ShowWindow.restype = wintypes.BOOL
    user32.SetForegroundWindow.argtypes = (wintypes.HWND,)
    user32.SetForegroundWindow.restype = wintypes.BOOL

    window = user32.FindWindowW(None, title)
    if not window:
        return False
    user32.ShowWindow(window, 9)  # SW_RESTORE; harmless when already visible.
    # Windows may reject SetForegroundWindow when its foreground-lock rules
    # do not grant this short-lived launcher permission. Finding and restoring
    # the exact settings window is still success: do not turn that normal OS
    # restriction into a blocking warning dialog that keeps the duplicate
    # launcher alive.
    user32.SetForegroundWindow(window)
    return True


def activate_existing_settings_window(
    *,
    _activate: Callable[[str], bool] = _real_activate_settings_window,
) -> bool:
    """Best-effort activation used by a duplicate settings launcher.

    False means the existing process owns the mutex but its window could not
    yet be found. Foreground activation itself is best effort because Windows
    may legitimately reject it for a background launcher.
    """

    try:
        return bool(_activate(_SETTINGS_WINDOW_TITLE))
    except Exception:
        return False


def _real_message_box(title: str, message: str) -> int:
    _require_windows()
    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    # int MessageBoxW(HWND hWnd, LPCWSTR lpText, LPCWSTR lpCaption, UINT uType)
    user32.MessageBoxW.argtypes = (wintypes.HWND, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.UINT)
    user32.MessageBoxW.restype = ctypes.c_int
    _MB_OK = 0x00000000
    _MB_ICONWARNING = 0x00000030
    _MB_SYSTEMMODAL = 0x00001000  # visible/on-top even with no owner window
    return user32.MessageBoxW(None, message, title, _MB_OK | _MB_ICONWARNING | _MB_SYSTEMMODAL)


def show_bridge_startup_blocked_notice(
    message: str,
    *,
    title: str = "Remote Mic · RC003",
    _message_box: Callable[[str, str], int] = _real_message_box,
) -> None:
    """Shows a visible Windows message box for a bridge launch the
    single-instance guard blocked - either a proven duplicate or an
    acquisition failure it could not resolve (XRBM-021 In-scope item 3;
    fail-closed contract in the module docstring). The packaged executable
    is windowed (``console=False`` in build/RemoteMicRC003.spec), so
    stdout/stderr are never visible to the user there - a message box is
    the only reliable user-visible signal. Off-Windows, or if the Win32
    call itself fails, this falls back to a stderr print so the signal is
    never completely silent during development/testing, even though that
    fallback path is not itself the task's "visible Windows notice".
    """

    try:
        _message_box(title, message)
    except Exception:
        print(f"Remote Mic RC003: {message}", file=sys.stderr)
