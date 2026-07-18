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
from typing import List, Optional

from . import (
    audio_output,
    audio_playback,
    ble_transport_winrt,
    config,
    connection_supervisor,
    frida_compat,
    hid_identity,
    hotkey,
    identity,
    key_mapping,
    logging_setup,
    raw_input_windows,
    voice_controller,
    win32_input,
)
from .atvv_session import AudioStarted, AudioStopped, MicButtonPressed


class CleanupIncompleteError(RuntimeError):
    """Raised by ``RC003App._cleanup_once()`` when the Raw Input listener
    and/or the BLE session report they are still alive after cleanup was
    attempted - see the module docstring's "Cleanup ownership" note. Every
    other cleanup step still ran before this is raised.
    """


class RC003App:
    def __init__(self) -> None:
        self._config_root = config.config_root()
        self._config = config.load_config(config.config_path(self._config_root))
        self._bindings = config.load_key_bindings(
            config.key_bindings_path(self._config_root)
        )
        self._logger: logging.Logger = logging_setup.get_logger(self._config_root)
        self._voice = voice_controller.VoiceController(
            key_mapping.VoiceTriggerMode(self._config["voice_trigger_mode"])
        )
        self._voice_hotkey = hotkey.HotkeySpec.parse(self._config["voice_hotkey"])
        self._ble_session: Optional[ble_transport_winrt.RC003BleSession] = None
        self._hid_listener: Optional[raw_input_windows.RawInputButtonListener] = None
        self._playback: Optional[audio_playback.EndpointPlaybackSink] = None
        self._back_key_compat = frida_compat.BackKeyCompatLayer()

        self._supervisor = connection_supervisor.ConnectionSupervisor(
            connect=self._connect_once,
            cleanup=self._cleanup_once,
            retry_delay=float(self._config.get("retry_delay", 2.0)),
            logger=self._logger,
        )

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

        self._logger.info(
            "startup: back-key compatibility layer status=%s",
            self._back_key_compat.status,
        )

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

        self._hid_listener = raw_input_windows.RawInputButtonListener(self._on_button_event)
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

        try:
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

    # -- HID button events (all buttons except mic; back is presently
    #    unmapped, see frida_compat.py) ------------------------------------

    def _on_button_event(self, button_id: str, is_pressed: bool) -> None:
        if not is_pressed:
            return  # this candidate maps simple taps; hold-repeat is future work
        action_dict = self._bindings.get("bindings", {}).get(button_id)
        if action_dict is None:
            return
        action = key_mapping.ButtonAction.from_dict(action_dict)
        self._apply_button_action(action)

    def _apply_button_action(self, action: key_mapping.ButtonAction) -> None:
        try:
            if action.kind == key_mapping.ActionKind.KEY_COMBO:
                win32_input.send_key_combo_tap(action.keys)
            elif action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_UP:
                win32_input.send_volume_up()
            elif action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_DOWN:
                win32_input.send_volume_down()
            # ActionKind.VOICE is only driven by ATVV control opcodes
            # (_on_control_event), never dispatched from a HID button event.
        except win32_input.Win32InputUnavailableError:
            self._logger.info("button action skipped: SendInput unavailable here")
        except OSError:
            self._logger.exception("button action failed to fully deliver")

    # -- ATVV control-channel events (mic button + audio start/stop) ------

    def _on_control_event(self, event: object) -> None:
        if isinstance(event, MicButtonPressed):
            self._handle_mic_button_pressed()
        elif isinstance(event, AudioStarted):
            pass  # playback is already opened (or voice already failed
            # closed) by _handle_mic_button_pressed before MIC_OPEN was
            # even sent - AudioStarted is purely informational here.
        elif isinstance(event, AudioStopped):
            action = self._voice.on_audio_stopped()
            if action is not None and not self._apply_voice_action(action):
                # Same rule as _cleanup_once(): on_audio_stopped() already
                # cleared the controller's pending state before we knew
                # whether the closing action (HOLD's KEY_UP or TOGGLE's
                # closing TAP) actually delivered. A failure here must not
                # be recorded as a clean close - restore the owed state and
                # fail closed by requesting a reconnect, the same way a BLE
                # disconnect or a playback write failure does (XRBM-019
                # review round 1 P1 #4).
                self._voice.restore_pending(action)
                self._logger.info(
                    "voice closing action failed to fully deliver; state retained, "
                    "requesting reconnect"
                )
                self._supervisor.request_reconnect()

    def _handle_mic_button_pressed(self) -> None:
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

        if not self._open_playback_for_new_session():
            self._logger.info(
                "voice failing closed: no usable output endpoint; hotkey/MIC_OPEN suppressed"
            )
            return

        action = self._voice.on_mic_button_pressed()
        if not self._apply_voice_action(action):
            # Nothing physically landed (win32_input.py's own batching
            # already rolled back any partial key-down) - clear the
            # controller's logical state without emitting a second,
            # likely-just-as-doomed compensating action.
            self._voice.cancel_pending()
            self._logger.info(
                "voice failing closed: host hotkey delivery failed; MIC_OPEN suppressed"
            )
            return

        if self._ble_session is not None:
            self._ble_session.send_mic_open_threadsafe()

    def _apply_voice_action(self, action: voice_controller.VoiceHostAction) -> bool:
        tokens = tuple(self._voice_hotkey.modifiers) + (self._voice_hotkey.key,)
        try:
            if action == voice_controller.VoiceHostAction.TAP:
                win32_input.send_key_combo_tap(tokens)
            elif action == voice_controller.VoiceHostAction.KEY_DOWN:
                win32_input.send_key_combo_down(tokens)
            else:
                win32_input.send_key_combo_up(tokens)
            return True
        except win32_input.Win32InputUnavailableError:
            self._logger.info("voice hotkey action skipped: SendInput unavailable here")
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
            return True
        except audio_output.AudioOutputUnavailableError as exc:
            self._logger.info("voice audio unavailable, failing closed: %s", exc)
            self._playback = None
            return False
        except Exception:
            self._logger.exception("voice audio failed to open, failing closed")
            self._playback = None
            return False

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


async def _run() -> None:
    app = RC003App()
    try:
        await app.run_forever()
    finally:
        await app.stop()


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
