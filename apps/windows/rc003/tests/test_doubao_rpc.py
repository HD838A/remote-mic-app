import ctypes
import sys
import types
import unittest
from unittest import mock

from ovb_rc003 import doubao_rpc


class _FakeFunction:
    def __init__(self, result=0):
        self.result = result
        self.calls = []
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        self.calls.append(args)
        return self.result


class _FakeLibrary:
    def __init__(self, result=0):
        self.RpcPipe_KeyDown = _FakeFunction(result)
        self.RpcPipe_KeyUp = _FakeFunction(result)


class DoubaoRpcTests(unittest.TestCase):
    def tearDown(self):
        doubao_rpc.clear_cached_api()

    def test_key_down_configures_native_abi_and_passes_endpoint(self):
        library = _FakeLibrary()
        with mock.patch.object(
            doubao_rpc.sys, "platform", "win32"
        ), mock.patch.object(
            doubao_rpc.os.path, "isfile", return_value=True
        ), mock.patch.object(
            doubao_rpc.ctypes, "WinDLL", return_value=library
        ):
            doubao_rpc.send_key_edge(0xA5, False)

        self.assertEqual(
            library.RpcPipe_KeyDown.calls,
            [(b"\\\\.\\pipe\\ObricIme\\oime-server", 0xA5, 0, None)],
        )
        self.assertEqual(
            library.RpcPipe_KeyDown.argtypes,
            (ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_char_p),
        )

    def test_key_up_uses_reverse_edge_without_context_arguments(self):
        library = _FakeLibrary()
        with mock.patch.object(
            doubao_rpc,
            "_load_api",
            return_value=(library.RpcPipe_KeyDown, library.RpcPipe_KeyUp),
        ):
            doubao_rpc.send_key_edge(0xA5, True)

        self.assertEqual(
            library.RpcPipe_KeyUp.calls,
            [(b"\\\\.\\pipe\\ObricIme\\oime-server", 0xA5)],
        )

    def test_nonzero_status_is_a_call_error(self):
        library = _FakeLibrary(result=5)
        with mock.patch.object(
            doubao_rpc,
            "_load_api",
            return_value=(library.RpcPipe_KeyDown, library.RpcPipe_KeyUp),
        ):
            with self.assertRaises(doubao_rpc.DoubaoRpcCallError):
                doubao_rpc.send_key_edge(0xA5, False)

    def test_missing_rpc_is_distinguishable_from_call_failure(self):
        with mock.patch.object(
            doubao_rpc,
            "_load_api",
            side_effect=doubao_rpc.DoubaoRpcUnavailableError("not installed"),
        ):
            with self.assertRaises(doubao_rpc.DoubaoRpcUnavailableError):
                doubao_rpc.send_key_edge(0xA5, False)


class DoubaoPhysicalizerTests(unittest.TestCase):
    def test_script_only_clears_marked_right_alt_in_doubao_callback(self):
        source = doubao_rpc._PHYSICALIZER_SOURCE

        self.assertIn("vk === 0xA5", source)
        self.assertIn("flags & 0x10", source)
        self.assertIn("flags & ~0x12", source)
        self.assertIn("event.add(16).writeU64(0)", source)

    def test_verified_module_requires_the_installed_doubao_path_and_hash(self):
        with mock.patch.object(
            doubao_rpc.hashlib,
            "sha256",
            return_value=mock.Mock(
                hexdigest=lambda: doubao_rpc._IME_SERVICE_SHA256
            ),
        ), mock.patch.object(doubao_rpc.Path, "read_bytes", return_value=b"verified"):
            self.assertTrue(
                doubao_rpc.DoubaoPhysicalizer._verify_module(
                    r"C:\Program Files\DoubaoIME\ImeService.exe"
                )
            )
            self.assertFalse(
                doubao_rpc.DoubaoPhysicalizer._verify_module(
                    r"C:\Program Files\Other\ImeService.exe"
                )
            )

    def test_start_attaches_only_after_module_verification(self):
        script = mock.Mock()
        session = mock.Mock()
        session.create_script.return_value = script
        process = types.SimpleNamespace(pid=46500, name="ImeService.exe")
        device = mock.Mock()
        device.enumerate_processes.return_value = [process]
        fake_frida = types.SimpleNamespace(
            get_local_device=lambda: device,
            attach=mock.Mock(return_value=session),
        )
        physicalizer = doubao_rpc.DoubaoPhysicalizer()
        with mock.patch.object(doubao_rpc.sys, "platform", "win32"), mock.patch.dict(
            sys.modules, {"frida": fake_frida}
        ), mock.patch.object(
            physicalizer,
            "_probe_module",
            return_value=r"C:\Program Files\DoubaoIME\ImeService.exe",
        ), mock.patch.object(
            physicalizer, "_verify_module", return_value=True
        ):
            self.assertTrue(physicalizer.start())

        self.assertEqual(physicalizer.status, "active")
        script.load.assert_called_once()
        fake_frida.attach.assert_called_once_with(46500)
        physicalizer.stop()
        script.unload.assert_called_once()
        session.detach.assert_called_once()

    def test_missing_ime_process_is_a_clean_optional_failure(self):
        device = mock.Mock()
        device.enumerate_processes.return_value = []
        fake_frida = types.SimpleNamespace(get_local_device=lambda: device)
        physicalizer = doubao_rpc.DoubaoPhysicalizer()
        with mock.patch.object(doubao_rpc.sys, "platform", "win32"), mock.patch.dict(
            sys.modules, {"frida": fake_frida}
        ):
            self.assertFalse(physicalizer.start())

        self.assertEqual(physicalizer.status, "unavailable")
        self.assertIn("not running", physicalizer.error or "")


if __name__ == "__main__":
    unittest.main()
