"""Entry point wiring: connects the pieces into a running RC003 client.

Windows-only end-to-end (BLE via winrt, HID via Raw Input, key injection via
SendInput). NOT exercised against real hardware in this candidate - no
device pairing/control happens anywhere in this repository or its tests, per
the project's hard boundary. See this package's top-level README.md "Known
gaps" section for what remains 待核验 (to be verified) on a real Windows
machine with a paired RC003.

Reconnect/cleanup contract (fixed after XRBM-014 review RETRY P1 #2 - see
XRBM-014's independent review): ``RC003App`` no longer connects once
and waits forever. ``connection_supervisor.ConnectionSupervisor`` drives a
connect/wait/cleanup/retry loop; a BLE disconnect notification or a protocol
error both call ``request_reconnect()``, which ends the current wait and
guarantees ``_cleanup_once()`` runs before the next connect attempt.
``_cleanup_once()`` releases the voice hotkey, stops the Raw Input listener
(which itself force-releases any stuck button), and closes the BLE session
(which sends MIC_CLOSE, unsubscribes, and closes the device/service) - every
step is individually wrapped so one step's failure never skips the rest.

Voice fail-closed ordering (P1 #3): the output endpoint is resolved and
opened BEFORE any hotkey/MIC_OPEN is sent, not lazily after the device has
already started streaming. If the endpoint is missing or fails to open,
neither the hotkey nor MIC_OPEN are sent at all - voice fails fully closed
while ordinary buttons keep working.

Further fail-closed ordering (XRBM-018, fixing XRBM-014 review round 2 P1
#6): the host hotkey is now sent BEFORE MIC_OPEN, and if it fails to fully
deliver, MIC_OPEN is never sent at all - a device streaming into Windows
without ever having actually tapped/held the configured hotkey is exactly
the "voice opened after host-trigger failure" defect the round-2 review
found. A playback write failure now also fails closed (closes and discards
the sink) and requests a reconnect, instead of logging indefinitely while
the device keeps streaming into nothing.

Cleanup ownership (XRBM-019 P1 #2, fixing XRBM-018 round 2 finding #2):
stopping the Raw Input listener or closing the BLE session can now each
raise when the resource they own reports it is still alive (a thread that
did not stop within its join timeout - see raw_input_windows.py's
``stop()``/ble_transport_winrt.py's ``close()``). ``_cleanup_once()`` still
attempts every one of the four steps (voice hotkey, HID, BLE, playback)
regardless of any single step's outcome, but a step whose owner reports it
is still alive is intentionally left set on ``self._hid_listener``/
``self._ble_session`` - not cleared to ``None`` - so no later code can
mistake a still-running listener/session for a clean slate. Once every step
has been attempted, any such retained-owner failure is aggregated and
raised from ``_cleanup_once()`` itself, which is
``ConnectionSupervisor.run_forever()``'s injected ``cleanup`` callable: that
exception propagates out of ``run_forever()``'s ``finally`` block and ends
the connect/retry loop entirely - the supervisor fails closed rather than
starting a fresh ``connect()`` generation over resources that might still
be live.
"""

from __future__ import annotations

import asyncio
import logging
import queue
import threading
from typing import List, Optional

from . import (
    audio_output,
    audio_playback,
    action_executor,
    ble_transport_winrt,
    bridge_control_windows,
    button_gesture,
    config,
    connection_supervisor,
    doubao_rpc,
    frida_compat,
    hid_identity,
    hotkey,
    identity,
    key_mapping,
    legacy_key_suppressor_windows,
    logging_setup,
    qianwen_physicalizer,
    raw_input_windows,
    usage_statistics,
    voice_controller,
    voice_edge_debouncer,
    win32_input,
    win32_keys,
)
from .atvv_session import AudioStarted, AudioStopped, CapsReceived, MicButtonPressed, PcmStats


class CleanupIncompleteError(RuntimeError):
    """Raised by ``RC003App._cleanup_once()`` when the Raw Input listener
    and/or the BLE session report they are still alive after cleanup was
    attempted - see the module docstring's "Cleanup ownership" note. Every
    other cleanup step still ran before this is raised.
    """


def open_configured_application(action: key_mapping.ButtonAction) -> bool:
    """Application-action seam kept at the app boundary for testability."""

    return action_executor.open_configured_application(action)


