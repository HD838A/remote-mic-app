"""Pure state machine deciding when to synthesize the voice hotkey edge.

The RC003 device autonomously tells the host when its own physical mic button
is pressed (ATVV control opcode 0x08) and when its audio stream stops
(opcode 0x00) - see atvv_session.py. This module only decides, given the
configured trigger mode, what host key action that should produce. It
performs no I/O itself, so it's fully unit testable; the actual SendInput
call lives in app.py.

Semantics (frozen by XRBM-018, replacing the XRBM-014 RETRY
P1 #4 fix below it - see the XRBM-014 round 2 replan-check finding
"Toggle release edge absent"):

- TOGGLE mode issues a key TAP on mic-button-press (starting the configured
  host voice shortcut) and issues ANOTHER TAP when the device's own
  AUDIO_STOP arrives (turning that same OS-level toggle back off). A single
  tap-only-on-press action (the previous XRBM-014 RETRY P1 #4 fix) avoided
  holding a modifier "stuck" for the duration of the stream, but left
  the host voice mode running indefinitely after the device stopped
  streaming, since the configured toggle shortcut needs a second press to
  turn back off.
- HOLD mode still holds the key down for the duration of the stream:
  key-down on mic-button-press, key-up when the device's own AUDIO_STOP
  arrives.
- Both modes' cleanup is provable: reset() always reports whether a
  closing action (KEY_UP for HOLD, TAP for TOGGLE) is still owed, and
  never leaves the controller thinking a session is still active.
"""

from __future__ import annotations

from enum import Enum
from typing import Optional

from .key_mapping import VoiceTriggerMode


class VoiceHostAction(str, Enum):
    TAP = "tap"
    KEY_DOWN = "key_down"
    KEY_UP = "key_up"


class VoiceController:
    def __init__(self, trigger_mode: VoiceTriggerMode = VoiceTriggerMode.TOGGLE) -> None:
        self.trigger_mode = trigger_mode
        self._holding = False  # HOLD mode: a key-down is outstanding
        self._toggle_active = False  # TOGGLE mode: a closing tap is owed

    @property
    def holding(self) -> bool:
        """Whether a HOLD-mode key-down is currently outstanding (owed a
        key-up). Always False in TOGGLE mode, since toggle never holds a
        key down - it owes a closing TAP instead (see ``active``).
        """

        return self._holding

    @property
    def active(self) -> bool:
        """Whether a mic session is open from this controller's point of
        view - a HOLD-mode key-down or a TOGGLE-mode closing tap is owed.
        """

        return self._holding or self._toggle_active

    def on_mic_button_pressed(self) -> VoiceHostAction:
        """React to the device's own MIC_BUTTON control opcode."""

        if self.trigger_mode == VoiceTriggerMode.HOLD:
            self._holding = True
            return VoiceHostAction.KEY_DOWN

        self._toggle_active = True
        return VoiceHostAction.TAP

    def on_audio_stopped(self) -> Optional[VoiceHostAction]:
        """React to the device's own AUDIO_STOP control opcode.

        HOLD mode releases the key the moment the device stops streaming.
        TOGGLE mode issues the second tap that turns the OS-level toggle
        back off - a no-op if no session is currently marked active (e.g.
        AUDIO_STOP without a prior press, or one already closed by reset()).
        """

        if self.trigger_mode == VoiceTriggerMode.HOLD:
            if self._holding:
                self._holding = False
                return VoiceHostAction.KEY_UP
            return None
        if self._toggle_active:
            self._toggle_active = False
            return VoiceHostAction.TAP
        return None

    def reset(self) -> Optional[VoiceHostAction]:
        """Force any outstanding session closed, e.g. on disconnect/shutdown
        cleanup.

        Provable cleanup: returns KEY_UP if a HOLD-mode key-down is still
        outstanding, TAP if a TOGGLE-mode session was started but never
        closed by its own AUDIO_STOP, or None if nothing is owed. Either
        way, ``active`` is False immediately after this returns.
        """

        if self._holding:
            self._holding = False
            return VoiceHostAction.KEY_UP
        if self._toggle_active:
            self._toggle_active = False
            return VoiceHostAction.TAP
        return None

    def restore_pending(self, action: VoiceHostAction) -> None:
        """Undoes ``reset()``/``on_audio_stopped()``'s eager state-clearing
        for a closing ``action`` that is now known to have failed to
        deliver (XRBM-019 review round 1 P1 #4).

        Both of those methods clear ``_holding``/``toggle_active`` and
        return the closing action BEFORE the caller has actually attempted
        to deliver it - correct when delivery succeeds, but if it fails
        (``win32_input.send_key_combo_up`` now raises instead of swallowing
        that - see win32_input.py), the controller must go back to thinking
        the session is still owed, not silently "closed": a failed HOLD-mode
        KEY_UP should not stop the caller from retrying the release, and a
        failed TOGGLE-mode closing TAP should not be forgotten either. A
        caller passes exactly the ``VoiceHostAction`` that failed; any other
        value (e.g. ``TAP`` from a TOGGLE-mode opening press, which is never
        a closing action - see ``on_mic_button_pressed``) is a caller bug,
        not something this method can distinguish, so this only restores
        the two closing-action shapes it actually owns.
        """

        if action == VoiceHostAction.KEY_UP:
            self._holding = True
        elif action == VoiceHostAction.TAP:
            self._toggle_active = True

    def cancel_pending(self) -> None:
        """Clear an outstanding session WITHOUT emitting a compensating host
        action - used when the action ``on_mic_button_pressed()`` just
        returned failed to actually deliver (see app.py's
        ``_handle_mic_button_pressed``): nothing physically landed, so there
        is nothing to release, and attempting a compensating action would
        itself be a second delivery attempt liable to fail the same way.
        """

        self._holding = False
        self._toggle_active = False