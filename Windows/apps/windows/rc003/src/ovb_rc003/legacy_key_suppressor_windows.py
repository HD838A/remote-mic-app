"""Suppress legacy keyboard events that leak from RC003 HID buttons.

Raw Input lets this app identify RC003 button presses, but Windows may also
deliver the same translated HID Keyboard-page usage to the foreground app as a
normal legacy keyboard event. The real RC003 microphone key does this as F5.

This module installs a narrow low-level keyboard hook that swallows only the
configured non-injected virtual-key codes. The RC003 voice replacement path
rewrites the original F5 record in place while forwarding it to later hooks,
so host applications see a physical right-Alt-shaped record rather than a new
injected event. The private ``dwExtraInfo`` marker remains for the optional
keybd_event fallback and is never accepted for unrelated injected input.
"""

from __future__ import annotations

import ctypes
import logging
import sys
import threading
import time
from ctypes import wintypes
from dataclasses import dataclass
from typing import Callable, FrozenSet, List, NamedTuple, Optional, Tuple


WH_KEYBOARD_LL = 13
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105
LLKHF_INJECTED = 0x00000010
LLKHF_LOWER_IL_INJECTED = 0x00000002
LLKHF_EXTENDED = 0x00000001
LLKHF_UP = 0x00000080

# "RMICRC03" as a pointer-sized value. It is cleared before the event reaches
# downstream hooks and is never used for ordinary input.
VOICE_EVENT_EXTRA_INFO = 0x524D494352433033


class LegacyKeySuppressorUnavailableError(Exception):
    """Raised when the Windows low-level keyboard hook cannot be started."""


def _require_windows() -> None:
    if sys.platform != "win32":
        raise LegacyKeySuppressorUnavailableError(
            "legacy key suppression is only available on Windows"
        )


