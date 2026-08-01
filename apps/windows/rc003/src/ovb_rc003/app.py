"""只承载 RC003 BLE 麦克风链路的 Windows 桥接进程。"""

from __future__ import annotations

import asyncio
import logging
import threading
from typing import Any, Callable, Mapping, Optional

from . import atvv_session, audio_output, audio_playback, ble_transport_winrt, identity
from .connection_supervisor import ConnectionSupervisor


class RC003VoiceBridge:
    """把 RC003 ATVV 音频写入用户明确选择的 Windows 播放端点。"""

    def __init__(
        self,
        settings: Mapping[str, Any],
        *,
        logger: Optional[logging.Logger] = None,
        discover_candidates_fn: Callable[..., Any] = ble_transport_winrt.discover_candidates,
        session_factory: Callable[..., Any] = ble_transport_winrt.RC003BleSession,
        enumerate_output_fn: Callable[[], list[audio_output.AudioEndpoint]] = (
            audio_output.enumerate_output_endpoints
        ),
        playback_factory: Callable[..., Any] = audio_playback.EndpointPlaybackSink,
        loop: Optional[asyncio.AbstractEventLoop] = None,
    ) -> None:
        self._settings = dict(settings)
        self._logger = logger or logging.getLogger("remote_mic_rc003")
        self._discover_candidates = discover_candidates_fn
        self._session_factory = session_factory
        self._enumerate_output = enumerate_output_fn
        self._playback_factory = playback_factory
        self._loop = loop or asyncio.get_event_loop()
        self._ble_session: Any = None
        self._playback: Any = None
        self._playback_lock = threading.RLock()
        self._supervisor = ConnectionSupervisor(
            connect=self._connect_once,
            cleanup=self._cleanup_once,
            retry_delay=float(self._settings["retry_delay"]),
            max_retry_delay=float(self._settings["max_retry_delay"]),
            logger=self._logger,
            loop=self._loop,
        )

    async def run_forever(self) -> None:
        await self._supervisor.run_forever()

    async def stop(self) -> None:
        await self._supervisor.stop()

    async def _connect_once(self) -> None:
        endpoints = self._enumerate_output()
        audio_output.resolve_selected_endpoint(
            endpoints,
            self._settings.get("output_endpoint_name"),
            self._settings.get("output_endpoint_host_api"),
        )
        candidates = await self._discover_candidates()
        candidate = identity.select_single_candidate(candidates)
        self._ble_session = self._session_factory(
            on_pcm_frame=self._on_pcm_frame,
            on_control_event=self._on_control_event,
            on_error=self._on_session_error,
            on_disconnected=self._on_disconnected,
            gain_db=float(self._settings["gain_db"]),
            loop=self._loop,
        )
        await self._ble_session.connect(candidate)
        self._logger.info("RC003 已连接，等待麦克风键")

    async def _cleanup_once(self) -> None:
        failures: list[str] = []
        session = self._ble_session
        if session is not None:
            try:
                await session.close()
                if self._ble_session is session:
                    self._ble_session = None
            except Exception as exc:  # noqa: BLE001 - cleanup must continue
                failures.append(f"BLE cleanup: {type(exc).__name__}")
                self._logger.exception("关闭 BLE 会话失败")
        try:
            self._close_playback()
        except Exception as exc:  # noqa: BLE001
            failures.append(f"audio cleanup: {type(exc).__name__}")
            self._logger.exception("关闭音频输出失败")
        if failures:
            raise RuntimeError("；".join(failures))

    def _open_playback(self) -> bool:
        with self._playback_lock:
            if self._playback is not None:
                return True
            sink = None
            try:
                endpoints = self._enumerate_output()
                selected = audio_output.resolve_selected_endpoint(
                    endpoints,
                    self._settings.get("output_endpoint_name"),
                    self._settings.get("output_endpoint_host_api"),
                )
                sink = self._playback_factory(selected.name, selected.host_api)
                sink.open()
                self._playback = sink
                self._logger.info(
                    "音频输出已打开：%s / %s", selected.host_api, selected.name
                )
                return True
            except Exception:  # noqa: BLE001 - voice fails closed
                self._logger.exception("无法打开已选择的音频输出，语音会话已阻止")
                if sink is not None:
                    try:
                        sink.close()
                    except Exception:  # noqa: BLE001 - retain no live local owner
                        self._logger.exception("清理未成功打开的音频输出失败")
                return False

    def _close_playback(self) -> None:
        with self._playback_lock:
            sink = self._playback
            if sink is None:
                return
            sink.close()
            self._playback = None

    def _on_control_event(self, event: object) -> None:
        if isinstance(event, atvv_session.CapsReceived):
            caps = event.capabilities
            self._logger.info(
                "ATVV 能力：version=0x%04x sample_rate=%s frame_size=%s",
                caps.version,
                caps.sample_rate,
                caps.frame_size,
            )
        elif isinstance(event, atvv_session.MicButtonPressed):
            if self._open_playback() and self._ble_session is not None:
                self._ble_session.send_mic_open_threadsafe()
        elif isinstance(event, atvv_session.AudioStarted):
            if not self._open_playback():
                self._supervisor.request_reconnect()
        elif isinstance(event, atvv_session.AudioStopped):
            try:
                self._close_playback()
            except Exception:  # noqa: BLE001
                self._logger.exception("语音结束后关闭音频输出失败")
                self._supervisor.request_reconnect()

    def _on_pcm_frame(self, samples: list[int]) -> None:
        if not self._open_playback():
            self._supervisor.request_reconnect()
            return
        try:
            with self._playback_lock:
                if self._playback is None:
                    return
                self._playback.write(samples)
        except Exception:  # noqa: BLE001 - reconnect from a clean state
            self._logger.exception("写入音频输出失败，准备重连")
            try:
                self._close_playback()
            except Exception:  # noqa: BLE001
                self._logger.exception("清理失败的音频输出时再次出错")
            self._supervisor.request_reconnect()

    def _on_disconnected(self) -> None:
        self._logger.info("RC003 已断开，准备重连")
        self._supervisor.request_reconnect()

    def _on_session_error(self, exc: BaseException) -> None:
        self._logger.info("ATVV 会话错误，准备重连：%s", exc)
        self._supervisor.request_reconnect()
