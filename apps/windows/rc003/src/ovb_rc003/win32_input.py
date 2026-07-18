"""Real Win32 key injection via SendInput.

Windows-only. Kept as thin as possible and separated from win32_keys.py's
pure VK-code resolution so the mapping logic stays unit-testable everywhere
while only the actual syscall needs ctypes/user32.

Batching/rollback contract (fixed after XRBM-014 review RETRY P1 #4 - see
XRBM-014's independent review; extended by XRBM-019/XRBM-020 - see
XRBM-019's independent review): a multi-key combo is submitted to
``SendInput`` as a single batched call (one array, one syscall) rather than
one call per key, so there is only one narrow window in which a partial
delivery could happen at all. If ``SendInput`` reports it queued fewer
events than requested, the exact keys that *did* go down are immediately
released before the failure is raised. A generic exception raised by the
sender AFTER submission is treated the same way - delivery is unknown, not
"nothing landed" - so every key that may still be down gets its own
best-effort release attempt before the failure is raised too. This applies
to all three combo helpers, including the cleanup-path ``send_key_combo_up``:
its failures (partial or generic) are best-effort retried and then RAISED as
an observable ``OSError``, never swallowed - the sole exception is
``Win32InputUnavailableError`` ("not running on Windows"), a pre-submission
platform-availability signal re-raised as-is with no rollback attempted,
since nothing could have landed.

Testability: every public function accepts an optional ``_sender`` keyword
(a callable matching ``RawSender``) used only by tests. Production callers
never pass it, so the real ``ctypes``/``user32.SendInput`` path is used -
but tests/test_win32_input_batching.py can inject a fake sender that
simulates partial delivery and assert the exact rollback calls that result,
without needing ``ctypes.windll`` (which does not exist off Windows) at all.
"""

from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from typing import Callable, List, Optional, Sequence, Tuple

from . import win32_keys

_INPUT_KEYBOARD = 1
_KEYEVENTF_KEYUP = 0x0002
_KEYEVENTF_EXTENDEDKEY = 0x0001

# Real x64 Win32 ``INPUT`` struct shape (fixed after XRBM-014 review round 2
# P1 #1: the union previously declared only ``KEYBDINPUT``, so
# ``ctypes.sizeof(INPUT)`` was smaller than the real ``sizeof(INPUT)``
# Windows expects in ``SendInput``'s ``cbSize`` argument - Microsoft
# documents that ``SendInput`` fails outright when ``cbSize`` does not match
# the real struct size. The real ``INPUT`` union is
# ``MOUSEINPUT | KEYBDINPUT | HARDWAREINPUT`` (``MOUSEINPUT`` is the largest
# member, which is what actually determines ``sizeof(INPUT)`` on x64), and
# ``dwExtraInfo`` is a ``ULONG_PTR`` (a pointer-*sized* integer, not a
# pointer-to-``ULONG``) - using a pointer type there previously happened to
# be the same width on x64 but was the wrong C type and would have been
# wrong on x86.
#
# ``ctypes.wintypes`` is importable on any OS (it defines plain ctypes
# aliases, no ``windll`` linkage) - but ``wintypes.DWORD``/``LONG`` are
# aliases for ``ctypes.c_ulong``/``c_long``, whose *width* tracks the HOST
# platform's C ``long`` (4 bytes on Windows' LLP64 model, but 8 bytes on
# 64-bit macOS/Linux's LP64 model). Using them here would make
# ``ctypes.sizeof()`` correct only when actually run on Windows. These
# fields are therefore declared with explicit fixed-width types
# (``c_uint32``/``c_int32``/``c_uint16``) that match the real Win32 ABI on
# every host - which is also what makes it possible to assert
# ``ctypes.sizeof(INPUT) == 40`` in a cross-platform test (see
# tests/test_win32_input_abi.py), not only a Windows-only one.
_ULONG_PTR = ctypes.c_size_t  # pointer-sized on every host/target pair this
# project supports (32-bit ULONG_PTR on x86 Windows, 64-bit on x64 Windows).


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_int32),
        ("dy", ctypes.c_int32),
        ("mouseData", ctypes.c_uint32),
        ("dwFlags", ctypes.c_uint32),
        ("time", ctypes.c_uint32),
        ("dwExtraInfo", _ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.c_uint16),
        ("wScan", ctypes.c_uint16),
        ("dwFlags", ctypes.c_uint32),
        ("time", ctypes.c_uint32),
        ("dwExtraInfo", _ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", ctypes.c_uint32),
        ("wParamL", ctypes.c_uint16),
        ("wParamH", ctypes.c_uint16),
    ]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("union", _INPUT_UNION)]

