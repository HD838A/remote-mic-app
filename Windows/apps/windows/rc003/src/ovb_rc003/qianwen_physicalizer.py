"""Version-locked Qianwen voice-shortcut input adapter.

QianwenIMEUiClient runs elevated and evaluates ``KBDLLHOOKSTRUCT`` inside its
own low-level keyboard callback.  Global hook mutation and ordinary generated
Right-Alt input do not cross that boundary.  This optional adapter attaches
only to the exact installed executable/PDB build verified during development
and clears the injected flags only for RemoteMic-marked Right-Alt events.

It never modifies the signed executable on disk.  A path, hash, process,
privilege or attach mismatch fails closed.
"""

from __future__ import annotations

import hashlib
import logging
import sys
import threading
from pathlib import Path
from typing import Any, Optional


_PROCESS_NAME = "QianwenIMEUiClient.exe"
# The installed EXE's SetWindowsHookExW(WH_KEYBOARD_LL, ...) call loads this
# callback address directly. The adjacent code verifies Right Alt (0xA5).
# The separately shipped PDB does not match this EXE's runtime layout.
_CALLBACK_RVA = 0x85684
_EXE_SHA256 = "2ef313df4fce58b067a0b4751e47c1ce547dd25b35891efdc55ba397c6ae1b56"
_REMOTE_MIC_MARKER = "0x524d494352433033"
_LOGGER = logging.getLogger("ovb_rc003")

_PHYSICALIZER_SOURCE = rf"""
const module = Process.getModuleByName('{_PROCESS_NAME}');
const callback = module.base.add(0x{_CALLBACK_RVA:x});
const remoteMicMarker = uint64('{_REMOTE_MIC_MARKER}');
Interceptor.attach(callback, {{
  onEnter(args) {{
    if (args[0].toInt32() < 0) return;
    const event = args[2];
    const vk = event.readU32();
    const flags = event.add(8).readU32();
    const extraInfo = event.add(16).readU64();
    if (vk !== 0xA5) return;
    const marked = (flags & 0x10) !== 0 && extraInfo.equals(remoteMicMarker);
    send({{
      type: 'ralt_event',
      flags: flags,
      extra_info: extraInfo.toString(),
      marked: marked
    }});
    if (marked) {{
      event.add(8).writeU32(flags & ~0x12);
      event.add(16).writeU64(0);
    }}
  }}
}});
send({{type: 'ready', callback: callback.toString()}});
"""


class QianwenPhysicalizer:
    """Own the verified Frida session inside Qianwen's keyboard callback."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._session = None
        self._script = None
        self._status = "not_started"
        self._error: Optional[str] = None
        self._script_ready = threading.Event()
        self._script_error: Optional[str] = None

    @property
    def status(self) -> str:
        with self._lock:
            return self._status

    @property
    def error(self) -> Optional[str]:
        with self._lock:
            return self._error

    def _set_failure(self, error: BaseException | str) -> bool:
        self._status = "unavailable"
        self._error = str(error)
        return False

    @staticmethod
    def _module_probe_source() -> str:
        return (
            f"const module = Process.getModuleByName('{_PROCESS_NAME}');"
            "send({type: 'module', path: module.path, size: module.size});"
        )

    @staticmethod
    def _verify_module(path: str) -> bool:
        try:
            module_path = Path(path)
            if module_path.name.casefold() != _PROCESS_NAME.casefold():
                return False
            if module_path.parent.name.casefold() != "qianwenime":
                return False
            digest = hashlib.sha256(module_path.read_bytes()).hexdigest()
        except OSError:
            return False
        return digest == _EXE_SHA256

    def _probe_module(self, session: Any) -> Optional[str]:
        info: dict[str, Any] = {}
        ready = threading.Event()

        def on_message(message: dict[str, Any], _data: Any) -> None:
            if message.get("type") == "send":
                payload = message.get("payload") or {}
                if payload.get("type") == "module":
                    info.update(payload)
                    ready.set()
            elif message.get("type") == "error":
                ready.set()

        probe = session.create_script(self._module_probe_source())
        probe.on("message", on_message)
        try:
            probe.load()
            if not ready.wait(2.0):
                return None
            path = info.get("path")
            return str(path) if path else None
        finally:
            try:
                probe.unload()
            except Exception:
                pass

    def _on_script_message(self, message: dict[str, Any], _data: Any) -> None:
        if message.get("type") == "send":
            payload = message.get("payload") or {}
            if payload.get("type") == "ready":
                _LOGGER.info(
                    "Qianwen physicalizer callback attached: %s",
                    payload.get("callback", "unknown"),
                )
                self._script_ready.set()
            elif payload.get("type") == "ralt_event":
                _LOGGER.info(
                    "Qianwen callback observed right-Alt: flags=0x%x "
                    "extra_info=%s remotemic_marked=%s",
                    int(payload.get("flags", 0)),
                    payload.get("extra_info", "unknown"),
                    bool(payload.get("marked")),
                )
        elif message.get("type") == "error":
            self._script_error = str(
                message.get("description") or message.get("stack") or message
            )
            self._script_ready.set()
            _LOGGER.error(
                "Qianwen physicalizer script error: %s",
                self._script_error,
            )

    def start(self) -> bool:
        with self._lock:
            if self._script is not None and self._session is not None:
                return True
            self._status = "starting"
            self._error = None
            if sys.platform != "win32":
                return self._set_failure("Qianwen physicalizer is Windows-only")
            try:
                import frida  # type: ignore[import-not-found]
            except ImportError:
                return self._set_failure("Python frida package is not installed")

            try:
                device = frida.get_local_device()
                candidates = [
                    process
                    for process in device.enumerate_processes()
                    if str(process.name).casefold() == _PROCESS_NAME.casefold()
                ]
                if not candidates:
                    return self._set_failure(f"{_PROCESS_NAME} is not running")
                last_error: Optional[BaseException] = None
                for process in candidates:
                    session = None
                    try:
                        session = frida.attach(process.pid)
                        module_path = self._probe_module(session)
                        if not module_path or not self._verify_module(module_path):
                            raise RuntimeError(
                                "Qianwen UI path or SHA-256 does not match the verified build"
                            )
                        script = session.create_script(_PHYSICALIZER_SOURCE)
                        self._script_ready.clear()
                        self._script_error = None
                        script.on("message", self._on_script_message)
                        script.load()
                        if not self._script_ready.wait(2.0):
                            raise RuntimeError(
                                "Qianwen callback adapter did not report ready"
                            )
                        if self._script_error:
                            raise RuntimeError(self._script_error)
                        self._session = session
                        self._script = script
                        self._status = "active"
                        return True
                    except BaseException as exc:  # noqa: BLE001 - optional boundary
                        last_error = exc
                        if session is not None:
                            try:
                                session.detach()
                            except Exception:
                                pass
                return self._set_failure(last_error or "could not attach to Qianwen UI")
            except BaseException as exc:  # noqa: BLE001 - optional boundary
                return self._set_failure(exc)

    def stop(self) -> None:
        with self._lock:
            script, session = self._script, self._session
            self._script = None
            self._session = None
            self._status = "stopped"
            if script is not None:
                try:
                    script.unload()
                except Exception:
                    pass
            if session is not None:
                try:
                    session.detach()
                except Exception:
                    pass


_physicalizer = QianwenPhysicalizer()


def start_physicalizer() -> bool:
    return _physicalizer.start()


def stop_physicalizer() -> None:
    _physicalizer.stop()


def physicalizer_status() -> str:
    return _physicalizer.status


def physicalizer_error() -> Optional[str]:
    return _physicalizer.error
