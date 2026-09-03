"""Real Win32 input for ordinary actions and the voice shortcut.

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
import time
from ctypes import wintypes
from typing import Callable, List, Optional, Sequence, Tuple

from . import win32_keys
from .legacy_key_suppressor_windows import VOICE_EVENT_EXTRA_INFO

_INPUT_KEYBOARD = 1
_KEYEVENTF_KEYUP = 0x0002
_KEYEVENTF_EXTENDEDKEY = 0x0001
_KEYEVENTF_SCANCODE = 0x0008

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
_EXTENDED_KEYS = frozenset(
    {
        win32_keys.VK_CODES[name]
        for name in ("up", "down", "left", "right", "rctrl", "ralt", "rwin")
    }
)

# Modifier VK codes are intentionally emitted as physical scan-code events.
# This keeps generic modifiers on their left-side physical key and preserves
# left/right identity for directional modifiers. The boolean records whether
# the scan code carries the E0 extended prefix.
_PHYSICAL_SCAN_CODES = {
    win32_keys.VK_CODES["ctrl"]: (0x1D, False),
    win32_keys.VK_CODES["lctrl"]: (0x1D, False),
    win32_keys.VK_CODES["rctrl"]: (0x1D, True),
    win32_keys.VK_CODES["shift"]: (0x2A, False),
    win32_keys.VK_CODES["lshift"]: (0x2A, False),
    win32_keys.VK_CODES["rshift"]: (0x36, False),
    win32_keys.VK_CODES["alt"]: (0x38, False),
    win32_keys.VK_CODES["lalt"]: (0x38, False),
    win32_keys.VK_CODES["ralt"]: (0x38, True),
    win32_keys.VK_CODES["win"]: (0x5B, True),
    win32_keys.VK_CODES["rwin"]: (0x5C, True),
}

RawSender = Callable[[Sequence[Tuple[int, bool]]], int]
VoiceSender = Callable[[int, bool], None]

_voice_backend: Optional[str] = None


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
        physical_scan = _PHYSICAL_SCAN_CODES.get(vk)
        if physical_scan is not None:
            scan_code, is_extended = physical_scan
            flags |= _KEYEVENTF_SCANCODE
            if is_extended:
                flags |= _KEYEVENTF_EXTENDEDKEY
            keybd_input = KEYBDINPUT(
                wVk=0,
                wScan=scan_code,
                dwFlags=flags,
                time=0,
                dwExtraInfo=0,
            )
        else:
            keybd_input = KEYBDINPUT(
                wVk=vk,
                wScan=0,
                dwFlags=flags,
                time=0,
                dwExtraInfo=0,
            )
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


def _real_keybd_event(vk: int, key_up: bool) -> None:
    """Emit one voice shortcut edge through the legacy Win32 keyboard API.

    Doubao registers its global voice shortcut as a virtual-key shortcut.  The
    upstream RC003 bridge uses ``keybd_event`` with the virtual key populated;
    sending the same edge as a scan-code-only ``SendInput`` event is accepted
    by Windows but is not recognized reliably by Doubao.
    """

    _require_windows()
    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    user32.MapVirtualKeyW.argtypes = (wintypes.UINT, wintypes.UINT)
    user32.MapVirtualKeyW.restype = wintypes.UINT
    user32.keybd_event.argtypes = (
        wintypes.BYTE,
        wintypes.BYTE,
        wintypes.DWORD,
        _ULONG_PTR,
    )
    user32.keybd_event.restype = None

    scan_code = int(user32.MapVirtualKeyW(vk, 0))
    flags = _KEYEVENTF_EXTENDEDKEY if vk in _EXTENDED_KEYS else 0
    if key_up:
        flags |= _KEYEVENTF_KEYUP
    user32.keybd_event(vk, scan_code, flags, VOICE_EVENT_EXTRA_INFO)


def reset_voice_backend() -> None:
    """Forget the selected voice transport so a later call can re-probe it."""

    global _voice_backend
    _voice_backend = None


def voice_backend_name() -> str:
    """Return the transport selected for the current voice session."""

    return _voice_backend or "unselected"


def _real_voice_event(vk: int, key_up: bool) -> None:
    """Emit a voice edge for the local hook to forward as a physical event."""

    global _voice_backend
    if _voice_backend is None:
        _voice_backend = "keybd_event_physicalized"
    _real_keybd_event(vk, key_up)


def _best_effort_voice_up(vk_codes: Sequence[int], sender: VoiceSender) -> None:
    for vk in reversed(vk_codes):
        try:
            sender(vk, True)
        except Exception:
            pass


def send_voice_key_combo_down(
    tokens: Sequence[str], *, _sender: Optional[VoiceSender] = None
) -> None:
    """Press a voice shortcut through the physicalized virtual-key path."""

    sender = _sender or _real_voice_event
    vk_codes = win32_keys.resolve_vk_codes(tokens)
    delivered: List[int] = []
    for vk in vk_codes:
        try:
            sender(vk, False)
        except Win32InputUnavailableError:
            raise
        except Exception as exc:
            _best_effort_voice_up(delivered, sender)
            raise OSError(f"voice key-down delivery failed: {exc}") from exc
        delivered.append(vk)


def send_voice_key_combo_up(
    tokens: Sequence[str], *, _sender: Optional[VoiceSender] = None
) -> None:
    """Release a voice shortcut through the selected voice transport."""

    sender = _sender or _real_voice_event
    vk_codes = list(reversed(win32_keys.resolve_vk_codes(tokens)))
    for vk in vk_codes:
        try:
            sender(vk, True)
        except Win32InputUnavailableError:
            raise
        except Exception as exc:
            _best_effort_voice_up([vk], sender)
            raise OSError(f"voice key-up delivery failed: {exc}") from exc


def send_voice_key_combo_tap(
    tokens: Sequence[str], *, _sender: Optional[VoiceSender] = None
) -> None:
    """Send a completed voice shortcut with the upstream 70 ms hold window."""

    sender = _sender or _real_voice_event
    vk_codes = win32_keys.resolve_vk_codes(tokens)
    send_voice_key_combo_down(tokens, _sender=sender)
    time.sleep(0.07)
    try:
        send_voice_key_combo_up(tokens, _sender=sender)
    except Exception:
        _best_effort_voice_up(vk_codes, sender)
        raise


def send_volume_up(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("volume_up",), _sender=_sender)


def send_volume_down(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("volume_down",), _sender=_sender)


# Semantic Windows actions.  These wrappers deliberately keep the action
# vocabulary out of ``app.py``'s platform plumbing: a configured ``方向上``
# action is an arrow action, not a UI string that happens to be translated to
# the token ``up``.  Tests can inject the same sender used by the low-level
# helpers, while production still emits one atomic SendInput batch.
def _send_semantic_tap(
    tokens: Sequence[str], *, _sender: Optional[RawSender] = None
) -> None:
    # Calling the default path without a keyword keeps these wrappers
    # compatible with simple injected senders used by callers/tests; the
    # explicit sender path remains available for ABI/batch tests.
    if _sender is None:
        send_key_combo_tap(tokens)
    else:
        send_key_combo_tap(tokens, _sender=_sender)


def send_escape(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("escape",), _sender=_sender)


def send_return(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("enter",), _sender=_sender)


def send_arrow_up(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("up",), _sender=_sender)


def send_arrow_down(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("down",), _sender=_sender)


def send_arrow_left(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("left",), _sender=_sender)


def send_arrow_right(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("right",), _sender=_sender)


def send_delete_backward(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("backspace",), _sender=_sender)


def send_show_desktop(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("win", "d"), _sender=_sender)


def send_context_menu(*, _sender: Optional[RawSender] = None) -> None:
    """Invoke the native Windows application/context-menu key."""

    _send_semantic_tap(("apps",), _sender=_sender)


def send_app_switcher(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("alt", "tab"), _sender=_sender)


def send_volume_mute(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("volume_mute",), _sender=_sender)


def send_play_pause(*, _sender: Optional[RawSender] = None) -> None:
    _send_semantic_tap(("media_play_pause",), _sender=_sender)
