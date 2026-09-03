import sys
import types
import unittest
from unittest import mock

from ovb_rc003 import qianwen_physicalizer


class QianwenPhysicalizerTests(unittest.TestCase):
    def test_script_is_version_locked_and_only_physicalizes_marked_right_alt(self):
        source = qianwen_physicalizer._PHYSICALIZER_SOURCE
        self.assertIn("module.base.add(0x85684)", source)
        self.assertIn("vk !== 0xA5", source)
        self.assertIn("flags & 0x10", source)
        self.assertIn("extraInfo.equals(remoteMicMarker)", source)
        self.assertIn("type: 'ralt_event'", source)
        self.assertIn("0x524d494352433033", source)
        self.assertIn("flags & ~0x12", source)

    def test_verified_module_requires_qianwen_install_path_and_hash(self):
        with mock.patch.object(
            qianwen_physicalizer.hashlib,
            "sha256",
            return_value=mock.Mock(
                hexdigest=lambda: qianwen_physicalizer._EXE_SHA256
            ),
        ), mock.patch.object(
            qianwen_physicalizer.Path, "read_bytes", return_value=b"verified"
        ):
            self.assertTrue(
                qianwen_physicalizer.QianwenPhysicalizer._verify_module(
                    r"C:\Program Files\QianwenIME\QianwenIMEUiClient.exe"
                )
            )
            self.assertFalse(
                qianwen_physicalizer.QianwenPhysicalizer._verify_module(
                    r"C:\Program Files\Other\QianwenIMEUiClient.exe"
                )
            )

    def test_start_attaches_only_after_module_verification(self):
        script = mock.Mock()
        session = mock.Mock()
        session.create_script.return_value = script
        process = types.SimpleNamespace(pid=9732, name="QianwenIMEUiClient.exe")
        device = mock.Mock()
        device.enumerate_processes.return_value = [process]
        fake_frida = types.SimpleNamespace(
            get_local_device=lambda: device,
            attach=mock.Mock(return_value=session),
        )
        physicalizer = qianwen_physicalizer.QianwenPhysicalizer()
        def load_with_ready():
            callback = script.on.call_args.args[1]
            callback(
                {"type": "send", "payload": {"type": "ready", "callback": "0x1"}},
                None,
            )

        script.load.side_effect = load_with_ready
        with mock.patch.object(
            qianwen_physicalizer.sys, "platform", "win32"
        ), mock.patch.dict(sys.modules, {"frida": fake_frida}), mock.patch.object(
            physicalizer,
            "_probe_module",
            return_value=r"C:\Program Files\QianwenIME\QianwenIMEUiClient.exe",
        ), mock.patch.object(physicalizer, "_verify_module", return_value=True):
            self.assertTrue(physicalizer.start())

        self.assertEqual(physicalizer.status, "active")
        script.on.assert_called_once_with("message", physicalizer._on_script_message)
        script.load.assert_called_once()
        fake_frida.attach.assert_called_once_with(9732)
        physicalizer.stop()

    def test_script_error_fails_closed_instead_of_reporting_active(self):
        script = mock.Mock()
        session = mock.Mock()
        session.create_script.return_value = script
        process = types.SimpleNamespace(pid=9732, name="QianwenIMEUiClient.exe")
        device = mock.Mock()
        device.enumerate_processes.return_value = [process]
        fake_frida = types.SimpleNamespace(
            get_local_device=lambda: device,
            attach=mock.Mock(return_value=session),
        )
        physicalizer = qianwen_physicalizer.QianwenPhysicalizer()

        def load_with_error():
            callback = script.on.call_args.args[1]
            callback({"type": "error", "description": "cannot intercept"}, None)

        script.load.side_effect = load_with_error
        with mock.patch.object(
            qianwen_physicalizer.sys, "platform", "win32"
        ), mock.patch.dict(sys.modules, {"frida": fake_frida}), mock.patch.object(
            physicalizer,
            "_probe_module",
            return_value=r"C:\Program Files\QianwenIME\QianwenIMEUiClient.exe",
        ), mock.patch.object(physicalizer, "_verify_module", return_value=True):
            self.assertFalse(physicalizer.start())

        self.assertEqual(physicalizer.status, "unavailable")
        self.assertIn("cannot intercept", physicalizer.error or "")

    def test_missing_qianwen_ui_is_a_clean_failure(self):
        device = mock.Mock()
        device.enumerate_processes.return_value = []
        fake_frida = types.SimpleNamespace(get_local_device=lambda: device)
        physicalizer = qianwen_physicalizer.QianwenPhysicalizer()
        with mock.patch.object(
            qianwen_physicalizer.sys, "platform", "win32"
        ), mock.patch.dict(sys.modules, {"frida": fake_frida}):
            self.assertFalse(physicalizer.start())

        self.assertEqual(physicalizer.status, "unavailable")
        self.assertIn("not running", physicalizer.error or "")


if __name__ == "__main__":
    unittest.main()
