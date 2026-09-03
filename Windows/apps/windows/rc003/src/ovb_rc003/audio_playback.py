"""Writes decoded ATVV PCM to the one user-selected Windows output endpoint.

Windows-only (``sounddevice``/PortAudio). Never touches the system default
device: it always opens the specific endpoint the user picked by name, and
raises immediately if that endpoint can't be opened - callers must treat
that as "voice fails closed, buttons keep working" (see audio_output.py).
"""

from __future__ import annotations

from collections import deque
import threading
import time
from typing import Deque, List, Optional

from . import audio_output

SOURCE_SAMPLE_RATE_HZ = 16000
DEFAULT_CHANNELS = 1

_DEFAULT_DRAIN_TIMEOUT_SECONDS = 0.500
_DRAIN_POLL_INTERVAL_SECONDS = 0.020
_DRAIN_STABLE_POLLS = 3  # stable for ~60 ms at the poll interval
_DEFAULT_PRIME_SECONDS = 0.150
_DEFAULT_PRIME_SETTLE_SECONDS = 0.050
_WRITER_READY_TIMEOUT_SECONDS = 0.500
_WRITER_JOIN_TIMEOUT_SECONDS = 0.500
_WRITER_BLOCK_SECONDS = 0.020
_MAX_QUEUED_AUDIO_SECONDS = 2.0


class PlaybackUnavailableError(Exception):
    pass


