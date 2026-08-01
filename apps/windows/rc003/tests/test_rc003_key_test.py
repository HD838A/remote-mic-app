import tempfile
import unittest
from pathlib import Path
from unittest import mock

import rc003_key_test
from ovb_rc003 import key_testing, raw_input_windows


class Rc003KeyTestCliTests(unittest.TestCase):
    def test_replay_assigns_the_first_unknown_signature(self):
        events = (
            raw_input_windows.RawInputEvent(
                source="keyboard",
                is_pressed=True,
                vkey=0xFF,
                make_code=0x70,
                flags=0x0002,
                message=0x0100,
            ),
            raw_input_windows.RawInputEvent(
                source="keyboard",
                is_pressed=False,
                vkey=0xFF,
                make_code=0x70,
                flags=0x0003,
                message=0x0101,
            ),
        )
        recorder = key_testing.KeyCaptureRecorder()
        for event in events:
            recorder.append(event)

        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "capture.jsonl"
            recorder.write_jsonl(path)
            self.assertEqual(
                rc003_key_test.main(
                    ["replay", "--input", str(path), "--button", "back"]
                ),
                0,
            )

    def test_replay_requires_a_target_button(self):
        with self.assertRaises(SystemExit):
            rc003_key_test.main(["replay", "--input", "capture.jsonl"])

    def test_incomplete_capture_does_not_save_a_physical_binding(self):
        class PressOnlyListener:
            def __init__(self, _on_button_event, on_raw_event):
                self._on_raw_event = on_raw_event

            def start(self, _device_path):
                self._on_raw_event(
                    raw_input_windows.RawInputEvent(
                        source="keyboard",
                        is_pressed=True,
                        vkey=0xFF,
                        make_code=0x70,
                        flags=0x0002,
                        message=0x0100,
                    )
                )

            def stop(self):
                return None

        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "incomplete.jsonl"
            with mock.patch.object(
                rc003_key_test.raw_input_windows,
                "RawInputButtonListener",
                PressOnlyListener,
            ), mock.patch.object(
                rc003_key_test.raw_input_windows,
                "enumerate_matching_device_paths",
                return_value=("rc003",),
            ), mock.patch.object(
                rc003_key_test.hid_identity,
                "select_single_device_path",
                return_value="rc003",
            ), mock.patch.object(
                rc003_key_test, "_save_physical_binding"
            ) as save_binding:
                result = rc003_key_test.main(
                    [
                        "capture",
                        "--assign",
                        "back",
                        "--duration",
                        "0",
                        "--output",
                        str(output),
                    ]
                )

        self.assertEqual(result, 1)
        save_binding.assert_not_called()


if __name__ == "__main__":
    unittest.main()