_logger = logging.getLogger(__name__)


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", wintypes.DWORD),
        ("scanCode", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class PhysicalKeyTarget(NamedTuple):
    """The physical low-level-hook identity to expose downstream."""

    vk_code: int
    scan_code: int
    extended: bool = False
    system_key: bool = False


@dataclass(frozen=True)
class _ArmedKeyEvent:
    vk_code: int
    scan_code: int
    extended: bool
    is_pressed: bool
    expires_at: float


def build_physical_key_event(
    target: PhysicalKeyTarget, is_pressed: bool, event_time: int
) -> Tuple[KBDLLHOOKSTRUCT, int]:
    """Build one non-injected low-level event and its keyboard message."""

    flags = LLKHF_EXTENDED if target.extended else 0
    if not is_pressed:
        flags |= LLKHF_UP
    event = KBDLLHOOKSTRUCT(
        vkCode=int(target.vk_code),
        scanCode=int(target.scan_code),
        flags=flags,
        time=int(event_time),
        dwExtraInfo=0,
    )
    if target.system_key:
        message = WM_SYSKEYDOWN if is_pressed else WM_SYSKEYUP
    else:
        message = WM_KEYDOWN if is_pressed else WM_KEYUP
    return event, message


class LegacyKeySuppressor:
    def __init__(
        self,
        suppress_vk_codes,
        on_key_event: Optional[Callable[[int, bool], None]] = None,
        on_key_transform: Optional[
            Callable[[int, bool], Optional[PhysicalKeyTarget]]
        ] = None,
        on_key_emit: Optional[Callable[[PhysicalKeyTarget, bool], bool]] = None,
        *,
        rc003_vk_codes: Optional[FrozenSet[int]] = None,
        voice_physicalize_vk_codes: Optional[FrozenSet[int]] = None,
        consume_wait_seconds: float = 0.060,
    ) -> None:
        self._suppress_vk_codes: FrozenSet[int] = frozenset(int(vk) for vk in suppress_vk_codes)
        self._on_key_event = on_key_event
        self._on_key_transform = on_key_transform
        # Production callers can replace a swallowed physical edge with a
        # real Win32 input edge. Returning False keeps the original event
        # swallowed while allowing the application to use its fallback path.
        self._on_key_emit = on_key_emit
        # The RC003 keyboard surface is a small, known set of VK codes. The
        # low-level hook only ever needs to wait for an arming Raw Input edge
        # for those codes; every other keyboard (and any other key) must pass
        # through with no latency, exactly like the upstream special-key hook.
        self._rc003_vk_codes: Optional[FrozenSet[int]] = (
            None if rc003_vk_codes is None else frozenset(int(vk) for vk in rc003_vk_codes)
        )
        # Voice-shortcut VK codes (modifiers + key) that the bridge injects
        # for the voice hotkey. The low-level hook rewrites ``LLKHF_INJECTED``
        # off these events so target applications (Typeless, 千问, ...) do
        # not see the bridge-owned edges as synthetic and discard them on
        # the injected-input reject path they use for any non-physical key.
        # Without this, real-device acceptance surfaced that the user's
        # voice window never opened even when the press/release TAP path was
        # exercised end-to-end - the events were delivered but every toggle
        # target silently dropped them.  See
        # ``docs/decisions/ADR-0005-voice-hotkey-physicalize.md``.
        self._voice_physicalize_vk_codes: Optional[FrozenSet[int]] = (
            None
            if voice_physicalize_vk_codes is None
            else frozenset(int(vk) for vk in voice_physicalize_vk_codes)
        )
        # The hook callback runs synchronously ahead of the Raw Input message
        # loop for the same physical press, so the arming edge can land up to
        # a few tens of milliseconds later (measured ~17ms on the RC003). The
        # upstream reference uses 0.06s for its correlated back/volume edges;
        # use the same conservative window for the RC003 key set.
        self._consume_wait_seconds = max(0.0, float(consume_wait_seconds))
        self._armed_events: List[_ArmedKeyEvent] = []
        self._armed_events_lock = threading.Lock()
        # Raw Input and the low-level hook run on different threads, so
        # ``arm_key_event`` (Raw Input thread) and ``consume_armed_key_event``
        # (hook thread) race for the same physical press. The consumer waits
        # briefly on this condition for the arming edge when it is not there
        # yet, instead of releasing the original key as a double action.
        self._armed_events_changed = threading.Condition(self._armed_events_lock)
        self._thread: Optional[threading.Thread] = None
        self._ready_event = threading.Event()
        self._stop_event = threading.Event()
        self._start_error: Optional[BaseException] = None
        self._thread_id = wintypes.DWORD(0)
        self._hook = None
        self._hookproc_keepalive = None

    @property
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def set_consume_wait_seconds(self, seconds: float) -> None:
        """Change the fallback correlation wait without restarting the hook.

        Once the direct HID side channel has produced a report it arms every
        RC003 edge before the low-level keyboard hook sees it.  At that point
        waiting for a later Raw Input arm only delays ordinary PC keys whose
        VK happens to overlap the remote (arrows, Enter, Home, and so on).
        """

        with self._armed_events_lock:
            self._consume_wait_seconds = max(0.0, float(seconds))
            self._armed_events_changed.notify_all()

    def set_rc003_vk_codes(self, vk_codes: FrozenSet[int]) -> None:
        """Replace the small VK set that may use Raw Input correlation."""

        with self._armed_events_lock:
            self._rc003_vk_codes = frozenset(int(vk) for vk in vk_codes)
            self._armed_events_changed.notify_all()

    def should_suppress(self, vk_code: int, flags: int) -> bool:
        if flags & LLKHF_INJECTED:
            return False
        return int(vk_code) in self._suppress_vk_codes

    def physicalize_injected_event(self, event: KBDLLHOOKSTRUCT) -> bool:
        """Make one bridge-owned voice edge look physical while forwarding.

        Two independent shapes are supported:

        * The legacy single-key ralt edge (``vk=0xA5``) that Doubao's own
          callback physicalises when the HOLD-mode built-in shortcut is
          selected.  Retained as a baseline so the upstream-shaped edge
          keeps working unchanged.
        * Every VK in ``voice_physicalize_vk_codes`` - the modifiers and
          key of the user's configured voice hotkey, e.g. ``lctrl``
          + ``lalt`` for Typeless.  Bridge-injected edges for any of
          these VK codes are also rewritten to drop
          ``LLKHF_INJECTED``/``LLKHF_LOWER_IL_INJECTED`` and clear
          ``dwExtraInfo`` so the foreground application receives a
          physical-shaped event and reacts to the toggle.

        Both shapes are guarded by ``dwExtraInfo == VOICE_EVENT_EXTRA_INFO``
        so that a foreign app's unrelated injected edges (a screen reader,
        a touch-typing automation tool, ...) still see the original
        ``LLKHF_INJECTED`` flag intact; only bridge-owned voice shortcuts
        get physicalised, never unrelated traffic.
        """

        if not (int(event.flags) & LLKHF_INJECTED):
            return False
        if int(event.dwExtraInfo) != VOICE_EVENT_EXTRA_INFO:
            return False
        vk = int(event.vkCode)
        is_ralt_legacy = vk == 0xA5
        is_voice_hotkey = (
            self._voice_physicalize_vk_codes is not None
            and vk in self._voice_physicalize_vk_codes
        )
        if not is_ralt_legacy and not is_voice_hotkey:
            return False
        event.flags = int(event.flags) & ~(
            LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED
        )
        event.dwExtraInfo = 0
        return True

    def handle_key_event(self, vk_code: int, flags: int, is_pressed: bool) -> bool:
        """Suppress one physical legacy event and optionally report its edge.

        Raw Input is the preferred device-scoped path, but Windows can expose
        the RC003 voice button only as a translated F5 legacy event. The
        caller is already swallowing that event, so reporting it here lets
        the application use the real key edge without allowing F5 to leak to
        the foreground window. Injected host shortcuts never enter this path.
        """

        if not self.should_suppress(vk_code, flags):
            return False
        if self._on_key_event is not None:
            try:
                self._on_key_event(int(vk_code), bool(is_pressed))
            except Exception:
                # The hook must remain fail-closed even if the application
                # callback is temporarily unavailable.
                pass
        return True

    def arm_key_event(
        self,
        vk_code: int,
        scan_code: int,
        extended: bool,
        is_pressed: bool,
        *,
        lifetime_seconds: float = 0.180,
    ) -> None:
        """Arm one exact Raw Input edge for low-level-hook suppression.

        Raw Input is device-scoped; ``WH_KEYBOARD_LL`` is not.  The app arms
        the exact keyboard edge it just received from the selected RC003, and
        the hook consumes only a matching non-injected edge for a short
        window.  This mirrors the reference project's event suppressor and
        prevents an injected arrow from being added to the remote's original
        arrow.
        """

        if int(vk_code) == 0x74:
            # F5 is handled by the dedicated voice path below.
            return
        expires_at = time.monotonic() + max(0.0, float(lifetime_seconds))
        armed = _ArmedKeyEvent(
            vk_code=int(vk_code),
            scan_code=int(scan_code),
            extended=bool(extended),
            is_pressed=bool(is_pressed),
            expires_at=expires_at,
        )
        with self._armed_events_lock:
            now = time.monotonic()
            self._armed_events = [
                event for event in self._armed_events if event.expires_at > now
            ]
            self._armed_events.append(armed)
            if len(self._armed_events) > 64:
                self._armed_events = self._armed_events[-64:]
            self._armed_events_changed.notify_all()
        _logger.info(
            "arm key edge: vk=0x%X scan=0x%X ext=%s pressed=%s window=%.3fs thread=%s",
            int(vk_code),
            int(scan_code),
            bool(extended),
            bool(is_pressed),
            float(lifetime_seconds),
            threading.current_thread().name,
        )

    def consume_armed_key_event(
        self,
        vk_code: int,
        scan_code: int,
        extended: bool,
        is_pressed: bool,
        *,
        wait_seconds: Optional[float] = None,
    ) -> bool:
        """Consume one matching pending physical keyboard edge.

        The low-level hook fires before the Raw Input ``WM_INPUT`` for the
        same physical press, on a different thread, so the arming edge from
        ``arm_key_event`` is normally not there yet when the hook runs. Wait
        a short window for it (upstream correlates the same way) so a quick
        remote press is not turned into a double action by the hook releasing
        the original key before the app's replacement edge arrives. The
        window only applies to the RC003 key set; every other key passes
        through with no latency.
        """

        if self._rc003_vk_codes is not None and int(vk_code) not in self._rc003_vk_codes:
            return False
        effective_wait = (
            self._consume_wait_seconds if wait_seconds is None else max(0.0, float(wait_seconds))
        )
        with self._armed_events_lock:
            deadline = time.monotonic() + effective_wait
            while True:
                now = time.monotonic()
                matched = self._consume_armed_key_event_locked(
                    vk_code, scan_code, extended, is_pressed, now
                )
                if matched or now >= deadline:
                    elapsed = now - deadline + effective_wait
                    log = _logger.info if matched else _logger.debug
                    log(
                        "consume key edge: vk=0x%X scan=0x%X ext=%s pressed=%s "
                        "matched=%s armed=%d waited=%.3fs thread=%s",
                        int(vk_code),
                        int(scan_code),
                        bool(extended),
                        bool(is_pressed),
                        bool(matched),
                        len(self._armed_events),
                        elapsed,
                        threading.current_thread().name,
                    )
                    return matched
                remaining = deadline - now
                self._armed_events_changed.wait(remaining)

    def _consume_armed_key_event_locked(
        self,
        vk_code: int,
        scan_code: int,
        extended: bool,
        is_pressed: bool,
        now: float,
    ) -> bool:
        kept: List[_ArmedKeyEvent] = []
        matched = False
        for event in self._armed_events:
            if (
                not matched
                and event.expires_at > now
                and event.vk_code == int(vk_code)
                and event.scan_code == int(scan_code)
                and event.extended == bool(extended)
                and event.is_pressed == bool(is_pressed)
            ):
                matched = True
                continue
            if event.expires_at > now:
                kept.append(event)
        self._armed_events = kept
        return matched

    def _forward_transformed_key_event(
        self,
        n_code: int,
        target: PhysicalKeyTarget,
        is_pressed: bool,
        event_time: int,
        event: KBDLLHOOKSTRUCT,
        event_address: int,
    ) -> None:
        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        user32.CallNextHookEx.argtypes = (
            wintypes.HHOOK,
            ctypes.c_int,
            wintypes.WPARAM,
            wintypes.LPARAM,
        )
        user32.CallNextHookEx.restype = ctypes.c_ssize_t
        transformed, message = build_physical_key_event(
            target, is_pressed, event_time
        )
        original = (
            event.vkCode,
            event.scanCode,
            event.flags,
            event.time,
            event.dwExtraInfo,
        )
        # The incoming event is already a physical low-level-hook record.
        # Mutate that record in place for the duration of CallNextHookEx so
        # the native consumer sees the same callback memory, with no
        # SendInput marker and no separately allocated/fabricated pointer.
        event.vkCode = transformed.vkCode
        event.scanCode = transformed.scanCode
        event.flags = transformed.flags
        event.time = transformed.time
        event.dwExtraInfo = transformed.dwExtraInfo
        try:
            user32.CallNextHookEx(self._hook, n_code, message, event_address)
        finally:
            (
                event.vkCode,
                event.scanCode,
                event.flags,
                event.time,
                event.dwExtraInfo,
            ) = original

    def start(
        self,
        *,
        start_timeout: float = 5.0,
        _run_target: Optional[Callable[[], None]] = None,
    ) -> None:
        if self.is_running:
            raise LegacyKeySuppressorUnavailableError(
                "legacy key suppressor is already running; call stop() first"
            )
        if not self._suppress_vk_codes:
            return
        if _run_target is None:
            _require_windows()
        self._ready_event.clear()
        self._stop_event.clear()
        self._start_error = None
        self._thread = threading.Thread(target=_run_target or self._run, daemon=True)
        self._thread.start()
        if not self._ready_event.wait(timeout=start_timeout):
            self._stop_event.set()
            self._thread.join(timeout=2.0)
            raise LegacyKeySuppressorUnavailableError(
                f"legacy key suppressor did not become ready within {start_timeout}s"
            )
        if self._start_error is not None:
            error = self._start_error
            self._thread = None
            raise error

    def stop(self) -> None:
        self._stop_event.set()
        with self._armed_events_lock:
            self._armed_events.clear()
        if self._thread is None:
            return
        if sys.platform == "win32" and self._thread_id.value:
            user32 = ctypes.windll.user32  # type: ignore[attr-defined]
            user32.PostThreadMessageW.argtypes = (
                wintypes.DWORD,
                wintypes.UINT,
                wintypes.WPARAM,
                wintypes.LPARAM,
            )
            user32.PostThreadMessageW.restype = wintypes.BOOL
            user32.PostThreadMessageW(self._thread_id.value, 0x0012, 0, 0)  # WM_QUIT
        self._thread.join(timeout=2.0)
        if self._thread.is_alive():
            raise LegacyKeySuppressorUnavailableError(
                "legacy key suppressor thread did not stop within 2.0s"
            )
        self._thread = None
        self._thread_id = wintypes.DWORD(0)

    def _run(self) -> None:
        try:
            user32 = ctypes.windll.user32  # type: ignore[attr-defined]
            kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]

            LRESULT = ctypes.c_ssize_t
            HOOKPROC = ctypes.WINFUNCTYPE(
                LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
            )
            hookproc = HOOKPROC(self._hookproc)
            self._hookproc_keepalive = hookproc

            kernel32.GetCurrentThreadId.argtypes = ()
            kernel32.GetCurrentThreadId.restype = wintypes.DWORD
            self._thread_id = wintypes.DWORD(kernel32.GetCurrentThreadId())

            kernel32.GetModuleHandleW.argtypes = (wintypes.LPCWSTR,)
            kernel32.GetModuleHandleW.restype = wintypes.HMODULE

            user32.SetWindowsHookExW.argtypes = (
                ctypes.c_int,
                HOOKPROC,
                wintypes.HINSTANCE,
                wintypes.DWORD,
            )
            user32.SetWindowsHookExW.restype = wintypes.HHOOK

            user32.UnhookWindowsHookEx.argtypes = (wintypes.HHOOK,)
            user32.UnhookWindowsHookEx.restype = wintypes.BOOL

            self._hook = user32.SetWindowsHookExW(
                WH_KEYBOARD_LL, hookproc, kernel32.GetModuleHandleW(None), 0
            )
            if not self._hook:
                raise LegacyKeySuppressorUnavailableError("SetWindowsHookExW failed")

            self._ready_event.set()

            msg = wintypes.MSG()
            user32.GetMessageW.argtypes = (
                ctypes.POINTER(wintypes.MSG),
                wintypes.HWND,
                wintypes.UINT,
                wintypes.UINT,
            )
            user32.GetMessageW.restype = ctypes.c_int
            while not self._stop_event.is_set():
                result = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
                if result <= 0:
                    break
        except BaseException as exc:  # noqa: BLE001 - surfaced to start()
            self._start_error = exc
            self._ready_event.set()
        finally:
            if self._hook:
                try:
                    ctypes.windll.user32.UnhookWindowsHookEx(self._hook)  # type: ignore[attr-defined]
                except Exception:
                    pass
                self._hook = None

    def _hookproc(self, n_code, w_param, l_param):
        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        user32.CallNextHookEx.argtypes = (
            wintypes.HHOOK,
            ctypes.c_int,
            wintypes.WPARAM,
            wintypes.LPARAM,
        )
        user32.CallNextHookEx.restype = ctypes.c_ssize_t
        if n_code >= 0 and int(w_param) in (
            WM_KEYDOWN,
            WM_KEYUP,
            WM_SYSKEYDOWN,
            WM_SYSKEYUP,
        ):
            event = KBDLLHOOKSTRUCT.from_address(int(l_param))
            is_pressed = int(w_param) in (WM_KEYDOWN, WM_SYSKEYDOWN)
            original_flags = int(event.flags)
            original_extra_info = int(event.dwExtraInfo)
            if self.physicalize_injected_event(event):
                try:
                    return user32.CallNextHookEx(
                        self._hook, n_code, w_param, int(l_param)
                    )
                finally:
                    event.flags = original_flags
                    event.dwExtraInfo = original_extra_info
            if self.should_suppress(event.vkCode, event.flags):
                if self._on_key_transform is not None:
                    try:
                        target = self._on_key_transform(
                            int(event.vkCode), is_pressed
                        )
                    except Exception:
                        target = None
                    if target is not None:
                        if self._on_key_emit is not None:
                            try:
                                self._on_key_emit(target, is_pressed)
                            except Exception:
                                # Never leak the original F5 if replacement
                                # delivery fails. The app callback still gets
                                # the edge and can use its normal fallback.
                                pass
                        else:
                            # Kept for isolated consumers of this helper. RC003
                            # production wiring leaves on_key_emit unset so
                            # the original hook record is forwarded directly
                            # through the native hook chain.
                            try:
                                self._forward_transformed_key_event(
                                    n_code,
                                    target,
                                    is_pressed,
                                    int(event.time),
                                    event,
                                    int(l_param),
                                )
                            except Exception:
                                pass
                        if self._on_key_event is not None:
                            try:
                                self._on_key_event(int(event.vkCode), is_pressed)
                            except Exception:
                                pass
                        return 1
                # Dedicated legacy keys (currently RC003 F5) never need the
                # ordinary-button Raw Input race.  Swallow/report them now so
                # an auto-repeat stream cannot monopolise the hook in 60 ms
                # waits and stall the user's real keyboard.
                if self.handle_key_event(event.vkCode, event.flags, is_pressed):
                    return 1
            if (
                not (int(event.flags) & LLKHF_INJECTED)
                and self.consume_armed_key_event(
                    int(event.vkCode),
                    int(event.scanCode),
                    bool(int(event.flags) & LLKHF_EXTENDED),
                    is_pressed,
                )
            ):
                return 1
        return user32.CallNextHookEx(self._hook, n_code, w_param, l_param)