class EndpointPlaybackSink:
    """Opens one output stream bound to a specific, already-resolved endpoint
    and accepts decoded int16 PCM sample batches to play.

    Endpoint identity is (name, host_api) - matching audio_output.py's
    disambiguation contract - since a bare display name is not always unique
    across PortAudio host APIs (e.g. the same physical device can appear
    once under WASAPI and once under MME).
    """

    def __init__(self, endpoint_name: str, host_api: str = "") -> None:
        self._endpoint_name = endpoint_name
        self._host_api = host_api
        self._stream = None
        self._output_sample_rate_hz = SOURCE_SAMPLE_RATE_HZ
        self._output_channels = DEFAULT_CHANNELS
        self._previous_sample = 0
        self._have_previous_sample = False
        self._queue_lock = threading.Lock()
        self._queued_chunks: Deque[object] = deque()
        self._queued_frames = 0
        self._max_queued_frames = SOURCE_SAMPLE_RATE_HZ * 2
        self._continuous_writer = False
        self._writer_ready = threading.Event()
        self._writer_stop = threading.Event()
        self._writer_thread: Optional[threading.Thread] = None
        self._writer_error: Optional[BaseException] = None
        self._writer_block_frames = 320

    def open(self) -> None:
        try:
            import sounddevice as sd  # type: ignore
        except ImportError as exc:  # pragma: no cover - exercised only on Windows
            raise PlaybackUnavailableError(
                "the 'sounddevice' package is not installed"
            ) from exc

        device_index = self._resolve_device_index(sd)
        self._output_channels = self._select_output_channels(sd, device_index)
        self._output_sample_rate_hz = self._select_output_sample_rate(sd, device_index)

        self._max_queued_frames = max(
            1, int(round(self._output_sample_rate_hz * _MAX_QUEUED_AUDIO_SECONDS))
        )
        self._writer_block_frames = max(
            1, int(round(self._output_sample_rate_hz * _WRITER_BLOCK_SECONDS))
        )
        self._clear_queue()
        self._writer_ready.clear()
        self._writer_stop.clear()
        self._writer_error = None
        self._continuous_writer = True
        self._stream = sd.OutputStream(
            device=device_index,
            channels=self._output_channels,
            dtype="int16",
            samplerate=self._output_sample_rate_hz,
            latency="low",
        )
        self._stream.start()
        self._writer_thread = threading.Thread(
            target=self._writer_loop,
            name="remotemic-audio-writer",
            daemon=True,
        )
        self._writer_thread.start()
        if not self._writer_ready.wait(_WRITER_READY_TIMEOUT_SECONDS):
            self.close()
            raise PlaybackUnavailableError(
                "selected output endpoint did not start its continuous writer"
            )
        if self._writer_error is not None or not self._writer_thread.is_alive():
            error = self._writer_error
            self.close()
            raise PlaybackUnavailableError(
                f"selected output endpoint writer stopped during startup: {error}"
            )
        self._previous_sample = 0
        self._have_previous_sample = False

    @property
    def output_sample_rate_hz(self) -> int:
        return self._output_sample_rate_hz

    @property
    def output_channels(self) -> int:
        return self._output_channels

    def _select_output_channels(self, sd, device_index: int) -> int:
        """Use stereo when the endpoint supports it so virtual cables receive both channels."""
        device = sd.query_devices()[device_index]
        return 2 if int(device.get("max_output_channels") or 0) >= 2 else DEFAULT_CHANNELS

    def _select_output_sample_rate(self, sd, device_index: int) -> int:
        device = sd.query_devices()[device_index]
        preferred = int(device.get("default_samplerate") or 0)
        candidates = []
        if preferred > 0:
            candidates.append(preferred)
        candidates.extend([SOURCE_SAMPLE_RATE_HZ, 48000, 44100])

        seen = set()
        errors = []
        for sample_rate in candidates:
            if sample_rate in seen:
                continue
            seen.add(sample_rate)
            try:
                sd.check_output_settings(
                    device=device_index,
                    channels=self._output_channels,
                    dtype="int16",
                    samplerate=sample_rate,
                )
                return sample_rate
            except Exception as exc:  # pragma: no cover - exercised only on Windows
                errors.append(f"{sample_rate} Hz: {exc}")

        detail = "; ".join(errors) if errors else "no candidate sample rates available"
        raise audio_output.AudioOutputUnavailableError(
            "selected output endpoint cannot play mono int16 PCM at any supported "
            f"sample rate ({detail})"
        )

    def _resolve_device_index(self, sd) -> int:
        host_apis = sd.query_hostapis()
        candidates = []
        for index, device in enumerate(sd.query_devices()):
            if device.get("max_output_channels", 0) <= 0:
                continue
            if device["name"] != self._endpoint_name:
                continue
            host_api_name = host_apis[device["hostapi"]]["name"] if host_apis else ""
            candidates.append((index, host_api_name))

        if not candidates:
            raise audio_output.AudioOutputUnavailableError(
                f"selected output endpoint is not currently present: {self._endpoint_name!r}"
            )

        if self._host_api:
            for index, host_api_name in candidates:
                if host_api_name == self._host_api:
                    return index
            raise audio_output.AudioOutputUnavailableError(
                f"selected output endpoint {self._endpoint_name!r} is no longer present "
                f"under host API {self._host_api!r}"
            )

        if len(candidates) > 1:
            raise audio_output.AudioOutputUnavailableError(
                f"{len(candidates)} output endpoints are named {self._endpoint_name!r} "
                "across different host APIs; open settings and re-select one to disambiguate"
            )

        return candidates[0][0]

    def write(self, samples: List[int]) -> None:
        if self._stream is None:
            raise PlaybackUnavailableError("open() must be called before write()")
        import numpy as np  # type: ignore

        array = np.asarray(samples, dtype="int16").reshape(-1, 1)
        if self._output_sample_rate_hz == 48000 and len(array) > 0:
            # Match the upstream RC003 path: continuous 16 kHz -> 48 kHz
            # interpolation keeps the boundary between BLE notifications smooth.
            values = array[:, 0].astype("int32").tolist()
            previous = self._previous_sample if self._have_previous_sample else values[0]
            output = []
            for current in values:
                delta = current - previous
                output.extend(
                    (
                        previous + round(delta / 3.0),
                        previous + round(delta * (2.0 / 3.0)),
                        current,
                    )
                )
                previous = current
            self._previous_sample = values[-1]
            self._have_previous_sample = True
            array = np.asarray(output, dtype="int16").reshape(-1, 1)
        elif self._output_sample_rate_hz != SOURCE_SAMPLE_RATE_HZ and len(array) > 1:
            ratio = self._output_sample_rate_hz / SOURCE_SAMPLE_RATE_HZ
            output_length = max(1, int(round(len(array) * ratio)))
            source_positions = np.arange(len(array), dtype=np.float64)
            target_positions = np.linspace(0, len(array) - 1, output_length)
            resampled = np.interp(target_positions, source_positions, array[:, 0])
            array = np.rint(resampled).clip(-32768, 32767).astype("int16").reshape(-1, 1)
        if self._output_channels > 1:
            array = np.repeat(array, self._output_channels, axis=1)
        if self._continuous_writer:
            self._enqueue_array(array)
        else:
            # Compatibility path for focused unit fakes that predate the
            # continuous writer. Production streams always use the worker.
            self._stream.write(array)

    def _enqueue_array(self, array) -> None:
        if len(array) <= 0:
            return
        with self._queue_lock:
            if len(array) >= self._max_queued_frames:
                self._queued_chunks.clear()
                array = array[-self._max_queued_frames :]
                self._queued_frames = 0
            while (
                self._queued_chunks
                and self._queued_frames + len(array) > self._max_queued_frames
            ):
                removed = self._queued_chunks.popleft()
                self._queued_frames -= len(removed)
            self._queued_chunks.append(array)
            self._queued_frames += len(array)

    def _dequeue_into(self, outdata) -> None:
        outdata.fill(0)
        with self._queue_lock:
            copied = 0
            frames = len(outdata)
            while copied < frames and self._queued_chunks:
                chunk = self._queued_chunks[0]
                take = min(frames - copied, len(chunk))
                outdata[copied : copied + take] = chunk[:take]
                copied += take
                self._queued_frames -= take
                if take == len(chunk):
                    self._queued_chunks.popleft()
                else:
                    self._queued_chunks[0] = chunk[take:]

    def _writer_loop(self) -> None:
        """Keep the blocking PortAudio stream fed; silence prevents underrun."""

        import numpy as np  # type: ignore

        stream = self._stream
        if stream is None:
            return
        block = np.zeros(
            (self._writer_block_frames, self._output_channels), dtype="int16"
        )
        try:
            while not self._writer_stop.is_set():
                self._dequeue_into(block)
                stream.write(block)
                self._writer_ready.set()
        except Exception as exc:
            if not self._writer_stop.is_set():
                self._writer_error = exc
                self._writer_ready.set()

    def _clear_queue(self) -> None:
        with self._queue_lock:
            self._queued_chunks.clear()
            self._queued_frames = 0

    def prepare_for_session(self) -> None:
        """Ensure the continuous blocking writer is live for a new session."""

        if self._stream is None:
            self.open()
            return
        active = bool(getattr(self._stream, "active", True))
        writer_alive = self._writer_thread is not None and self._writer_thread.is_alive()
        if not active or not writer_alive or self._writer_error is not None:
            self.reopen()

    def reopen(self) -> None:
        """Replace the underlying PortAudio stream for a new voice session.

        A long-lived WASAPI stream can remain writable after a virtual cable
        route stops delivering samples.  Reopening at the session boundary
        prevents that silent stale-stream state while retaining this sink as
        the application's single playback owner.
        """

        self.close()
        self.open()

    def prime(
        self,
        duration_seconds: float = _DEFAULT_PRIME_SECONDS,
        settle_seconds: float = _DEFAULT_PRIME_SETTLE_SECONDS,
    ) -> None:
        """Warm the selected WASAPI route with silence before host capture.

        The silence is written before the dictation shortcut, so it cannot
        become transcription input.  The short settle window gives a virtual
        cable time to finish activating before the target application opens
        its recording endpoint.
        """

        if not self._continuous_writer:
            sample_count = max(1, int(round(SOURCE_SAMPLE_RATE_HZ * duration_seconds)))
            self.write([0] * sample_count)
        if settle_seconds > 0:
            time.sleep(float(settle_seconds))

    def drain(self, timeout_seconds: float = _DEFAULT_DRAIN_TIMEOUT_SECONDS) -> bool:
        """Wait for the PortAudio output buffer to empty, up to ``timeout_seconds``.

        The macOS upstream reference (``VoiceFnTapSessionController.swift`` in
        ``HD838A/remote-mic-app``) uses ``VirtualAudioOutput.endSessionAfterDraining``
        to wait for the AVAudioEngine queue to empty before sending the closing
        ``Fn`` tap, so the target application (Typeless,豆包输入法的 Fn 长按模式)
        sees the host session stay open until every buffered voice sample has
        reached CABLE Output.  On Windows, the equivalent is polling
        ``OutputStream.write_available`` until it stops decreasing.

        Returns ``True`` if the buffer drained within the timeout, ``False``
        otherwise.  ``True`` is also returned when the stream has not been
        opened yet or when the underlying API does not expose ``write_available``.
        This method never raises on a transient query failure; the worst case
        is it returns ``False`` and the caller emits the closing host edge
        immediately.

        Fix C of ``docs/decisions/ADR-0003-voice-edge-debounce-and-hook-decoupling.md``.
        """

        if self._stream is None:
            return True
        timeout_seconds = max(0.0, float(timeout_seconds))
        deadline = time.monotonic() + timeout_seconds
        if self._continuous_writer:
            while time.monotonic() < deadline:
                with self._queue_lock:
                    queue_empty = self._queued_frames == 0
                if queue_empty:
                    time.sleep(_WRITER_BLOCK_SECONDS)
                    return True
                time.sleep(_DRAIN_POLL_INTERVAL_SECONDS)
            return False
        last_available: Optional[int] = None
        stable_polls = 0
        while True:
            try:
                current_available = int(self._stream.write_available)
            except Exception:
                # ``write_available`` may raise after stop()/close(); treat
                # that as "drained" so we don't block the caller forever.
                return True
            if last_available is not None and current_available == last_available:
                stable_polls += 1
                if stable_polls >= _DRAIN_STABLE_POLLS:
                    return True
            else:
                stable_polls = 0
            last_available = current_available
            if time.monotonic() >= deadline:
                return False
            time.sleep(_DRAIN_POLL_INTERVAL_SECONDS)

    def close(self) -> None:
        self._writer_stop.set()
        writer = self._writer_thread
        if writer is not None and writer is not threading.current_thread():
            writer.join(timeout=_WRITER_JOIN_TIMEOUT_SECONDS)
        if self._stream is not None:
            if writer is not None and writer.is_alive():
                try:
                    self._stream.abort()
                except Exception:
                    pass
                writer.join(timeout=_WRITER_JOIN_TIMEOUT_SECONDS)
            try:
                self._stream.stop()
            except Exception:
                pass
            try:
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        self._continuous_writer = False
        self._writer_thread = None
        self._writer_ready.clear()
        self._writer_error = None
        self._clear_queue()
