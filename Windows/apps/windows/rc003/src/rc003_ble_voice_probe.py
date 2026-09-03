"""Time-bounded, privacy-safe RC003 ATVV voice-path probe.

The probe connects to exactly one paired RC003, subscribes to its ATVV
control/audio characteristics, and records aggregate PCM statistics only.
It never stores audio samples, recognized text, or a device identifier.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import sys
from pathlib import Path
from typing import TextIO

from ovb_rc003 import atvv_session, ble_transport_winrt, identity


async def _run(seconds: float) -> int:
    events: list[str] = []
    errors: list[str] = []
    stats = atvv_session.PcmStats()
    holder: dict[str, ble_transport_winrt.RC003BleSession] = {}

    def on_pcm(samples: list[int]) -> None:
        stats.add(samples)

    def on_control(event: object) -> None:
        event_name = type(event).__name__
        events.append(event_name)
        if isinstance(event, atvv_session.CapsReceived):
            caps = event.capabilities
            print(
                "RC003 BLE CAPS "
                f"version=0x{caps.version:04x} sample_rate={caps.sample_rate} "
                f"frame_size={caps.frame_size}",
                flush=True,
            )
        else:
            print(f"RC003 BLE CONTROL event={event_name}", flush=True)
        if isinstance(event, atvv_session.MicButtonPressed):
            holder["session"].send_mic_open_threadsafe()

    def on_error(error: BaseException) -> None:
        errors.append(f"{type(error).__name__}: {error}")
        print(f"RC003 BLE ERROR {errors[-1]}", flush=True)

    def on_disconnected() -> None:
        errors.append("device_disconnected")
        print("RC003 BLE ERROR device_disconnected", flush=True)

    print(f"RC003 BLE PROBE START duration_seconds={seconds:g}", flush=True)
    candidates = await ble_transport_winrt.discover_candidates()
    candidate = identity.select_single_candidate(candidates)
    print("RC003 BLE PROBE candidate=exactly_one", flush=True)

    session = ble_transport_winrt.RC003BleSession(
        on_pcm_frame=on_pcm,
        on_control_event=on_control,
        on_error=on_error,
        on_disconnected=on_disconnected,
    )
    holder["session"] = session
    await session.connect(candidate)
    print("RC003 BLE PROBE connected=true notifications=subscribed", flush=True)
    try:
        await asyncio.sleep(seconds)
    finally:
        await session.close()

    summary = stats.summary()
    print(
        "RC003 BLE PROBE END "
        f"events={','.join(events) or 'none'} errors={len(errors)} "
        f"frames={summary['frames']} samples={summary['samples']} "
        f"audio_ms={summary['audio_ms']:.0f} peak={summary['peak']} "
        f"result={summary['result']}",
        flush=True,
    )
    has_caps = "CapsReceived" in events
    has_voice = "AudioStarted" in events and summary["result"] == "signal"
    return 0 if has_caps and has_voice and not errors else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--output", type=Path)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if args.seconds <= 0:
        raise SystemExit("--seconds must be greater than zero")

    stream: TextIO | None = None
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        stream = args.output.open("w", encoding="utf-8", buffering=1)
    try:
        if stream is None:
            return asyncio.run(_run(args.seconds))
        with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
            return asyncio.run(_run(args.seconds))
    finally:
        if stream is not None:
            stream.close()


if __name__ == "__main__":
    sys.exit(main())
