"""Transport-agnostic ATVV session state machine.

Consumes raw control/audio notification bytes (from whatever BLE transport
feeds it - see ble_transport_winrt.py) and turns them into decoded PCM sample
batches and session lifecycle events. Kept independent of any Windows API so
it can be unit tested on any OS.

Behavior (capability gate, decoder reset-on-AUDIO_START, one-shot AUDIO_SYNC,
late-audio discard guard) is a clean-room reimplementation of the protocol
behavior documented in this repository's own macOS adapter and the upstream
reference (see atvv_protocol.py module docstring for provenance).
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable, List, Optional

from . import atvv_protocol as proto


class ATVVProtocolError(Exception):
    """Raised when the device sends a malformed or unrecognized control frame."""


class UnsupportedSampleRateError(ATVVProtocolError):
    """Raised when the negotiated codec is not the required 16 kHz mode.

    This is a deliberate fail-closed gate: the client refuses to guess at an
    8 kHz fallback rather than risk silently mis-decoding audio.
    """


@dataclass(frozen=True)
class CapsReceived:
    capabilities: proto.ATVVCapabilities


@dataclass(frozen=True)
class MicButtonPressed:
    pass


@dataclass(frozen=True)
class AudioStarted:
    session_id: Optional[int]


@dataclass(frozen=True)
class AudioStopped:
    pass


@dataclass(frozen=True)
class AudioSynced:
    pass


@dataclass(frozen=True)
class UnknownControl:
    opcode: int


ControlEvent = object  # union of the dataclasses above, kept loose for simplicity

ClockFn = Callable[[], float]


class ATVVSession:
    """One BLE connection's worth of ATVV protocol state.

    A fresh instance should be created per connection attempt so state never
    leaks across a reconnect (there is no shared/global session state).
    """

    def __init__(self, gain_db: float = 0.0, clock: ClockFn = time.monotonic) -> None:
        self.gain_db = gain_db
        self._clock = clock
        self._decoder = proto.IMAADPCMDecoder()
        self._accumulator = proto.FrameAccumulator()
        self._frame_size = proto.DEFAULT_FRAME_SIZE
        self._version = 0
        self._caps: Optional[proto.ATVVCapabilities] = None
        self._pending_sync: Optional[tuple] = None
        self._mic_open = False
        self._last_mic_off_at: Optional[float] = None
        self._last_session_id: Optional[int] = None

    @property
    def capabilities(self) -> Optional[proto.ATVVCapabilities]:
        return self._caps

    @property
    def mic_open(self) -> bool:
        return self._mic_open

    def handle_control(self, payload: bytes) -> ControlEvent:
        if not payload:
            raise ATVVProtocolError("empty control payload")

        opcode = payload[0]

        if opcode == proto.OPCODE_CAPS:
            caps = proto.ATVVCapabilities.parse(payload)
            if caps is None:
                raise ATVVProtocolError(f"malformed CAPS payload: {payload!r}")
            if caps.sample_rate != proto.SUPPORTED_SAMPLE_RATE_HZ:
                raise UnsupportedSampleRateError(
                    "this bridge currently requires ATVV 16 kHz audio "
                    f"(device offered {caps.sample_rate} Hz)"
                )
            self._caps = caps
            self._version = caps.version
            self._frame_size = caps.frame_size
            return CapsReceived(caps)

        if opcode == proto.OPCODE_MIC_BUTTON:
            return MicButtonPressed()

        if opcode == proto.OPCODE_AUDIO_START:
            self._decoder.reset()
            self._accumulator.reset()
            self._pending_sync = None
            self._mic_open = True
            session_id = payload[3] if len(payload) >= 4 else None
            self._last_session_id = session_id
            return AudioStarted(session_id=session_id)

        if opcode == proto.OPCODE_AUDIO_STOP:
            self._mic_open = False
            self._last_mic_off_at = self._clock()
            self._accumulator.reset()
            return AudioStopped()

        if opcode == proto.OPCODE_AUDIO_SYNC and len(payload) >= 7:
            predictor = int.from_bytes(payload[4:6], "big", signed=True)
            step_index = payload[6]
            self._pending_sync = (predictor, step_index)
            return AudioSynced()

        return UnknownControl(opcode=opcode)

    def handle_audio(self, payload: bytes) -> List[int]:
        if not self._mic_open:
            if (
                self._last_mic_off_at is not None
                and (self._clock() - self._last_mic_off_at) < proto.LATE_AUDIO_GUARD_SECONDS
            ):
                return []

        frames = self._accumulator.append(payload, self._frame_size)
        samples: List[int] = []
        for frame in frames:
            if self._pending_sync is not None:
                self._decoder.reset(*self._pending_sync)
                self._pending_sync = None
            decoded = self._decoder.decode(frame)
            samples.extend(proto.postprocess(decoded, self.gain_db))
        return samples

    def mic_open_command(self) -> bytes:
        return proto.mic_open_command(self._version)

    def mic_close_command(self) -> bytes:
        return proto.mic_close_command(self._version, self._last_session_id or 0)
