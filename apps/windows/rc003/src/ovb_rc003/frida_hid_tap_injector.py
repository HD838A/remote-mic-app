"""Narrowly-scoped x64 DLL injector for the RC003 WUDF host.

This is adapted from remote-bridge-hub's Xiaomi injector.  Injection is only
attempted from a process the user has explicitly started with administrator
rights.  The normal Remote Mic process never elevates itself.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path

from .frida_hid_tap_runtime import (
    GADGET_DLL_SHA256,
    find_rc003_hidogatt_host_pid,
    prepare_secure_runtime,
    sha256_file,
)


PROCESS_CREATE_THREAD = 0x0002
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_OPERATION = 0x0008
PROCESS_VM_WRITE = 0x0020
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
MEM_RESERVE = 0x2000
MEM_RELEASE = 0x8000
PAGE_READWRITE = 0x04
WAIT_OBJECT_0 = 0
TOKEN_ADJUST_PRIVILEGES = 0x0020
TOKEN_QUERY = 0x0008
SE_PRIVILEGE_ENABLED = 0x00000002
ERROR_NOT_ALL_ASSIGNED = 1300


class LUID(ctypes.Structure):
    _fields_ = (("LowPart", wintypes.DWORD), ("HighPart", wintypes.LONG))


class LUID_AND_ATTRIBUTES(ctypes.Structure):
    _fields_ = (("Luid", LUID), ("Attributes", wintypes.DWORD))


class TOKEN_PRIVILEGES(ctypes.Structure):
    _fields_ = (
        ("PrivilegeCount", wintypes.DWORD),
        ("Privileges", LUID_AND_ATTRIBUTES * 1),
    )


def enable_debug_privilege() -> None:
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetCurrentProcess.argtypes = ()
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    advapi32.OpenProcessToken.argtypes = (
        wintypes.HANDLE,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.HANDLE),
    )
    advapi32.OpenProcessToken.restype = wintypes.BOOL
    advapi32.LookupPrivilegeValueW.argtypes = (
        wintypes.LPCWSTR,
        wintypes.LPCWSTR,
        ctypes.POINTER(LUID),
    )
    advapi32.LookupPrivilegeValueW.restype = wintypes.BOOL
    advapi32.AdjustTokenPrivileges.argtypes = (
        wintypes.HANDLE,
        wintypes.BOOL,
        ctypes.POINTER(TOKEN_PRIVILEGES),
        wintypes.DWORD,
        ctypes.c_void_p,
        ctypes.c_void_p,
    )
    advapi32.AdjustTokenPrivileges.restype = wintypes.BOOL

    token = wintypes.HANDLE()
    if not advapi32.OpenProcessToken(
        kernel32.GetCurrentProcess(),
        TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
        ctypes.byref(token),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        luid = LUID()
        if not advapi32.LookupPrivilegeValueW(
            None, "SeDebugPrivilege", ctypes.byref(luid)
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        privileges = TOKEN_PRIVILEGES()
        privileges.PrivilegeCount = 1
        privileges.Privileges[0].Luid = luid
        privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED
        ctypes.set_last_error(0)
        if not advapi32.AdjustTokenPrivileges(
            token, False, ctypes.byref(privileges), 0, None, None
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        error = ctypes.get_last_error()
        if error == ERROR_NOT_ALL_ASSIGNED:
            raise PermissionError("SeDebugPrivilege is not assigned")
        if error:
            raise ctypes.WinError(error)
    finally:
        kernel32.CloseHandle(token)


def inject_library(pid: int, dll_path: Path) -> None:
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.VirtualAllocEx.argtypes = (
        wintypes.HANDLE,
        wintypes.LPVOID,
        ctypes.c_size_t,
        wintypes.DWORD,
        wintypes.DWORD,
    )
    kernel32.VirtualAllocEx.restype = wintypes.LPVOID
    kernel32.WriteProcessMemory.argtypes = (
        wintypes.HANDLE,
        wintypes.LPVOID,
        wintypes.LPCVOID,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    )
    kernel32.WriteProcessMemory.restype = wintypes.BOOL
    kernel32.VirtualFreeEx.argtypes = (
        wintypes.HANDLE,
        wintypes.LPVOID,
        ctypes.c_size_t,
        wintypes.DWORD,
    )
    kernel32.VirtualFreeEx.restype = wintypes.BOOL
    kernel32.GetModuleHandleW.argtypes = (wintypes.LPCWSTR,)
    kernel32.GetModuleHandleW.restype = wintypes.HMODULE
    kernel32.GetProcAddress.argtypes = (wintypes.HMODULE, wintypes.LPCSTR)
    kernel32.GetProcAddress.restype = wintypes.LPVOID
    kernel32.CreateRemoteThread.argtypes = (
        wintypes.HANDLE,
        wintypes.LPVOID,
        ctypes.c_size_t,
        wintypes.LPVOID,
        wintypes.LPVOID,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
    )
    kernel32.CreateRemoteThread.restype = wintypes.HANDLE
    kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.GetExitCodeThread.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.DWORD),
    )
    kernel32.GetExitCodeThread.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL

    rights = (
        PROCESS_CREATE_THREAD
        | PROCESS_QUERY_INFORMATION
        | PROCESS_VM_OPERATION
        | PROCESS_VM_WRITE
        | PROCESS_VM_READ
    )
    process = kernel32.OpenProcess(rights, False, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    remote_path = None
    thread = None
    try:
        encoded = (str(dll_path.resolve()) + "\0").encode("utf-16-le")
        remote_path = kernel32.VirtualAllocEx(
            process, None, len(encoded), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE
        )
        if not remote_path:
            raise ctypes.WinError(ctypes.get_last_error())
        buffer = ctypes.create_string_buffer(encoded)
        written = ctypes.c_size_t()
        if not kernel32.WriteProcessMemory(
            process, remote_path, buffer, len(encoded), ctypes.byref(written)
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        if written.value != len(encoded):
            raise RuntimeError(f"partial remote write: {written.value}/{len(encoded)}")
        kernel = kernel32.GetModuleHandleW("kernel32.dll")
        load_library = kernel32.GetProcAddress(kernel, b"LoadLibraryW")
        if not load_library:
            raise ctypes.WinError(ctypes.get_last_error())
        thread_id = wintypes.DWORD()
        thread = kernel32.CreateRemoteThread(
            process,
            None,
            0,
            load_library,
            remote_path,
            0,
            ctypes.byref(thread_id),
        )
        if not thread:
            raise ctypes.WinError(ctypes.get_last_error())
        if kernel32.WaitForSingleObject(thread, 20_000) != WAIT_OBJECT_0:
            raise TimeoutError("remote LoadLibraryW timed out")
        exit_code = wintypes.DWORD()
        if not kernel32.GetExitCodeThread(thread, ctypes.byref(exit_code)):
            raise ctypes.WinError(ctypes.get_last_error())
        if exit_code.value == 0:
            raise RuntimeError("remote LoadLibraryW returned NULL")
    finally:
        if thread:
            kernel32.CloseHandle(thread)
        if remote_path:
            kernel32.VirtualFreeEx(process, remote_path, 0, MEM_RELEASE)
        kernel32.CloseHandle(process)


def _target_process_name(pid: int) -> str:
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.QueryFullProcessImageNameW.argtypes = (
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.LPWSTR,
        ctypes.POINTER(wintypes.DWORD),
    )
    kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    process = kernel32.OpenProcess(0x1000, False, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        buffer = ctypes.create_unicode_buffer(32768)
        length = wintypes.DWORD(len(buffer))
        if not kernel32.QueryFullProcessImageNameW(
            process, 0, buffer, ctypes.byref(length)
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        return Path(buffer.value[: length.value]).name.casefold()
    finally:
        kernel32.CloseHandle(process)


def inject_current_process(pid: int) -> None:
    """Inject only when this process already has the required rights.

    The application deliberately does not request elevation.  Callers that
    want the optional tap must launch the bridge explicitly from an elevated
    terminal or executable.
    """

    if os.name != "nt":
        raise PermissionError("RC003 injector requires Windows administrator elevation")
    expected_pid = find_rc003_hidogatt_host_pid()
    if expected_pid != pid:
        raise RuntimeError(
            f"RC003 host changed before injection: expected={expected_pid} requested={pid}"
        )
    if _target_process_name(pid) != "wudfhost.exe":
        raise RuntimeError("refusing non-WUDFHost target")
    dll_path = prepare_secure_runtime()
    dll_hash = sha256_file(dll_path)
    if dll_hash != GADGET_DLL_SHA256:
        raise RuntimeError(f"verified Gadget changed before injection: {dll_hash}")
    enable_debug_privilege()
    inject_library(pid, dll_path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--pid", type=int, required=True)
    args = parser.parse_args(argv)
    inject_current_process(args.pid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
