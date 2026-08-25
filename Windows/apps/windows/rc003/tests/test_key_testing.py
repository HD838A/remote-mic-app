import json
import struct
import tempfile
import unittest
from pathlib import Path

from ovb_rc003 import hid_identity, key_testing, raw_input_windows


WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101


def _rawkeyboard_body(
    make_code: int, vkey: int, message: int, flags: int = 0x0002
) -> bytes:
    return struct.pack("<HHHHII", make_code, flags, 0, vkey, message, 0)


def _rawhid_body(report: bytes) -> bytes:
    return len(report).to_bytes(4, "little") + (1).to_bytes(4, "little") + report


def _report(usage: int) -> bytes:
    payload = usage.to_bytes(2, "little") + b"\x00\x00\x00\x00"
    return b"\x01\x00\x00" + payload


class PhysicalSignatureTests(unittest.TestCase):
    def test_keyboard_signature_is_same_for_press_and_release(self):
        press = raw_input_windows.RawInputEvent(
            source="keyboard",
            is_pressed=True,
            vkey=0xFF,
            make_code=0x70,
            flags=0x0002,
            message=WM_KEYDOWN,
        )
        release = raw_input_windows.RawInputEvent(
            source="keyboard",
            is_pressed=False,
            vkey=0xFF,
            make_code=0x70,
            flags=0x0003,
            message=WM_KEYUP,
        )
        self.assertEqual(
            raw_input_windows.physical_signature(press),
            raw_input_windows.physical_signature(release),
        )

    def test_hid_signature_does_not_include_device_path(self):
        first = raw_input_windows.RawInputEvent(
            source="hid",
            is_pressed=True,
            report=_report(0x1234),
            usages=(0x1234,),
            device_path="path-a",
        )
        second = raw_input_windows.RawInputEvent(
            source="hid",
            is_pressed=True,
            report=_report(0x1234),
            usages=(0x1234,),
            device_path="path-b",
        )
        self.assertEqual(
            raw_input_windows.physical_signature(first),
            raw_input_windows.physical_signature(second),
        )


class CaptureReplayTests(unittest.TestCase):
    def test_unknown_keyboard_capture_can_be_bound_and_replayed(self):
        event = raw_input_windows.RawInputEvent(
            source="keyboard",
            is_pressed=True,
            vkey=0xFF,
            make_code=0x70,
            flags=0x0002,
            message=WM_KEYDOWN,
        )
        release = raw_input_windows.RawInputEvent(
            source="keyboard",
            is_pressed=False,
            vkey=0xFF,
            make_code=0x70,
            flags=0x0003,
            message=WM_KEYUP,
        )
        binding = key_testing.binding_for_event(event, "back")
        result = key_testing.evaluate_key_capture(
            (event, release), "back", physical_bindings=binding
        )
        self.assertTrue(result.passed)
        self.assertEqual(result.observed_buttons, ("back",))

    def test_capture_round_trip_preserves_unknown_hid_report(self):
        event = raw_input_windows.RawInputEvent(
            source="hid",
            is_pressed=True,
            report=_report(0x1234),
            usages=(0x1234,),
            decode_error=None,
        )
        recorder = key_testing.KeyCaptureRecorder()
        recorder.append(event)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "capture.jsonl"
            recorder.write_jsonl(path)
            loaded = key_testing.load_capture(path)
        self.assertEqual(loaded, (event,))
        record = recorder.records[0]
        self.assertEqual(record["signature"], raw_input_windows.physical_signature(event))
        self.assertNotIn("device_path", record)

    def test_recorder_can_include_device_path_only_for_live_diagnostics(self):
        event = raw_input_windows.RawInputEvent(
            source="keyboard",
            is_pressed=True,
            vkey=0x27,
            device_path="\\\\?\\HID#RC003",
        )
        recorder = key_testing.KeyCaptureRecorder(include_device_path=True)
        recorder.append(event)
        self.assertEqual(recorder.records[0]["device_path"], event.device_path)

    def test_capture_schema_version_is_checked(self):
        record = {
            "schema_version": key_testing.CAPTURE_SCHEMA_VERSION + 1,
            "kind": key_testing.CAPTURE_KIND,
        }
        with self.assertRaises(ValueError):
            key_testing.record_to_event(record)

    def test_decode_error_keeps_a_capture_from_passing(self):
        event = raw_input_windows.RawInputEvent(
            source="hid",
            is_pressed=False,
            decode_error="expected a 6-byte payload",
        )
        result = key_testing.evaluate_key_capture((event,), "back")
        self.assertFalse(result.passed)
        self.assertEqual(result.decode_errors, ("expected a 6-byte payload",))


class ListenerAdaptationTests(unittest.TestCase):
    def test_unknown_keyboard_signature_can_dispatch_as_back(self):
        calls = []
        raw_events = []
        probe = raw_input_windows.RawInputEvent(
            source="keyboard",
            is_pressed=True,
            vkey=0xFF,
            make_code=0x70,
            flags=0x0002,
            message=WM_KEYDOWN,
        )
        listener = raw_input_windows.RawInputButtonListener(
            lambda button, pressed: calls.append((button, pressed)),
            raw_events.append,
            key_testing.binding_for_event(probe, "back"),
        )
        listener._handle_keyboard_body(
            _rawkeyboard_body(0x70, 0xFF, WM_KEYDOWN)
        )
        listener._handle_keyboard_body(
            _rawkeyboard_body(0x70, 0xFF, WM_KEYUP)
        )
        self.assertEqual(calls, [("back", True), ("back", False)])
        self.assertEqual([event.button_id for event in raw_events], ["back", "back"])

    def test_unknown_hid_usage_is_visible_instead_of_discarded(self):
        raw_events = []
        listener = raw_input_windows.RawInputButtonListener(
            lambda *_: None, raw_events.append
        )
        listener._handle_hid_body(_rawhid_body(_report(0x1234)))
        listener._handle_hid_body(_rawhid_body(_report(0)))
        self.assertEqual([event.usages for event in raw_events], [(0x1234,), (0x1234,)])
        self.assertEqual([event.button_id for event in raw_events], [None, None])
        self.assertEqual([event.is_pressed for event in raw_events], [True, False])


class ReportShapeTests(unittest.TestCase):
    def test_compact_report_forms_decode_like_legacy_form(self):
        legacy = _report(0x003E)
        compact = legacy[0:1] + legacy[3:]
        payload = legacy[3:]
        expected = frozenset({0x003E})
        self.assertEqual(hid_identity.decode_report_usages(legacy), expected)
        self.assertEqual(hid_identity.decode_report_usages(compact), expected)
        self.assertEqual(hid_identity.decode_report_usages(payload), expected)
        self.assertEqual(hid_identity.decode_active_usages(compact), expected)


if __name__ == "__main__":
    unittest.main()
