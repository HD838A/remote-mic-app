import unittest

from ovb_rc003.button_gesture import (
    ButtonGestureDispatcher,
    ButtonGestureRecognizer,
    ButtonTrigger,
    GestureCommand,
)


class ButtonGestureRecognizerTests(unittest.TestCase):
    def test_single_click_is_delayed_only_when_double_click_is_configured(self):
        recognizer = ButtonGestureRecognizer()

        commands = recognizer.press(
            "up", recognizes_double_click=True, recognizes_long_press=False
        )
        self.assertEqual(commands, [])
        commands = recognizer.release("up")
        self.assertEqual(
            commands,
            [
                GestureCommand.schedule_double_click_timeout("up"),
            ],
        )
        self.assertEqual(
            recognizer.double_click_timed_out("up"),
            [GestureCommand.trigger("up", ButtonTrigger.SINGLE_CLICK)],
        )

    def test_second_press_converts_pending_single_to_double_click(self):
        recognizer = ButtonGestureRecognizer()
        recognizer.press("ok", recognizes_double_click=True, recognizes_long_press=True)
        recognizer.release("ok")

        self.assertEqual(
            recognizer.press(
                "ok", recognizes_double_click=True, recognizes_long_press=True
            ),
            [
                GestureCommand.cancel_double_click_timeout("ok"),
                GestureCommand.schedule_long_press_timeout("ok"),
            ],
        )
        self.assertEqual(
            recognizer.release("ok"),
            [
                GestureCommand.cancel_long_press_timeout("ok"),
                GestureCommand.trigger("ok", ButtonTrigger.DOUBLE_CLICK),
            ],
        )

    def test_long_press_suppresses_single_click(self):
        recognizer = ButtonGestureRecognizer()
        recognizer.press("power", recognizes_double_click=False, recognizes_long_press=True)

        self.assertEqual(
            recognizer.long_press_timed_out("power"),
            [GestureCommand.trigger("power", ButtonTrigger.LONG_PRESS)],
        )
        self.assertEqual(
            recognizer.release("power"),
            [GestureCommand.cancel_long_press_timeout("power")],
        )

    def test_unconfigured_button_triggers_single_click_on_release(self):
        recognizer = ButtonGestureRecognizer()
        recognizer.press("back", recognizes_double_click=False, recognizes_long_press=False)
        self.assertEqual(
            recognizer.release("back"),
            [GestureCommand.trigger("back", ButtonTrigger.SINGLE_CLICK)],
        )


class _FakeTimer:
    def __init__(self, callback):
        self.callback = callback
        self.cancelled = False
        self.started = False

    def start(self):
        self.started = True

    def cancel(self):
        self.cancelled = True

    def fire(self):
        if not self.cancelled:
            self.callback()


class ButtonGestureDispatcherTests(unittest.TestCase):
    def setUp(self):
        self.timers = []
        self.triggers = []

        def timer_factory(_delay, callback):
            timer = _FakeTimer(callback)
            self.timers.append(timer)
            return timer

        self.dispatcher = ButtonGestureDispatcher(
            is_action_configured=lambda button, trigger: (
                (button == "up" and trigger == ButtonTrigger.SINGLE_CLICK)
                or (button == "ok" and trigger == ButtonTrigger.DOUBLE_CLICK)
            ),
            is_repeatable=lambda button: button == "up",
            on_trigger=lambda button, trigger: self.triggers.append((button, trigger)),
            timer_factory=timer_factory,
        )

    def test_simple_button_emits_once_and_does_not_duplicate_on_repeat_press(self):
        self.dispatcher.press("up")
        self.dispatcher.press("up")
        self.assertEqual(self.triggers, [("up", ButtonTrigger.SINGLE_CLICK)])
        self.dispatcher.release("up")

    def test_double_click_timer_resolves_single_click(self):
        self.dispatcher.press("ok")
        self.dispatcher.release("ok")
        self.assertEqual(self.triggers, [])
        self.assertEqual(len(self.timers), 1)

        self.timers[0].fire()
        self.assertEqual(self.triggers, [("ok", ButtonTrigger.SINGLE_CLICK)])

    def test_double_click_emits_only_double_action(self):
        self.dispatcher.press("ok")
        self.dispatcher.release("ok")
        first_timer = self.timers[0]
        self.dispatcher.press("ok")
        self.dispatcher.release("ok")
        first_timer.fire()
        self.assertEqual(self.triggers, [("ok", ButtonTrigger.DOUBLE_CLICK)])

    def test_long_press_emits_long_action_and_release_emits_no_single(self):
        self.dispatcher = ButtonGestureDispatcher(
            is_action_configured=lambda button, trigger: (
                button == "ok" and trigger == ButtonTrigger.LONG_PRESS
            ),
            is_repeatable=lambda button: False,
            on_trigger=lambda button, trigger: self.triggers.append((button, trigger)),
            timer_factory=lambda delay, callback: self._new_timer(callback),
        )
        self.dispatcher.press("ok")
        self.assertEqual(len(self.timers), 1)
        self.timers[0].fire()
        self.assertEqual(self.triggers, [("ok", ButtonTrigger.LONG_PRESS)])
        self.dispatcher.release("ok")
        self.assertEqual(self.triggers, [("ok", ButtonTrigger.LONG_PRESS)])

    def _new_timer(self, callback):
        timer = _FakeTimer(callback)
        self.timers.append(timer)
        return timer


if __name__ == "__main__":
    unittest.main()
