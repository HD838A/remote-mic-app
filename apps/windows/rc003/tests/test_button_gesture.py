import unittest

from ovb_rc003 import button_gesture, key_mapping


class ButtonGestureRecognizerTests(unittest.TestCase):
    def test_single_click_fires_on_release_without_secondary_actions(self):
        recognizer = button_gesture.ButtonGestureRecognizer()

        self.assertEqual(recognizer.press("ok", double=False, long=False), [])
        self.assertEqual(
            recognizer.release("ok"),
            [(key_mapping.SINGLE_CLICK, "ok")],
        )

    def test_double_click_suppresses_single_click(self):
        recognizer = button_gesture.ButtonGestureRecognizer()

        recognizer.press("ok", double=True, long=False)
        self.assertEqual(recognizer.release("ok"), [("schedule_double", "ok")])
        self.assertEqual(
            recognizer.press("ok", double=True, long=False),
            [("cancel_double", "ok")],
        )
        self.assertEqual(
            recognizer.release("ok"),
            [(key_mapping.DOUBLE_CLICK, "ok")],
        )

    def test_long_press_suppresses_release_single(self):
        recognizer = button_gesture.ButtonGestureRecognizer()

        self.assertEqual(
            recognizer.press("home", double=False, long=True),
            [("schedule_long", "home")],
        )
        self.assertEqual(
            recognizer.long_timeout("home"),
            [(key_mapping.LONG_PRESS, "home")],
        )
        self.assertEqual(recognizer.release("home"), [("cancel_long", "home")])


if __name__ == "__main__":
    unittest.main()