# Keys Windows treats as "extended" for SendInput purposes.
_EXTENDED_KEYS = frozenset({win32_keys.VK_CODES[name] for name in ("up", "down", "left", "right")})

RawSender = Callable[[Sequence[Tuple[int, bool]]], int]


class Win32InputUnavailableError(Exception):
    """Raised when SendInput is invoked on a non-Windows platform."""


def _require_windows() -> None:
    if sys.platform != "win32":
        raise Win32InputUnavailableError(
            "SendInput key injection is only available on Windows"
        )


def _build_input_array(events: Sequence[Tuple[int, bool]]):
    array = (INPUT * len(events))()
    for index, (vk, key_up) in enumerate(events):
        flags = _KEYEVENTF_KEYUP if key_up else 0
        if vk in _EXTENDED_KEYS:
            flags |= _KEYEVENTF_EXTENDEDKEY
        keybd_input = KEYBDINPUT(wVk=vk, wScan=0, dwFlags=flags, time=0, dwExtraInfo=0)
        array[index] = INPUT(type=_INPUT_KEYBOARD, union=_INPUT_UNION(ki=keybd_input))
    return array, INPUT


def _real_send_input_batch(events: Sequence[Tuple[int, bool]]) -> int:
    """Submits every (vk, key_up) pair in ``events`` as ONE real SendInput
    call. Returns the number of events SendInput reports it queued (may be
    less than ``len(events)`` on partial delivery). This is the only
    function in this module that is fundamentally impossible to exercise
    off Windows (``ctypes.windll`` does not exist there) - see the module
    docstring for how the rest of the batching/rollback logic is still
    tested via dependency injection.
    """

    _require_windows()
    if not events:
        return 0

    array, input_type = _build_input_array(events)
    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    # Declared explicitly (XRBM-014 review round 2 P1 #8) rather than left at
    # ctypes defaults: without an explicit restype, ctypes assumes a 32-bit
    # ``int`` return, and without argtypes the pointer/size arguments are
    # marshaled less predictably on 64-bit Windows.
    user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(input_type), ctypes.c_int)
    user32.SendInput.restype = wintypes.UINT
    # XRBM-018 RETRY 1 P1 #1: with ``argtypes`` declared as
    # ``POINTER(INPUT)`` (a pointer to one element), ctypes only accepts the
    # array instance itself here (it implicitly decays to a pointer to its
    # first element, exactly like a C array passed where a pointer is
    # expected) - ``ctypes.byref(array)`` instead produces a pointer *to the
    # array object* (a distinct, incompatible pointer type from ctypes' point
    # of view: ``LP_INPUT_Array_N``, not ``LP_INPUT``) and raises
    # ``ArgumentError`` before the call ever reaches Windows. ``byref()`` is
    # only correct for a pointer to a single instance, never to an array.
    sent = user32.SendInput(len(events), array, ctypes.sizeof(input_type))
    return int(sent)


def _best_effort_release(vk_codes: Sequence[int], sender: RawSender) -> None:
    """Releases exactly these VK codes, swallowing any failure - used only
    for rollback/cleanup paths that must never raise past this point.
    """

    for vk in vk_codes:
        try:
            sender([(vk, True)])
        except Exception:
            pass


def send_key_combo_down(
    tokens: Sequence[str], *, _sender: Optional[RawSender] = None
) -> None:
    """Presses every key in ``tokens`` down, in one batched call.

    On partial delivery, releases exactly the keys that did go down, then
    raises - callers must not assume the combo is active after an exception.

    XRBM-020 (fixing the XRBM-019 REPLAN gap - see
    XRBM-019's independent review round 2): a generic exception
    raised by the sender AFTER submission does not prove zero events reached
    Windows - delivery is unknown, not "nothing landed". Every key in the
    batch is therefore treated as possibly down and gets its own best-effort
    release attempt before the failure is surfaced as ``OSError`` chained
    from the original exception. ``Win32InputUnavailableError`` is a
    PRE-submission platform-availability signal (raised by
    ``_require_windows()`` before any event is built), so it is re-raised
    as-is with no rollback attempted - nothing could have landed.
    """

    sender = _sender or _real_send_input_batch
    vk_codes = win32_keys.resolve_vk_codes(tokens)
    events: List[Tuple[int, bool]] = [(vk, False) for vk in vk_codes]
    try:
        sent = sender(events)
    except Win32InputUnavailableError:
        raise
    except Exception as exc:
        _best_effort_release(list(reversed(vk_codes)), sender)
        raise OSError(f"key-down delivery failed: {exc}") from exc
    if sent < len(events):
        stuck_down = [vk for vk, _key_up in events[:sent]]
        _best_effort_release(list(reversed(stuck_down)), sender)
        raise OSError(
            f"SendInput delivered only {sent}/{len(events)} key-down events; rolled back"
        )