class RC003App:
    def __init__(self) -> None:
        self._config_root = config.config_root()
        self._config = config.load_config(config.config_path(self._config_root))
        self._bindings_path = config.key_bindings_path(self._config_root)
        self._bindings = config.load_key_bindings(
            self._bindings_path
        )
        self._bindings_mtime_ns = self._bindings_file_mtime_ns()
        self._raw_input_native_passthrough_buttons = (
            self._compute_raw_input_native_passthrough_buttons()
        )
        self._button_gestures = button_gesture.ButtonGestureDispatcher(
            is_action_configured=self._is_button_action_configured,
            is_repeatable=self._is_button_repeatable,
            on_trigger=self._on_button_trigger,
        )
        self._logger: logging.Logger = logging_setup.get_logger(self._config_root)
        self._usage_statistics = usage_statistics.UsageStatisticsStore(self._config_root)
        # Raw Input may repeat a key-down edge while a button is held.  Usage
        # frequency represents physical presses, not keyboard auto-repeat.
        self._usage_pressed_buttons: set[str] = set()
        self._voice = voice_controller.VoiceController(
            key_mapping.VoiceTriggerMode(self._config["voice_trigger_mode"])
        )
        self._voice_hotkey = hotkey.HotkeySpec.parse(self._config["voice_hotkey"])
        self._logger.info(
            "voice host protocol configured: mode=%s hotkey=%s",
            self._voice.trigger_mode.value,
            self._voice_hotkey.serialize(),
        )
        self._voice_audio_start_fallback_pending = False
        self._voice_audio_started_waiting_for_legacy_f5 = False
        # Raw Input and the ATVV control channel arrive on different worker
        # threads. Serialize the voice state machine so one physical press
        # cannot race into two host shortcut deliveries.
        self._voice_trigger_lock = threading.Lock()
        self._voice_raw_input_trigger_pending = False
        # Typeless uses a toggle shortcut, while the RC003 microphone is a
        # physical hold-to-talk control.  Track the real key lifecycle so
        # short/fragmented ATVV AUDIO_STOP notifications cannot close the
        # host recognizer before the user actually releases the remote.
        self._voice_physical_button_down = False
        # A stable ATVV AUDIO_STOP can arrive tens of seconds before the
        # translated Windows F5 key-up. After TOGGLE closes on that stronger
        # transport boundary, ignore stale F5 downs until a debounced
        # physical release or a later authoritative AUDIO_START clears it.
        self._voice_waiting_for_physical_release_after_audio_stop = False
        # When the built-in HOLD shortcut is selected, the low-level F5 hook
        # can deliver one right-Alt edge through the physicalized low-level
        # hook path. Keep this separate from VoiceController's logical state so
        # the normal audio/ATVV lifecycle still deduplicates correctly without
        # sending a second host shortcut.
        self._voice_legacy_transform_key_down = False
        self._voice_legacy_transform_session = False
        self._voice_legacy_transform_emitted = False
        self._legacy_f5_is_down = False
        self._ble_session: Optional[ble_transport_winrt.RC003BleSession] = None
        self._hid_listener: Optional[raw_input_windows.RawInputButtonListener] = None
        self._legacy_key_suppressor: Optional[
            legacy_key_suppressor_windows.LegacyKeySuppressor
        ] = None
        self._hid_report_tap: Optional[frida_compat.RC003HidReportTap] = None
        self._direct_hid_usages: set[int] = set()
        self._direct_hid_lock = threading.Lock()
        # True once the tap has reported at least one full keyboard snapshot.
        # While the tap side channel is live, the keyboard Raw Input path
        # stands down so the same physical edge is not armed/dispatched twice.
        self._direct_hid_tap_active = False
        self._playback: Optional[audio_playback.EndpointPlaybackSink] = None
        self._voice_pcm_stats = PcmStats()

        self._supervisor = connection_supervisor.ConnectionSupervisor(
            connect=self._connect_once,
            cleanup=self._cleanup_once,
            retry_delay=float(self._config.get("retry_delay", 2.0)),
            max_retry_delay=float(self._config.get("max_retry_delay", 60.0)),
            logger=self._logger,
        )
        # Voice edge queue + worker. The low-level keyboard hook thread
        # (Thread-3 (_run) in LegacyKeySuppressor) must NEVER acquire
        # ``self._voice_trigger_lock`` and must NEVER block on PortAudio
        # startup; doing so lets Windows time the WH_KEYBOARD_LL callback
        # out and dispatch the original physical F5 to the foreground
        # application (the Notepad F5 -> Edit -> Time/Date leak observed
        # on 2026-08-22 at 22:49:57.898 in %LOCALAPPDATA%\RemoteMic\
        # RC003\logs\app.log). Fix A of ADR-0003 makes the hook path
        # enqueue here and return immediately; the worker thread below
        # is the only place that calls into ``_on_button_event`` for the
        # LL hook path, so application locks never block the hook thread.
        # Fix B of ADR-0003 (50 ms release debounce) lives in
        # ``voice_edge_debouncer.VoiceEdgeDebouncer`` and is consumed by
        # ``_dispatch_voice_mic_edge``.
        self._voice_edge_queue: "queue.Queue[Optional[tuple]]" = queue.Queue(maxsize=64)
        self._voice_edge_worker_stop_event = threading.Event()
        self._voice_edge_worker_thread: Optional[threading.Thread] = None
        # ``_normalize_voice_release_debounce`` (see ``config.py``) clamps
        # the stored value into the [0.050, 0.500] s band documented in
        # ADR-0003 "Window refinement 2026-08-23", so the key is always
        # present and in-range by the time we read it here.  The hard
        # default in ``self._config.get`` mirrors the debouncer default so
        # a stripped config.json still produces the production 200 ms
        # window.
        self._voice_edge_debouncer = voice_edge_debouncer.VoiceEdgeDebouncer(
            release_window_seconds=float(
                self._config.get("voice_release_debounce_seconds", 0.200)
            ),
        )
        # Real sessions contain short AUDIO_STOP -> AUDIO_START gaps while a
        # physical hold continues. The longest observed gap is 2.342 s;
        # 2.5 s absorbs it. A stable stop is stronger than the Windows F5
        # key-up, which has been observed arriving roughly 25 seconds late.
        self._voice_audio_stop_debouncer = voice_edge_debouncer.VoiceEdgeDebouncer(
            release_window_seconds=2.500,
        )
        # Fix C of ADR-0003: how long the worker is willing to wait for
        # the PortAudio output buffer to drain after physical release
        # before emitting the closing host edge.  500 ms matches the
        # upstream macOS default and is bounded so a single physical
        # press never extends the host session beyond ~500 ms after
        # physical release under any circumstance.
        self._playback_drain_timeout_seconds: float = 0.500

    # -- lifecycle: driven by ConnectionSupervisor -------------------------

    async def run_forever(self) -> None:
        await self._supervisor.run_forever()

    async def stop(self) -> None:
        await self._supervisor.stop()

    async def _connect_once(self) -> None:
        self._logger.info("startup: resolving RC003 identity")
        candidates = await ble_transport_winrt.discover_candidates()
        # Fail-closed by construction: raises NoCandidateFoundError or
        # AmbiguousCandidateError instead of guessing.
        candidate = identity.select_single_candidate(candidates)
        self._logger.info("startup: exactly one RC003 candidate resolved")

        self._ble_session = ble_transport_winrt.RC003BleSession(
            on_pcm_frame=self._on_pcm_frame,
            on_control_event=self._on_control_event,
            on_error=self._on_session_error,
            on_disconnected=self._on_disconnected,
            gain_db=float(self._config["gain_db"]),
        )
        await self._ble_session.connect(candidate)

        self._start_hid_listener()
        self._start_hid_report_tap()
        # Fix A of ADR-0003: start the dedicated worker thread that
        # drains the LL hook voice-edge queue.  Must start before the
        # LL hook can fire, which happens inside ``_start_hid_listener``
        # above (the suppressor is started at the end of that method).
        self._start_voice_edge_worker()


    def _start_hid_listener(self) -> None:
        """Best-effort: buttons fail closed independently of BLE/voice.

        Multiple matching HID device paths -> fail closed for buttons only
        (log and leave the listener unstarted); this must not tear down the
        BLE/voice path, which does not depend on HID at all.

        XRBM-019 review round 1 P1 #3: a failed ``start()`` call does not
        necessarily mean the listener never came alive - it may have left a
        thread/window behind that its own bounded failed-start cleanup could
        not stop (see raw_input_windows.py's ``_abandon_failed_start()``,
        which keeps ``is_running`` honest for exactly this reason). Clearing
        ``self._hid_listener`` to ``None`` unconditionally here would lose
        that owner reference and let a later ``_connect_once()`` generation
        start a second listener over the still-live one. Only clear it once
        the listener itself confirms it is not running; otherwise retain and
        re-raise so this propagates up through ``_connect_once()`` into
        ``ConnectionSupervisor.run_forever()``'s except handler, which still
        falls through to ``_cleanup_once()`` - giving cleanup a chance to
        retry stopping it, exactly like any other retained-owner failure.
        """

        try:
            paths = raw_input_windows.enumerate_matching_device_paths()
            device_path = hid_identity.select_single_device_path(paths)
        except raw_input_windows.RawInputUnavailableError as exc:
            self._logger.info("startup: Raw Input unavailable; buttons disabled: %s", exc)
            return
        except hid_identity.NoDevicePathFoundError:
            self._logger.info("startup: no RC003 HID device path found; buttons unavailable")
            return
        except hid_identity.AmbiguousDevicePathError as exc:
            self._logger.info(
                "startup: buttons failing closed, ambiguous HID device paths: %s", exc
            )
            return

        self._hid_listener = raw_input_windows.RawInputButtonListener(
            self._on_raw_input_button_event
        )
        set_physical_bindings = getattr(
            self._hid_listener, "set_physical_bindings", None
        )
        if callable(set_physical_bindings):
            set_physical_bindings(self._bindings.get("physical_bindings", {}))
        set_raw_event_callback = getattr(self._hid_listener, "set_raw_event_callback", None)
        if set_raw_event_callback is not None:
            set_raw_event_callback(self._on_raw_input_event)
        try:
            self._hid_listener.start(device_path)
        except raw_input_windows.RawInputUnavailableError as exc:
            if self._hid_listener.is_running:
                self._logger.exception(
                    "startup: Raw Input listener failed to start but is still running; "
                    "owner retained for cleanup to retry"
                )
                raise
            self._logger.info("startup: Raw Input listener failed to start: %s", exc)
            self._hid_listener = None
            return

        # RC003's voice key is reported by Windows' keyboard class as F5 as
        # well as through ATVV. Raw Input is preferred when available; this
        # narrowly intercepts the same legacy F5 leak and emits one marked
        # right-Alt edge before audio starts. Doubao's own callback then
        # physicalizes that marked edge.
        # Voice-shortcut VK codes (modifiers + key) the bridge injects via
        # ``_real_voice_event``.  The low-level hook drops the
        # ``LLKHF_INJECTED`` flag off these VK codes so the foreground
        # application (Typeless, 千问, ...) reacts to them as a physical
        # key chord and not as an injected event.  Without this, real
        # device acceptance ran through the press/release path but no
        # target toggled on the edges - the events were delivered but
        # every toggle target silently dropped them.  See
        # ``docs/decisions/ADR-0005-voice-hotkey-physicalize.md``.
        voice_hotkey_tokens = tuple(self._voice_hotkey.modifiers) + (
            self._voice_hotkey.key,
        )
        try:
            voice_physicalize_vk_codes = frozenset(
                win32_keys.resolve_vk_codes(voice_hotkey_tokens)
            )
        except Exception:
            # Off-Windows unit tests and unusual hotkey spellings; fall
            # back to an empty set rather than crashing the bridge.  The
            # legacy ralt path below still physicalises one VK at a
            # time on its own.
            voice_physicalize_vk_codes = frozenset()

        correlated_vk_codes = frozenset(
            vk
            for vk, button in raw_input_windows.KEYBOARD_VK_TO_BUTTON.items()
            if button not in self._raw_input_native_passthrough_buttons
        )
        self._legacy_key_suppressor = legacy_key_suppressor_windows.LegacyKeySuppressor(
            {0x74},
            on_key_event=self._on_legacy_key_event,
            on_key_transform=self._transform_legacy_voice_key,
            on_key_emit=self._emit_legacy_voice_key,
            rc003_vk_codes=correlated_vk_codes,
            voice_physicalize_vk_codes=voice_physicalize_vk_codes,
        )
        try:
            self._legacy_key_suppressor.start()
            self._logger.info("startup: RC003 voice legacy-key guard enabled")
            if self._legacy_voice_transform_enabled():
                self._logger.info(
                    "startup: RC003 F5 voice edge transforms to one physical right-Alt edge"
                )
                if doubao_rpc.start_physicalizer():
                    self._logger.info(
                        "startup: Doubao low-level voice event physicalizer enabled"
                    )
                else:
                    self._logger.warning(
                        "startup: Doubao voice physicalizer unavailable: %s",
                        doubao_rpc.physicalizer_error() or doubao_rpc.physicalizer_status(),
                    )
            if self._qianwen_target_physicalizer_enabled():
                if qianwen_physicalizer.start_physicalizer():
                    self._logger.info(
                        "startup: verified Qianwen target-local voice physicalizer enabled"
                    )
                else:
                    self._logger.warning(
                        "startup: Qianwen target-local voice physicalizer unavailable: %s",
                        qianwen_physicalizer.physicalizer_error()
                        or qianwen_physicalizer.physicalizer_status(),
                    )
        except legacy_key_suppressor_windows.LegacyKeySuppressorUnavailableError as exc:
            self._logger.warning("startup: RC003 voice legacy-key guard unavailable: %s", exc)
            self._legacy_key_suppressor = None

    def _start_hid_report_tap(self) -> None:
        """Start the upstream-derived tap for usages Windows drops.

        This is independent of the normal Raw Input listener.  A missing or
        unverified Gadget is a button-only degradation and must not prevent
        BLE voice from starting.
        """

        tap = frida_compat.RC003HidReportTap(self._on_direct_hid_report)
        try:
            if tap.start():
                self._hid_report_tap = tap
                self._logger.info("startup: RC003 HID report tap enabled")
            else:
                self._logger.info(
                    "startup: RC003 HID report tap unavailable: %s", tap.status
                )
        except Exception:
            self._logger.exception("startup: RC003 HID report tap failed to start")
            try:
                tap.stop()
            except Exception:
                self._logger.exception("startup: RC003 HID report tap cleanup failed")

    def _on_direct_hid_report(self, report_id: int, payload: bytes) -> None:
        """Translate every RC003 keyboard HID usage into button edges.

        The tap observes the full keyboard report on its own socket thread,
        which the low-level keyboard hook does not block.  Arming the
        duplicate suppressor from this side channel makes the arming edge
        arrive inside the hook's wait window (the WM_INPUT arm arrives too
        late, ~63-72ms after the hook on this device).  As on macOS, a direct
        microphone usage owns the voice key-down/key-up lifecycle.  The
        translated Windows F5 and ATVV controls then remain suppression and
        audio-lifecycle paths instead of producing extra host shortcuts.
        """

        if report_id != 1 or len(payload) != 6:
            return
        active = {
            int.from_bytes(payload[index : index + 2], "little")
            for index in range(0, len(payload), 2)
        } & set(frida_compat.TAP_USAGE_TO_BUTTON)
        with self._direct_hid_lock:
            previous = self._direct_hid_usages
            if active == previous:
                return
            pressed = active - previous
            released = previous - active
            self._direct_hid_usages = set(active)
        if active and not self._direct_hid_tap_active:
            self._direct_hid_tap_active = True
            suppressor = self._legacy_key_suppressor
            if suppressor is not None:
                # The direct HID socket now arms exact RC003 edges before
                # WH_KEYBOARD_LL sees them.  Disable the 60 ms Raw Input race
                # fallback so ordinary arrows/Enter/Home on the PC keyboard
                # are never stalled merely because they share an RC003 VK.
                suppressor.set_rc003_vk_codes(
                    frozenset(raw_input_windows.KEYBOARD_VK_TO_BUTTON)
                )
                suppressor.set_consume_wait_seconds(0.0)
                self._logger.info(
                    "RC003 direct HID active: ordinary overlapping keyboard keys use zero-wait pass-through"
                )
        for usage in sorted(pressed):
            button = frida_compat.TAP_USAGE_TO_BUTTON[usage]
            self._logger.info(
                "RC003 direct HID usage down: 0x%04x -> %s",
                usage,
                button,
            )
            self._arm_from_direct_usage(usage, True)
            self._on_button_event(button, True)
        for usage in sorted(released):
            button = frida_compat.TAP_USAGE_TO_BUTTON[usage]
            self._logger.info(
                "RC003 direct HID usage up: 0x%04x -> %s",
                usage,
                button,
            )
            self._arm_from_direct_usage(usage, False)
            self._on_button_event(button, False)

    def _arm_from_direct_usage(self, usage: int, is_pressed: bool) -> None:
        """Arm the exact physical edge seen by the tap's socket thread.

        Uses the same vk/scan/extended values the low-level hook observes for
        that physical key, so ``consume_armed_key_event`` matches regardless
        of whether the arm arrived from Raw Input or from the tap.
        """

        suppressor = self._legacy_key_suppressor
        if suppressor is None:
            return
        key = frida_compat.TAP_USAGE_TO_KEY.get(usage)
        if key is None:
            return
        vk_code, make_code, extended = key
        if vk_code == 0x74:
            return
        suppressor.arm_key_event(vk_code, make_code, extended, is_pressed)


    async def _cleanup_once(self) -> None:
        """Every step is independently attempted: one failing must never
        skip the rest (XRBM-014 review RETRY P1 #4). XRBM-019 P1 #2/#5: the
        HID listener and BLE session owners are only cleared to ``None``
        when their own stop()/close() call reports success - if either
        reports its resource is still alive (raises), the owner reference
        is deliberately retained so no later code can mistake a still-
        running listener/session for a clean slate, and this method raises
        ``CleanupIncompleteError`` once every step has still been
        attempted (see the module docstring's "Cleanup ownership" note for
        how that ends the connect/retry loop).
        """

        failures: List[str] = []

        if self._hid_report_tap is not None:
            try:
                self._hid_report_tap.stop()
                self._hid_report_tap = None
            except Exception:
                self._logger.exception("cleanup: stopping the RC003 HID report tap failed")
                failures.append("RC003 HID report tap did not stop; owner retained")
        with self._direct_hid_lock:
            self._direct_hid_usages.clear()
        self._direct_hid_tap_active = False

        # Cancel gesture timers before stopping Raw Input. The listener's
        # forced releases then clear the dispatcher state without a late
        # double/long callback racing the next connection generation.
        self._button_gestures.reset()

        # Fix A of ADR-0003: stop the voice-edge worker BEFORE the LL hook
        # is stopped, so any final enqueued event is drained.  Cancels
        # any pending debounced release too.
        self._stop_voice_edge_worker()

        try:
            with self._voice_trigger_lock:
                self._voice_audio_start_fallback_pending = False
                self._voice_audio_started_waiting_for_legacy_f5 = False
                self._voice_raw_input_trigger_pending = False
                self._voice_physical_button_down = False
                self._voice_waiting_for_physical_release_after_audio_stop = False
                reset_action = self._voice.reset()
                if reset_action is not None and not self._apply_voice_action(reset_action):
                    # _apply_voice_action() already logged the specific failure.
                    # reset() already cleared the controller's own pending
                    # state before we knew delivery would fail - restore it so
                    # a HOLD-mode key isn't recorded as released while it may
                    # still be physically down, and a TOGGLE-mode closing tap
                    # isn't forgotten (XRBM-019 review round 1 P1 #4).
                    self._voice.restore_pending(reset_action)
                    failures.append("voice hotkey release did not fully deliver; state retained")
                self._voice_legacy_transform_key_down = False
                self._voice_legacy_transform_session = False
                self._voice_legacy_transform_emitted = False
                self._legacy_f5_is_down = False
        except Exception:
            self._logger.exception("cleanup: releasing the voice hotkey failed")

        if self._hid_listener is not None:
            try:
                self._hid_listener.stop()
                self._hid_listener = None
            except Exception:
                self._logger.exception("cleanup: stopping the Raw Input listener failed")
                failures.append("Raw Input listener did not stop; owner retained")
                # self._hid_listener is intentionally NOT cleared here: it
                # may still be a live thread/window.

        if self._legacy_key_suppressor is not None:
            try:
                self._legacy_key_suppressor.stop()
                self._legacy_key_suppressor = None
            except Exception:
                self._logger.exception("cleanup: stopping RC003 voice legacy-key guard failed")
                failures.append("RC003 voice legacy-key guard did not stop; owner retained")

        try:
            doubao_rpc.stop_physicalizer()
        except Exception:
            self._logger.exception("cleanup: stopping Doubao voice physicalizer failed")
            failures.append("Doubao voice physicalizer did not stop")

        try:
            qianwen_physicalizer.stop_physicalizer()
        except Exception:
            self._logger.exception("cleanup: stopping Qianwen voice physicalizer failed")
            failures.append("Qianwen voice physicalizer did not stop")

        if self._ble_session is not None:
            try:
                await self._ble_session.close()
                self._ble_session = None
            except Exception:
                self._logger.exception("cleanup: closing the BLE session failed")
                failures.append("BLE session did not fully close; owner retained")
                # self._ble_session is intentionally NOT cleared here either.

        if self._playback is not None:
            try:
                self._playback.close()
                self._playback = None
            except Exception:
                self._logger.exception("cleanup: closing audio playback failed")
                failures.append("audio playback did not fully close; owner retained")
                # self._playback is intentionally NOT cleared here either -
                # it owns a PortAudio stream; discarding the reference would
                # hide an incompletely closed resource and let a reconnect
                # open a second sink over it (XRBM-019 review round 1 P1
                # #5).

        self._logger.info("cleanup: attempted release of hotkey state and BLE/HID/audio")

        if failures:
            raise CleanupIncompleteError(
                "cleanup could not release all owned resources: " + "; ".join(failures)
            )

    # -- disconnect / error callbacks: hand off to the supervisor ----------

    def _on_disconnected(self) -> None:
        self._logger.info("BLE reported disconnected; requesting reconnect")
        self._supervisor.request_reconnect()

    def _on_session_error(self, exc: BaseException) -> None:
        self._logger.info("ATVV protocol error, requesting reconnect: %s", exc)
        self._supervisor.request_reconnect()

    def _legacy_voice_transform_enabled(self) -> bool:
        """Whether the selected HOLD preset uses the physical right-Alt path."""

        return self._voice.trigger_mode == key_mapping.VoiceTriggerMode.HOLD and (
            self._voice_hotkey.serialize() in {"ralt", "lctrl+win", "lctrl+lwin"}
        )

    def _qianwen_target_physicalizer_enabled(self) -> bool:
        """Whether the version-locked Qianwen callback adapter is required."""

        return self._voice.trigger_mode == key_mapping.VoiceTriggerMode.TOGGLE and (
            self._voice_hotkey.serialize() == "ralt"
        )

    def _emit_legacy_voice_key(
        self,
        target: legacy_key_suppressor_windows.PhysicalKeyTarget,
        is_pressed: bool,
    ) -> bool:
        """Emit exactly one right-Alt edge for a physical F5 edge.

        The original F5 is swallowed by ``LegacyKeySuppressor``. This callback
        emits the single marked right-Alt edge for Doubao's verified callback
        physicalizer. No second host shortcut is sent for this session.
        """

        expected = legacy_key_suppressor_windows.PhysicalKeyTarget(
            vk_code=0xA5,
            scan_code=0x38,
            extended=True,
            system_key=True,
        )
        if target != expected:
            self._voice_legacy_transform_emitted = False
            return False
        try:
            if is_pressed:
                win32_input.send_voice_key_combo_down(("ralt",))
            else:
                win32_input.send_voice_key_combo_up(("ralt",))
            self._voice_legacy_transform_emitted = True
            self._logger.info(
                "voice physical F5 replaced with one right-Alt edge via %s: %s",
                win32_input.voice_backend_name(),
                "down" if is_pressed else "up",
            )
            return True
        except (win32_input.Win32InputUnavailableError, OSError):
            self._voice_legacy_transform_emitted = False
            if is_pressed:
                self._voice_legacy_transform_key_down = False
            self._logger.exception(
                "voice physical right-Alt replacement failed; using host fallback"
            )
            return False

    def _transform_legacy_voice_key(
        self, vk_code: int, is_pressed: bool
    ) -> Optional[legacy_key_suppressor_windows.PhysicalKeyTarget]:
        """Replace a physical RC003 F5 edge with one physical right-Alt edge.

        The callback runs inside the low-level hook.  It deliberately only
        arms a new down edge while no voice trigger is already in flight; a
        matching up edge is still transformed after the app has marked the
        session active.  This prevents a Raw Input duplicate from opening a
        second host shortcut while preserving the hold/release pair.
        """

        if vk_code != 0x74 or not self._legacy_voice_transform_enabled():
            return None
        if is_pressed:
            if (
                self._voice.active
                or self._voice_raw_input_trigger_pending
                or self._voice_legacy_transform_key_down
                or self._legacy_f5_is_down
            ):
                return None
            self._voice_legacy_transform_key_down = True
        elif not self._voice_legacy_transform_key_down:
            return None
        else:
            self._voice_legacy_transform_key_down = False
        return legacy_key_suppressor_windows.PhysicalKeyTarget(
            vk_code=0xA5,
            scan_code=0x38,
            extended=True,
            system_key=True,
        )

    def _on_legacy_key_event(self, vk_code: int, is_pressed: bool) -> None:
        """Use the already-suppressed physical F5 leak as a voice edge.

        Some RC003 firmware/Windows input-class combinations do not produce
        a device-scoped Raw Input keyboard record for the microphone button,
        even though the same physical press is visible to the low-level hook
        as F5. The hook is configured only for that legacy F5 and swallows it
        before it reaches the foreground app; route the edge through the same
        deduplicated voice path as Raw Input.

        Fix A of ``docs/decisions/ADR-0003-voice-edge-debounce-and-hook-decoupling.md``:
        this method MUST stay non-blocking and lock-free.  It runs on the
        ``LegacyKeySuppressor`` ``Thread-3 (_run)`` callback thread, which
        Windows times out at roughly 200-300 ms; acquiring
        ``_voice_trigger_lock`` here (which ``_on_button_event`` does) can
        block for ~480 ms while ``_open_playback_for_new_session`` opens a
        fresh PortAudio sink on the very first physical press, and Windows
        then dispatches the F5 to the foreground application anyway,
        producing the Notepad F5 → Edit → Time/Date leak.

        Instead, the edge is enqueued onto ``_voice_edge_queue`` and the
        dedicated ``voice-edge-worker`` thread calls
        ``_dispatch_voice_mic_edge`` (which acquires the application lock
        and runs ``_on_button_event``).  This method only updates the
        lock-free atomic flags used by other hook/UI code paths and
        enqueues a single tuple; it never blocks.
        """

        if vk_code == 0x74:
            # The direct HID tap is the closest Windows equivalent to the
            # macOS IOHID edge monitor.  Once it has supplied the microphone
            # edge, this legacy F5 is only the translated duplicate.  The
            # low-level hook still swallows it, but it must not dispatch a
            # second voice action.
            if self._direct_hid_tap_active:
                self._logger.info(
                    "voice legacy F5 swallowed: direct HID owns microphone edge"
                )
                return
            if is_pressed:
                # WH_KEYBOARD_LL also reports auto-repeat key-down messages
                # while the remote button is held.  They are not new remote
                # gestures; collapse them until the matching physical up.
                if self._legacy_f5_is_down:
                    return
                self._legacy_f5_is_down = True
                self._logger.info(
                    "voice legacy F5 trigger received from low-level keyboard hook"
                )
                if (
                    self._voice_legacy_transform_emitted
                    or self._voice_legacy_transform_key_down
                ):
                    self._voice_legacy_transform_session = True
            elif not self._legacy_f5_is_down:
                return
            else:
                self._legacy_f5_is_down = False
            host_action_handled = self._voice_legacy_transform_session
            # Enqueue the dispatch for the worker thread.  The hook thread
            # itself must NEVER acquire ``_voice_trigger_lock``; if the
            # queue is full (which would mean the worker has fallen badly
            # behind the hook), drop the event and log - releasing the
            # lock in flight is worse than missing a single mic release.
            try:
                self._voice_edge_queue.put_nowait((is_pressed, host_action_handled))
            except queue.Full:
                self._logger.warning(
                    "voice edge queue full; dropping %s edge from LL hook",
                    "press" if is_pressed else "release",
                )
            self._voice_legacy_transform_emitted = False

    def _dispatch_voice_mic_edge(
        self, is_pressed: bool, host_action_handled: bool
    ) -> None:
        """Apply Fix B (50 ms release debounce) and Fix C (drain-before-stop),
        then route the edge through ``_on_button_event``.

        Press edges are dispatched immediately.  Release edges are scheduled
        via ``_voice_edge_debouncer``; if a press arrives before the 50 ms
        window expires, the release is cancelled and the host session
        continues uninterrupted, absorbing the RC003 firmware release/
        press bounce observed in live ``app.log`` (typically < 10 ms, see
        ``CURRENT_STATUS.md`` "Observed one real post-change RC003 hold"
        and the 23:01:23 / 23:01:26 / 23:01:37 entries).

        When the debouncer runs (the release was not cancelled), this
        method waits up to ``_playback_drain_timeout_seconds`` for the
        PortAudio output buffer to empty before emitting the closing
        host edge, so target applications like Typeless whose voice UI
        stays open while the host key is held see the X / ✓
        confirmation pill persist until every buffered voice sample has
        reached CABLE Output.  This is the Windows equivalent of the
        macOS upstream's ``VoiceFnTapSessionController.endSessionAfterDraining``.

        Runs on the ``voice-edge-worker`` thread only.  Tests that need
        to exercise the dispatch synchronously should call this method
        directly, bypassing the LL hook callback and the queue.
        """

        if is_pressed:
            # Cancel a pending release: this press continues the same
            # physical hold; do not close the host session.
            self._voice_edge_debouncer.on_press()
            self._on_button_event(
                "mic", True, host_action_handled=host_action_handled
            )
            return

        # Release: schedule via debouncer; on fire, drain then then emit.
        def _release_after_drain() -> None:
            try:
                if self._playback is not None:
                    self._playback.drain(self._playback_drain_timeout_seconds)
            except Exception:
                # Drain is a best-effort: any failure must not skip the
                # host release, otherwise the target application would
                # stay stuck in its voice UI forever.
                self._logger.exception(
                    "voice release drain failed; emitting host release anyway"
                )
            self._on_button_event(
                "mic", False, host_action_handled=host_action_handled
            )

        self._voice_edge_debouncer.on_release(_release_after_drain)

    def _start_voice_edge_worker(self) -> None:
        """Start the dedicated worker that drains the LL hook queue.

        Idempotent; safe to call repeatedly if a reconnect re-arms the
        bridge.  The worker exits when ``_voice_edge_worker_stop_event``
        is set or when a ``None`` sentinel is observed on the queue.
        """

        if (
            self._voice_edge_worker_thread is not None
            and self._voice_edge_worker_thread.is_alive()
        ):
            return
        self._voice_edge_worker_stop_event.clear()
        self._voice_edge_worker_thread = threading.Thread(
            target=self._voice_edge_worker_loop,
            name="voice-edge-worker",
            daemon=True,
        )
        self._voice_edge_worker_thread.start()

    def _stop_voice_edge_worker(self) -> None:
        """Stop the worker and cancel any pending debounced release.

        The worker thread is allowed a bounded time to exit; if it has
        not stopped by then, the daemon thread will be cleaned up by
        interpreter shutdown rather than blocking cleanup.
        """

        self._voice_edge_worker_stop_event.set()
        try:
            self._voice_edge_queue.put_nowait(None)
        except queue.Full:
            pass
        self._voice_edge_debouncer.shutdown()
        self._voice_audio_stop_debouncer.shutdown()
        thread = self._voice_edge_worker_thread
        self._voice_edge_worker_thread = None
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)

    def _voice_edge_worker_loop(self) -> None:
        """Single consumer of ``_voice_edge_queue``.

        Never raises; on any unexpected exception the loop logs and
        exits so the bridge can fall back to the (already-known) state
        machine for ordinary buttons without an LL hook dispatcher.
        """

        while not self._voice_edge_worker_stop_event.is_set():
            try:
                item = self._voice_edge_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if item is None:
                break
            is_pressed, host_action_handled = item
            try:
                self._dispatch_voice_mic_edge(is_pressed, host_action_handled)
            except Exception:
                self._logger.exception(
                    "voice edge worker dispatch failed; dropping edge"
                )

    def _drain_voice_edge_queue_for_test(self) -> int:
        """Synchronously drain every queued edge and dispatch it inline.

        Used by ``tests/test_app_wiring.py`` (and any future test) that
        needs to observe the same dispatch path the worker would take,
        without actually starting the worker thread.  Drains every
        queued item until the queue is empty, fires any pending
        debounced release synchronously so the test sees the closing
        host edge immediately, and returns the number of edges dispatched.

        This method MUST NOT be called from production code paths.
        """

        drained = 0
        while True:
            try:
                item = self._voice_edge_queue.get_nowait()
            except queue.Empty:
                break
            if item is None:
                continue
            is_pressed, host_action_handled = item
            self._dispatch_voice_mic_edge(is_pressed, host_action_handled)
            drained += 1
        # Force any pending debounced release to fire so the test sees
        # the host release immediately after the press.  We invoke the
        # debouncer's release callback path directly, bypassing the
        # timer wait, so tests don't have to sleep.
        if self._voice_edge_debouncer.fire_pending_now_for_test():
            drained += 1
        return drained

    def _on_raw_input_button_event(self, button_id: str, is_pressed: bool) -> None:
        """Dispatch device-scoped buttons without duplicating the voice edge.

        On this RC003, Windows exposes the microphone press both as keyboard
        Raw Input and as the same translated F5 seen by the low-level hook.
        The hook is the earlier edge and is also the boundary that can swallow
        F5 before Notepad (where F5 inserts the current date).  Therefore Raw
        Input owns ordinary buttons only; voice is owned by direct HID when
        available, otherwise by the swallowed F5 fallback.
        """

        if button_id == "mic":
            self._logger.info(
                "voice Raw Input mic edge ignored: direct HID/F5 path owns voice"
            )
            return
        if (
            not self._direct_hid_tap_active
            and button_id in self._raw_input_native_passthrough_buttons
        ):
            # The normal Windows keyboard event already represents exactly
            # this default action.  Let it reach the foreground once instead
            # of swallowing and reinjecting it; this also means the user's
            # own Arrow/Enter keys never enter the correlation wait.
            return
        self._on_button_event(button_id, is_pressed)

    def _on_raw_input_event(self, event: raw_input_windows.RawInputEvent) -> None:
        """Arm the exact original keyboard edge for duplicate suppression.

        The selected RC003 Raw Input listener is device-scoped; the global
        low-level keyboard hook is not.  Passing the observed VKey/MakeCode
        pair across this seam lets the hook swallow only the remote's
        original arrow/Enter/Home/consumer event before the injected mapping
        action is delivered.
        """

        suppressor = self._legacy_key_suppressor
        if (
            suppressor is None
            or event.source != "keyboard"
            or event.button_id == "mic"
            or event.button_id is None
            or event.vkey is None
            or event.make_code is None
        ):
            return
        # While the Frida tap side channel is reporting full keyboard
        # snapshots, it already arms and dispatches every ordinary button on
        # its own socket thread.  Stand the Raw Input path down so one
        # physical edge is not armed and dispatched twice.
        if self._direct_hid_tap_active:
            return
        if event.button_id in self._raw_input_native_passthrough_buttons:
            return
        # Only arm a physical edge when this RC003 button has at least one
        # configured ordinary gesture.  Unknown usages and deliberately
        # unbound controls must remain ordinary Windows input instead of
        # being swallowed with no replacement action.
        if not any(
            self._is_button_action_configured(event.button_id, trigger)
            for trigger in button_gesture.ButtonTrigger
        ):
            return
        # RAWKEYBOARD uses RI_KEY_E0 (0x02) for the extended prefix; the
        # low-level hook uses LLKHF_EXTENDED (0x01).
        suppressor.arm_key_event(
            event.vkey,
            event.make_code,
            bool((event.flags or 0) & 0x02),
            event.is_pressed,
        )

    # -- HID button events --------------------------------------------------

    def _bindings_file_mtime_ns(self) -> int:
        try:
            return self._bindings_path.stat().st_mtime_ns
        except OSError:
            return -1

    def _compute_raw_input_native_passthrough_buttons(self) -> set[str]:
        native_actions = {
            "up": key_mapping.ActionKind.ARROW_UP,
            "down": key_mapping.ActionKind.ARROW_DOWN,
            "left": key_mapping.ActionKind.ARROW_LEFT,
            "right": key_mapping.ActionKind.ARROW_RIGHT,
            "ok": key_mapping.ActionKind.RETURN,
        }
        result = set()
        for button_id, action_kind in native_actions.items():
            single = key_mapping.button_action_for(
                self._bindings,
                button_id,
                button_gesture.ButtonTrigger.SINGLE_CLICK,
            )
            if single.kind == action_kind and not key_mapping.has_secondary_action(
                self._bindings, button_id
            ):
                result.add(button_id)
        return result

    def _reload_bindings_if_changed(self) -> None:
        """Apply settings edits without requiring a bridge restart."""

        current_mtime_ns = self._bindings_file_mtime_ns()
        if current_mtime_ns == self._bindings_mtime_ns:
            return
        try:
            refreshed = config.load_key_bindings(self._bindings_path)
        except Exception as exc:  # noqa: BLE001 - keep the last valid mapping
            self._logger.warning("settings reload skipped: %s", exc)
            self._bindings_mtime_ns = current_mtime_ns
            return
        self._bindings = refreshed
        self._bindings_mtime_ns = current_mtime_ns
        self._raw_input_native_passthrough_buttons = (
            self._compute_raw_input_native_passthrough_buttons()
        )
        suppressor = self._legacy_key_suppressor
        if suppressor is not None and not self._direct_hid_tap_active:
            suppressor.set_rc003_vk_codes(
                frozenset(
                    vk
                    for vk, button in raw_input_windows.KEYBOARD_VK_TO_BUTTON.items()
                    if button not in self._raw_input_native_passthrough_buttons
                )
            )
        self._logger.info("settings mappings reloaded from disk")

    def _on_button_event(
        self, button_id: str, is_pressed: bool, *, host_action_handled: bool = False
    ) -> None:
        self._reload_bindings_if_changed()
        if button_id == "mic":
            with self._voice_trigger_lock:
                if not is_pressed:
                    self._voice_audio_stop_debouncer.on_press()
                    self._voice_physical_button_down = False
                    self._voice_waiting_for_physical_release_after_audio_stop = False
                    self._voice_raw_input_trigger_pending = False
                    if self._voice.active:
                        self._logger.info(
                            "voice physical mic released; closing host session"
                        )
                        self._close_voice_host_session()
                    return
                self._voice_physical_button_down = True
                if self._voice_waiting_for_physical_release_after_audio_stop:
                    self._logger.info(
                        "voice physical trigger ignored: waiting for stable release "
                        "after audio-stop close"
                    )
                    return
                if self._voice.active:
                    self._logger.info(
                        "voice physical trigger ignored: voice session already active"
                    )
                    return
                if self._voice_raw_input_trigger_pending:
                    self._logger.info(
                        "voice physical trigger ignored: trigger already in progress"
                    )
                    return
                # The physical key is the earliest reliable signal. Send the
                # host shortcut before the device's audio-start event so
                # voice input is already armed when PCM arrives. The matching
                # ATVV event is consumed by this pending latch.
                self._voice_raw_input_trigger_pending = True
                self._logger.info(
                    "voice physical mic trigger received before audio start"
                )
                self._handle_mic_button_pressed(
                    host_action_handled=host_action_handled,
                )
                if not self._voice.active:
                    self._voice_raw_input_trigger_pending = False
            return
        if is_pressed:
            if button_id not in self._usage_pressed_buttons:
                self._usage_pressed_buttons.add(button_id)
                self._record_button_usage()
            self._button_gestures.press(button_id)
        else:
            self._usage_pressed_buttons.discard(button_id)
            self._button_gestures.release(button_id)

    def _is_button_action_configured(
        self, button_id: str, trigger: button_gesture.ButtonTrigger
    ) -> bool:
        action = key_mapping.button_action_for(self._bindings, button_id, trigger)
        if action.kind == key_mapping.ActionKind.DISABLED:
            return False
        if action.kind == key_mapping.ActionKind.KEY_COMBO:
            try:
                win32_keys.resolve_vk_codes(action.keys)
            except win32_keys.UnknownKeyTokenError:
                return False
        if action_executor.is_application_action(action):
            # The action is intentional even if the app is currently not
            # installed.  Do not scan Start Menu/WindowsApps from the Raw
            # Input callback; dispatch will report the missing executable and
            # the configured mapping still correctly owns this physical key.
            return True
        return action.kind != key_mapping.ActionKind.VOICE

    def _is_button_repeatable(self, button_id: str) -> bool:
        if button_id not in {
            "up",
            "down",
            "left",
            "right",
            "back",
            "volume_up",
            "volume_down",
        }:
            return False
        action = key_mapping.button_action_for(
            self._bindings,
            button_id,
            key_mapping.ButtonTrigger.SINGLE_CLICK,
        )
        return key_mapping.action_allows_repeat(action)

    def _on_button_trigger(
        self, button_id: str, trigger: button_gesture.ButtonTrigger
    ) -> None:
        self._reload_bindings_if_changed()
        action = key_mapping.button_action_for(
            self._bindings,
            button_id,
            key_mapping.ButtonTrigger(trigger.value),
        )
        try:
            if action.kind == key_mapping.ActionKind.KEY_COMBO:
                win32_keys.resolve_vk_codes(action.keys)
        except (KeyError, TypeError, ValueError, win32_keys.UnknownKeyTokenError):
            # A hand-edited or partially corrupted bindings file must disable
            # only the affected button, never escape the Raw Input callback
            # and tear down ordinary-button processing for the whole device.
            self._logger.warning(
                "invalid button binding ignored: button=%s trigger=%s",
                button_id,
                trigger.value,
            )
            return
        self._apply_button_action(action)

    def _apply_button_action(self, action: key_mapping.ButtonAction) -> None:
        try:
            if action.kind == key_mapping.ActionKind.DISABLED:
                return
            if action.kind == key_mapping.ActionKind.KEY_COMBO:
                win32_input.send_key_combo_tap(action.keys)
            elif action.kind == key_mapping.ActionKind.ESCAPE:
                win32_input.send_escape()
            elif action.kind == key_mapping.ActionKind.RETURN:
                win32_input.send_return()
            elif action.kind == key_mapping.ActionKind.ARROW_UP:
                win32_input.send_arrow_up()
            elif action.kind == key_mapping.ActionKind.ARROW_DOWN:
                win32_input.send_arrow_down()
            elif action.kind == key_mapping.ActionKind.ARROW_LEFT:
                win32_input.send_arrow_left()
            elif action.kind == key_mapping.ActionKind.ARROW_RIGHT:
                win32_input.send_arrow_right()
            elif action.kind == key_mapping.ActionKind.DELETE_BACKWARD:
                win32_input.send_delete_backward()
            elif action.kind == key_mapping.ActionKind.SHOW_DESKTOP:
                win32_input.send_show_desktop()
            elif action.kind == key_mapping.ActionKind.CONTEXT_MENU:
                win32_input.send_context_menu()
            elif action.kind == key_mapping.ActionKind.APP_SWITCHER:
                win32_input.send_app_switcher()
            elif action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_UP:
                win32_input.send_volume_up()
            elif action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_DOWN:
                win32_input.send_volume_down()
            elif action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_MUTE:
                win32_input.send_volume_mute()
            elif action.kind == key_mapping.ActionKind.PLAY_PAUSE:
                win32_input.send_play_pause()
            elif action_executor.is_application_action(action):
                if not open_configured_application(action):
                    self._logger.warning(
                        "application action unavailable: action=%s", action.kind.value
                    )
            # ActionKind.VOICE is only driven by ATVV control opcodes
            # (_on_control_event), never dispatched from a HID button event.
        except win32_input.Win32InputUnavailableError:
            self._logger.info("button action skipped: SendInput unavailable here")
        except OSError:
            self._logger.exception("button action failed to fully deliver")

    def _record_button_usage(self) -> None:
        try:
            self._usage_statistics.record_button_press()
        except OSError:
            self._logger.warning("daily button usage statistics could not be saved")

    def _record_voice_usage(self, duration_seconds: float) -> None:
        try:
            self._usage_statistics.record_voice_session(duration_seconds)
        except OSError:
            self._logger.warning("daily voice usage statistics could not be saved")

    # -- ATVV control-channel events (mic button + audio start/stop) ------

    def _on_control_event(self, event: object) -> None:
        if isinstance(event, CapsReceived):
            self._logger.info(
                "voice capabilities received: version=0x%04x sample_rate=%s frame_size=%s",
                event.capabilities.version,
                event.capabilities.sample_rate,
                event.capabilities.frame_size,
            )
        elif isinstance(event, MicButtonPressed):
            with self._voice_trigger_lock:
                if self._voice_waiting_for_physical_release_after_audio_stop:
                    self._logger.info(
                        "voice mic control ignored: waiting for stable physical release"
                    )
                    return
                if self._voice_raw_input_trigger_pending:
                    self._voice_raw_input_trigger_pending = False
                    self._logger.info(
                        "voice mic trigger ignored: matched prior Raw Input trigger"
                    )
                elif self._voice_audio_start_fallback_pending:
                    self._voice_audio_start_fallback_pending = False
                    self._logger.info(
                        "voice mic trigger ignored: matched prior AUDIO_STARTED fallback"
                    )
                elif self._voice_audio_started_waiting_for_legacy_f5:
                    if self._voice.trigger_mode == key_mapping.VoiceTriggerMode.HOLD:
                        self._logger.info(
                            "voice ATVV mic control observed; waiting for physical mic edge"
                        )
                        self._open_playback_for_new_session()
                    else:
                        self._voice_audio_started_waiting_for_legacy_f5 = False
                        self._logger.info(
                            "voice mic trigger received without F5; using host fallback"
                        )
                        self._handle_mic_button_pressed(send_device_open=False)
                else:
                    if (
                        self._voice.trigger_mode == key_mapping.VoiceTriggerMode.HOLD
                    ):
                        self._logger.info(
                            "voice mic trigger received from ATVV; waiting for physical mic edge"
                        )
                        self._voice_audio_started_waiting_for_legacy_f5 = True
                        self._open_playback_for_new_session()
                    else:
                        self._logger.info("voice mic trigger received from ATVV control channel")
                        self._handle_mic_button_pressed()
        elif isinstance(event, AudioStarted):
            with self._voice_trigger_lock:
                self._voice_audio_stop_debouncer.on_press()
                if self._voice_waiting_for_physical_release_after_audio_stop:
                    self._logger.info(
                        "voice new audio start accepted before delayed physical key-up"
                    )
                    self._voice_waiting_for_physical_release_after_audio_stop = False
                    self._voice_physical_button_down = True
                self._logger.info("voice audio started")
                self._voice_pcm_stats.reset()
                self._voice_audio_start_fallback_pending = False
                if not self._voice.active:
                    if (
                        self._voice.trigger_mode == key_mapping.VoiceTriggerMode.HOLD
                    ):
                        self._logger.info(
                            "voice audio started; waiting for physical mic edge"
                        )
                        self._voice_audio_started_waiting_for_legacy_f5 = True
                        self._open_playback_for_new_session()
                    else:
                        self._logger.info("voice audio start used as microphone trigger")
                        # Real RC003 hardware can emit AUDIO_START before the
                        # host has acknowledged the session.  The probe that
                        # sustains streaming sends MIC_OPEN in response; do
                        # the same here, but only after playback and the host
                        # shortcut have succeeded (the fail-closed ordering
                        # enforced by _handle_mic_button_pressed).
                        self._handle_mic_button_pressed()
                        self._voice_audio_start_fallback_pending = self._voice.active
        elif isinstance(event, AudioStopped):
            with self._voice_trigger_lock:
                self._logger.info("voice audio stopped")
                stats = self._voice_pcm_stats.summary()
                self._logger.info(
                    "voice PCM summary: frames=%s samples=%s audio_ms=%.0f "
                    "peak=%s rms=%.1f mean_abs=%.1f mean=%.1f "
                    "clipped=%s(%.3f%%) zero_crossings=%s result=%s",
                    stats["frames"],
                    stats["samples"],
                    stats["audio_ms"],
                    stats["peak"],
                    stats["rms"],
                    stats["mean_abs"],
                    stats["mean"],
                    stats["clipped_samples"],
                    stats["clipped_pct"],
                    stats["zero_crossings"],
                    stats["result"],
                )
                self._record_voice_usage(float(stats["audio_ms"]) / 1000.0)
                self._voice_audio_start_fallback_pending = False
                self._voice_audio_started_waiting_for_legacy_f5 = False
                self._voice_raw_input_trigger_pending = False
                if self._voice_physical_button_down:
                    if (
                        self._voice.trigger_mode
                        == key_mapping.VoiceTriggerMode.TOGGLE
                    ):
                        self._logger.info(
                            "voice audio stop pending: waiting 2.500s for restart "
                            "before closing toggle session"
                        )

                        def _close_after_stable_audio_stop() -> None:
                            with self._voice_trigger_lock:
                                if not self._voice.active:
                                    return
                                self._voice_waiting_for_physical_release_after_audio_stop = True
                                self._logger.info(
                                    "voice audio stop stable; closing toggle session "
                                    "without waiting for delayed physical key-up"
                                )
                                self._close_voice_host_session()

                        self._voice_audio_stop_debouncer.on_release(
                            _close_after_stable_audio_stop
                        )
                    else:
                        self._logger.info(
                            "voice audio stop deferred: physical mic remains pressed"
                        )
                else:
                    self._close_voice_host_session()

    def _close_voice_host_session(self) -> None:
        """Deliver the configured closing action and retain failed work.

        A TOGGLE host protocol maps one RC003 physical session to two
        discrete TAPs: one at the accepted press boundary and one here at
        the debounced release boundary.  HOLD remains available as a
        compatibility protocol and closes with KEY_UP.  The controller is
        the single source of truth for which action is owed, including
        reconnect and shutdown cleanup.
        """

        action = self._voice.on_audio_stopped()
        transformed_session = self._voice_legacy_transform_session
        action_applied = True if action is None else self._apply_voice_action(action)
        if transformed_session:
            self._voice_legacy_transform_session = False
        if action is not None and not action_applied:
            # Same rule as _cleanup_once(): on_audio_stopped() already
            # cleared the controller's pending state before we knew whether
            # the closing action actually delivered. Restore the owed state
            # and fail closed by requesting a reconnect.
            self._voice.restore_pending(action)
            self._logger.info(
                "voice closing action failed to fully deliver; state retained, "
                "requesting reconnect"
            )
            self._supervisor.request_reconnect()

    def _handle_mic_button_pressed(
        self,
        *,
        send_device_open: bool = True,
        host_action_handled: bool = False,
    ) -> None:
        """Resolve and open the user-selected output endpoint FIRST; only
        send the hotkey if that succeeds, and only send MIC_OPEN if the
        hotkey itself fully delivered. This is the fail-closed ordering
        XRBM-014 review RETRY P1 #3 (endpoint) and review round 2 P1 #6
        (hotkey) both require: a device streaming audio into Windows
        without the configured hotkey having actually engaged voice typing
        is exactly the "opens after host-trigger failure" defect - so
        failure at either step suppresses MIC_OPEN, not just a missing
        endpoint.
        """

        if self._ble_session is None:
            self._logger.info("voice ignored: BLE voice session is not connected")
            return

        self._voice_audio_started_waiting_for_legacy_f5 = False

        if not self._prepare_playback_for_new_session():
            self._logger.info(
                "voice failing closed: no usable output endpoint; hotkey/MIC_OPEN suppressed"
            )
            return

        action = self._voice.on_mic_button_pressed()
        action_delivered = (
            True
            if host_action_handled
            else self._apply_voice_action(action)
        )
        if host_action_handled:
            self._logger.info(
                "voice host shortcut already handled by physical F5-to-right-Alt transform"
            )
        if not action_delivered:
            # Nothing physically landed (win32_input.py's own batching
            # already rolled back any partial key-down) - clear the
            # controller's logical state without emitting a second,
            # likely-just-as-doomed compensating action.
            self._voice.cancel_pending()
            self._logger.info(
                "voice failing closed: host hotkey delivery failed; MIC_OPEN suppressed"
            )
            return

        if send_device_open and self._ble_session is not None:
            self._ble_session.send_mic_open_threadsafe()

    def _apply_voice_action(self, action: voice_controller.VoiceHostAction) -> bool:
        tokens = tuple(self._voice_hotkey.modifiers) + (self._voice_hotkey.key,)
        if self._qianwen_target_physicalizer_enabled() and (
            qianwen_physicalizer.physicalizer_status() != "active"
        ):
            self._logger.info(
                "voice failing closed: verified Qianwen physicalizer is not active"
            )
            return False
        if self._voice_legacy_transform_session:
            if (
                action == voice_controller.VoiceHostAction.KEY_UP
                and self._voice_legacy_transform_key_down
            ):
                # Audio can stop before the remote's leaked F5 key-up arrives.
                # Release the replacement right-Alt edge here so a disconnect
                # or early stream stop can never leave Alt logically held.
                try:
                    win32_input.send_voice_key_combo_up(("ralt",))
                    self._voice_legacy_transform_key_down = False
                    self._voice_legacy_transform_session = False
                    self._logger.info(
                        "voice released right-Alt replacement before physical F5 key-up"
                    )
                    return True
                except (
                    win32_input.Win32InputUnavailableError,
                    OSError,
                ):
                    self._logger.exception(
                        "voice right-Alt replacement release failed"
                    )
                    return False
            self._logger.info(
                "voice host action already delivered by physical F5-to-right-Alt transform: %s",
                action.value,
            )
            return True
        try:
            if action == voice_controller.VoiceHostAction.TAP:
                self._logger.info(
                    "voice host tap delivered: tokens=%s thread=%s",
                    tokens,
                    threading.current_thread().name,
                )
                win32_input.send_voice_key_combo_tap(tokens)
            elif action == voice_controller.VoiceHostAction.KEY_DOWN:
                self._logger.info(
                    "voice host key-down delivered: tokens=%s thread=%s",
                    tokens,
                    threading.current_thread().name,
                )
                win32_input.send_voice_key_combo_down(tokens)
            else:
                self._logger.info(
                    "voice host key-up delivered: tokens=%s thread=%s",
                    tokens,
                    threading.current_thread().name,
                )
                win32_input.send_voice_key_combo_up(tokens)
            return True
        except win32_input.Win32InputUnavailableError:
            self._logger.info("voice hotkey action skipped: no usable voice input backend")
            return False
        except OSError:
            self._logger.exception("voice hotkey action failed to fully deliver")
            return False

    def _open_playback_for_new_session(self) -> bool:
        if self._playback is not None:
            return True
        endpoint_name = self._config.get("output_endpoint_name") or ""
        endpoint_host_api = self._config.get("output_endpoint_host_api") or ""
        try:
            endpoints = audio_output.enumerate_output_endpoints()
            audio_output.resolve_selected_endpoint(endpoints, endpoint_name, endpoint_host_api)
            sink = audio_playback.EndpointPlaybackSink(endpoint_name, endpoint_host_api)
            sink.open()
            self._playback = sink
            self._logger.info(
                "voice playback opened: host_api=%s sample_rate=%s channels=%s",
                endpoint_host_api or "unspecified",
                sink.output_sample_rate_hz,
                sink.output_channels,
            )
            return True
        except audio_output.AudioOutputUnavailableError as exc:
            self._logger.info("voice audio unavailable, failing closed: %s", exc)
            self._playback = None
            return False
        except Exception:
            self._logger.exception("voice audio failed to open, failing closed")
            self._playback = None
            return False

    def _prepare_playback_for_new_session(self) -> bool:
        """Ensure the continuous PortAudio writer is live before the hotkey.

        The writer emits silence between voice packets and sessions, so the
        WASAPI/VB-CABLE route stays active instead of entering the silent
        underflow state that a blocking write stream can report as healthy.
        """

        if self._playback is None:
            if not self._open_playback_for_new_session():
                return False
        try:
            self._playback.prepare_for_session()
        except Exception:
            self._logger.exception(
                "voice playback writer is not healthy; hotkey/MIC_OPEN suppressed"
            )
            return False
        self._logger.info("voice playback writer ready for host trigger")
        return True

    def _on_pcm_frame(self, samples) -> None:
        """Fails closed on a write failure (XRBM-014 review round 2 P1 #6):
        a broken playback sink must not be left open logging indefinitely
        while the device keeps streaming into it - request a reconnect so
        the next attempt starts from a clean state, unconditionally either
        way. Whether ``self._playback`` itself is cleared here depends on
        whether the follow-up ``close()`` actually succeeds (XRBM-019
        review round 1 P1 #5): a sink whose close call also failed still
        owns a PortAudio stream, and clearing the reference would hide that
        incompletely closed resource and let a reconnect open a second sink
        over it - the owner is only cleared once close() confirms success,
        same rule as ``_cleanup_once()``'s HID/BLE/playback steps.

        Runs on ble_transport_winrt.py's dedicated worker thread (not the
        event loop thread), so ``request_reconnect()`` must be - and is -
        safe to call cross-thread (see connection_supervisor.py).
        """

        if self._playback is None:
            return
        try:
            self._voice_pcm_stats.add(samples)
            if self._voice_pcm_stats.frames in (1, 10) or self._voice_pcm_stats.frames % 200 == 0:
                stats = self._voice_pcm_stats.summary()
                self._logger.info(
                    "voice PCM progress: frames=%s samples=%s peak=%s rms=%.1f "
                    "mean_abs=%.1f clipped=%.3f%%",
                    stats["frames"],
                    stats["samples"],
                    stats["peak"],
                    stats["rms"],
                    stats["mean_abs"],
                    stats["clipped_pct"],
                )
            self._playback.write(samples)
        except Exception:
            self._logger.exception("audio playback write failed; failing closed")
            try:
                self._playback.close()
                self._playback = None
            except Exception:
                self._logger.exception("cleanup: closing the failed playback sink failed")
                # self._playback is intentionally NOT cleared here: it may
                # still own a live PortAudio stream.
            self._supervisor.request_reconnect()


async def _run(
    stop_signal: Optional[bridge_control_windows.BridgeStopSignal] = None,
) -> None:
    app = RC003App()
    run_task: Optional[asyncio.Task] = None
    stop_task: Optional[asyncio.Task] = None
    try:
        if stop_signal is None:
            await app.run_forever()
            return
        run_task = asyncio.create_task(app.run_forever())

        async def _wait_for_stop() -> None:
            while not await asyncio.to_thread(stop_signal.wait, 0.250):
                pass

        stop_task = asyncio.create_task(_wait_for_stop())
        done, _pending = await asyncio.wait(
            (run_task, stop_task), return_when=asyncio.FIRST_COMPLETED
        )
        if stop_task in done:
            app._logger.info("bridge stop requested by settings; cleaning up")
            await app.stop()
        await run_task
    finally:
        await app.stop()
        if stop_task is not None and not stop_task.done():
            stop_task.cancel()
            try:
                await stop_task
            except asyncio.CancelledError:
                pass


def main(
    stop_signal: Optional[bridge_control_windows.BridgeStopSignal] = None,
) -> None:
    asyncio.run(_run(stop_signal))


if __name__ == "__main__":
    main()
