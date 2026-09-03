"""Per-button click/hold gesture recognition for the RC003 mapping layer.

This is the Windows counterpart of the reference project's
``RemoteButtonGestureRecognizer``.  The recognizer itself is pure state and
has no timers or Windows dependencies; ``ButtonGestureDispatcher`` adds the
small amount of timer/repeat plumbing needed by the Raw Input callback.

The important contract is deliberately explicit:

* a button with no secondary action keeps immediate single-click behavior;
* configuring double-click delays the single action by 300 ms;
* configuring long-press fires it at 550 ms and suppresses single-click;
* any configured secondary action disables ordinary hold-repeat.

The physical microphone button never enters this module.  The app routes it
through the ATVV voice lifecycle, matching the reference implementation.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Dict, List, Optional, Set


class ButtonTrigger(str, Enum):
    SINGLE_CLICK = "single_click"
    DOUBLE_CLICK = "double_click"
    LONG_PRESS = "long_press"


class _CommandKind(str, Enum):
    SCHEDULE_DOUBLE = "schedule_double"
    CANCEL_DOUBLE = "cancel_double"
    SCHEDULE_LONG = "schedule_long"
    CANCEL_LONG = "cancel_long"
    TRIGGER = "trigger"


@dataclass(frozen=True)
class GestureCommand:
    kind: _CommandKind
    button_id: str
    trigger: Optional[ButtonTrigger] = None

    @classmethod
    def schedule_double_click_timeout(cls, button_id: str) -> "GestureCommand":
        return cls(_CommandKind.SCHEDULE_DOUBLE, button_id)

    @classmethod
    def cancel_double_click_timeout(cls, button_id: str) -> "GestureCommand":
        return cls(_CommandKind.CANCEL_DOUBLE, button_id)

    @classmethod
    def schedule_long_press_timeout(cls, button_id: str) -> "GestureCommand":
        return cls(_CommandKind.SCHEDULE_LONG, button_id)

    @classmethod
    def cancel_long_press_timeout(cls, button_id: str) -> "GestureCommand":
        return cls(_CommandKind.CANCEL_LONG, button_id)

    @classmethod
    def trigger(cls, button_id: str, trigger: ButtonTrigger) -> "GestureCommand":
        return cls(_CommandKind.TRIGGER, button_id, trigger)


@dataclass
class _ButtonState:
    is_pressed: bool = True
    is_second_press: bool = False
    waiting_for_second_press: bool = False
    long_press_triggered: bool = False
    recognizes_double_click: bool = False
    recognizes_long_press: bool = False


class ButtonGestureRecognizer:
    """Pure per-button state machine.

    A separate state is kept for every button so activity on one remote key
    cannot cancel or complete a gesture on another key.
    """

    def __init__(self) -> None:
        self._states: Dict[str, _ButtonState] = {}

    def is_tracking(self, button_id: str) -> bool:
        return button_id in self._states

    def press(
        self,
        button_id: str,
        *,
        recognizes_double_click: bool,
        recognizes_long_press: bool,
    ) -> List[GestureCommand]:
        state = self._states.get(button_id)
        if state is not None:
            if not state.waiting_for_second_press:
                return []
            state.is_pressed = True
            state.is_second_press = True
            state.waiting_for_second_press = False
            self._states[button_id] = state
            commands = [GestureCommand.cancel_double_click_timeout(button_id)]
            if state.recognizes_long_press:
                commands.append(GestureCommand.schedule_long_press_timeout(button_id))
            return commands

        self._states[button_id] = _ButtonState(
            recognizes_double_click=recognizes_double_click,
            recognizes_long_press=recognizes_long_press,
        )
        if recognizes_long_press:
            return [GestureCommand.schedule_long_press_timeout(button_id)]
        return []

    def release(self, button_id: str) -> List[GestureCommand]:
        state = self._states.get(button_id)
        if state is None or not state.is_pressed:
            return []

        state.is_pressed = False
        commands: List[GestureCommand] = []
        if state.recognizes_long_press:
            commands.append(GestureCommand.cancel_long_press_timeout(button_id))
        if state.long_press_triggered:
            self._states.pop(button_id, None)
            return commands
        if state.is_second_press:
            self._states.pop(button_id, None)
            commands.append(
                GestureCommand.trigger(button_id, ButtonTrigger.DOUBLE_CLICK)
            )
            return commands
        if state.recognizes_double_click:
            state.waiting_for_second_press = True
            self._states[button_id] = state
            commands.append(GestureCommand.schedule_double_click_timeout(button_id))
            return commands

        self._states.pop(button_id, None)
        commands.append(GestureCommand.trigger(button_id, ButtonTrigger.SINGLE_CLICK))
        return commands

    def double_click_timed_out(self, button_id: str) -> List[GestureCommand]:
        state = self._states.get(button_id)
        if state is None or not state.waiting_for_second_press or state.is_pressed:
            return []
        self._states.pop(button_id, None)
        return [GestureCommand.trigger(button_id, ButtonTrigger.SINGLE_CLICK)]

    def long_press_timed_out(self, button_id: str) -> List[GestureCommand]:
        state = self._states.get(button_id)
        if state is None or not state.is_pressed or not state.recognizes_long_press:
            return []
        state.long_press_triggered = True
        self._states[button_id] = state
        return [GestureCommand.trigger(button_id, ButtonTrigger.LONG_PRESS)]

    def reset(self) -> None:
        self._states.clear()


TimerFactory = Callable[[float, Callable[[], None]], object]
ActionConfigured = Callable[[str, ButtonTrigger], bool]
TriggerCallback = Callable[[str, ButtonTrigger], None]
RepeatableCallback = Callable[[str], bool]


class ButtonGestureDispatcher:
    """Thread-safe timer adapter used by ``RC003App``.

    Raw Input callbacks run on a hidden Win32 message-loop thread, while the
    two timeout callbacks run on timer threads.  The lock serializes those
    edges and prevents a timeout racing a release from producing both a
    single and a double/long action.
    """

    DOUBLE_CLICK_SECONDS = 0.300
    LONG_PRESS_SECONDS = 0.550
    REPEAT_DELAY_SECONDS = 0.350
    REPEAT_INTERVAL_SECONDS = 0.100
    BACK_REPEAT_INTERVAL_SECONDS = 0.050

    def __init__(
        self,
        *,
        is_action_configured: ActionConfigured,
        is_repeatable: RepeatableCallback,
        on_trigger: TriggerCallback,
        timer_factory: Optional[TimerFactory] = None,
    ) -> None:
        self._is_action_configured = is_action_configured
        self._is_repeatable = is_repeatable
        self._on_trigger = on_trigger
        self._timer_factory = timer_factory or (
            lambda delay, callback: threading.Timer(delay, callback)
        )
        self._lock = threading.RLock()
        self._recognizer = ButtonGestureRecognizer()
        self._double_timers: Dict[str, object] = {}
        self._long_timers: Dict[str, object] = {}
        self._repeat_timers: Dict[str, object] = {}
        self._held_immediate_buttons: Set[str] = set()

    def press(self, button_id: str) -> None:
        callbacks: List[ButtonTrigger] = []
        with self._lock:
            if button_id in self._held_immediate_buttons:
                return
            recognizes_double = self._is_action_configured(
                button_id, ButtonTrigger.DOUBLE_CLICK
            )
            recognizes_long = self._is_action_configured(
                button_id, ButtonTrigger.LONG_PRESS
            )
            if not recognizes_double and not recognizes_long and not self._recognizer.is_tracking(button_id):
                if not self._is_action_configured(button_id, ButtonTrigger.SINGLE_CLICK):
                    return
                self._held_immediate_buttons.add(button_id)
                callbacks.append(ButtonTrigger.SINGLE_CLICK)
                if self._is_repeatable(button_id):
                    self._schedule_repeat_locked(button_id, self.REPEAT_DELAY_SECONDS)
            else:
                commands = self._recognizer.press(
                    button_id,
                    recognizes_double_click=recognizes_double,
                    recognizes_long_press=recognizes_long,
                )
                callbacks.extend(self._execute_commands_locked(commands))
        self._emit(button_id, callbacks)

    def release(self, button_id: str) -> None:
        with self._lock:
            self._held_immediate_buttons.discard(button_id)
            self._cancel_timer_locked(self._repeat_timers, button_id)
            commands = self._recognizer.release(button_id)
            callbacks = self._execute_commands_locked(commands)
        self._emit_many(commands, callbacks)

    def reset(self) -> None:
        with self._lock:
            for timers in (
                self._double_timers,
                self._long_timers,
                self._repeat_timers,
            ):
                for timer in timers.values():
                    self._cancel_timer(timer)
                timers.clear()
            self._held_immediate_buttons.clear()
            self._recognizer.reset()

    def _execute_commands_locked(
        self, commands: List[GestureCommand]
    ) -> List[ButtonTrigger]:
        callbacks: List[ButtonTrigger] = []
        for command in commands:
            if command.kind is _CommandKind.SCHEDULE_DOUBLE:
                self._schedule_double_locked(command.button_id)
            elif command.kind is _CommandKind.CANCEL_DOUBLE:
                self._cancel_timer_locked(self._double_timers, command.button_id)
            elif command.kind is _CommandKind.SCHEDULE_LONG:
                self._schedule_long_locked(command.button_id)
            elif command.kind is _CommandKind.CANCEL_LONG:
                self._cancel_timer_locked(self._long_timers, command.button_id)
            elif command.kind is _CommandKind.TRIGGER and command.trigger is not None:
                callbacks.append(command.trigger)
        return callbacks

    def _schedule_double_locked(self, button_id: str) -> None:
        self._cancel_timer_locked(self._double_timers, button_id)
        timer = self._timer_factory(
            self.DOUBLE_CLICK_SECONDS,
            lambda: self._double_click_timeout(button_id),
        )
        self._double_timers[button_id] = timer
        timer.start()

    def _schedule_long_locked(self, button_id: str) -> None:
        self._cancel_timer_locked(self._long_timers, button_id)
        timer = self._timer_factory(
            self.LONG_PRESS_SECONDS,
            lambda: self._long_press_timeout(button_id),
        )
        self._long_timers[button_id] = timer
        timer.start()

    def _schedule_repeat_locked(self, button_id: str, delay: float) -> None:
        self._cancel_timer_locked(self._repeat_timers, button_id)
        timer = self._timer_factory(delay, lambda: self._repeat_timeout(button_id))
        self._repeat_timers[button_id] = timer
        timer.start()

    def _double_click_timeout(self, button_id: str) -> None:
        with self._lock:
            self._double_timers.pop(button_id, None)
            commands = self._recognizer.double_click_timed_out(button_id)
            callbacks = self._execute_commands_locked(commands)
        self._emit_many(commands, callbacks)

    def _long_press_timeout(self, button_id: str) -> None:
        with self._lock:
            self._long_timers.pop(button_id, None)
            commands = self._recognizer.long_press_timed_out(button_id)
            callbacks = self._execute_commands_locked(commands)
        self._emit_many(commands, callbacks)

    def _repeat_timeout(self, button_id: str) -> None:
        with self._lock:
            if button_id not in self._held_immediate_buttons:
                self._repeat_timers.pop(button_id, None)
                return
            self._repeat_timers.pop(button_id, None)
            interval = (
                self.BACK_REPEAT_INTERVAL_SECONDS
                if button_id == "back"
                else self.REPEAT_INTERVAL_SECONDS
            )
            self._schedule_repeat_locked(button_id, interval)
        self._on_trigger(button_id, ButtonTrigger.SINGLE_CLICK)

    def _emit(self, button_id: str, callbacks: List[ButtonTrigger]) -> None:
        for trigger in callbacks:
            self._on_trigger(button_id, trigger)

    def _emit_many(
        self, commands: List[GestureCommand], callbacks: List[ButtonTrigger]
    ) -> None:
        for command, trigger in zip(
            (command for command in commands if command.kind is _CommandKind.TRIGGER),
            callbacks,
        ):
            self._on_trigger(command.button_id, trigger)

    def _cancel_timer_locked(self, timers: Dict[str, object], button_id: str) -> None:
        timer = timers.pop(button_id, None)
        if timer is not None:
            self._cancel_timer(timer)

    @staticmethod
    def _cancel_timer(timer: object) -> None:
        cancel = getattr(timer, "cancel", None)
        if cancel is not None:
            cancel()
