"""Cross-platform regression test for XRBM-018 RETRY 1 P1 #1: two Win32
calls declared ``POINTER(Struct)`` argtypes but were invoked with
``ctypes.byref(array)`` instead of the array itself.

With ``argtypes`` enabled, ctypes performs real argument-type checking: a
``POINTER(Struct)`` parameter accepts a ``Struct`` array directly (the array
decays to a pointer to its first element, exactly like a C array does), but
rejects ``ctypes.byref(array)`` - ``byref()`` of an *array* produces a
pointer to the array *object* (ctypes' ``LP_Struct_Array_N``), a distinct,
incompatible pointer type from ``LP_Struct``, and ctypes raises
``ArgumentError`` before any real call happens.

This does not need ``ctypes.windll`` (Windows-only) at all - only
``ctypes.CFUNCTYPE`` and the exact real production struct/argtypes, which
work identically on any host. This is exactly the reproduction the round-1
independent review used to find the bug (see
XRBM-018's independent review); it's captured here as a standing
regression test so it doesn't have to be rediscovered by a Windows CI
failure again, and so this project isn't solely dependent on a Windows
runner to catch this bug class.
"""

import ctypes
import unittest
from ctypes import wintypes

from ovb_rc003 import raw_input_windows, win32_input


class SendInputInputArrayArgtypeTests(unittest.TestCase):
    """Mirrors win32_input.py's real ``SendInput`` argtypes:
    ``(UINT, POINTER(INPUT), c_int) -> UINT``.
    """

    def _stub_type(self):
        return ctypes.CFUNCTYPE(
            ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(win32_input.INPUT), ctypes.c_int
        )

    def test_the_real_build_input_array_output_is_accepted_directly(self):
        array, input_type = win32_input._build_input_array([(0x41, False), (0x41, True)])
        self.assertIs(input_type, win32_input.INPUT)

        received = {}

        def _impl(count, pointer, size):
            received["count"] = count
            received["first_type"] = pointer[0].type
            received["size"] = size
            return count

        stub = self._stub_type()(_impl)

        # This is exactly the call shape _real_send_input_batch() now uses:
        # the array itself, never ctypes.byref(array).
        sent = stub(len(array), array, ctypes.sizeof(input_type))

        self.assertEqual(sent, 2)
        self.assertEqual(received["count"], 2)
        self.assertEqual(received["size"], 40)  # sizeof(INPUT) on x64

    def test_byref_of_the_array_is_rejected_by_argtypes(self):
        array, input_type = win32_input._build_input_array([(0x41, False)])
        stub = self._stub_type()(lambda count, pointer, size: count)

        with self.assertRaises(ctypes.ArgumentError):
            stub(len(array), ctypes.byref(array), ctypes.sizeof(input_type))


class GetRawInputDeviceListArrayArgtypeTests(unittest.TestCase):
    """Mirrors raw_input_windows.py's real ``GetRawInputDeviceList``
    argtypes: ``(POINTER(RAWINPUTDEVICELIST), POINTER(UINT), UINT) -> UINT``.
    """

    def _stub_type(self):
        return ctypes.CFUNCTYPE(
            ctypes.c_uint,
            ctypes.POINTER(raw_input_windows.RAWINPUTDEVICELIST),
            ctypes.POINTER(wintypes.UINT),
            wintypes.UINT,
        )

    def test_the_real_device_list_array_type_is_accepted_directly(self):
        array = (raw_input_windows.RAWINPUTDEVICELIST * 3)()
        count = wintypes.UINT(0)

        received = {}

        def _impl(pointer, count_pointer, size):
            received["size"] = size
            return 3

        stub = self._stub_type()(_impl)

        # This is exactly the call shape enumerate_matching_device_paths()
        # now uses for the fill pass: the array itself, never
        # ctypes.byref(device_list) - byref(count) (a scalar UINT, not an
        # array) remains correct and unchanged.
        written = stub(
            array, ctypes.byref(count), ctypes.sizeof(raw_input_windows.RAWINPUTDEVICELIST)
        )

        self.assertEqual(written, 3)
        self.assertEqual(received["size"], ctypes.sizeof(raw_input_windows.RAWINPUTDEVICELIST))

    def test_byref_of_the_device_list_array_is_rejected_by_argtypes(self):
        array = (raw_input_windows.RAWINPUTDEVICELIST * 3)()
        count = wintypes.UINT(0)
        stub = self._stub_type()(lambda pointer, count_pointer, size: 0)

        with self.assertRaises(ctypes.ArgumentError):
            stub(
                ctypes.byref(array),
                ctypes.byref(count),
                ctypes.sizeof(raw_input_windows.RAWINPUTDEVICELIST),
            )

    def test_byref_of_the_scalar_count_is_still_correct(self):
        # Sanity check that this fix is specific to *arrays*: byref() of a
        # single scalar instance (UINT here, matching the real "count" out-
        # parameter) is the correct, unaffected usage - this must keep
        # working exactly as before.
        array = (raw_input_windows.RAWINPUTDEVICELIST * 1)()
        count = wintypes.UINT(0)

        def _impl(pointer, count_pointer, size):
            count_pointer[0] = 7
            return 1

        stub = self._stub_type()(_impl)
        written = stub(
            array, ctypes.byref(count), ctypes.sizeof(raw_input_windows.RAWINPUTDEVICELIST)
        )

        self.assertEqual(written, 1)
        self.assertEqual(count.value, 7)