def send_key_combo_up(
    tokens: Sequence[str], *, _sender: Optional[RawSender] = None
) -> None:
    """Releases every key in ``tokens`` (reverse order), in one batched call.

    This is a cleanup-path primitive: besides "SendInput is not available on
    this OS" (``Win32InputUnavailableError``, re-raised so callers can log
    it once), every other failure still gets a best-effort retry of whatever
    key(s) may not have landed - but (XRBM-019 review round 1 P1 #4) it now
    RAISES ``OSError`` afterward instead of swallowing the failure, generic
    or partial. A caller doing multi-step cleanup (see app.py's
    ``_cleanup_once``) must still be able to attempt its other independent
    steps after this raises - that is done by wrapping this call, not by
    this function silently reporting success it cannot back up. Silently
    swallowing a failed key-up here previously meant a host key could be
    left physically down (HOLD mode) or a closing tap could be lost (TOGGLE
    mode) while the caller's own state already recorded it as released.

    XRBM-020 (fixing the XRBM-019 REPLAN gap - see
    XRBM-019's independent review round 2): the generic-exception
    branch used to raise immediately with no rollback attempt at all - an
    exception raised by the sender AFTER submission does not prove zero
    key-ups landed, so every key in the batch is now given its own
    best-effort release attempt (matching the partial-delivery branch)
    before ``OSError`` is raised, chained from the original exception.
    """

    sender = _sender or _real_send_input_batch
    vk_codes = list(reversed(win32_keys.resolve_vk_codes(tokens)))
    events: List[Tuple[int, bool]] = [(vk, True) for vk in vk_codes]
    try:
        sent = sender(events)
    except Win32InputUnavailableError:
        raise
    except Exception as exc:
        _best_effort_release(vk_codes, sender)
        raise OSError(f"key-up delivery failed: {exc}") from exc
    if sent < len(events):
        remaining = [vk for vk, _key_up in events[sent:]]
        _best_effort_release(remaining, sender)
        raise OSError(
            f"SendInput delivered only {sent}/{len(events)} key-up events; "
            "best-effort release attempted for the rest"
        )


def send_key_combo_tap(
    tokens: Sequence[str], *, _sender: Optional[RawSender] = None
) -> None:
    """Presses and releases every key in ``tokens`` as ONE batched SendInput
    call (all key-downs in order, then all key-ups in reverse order).

    On partial delivery, rolls back whichever keys are still down (either
    because the down half didn't fully land, or because the down half fully
    landed but part of the up half didn't) before raising.

    XRBM-020 (fixing the XRBM-019 REPLAN gap - see
    XRBM-019's independent review round 2): a generic exception
    raised by the sender AFTER submission does not prove zero events
    (either half) reached Windows - every key in this tap is treated as
    possibly still down and gets its own best-effort release attempt before
    ``OSError`` is raised, chained from the original exception.
    ``Win32InputUnavailableError`` is re-raised as-is with no rollback, same
    as the other two helpers - it is a pre-submission signal.
    """

    sender = _sender or _real_send_input_batch
    vk_codes = win32_keys.resolve_vk_codes(tokens)
    down_events: List[Tuple[int, bool]] = [(vk, False) for vk in vk_codes]
    up_events: List[Tuple[int, bool]] = [(vk, True) for vk in reversed(vk_codes)]
    events = down_events + up_events
    try:
        sent = sender(events)
    except Win32InputUnavailableError:
        raise
    except Exception as exc:
        _best_effort_release(list(reversed(vk_codes)), sender)
        raise OSError(f"key tap delivery failed: {exc}") from exc
    if sent < len(events):
        if sent < len(down_events):
            # Not every key-down made it; release exactly the ones that did.
            stuck_down = [vk for vk, _key_up in down_events[:sent]]
            _best_effort_release(list(reversed(stuck_down)), sender)
        else:
            # All key-downs landed; finish releasing whatever key-ups didn't.
            remaining_index = sent - len(down_events)
            remaining_ups = [vk for vk, _key_up in up_events[remaining_index:]]
            _best_effort_release(remaining_ups, sender)
        raise OSError(
            f"SendInput delivered only {sent}/{len(events)} events for a key tap; rolled back"
        )


def send_volume_up(*, _sender: Optional[RawSender] = None) -> None:
    send_key_combo_tap(("volume_up",), _sender=_sender)


def send_volume_down(*, _sender: Optional[RawSender] = None) -> None:
    send_key_combo_tap(("volume_down",), _sender=_sender)
