"""RC003 单击、双击、长按识别与定时调度。"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Callable

from . import key_mapping


@dataclass
class _State:
    is_pressed: bool = True
    is_second_press: bool = False
    waiting_for_second_press: bool = False
    long_press_triggered: bool = False
    recognizes_double: bool = False
    recognizes_long: bool = False


class ButtonGestureRecognizer:
    """不依赖 Windows API 的逐键手势状态机。"""

    def __init__(self) -> None:
        self._states: dict[str, _State] = {}

    def press(
        self, button_id: str, *, double: bool, long: bool
    ) -> list[tuple[str, str]]:
        state = self._states.get(button_id)
        if state is not None:
            if not state.waiting_for_second_press:
                return []
            state.is_pressed = True
            state.is_second_press = True
            state.waiting_for_second_press = False
            commands = [("cancel_double", button_id)]
            if state.recognizes_long:
                commands.append(("schedule_long", button_id))
            return commands

        self._states[button_id] = _State(
            recognizes_double=double,
            recognizes_long=long,
        )
        return [("schedule_long", button_id)] if long else []

    def release(self, button_id: str) -> list[tuple[str, str]]:
        state = self._states.get(button_id)
        if state is None or not state.is_pressed:
            return []
        state.is_pressed = False
        commands: list[tuple[str, str]] = []
        if state.recognizes_long:
            commands.append(("cancel_long", button_id))
        if state.long_press_triggered:
            self._states.pop(button_id, None)
        elif state.is_second_press:
            self._states.pop(button_id, None)
            commands.append((key_mapping.DOUBLE_CLICK, button_id))
        elif state.recognizes_double:
            state.waiting_for_second_press = True
            commands.append(("schedule_double", button_id))
        else:
            self._states.pop(button_id, None)
            commands.append((key_mapping.SINGLE_CLICK, button_id))
        return commands

    def double_timeout(self, button_id: str) -> list[tuple[str, str]]:
        state = self._states.get(button_id)
        if state is None or not state.waiting_for_second_press or state.is_pressed:
            return []
        self._states.pop(button_id, None)
        return [(key_mapping.SINGLE_CLICK, button_id)]

    def long_timeout(self, button_id: str) -> list[tuple[str, str]]:
        state = self._states.get(button_id)
        if state is None or not state.is_pressed or not state.recognizes_long:
            return []
        state.long_press_triggered = True
        return [(key_mapping.LONG_PRESS, button_id)]

    def reset(self) -> None:
        self._states.clear()


class ButtonGestureDispatcher:
    DOUBLE_SECONDS = 0.30
    LONG_SECONDS = 0.55
    REPEAT_DELAY_SECONDS = 0.35
    REPEAT_SECONDS = 0.10

    def __init__(
        self,
        *,
        action_for: Callable[[str, str], str],
        on_trigger: Callable[[str, str], None],
    ) -> None:
        self._action_for = action_for
        self._on_trigger = on_trigger
        self._recognizer = ButtonGestureRecognizer()
        self._lock = threading.RLock()
        self._timers: dict[tuple[str, str], threading.Timer] = {}
        self._immediate_held: set[str] = set()

    def press(self, button_id: str) -> None:
        callbacks: list[tuple[str, str]] = []
        with self._lock:
            if button_id in self._immediate_held:
                return
            has_double = (
                self._action_for(button_id, key_mapping.DOUBLE_CLICK) != "disabled"
            )
            has_long = self._action_for(button_id, key_mapping.LONG_PRESS) != "disabled"
            if not has_double and not has_long:
                action = self._action_for(button_id, key_mapping.SINGLE_CLICK)
                if action == "disabled":
                    return
                self._immediate_held.add(button_id)
                callbacks.append((button_id, key_mapping.SINGLE_CLICK))
                if key_mapping.action_allows_repeat(action):
                    self._schedule_repeat(button_id, self.REPEAT_DELAY_SECONDS)
            else:
                self._run_commands(
                    self._recognizer.press(button_id, double=has_double, long=has_long),
                    callbacks,
                )
        self._emit(callbacks)

    def release(self, button_id: str) -> None:
        callbacks: list[tuple[str, str]] = []
        with self._lock:
            self._immediate_held.discard(button_id)
            self._cancel(("repeat", button_id))
            self._run_commands(self._recognizer.release(button_id), callbacks)
        self._emit(callbacks)

    def reset(self) -> None:
        with self._lock:
            for timer in self._timers.values():
                timer.cancel()
            self._timers.clear()
            self._immediate_held.clear()
            self._recognizer.reset()

    def _run_commands(
        self, commands: list[tuple[str, str]], callbacks: list[tuple[str, str]]
    ) -> None:
        for command, button_id in commands:
            if command == "schedule_double":
                self._schedule(
                    "double", button_id, self.DOUBLE_SECONDS, self._double_timeout
                )
            elif command == "cancel_double":
                self._cancel(("double", button_id))
            elif command == "schedule_long":
                self._schedule("long", button_id, self.LONG_SECONDS, self._long_timeout)
            elif command == "cancel_long":
                self._cancel(("long", button_id))
            else:
                callbacks.append((button_id, command))

    def _schedule(
        self,
        kind: str,
        button_id: str,
        delay: float,
        callback: Callable[[str], None],
    ) -> None:
        key = (kind, button_id)
        self._cancel(key)
        timer = threading.Timer(delay, lambda: callback(button_id))
        timer.daemon = True
        self._timers[key] = timer
        timer.start()

    def _schedule_repeat(self, button_id: str, delay: float) -> None:
        self._schedule("repeat", button_id, delay, self._repeat_timeout)

    def _cancel(self, key: tuple[str, str]) -> None:
        timer = self._timers.pop(key, None)
        if timer is not None:
            timer.cancel()

    def _double_timeout(self, button_id: str) -> None:
        callbacks: list[tuple[str, str]] = []
        with self._lock:
            self._timers.pop(("double", button_id), None)
            self._run_commands(self._recognizer.double_timeout(button_id), callbacks)
        self._emit(callbacks)

    def _long_timeout(self, button_id: str) -> None:
        callbacks: list[tuple[str, str]] = []
        with self._lock:
            self._timers.pop(("long", button_id), None)
            self._run_commands(self._recognizer.long_timeout(button_id), callbacks)
        self._emit(callbacks)

    def _repeat_timeout(self, button_id: str) -> None:
        should_emit = False
        with self._lock:
            self._timers.pop(("repeat", button_id), None)
            if button_id in self._immediate_held:
                should_emit = True
                self._schedule_repeat(button_id, self.REPEAT_SECONDS)
        if should_emit:
            self._on_trigger(button_id, key_mapping.SINGLE_CLICK)

    def _emit(self, callbacks: list[tuple[str, str]]) -> None:
        for button_id, trigger in callbacks:
            self._on_trigger(button_id, trigger)