class PostMessageWArgtypeTests(unittest.TestCase):
    """XRBM-019 P1 #1: ``PostMessageW`` was the one remaining Win32 window-
    handle call ``raw_input_windows.py`` invoked without ever declaring an
    explicit ctypes prototype (see XRBM-018's independent review
    round 2 finding #1). Python's ctypes documentation states that an
    unprototyped foreign-function argument is passed using the platform
    default C ``int`` - 32-bit, even on 64-bit Windows - which can
    truncate/mask a real x64 window handle before it ever reaches Windows.

    XRBM-019 review round 1 P1 #2: the previous version of this test
    reproduced the failure using ``ctypes.CDLL(None).labs`` - the current
    process image's own symbol table. That is not a Windows-portable
    regression: ``CDLL(None)`` on Windows does not guarantee any particular
    C-runtime export surface, and Windows' LLP64 model keeps C ``long`` at
    32 bits regardless of prototyping, so ``labs`` was also the wrong typed
    function for a pointer-sized round-trip claim in the first place. This
    now reproduces the identical failure-mode CLASS - a C parameter type too
    narrow for a real 64-bit handle silently masks it to the low 32 bits,
    no exception, no warning - with a deterministic, injected ``CFUNCTYPE``
    stub instead: ctypes marshals a plain Python int through a declared
    ``c_int`` parameter exactly as it would marshal one through an
    undeclared/default argument (ctypes' documented unprototyped-argument
    default *is* the platform C ``int``), so this needs no real DLL symbol
    and behaves identically on every host. It then proves the fix the same
    way as before: declaring the real ``HWND``/``WPARAM``/``LPARAM``
    prototype (pointer-sized types, exactly what ``_post_close_message()``
    now declares) makes a real x64-plausible window-handle value round-trip
    exactly instead of being silently masked to its low 32 bits.
    """

    # Only a real 64-bit handle could plausibly be this large (> 2**32), so
    # any accidental 32-bit truncation is immediately observable - the low
    # 32 bits alone are a completely different, wrong value.
    _PLAUSIBLE_X64_HANDLE = 0x0000_0140_0000_1000
    _WM_CLOSE = 0x0010

    def test_a_too_narrow_parameter_type_silently_truncates_a_real_handle_value(self):
        # A deterministic, portable, injected stand-in for "no/insufficient
        # prototype" - a plain C `int` (32-bit even on 64-bit Windows) is
        # exactly what ctypes uses by default for an unprototyped argument,
        # so declaring it explicitly here reproduces the identical
        # marshaling behavior without depending on any real DLL symbol.
        stub_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int)

        def _impl(value):
            return value

        stub = stub_type(_impl)
        result = stub(self._PLAUSIBLE_X64_HANDLE)

        self.assertNotEqual(
            result, self._PLAUSIBLE_X64_HANDLE,
            "expected silent truncation, reproducing the unprototyped-call bug class",
        )
        self.assertEqual(result, self._PLAUSIBLE_X64_HANDLE & 0xFFFFFFFF)

    def test_wintypes_hwnd_wparam_lparam_are_genuinely_pointer_sized(self):
        # ctypes.wintypes picks the pointer-sized integer type for
        # WPARAM/LPARAM based on the actual host's sizeof(c_void_p) at
        # import time (c_ulong/c_long on LP64 hosts, c_ulonglong/c_longlong
        # on LLP64 hosts like real 64-bit Windows) - correct on every
        # platform, not just this test host.
        self.assertEqual(ctypes.sizeof(wintypes.HWND), ctypes.sizeof(ctypes.c_void_p))
        self.assertEqual(ctypes.sizeof(wintypes.WPARAM), ctypes.sizeof(ctypes.c_void_p))
        self.assertEqual(ctypes.sizeof(wintypes.LPARAM), ctypes.sizeof(ctypes.c_void_p))

    def test_declaring_the_real_postmessagew_prototype_round_trips_a_handle(self):
        # Mirrors PostMessageW(HWND, UINT, WPARAM, LPARAM) -> BOOL exactly -
        # the same fix _post_close_message() applies for the real call.
        stub_type = ctypes.CFUNCTYPE(
            wintypes.BOOL, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM
        )
        received = {}

        def _impl(hwnd, msg, wparam, lparam):
            received["hwnd"] = hwnd
            received["msg"] = msg
            return 1

        stub = stub_type(_impl)
        posted = stub(self._PLAUSIBLE_X64_HANDLE, self._WM_CLOSE, 0, 0)

        self.assertEqual(posted, 1)
        self.assertEqual(received["hwnd"], self._PLAUSIBLE_X64_HANDLE)
        self.assertEqual(received["msg"], self._WM_CLOSE)

    def test_post_close_message_declares_the_full_real_prototype(self):
        # Structural source check: _post_close_message must declare all
        # four parameter types plus a restype, not rely on ctypes defaults
        # for any of them - defends against a partial fix that only
        # prototypes some of PostMessageW's four parameters.
        import inspect

        source = inspect.getsource(raw_input_windows.RawInputButtonListener._post_close_message)
        self.assertIn("PostMessageW.argtypes", source)
        self.assertIn("PostMessageW.restype", source)
        for token in (
            "wintypes.HWND",
            "wintypes.UINT",
            "wintypes.WPARAM",
            "wintypes.LPARAM",
            "wintypes.BOOL",
        ):
            self.assertIn(token, source)

    def test_stop_and_abandon_failed_start_both_call_the_shared_helper(self):
        # Structural check that both stop()/failed-start paths reuse the
        # same prototyped helper (XRBM-019 In-scope item 1: "reuse... on
        # every stop/failed-start path") instead of re-declaring (or
        # forgetting to declare) the prototype independently at each call
        # site.
        import inspect

        stop_source = inspect.getsource(raw_input_windows.RawInputButtonListener.stop)
        abandon_source = inspect.getsource(
            raw_input_windows.RawInputButtonListener._abandon_failed_start
        )
        self.assertIn("self._post_close_message()", stop_source)
        self.assertIn("self._post_close_message()", abandon_source)


if __name__ == "__main__":
    unittest.main()
