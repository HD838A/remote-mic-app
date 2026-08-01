"""Portable RC003 physical-key capture, replay, and adaptation helpers.

The physical decoder and the configured action are deliberately separate:
this module records what Windows actually delivered, assigns a stable
signature to it, and can replay the sample without Windows. A signature can
then be bound to a canonical RC003 button before the normal semantic action
mapping is consulted.
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .raw_input_windows import RawInputEvent, physical_signature


CAPTURE_SCHEMA_VERSION = 1
CAPTURE_KIND = "rc003_raw_input"


def event_to_record(
    event: RawInputEvent,
    sequence: int,
    *,
    timestamp_ns: Optional[int] = None,
    include_device_path: bool = False,
) -> Dict[str, Any]:
    """Convert one runtime event into a stable JSONL record."""

    record: Dict[str, Any] = {
        "schema_version": CAPTURE_SCHEMA_VERSION,
        "kind": CAPTURE_KIND,
        "sequence": int(sequence),
        "timestamp_ns": int(time.time_ns() if timestamp_ns is None else timestamp_ns),
        "source": event.source,
        "is_pressed": bool(event.is_pressed),
        "button_id": event.button_id,
        "vkey": event.vkey,
        "make_code": event.make_code,
        "flags": event.flags,
        "message": event.message,
        "usages": [int(usage) for usage in event.usages],
        "report_hex": event.report.hex(),
        "signature": physical_signature(event),
    }
    if event.decode_error:
        record["decode_error"] = event.decode_error
    if include_device_path and event.device_path:
        record["device_path"] = event.device_path
    return record


def record_to_event(record: Mapping[str, Any]) -> RawInputEvent:
    """Decode one JSONL record and reject malformed capture data."""

    if record.get("schema_version") != CAPTURE_SCHEMA_VERSION:
        raise ValueError(
            "unsupported capture schema version: "
            f"{record.get('schema_version')!r}"
        )
    if record.get("kind") != CAPTURE_KIND:
        raise ValueError(f"unsupported capture kind: {record.get('kind')!r}")
    try:
        report_hex = str(record.get("report_hex", ""))
        report = bytes.fromhex(report_hex)
        usages = tuple(int(usage) for usage in record.get("usages", ()))
        return RawInputEvent(
            source=str(record["source"]),
            is_pressed=bool(record["is_pressed"]),
            button_id=record.get("button_id"),
            vkey=_optional_int(record.get("vkey")),
            make_code=_optional_int(record.get("make_code")),
            flags=_optional_int(record.get("flags")),
            message=_optional_int(record.get("message")),
            report=report,
            usages=usages,
            device_path=record.get("device_path"),
            decode_error=record.get("decode_error"),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"invalid RC003 capture record: {record!r}") from exc


def _optional_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    return int(value)


def adapt_event(
    event: RawInputEvent, physical_bindings: Mapping[str, str]
) -> RawInputEvent:
    """Apply a physical override without changing the semantic action map."""

    button_id = physical_bindings.get(physical_signature(event), event.button_id)
    if button_id == event.button_id:
        return event
    return replace(event, button_id=button_id)


def replay_capture(
    events: Iterable[RawInputEvent],
    *,
    physical_bindings: Optional[Mapping[str, str]] = None,
    on_event: Optional[Callable[[RawInputEvent], None]] = None,
) -> Tuple[RawInputEvent, ...]:
    """Replay captured edges deterministically and return adapted events."""

    bindings = physical_bindings or {}
    replayed: List[RawInputEvent] = []
    for event in events:
        adapted = adapt_event(event, bindings)
        replayed.append(adapted)
        if on_event is not None:
            on_event(adapted)
    return tuple(replayed)


def load_capture(path: Path) -> Tuple[RawInputEvent, ...]:
    """Load a JSONL capture produced by :class:`KeyCaptureRecorder`."""

    events: List[RawInputEvent] = []
    with path.open("r", encoding="utf-8-sig") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                events.append(record_to_event(record))
            except (json.JSONDecodeError, ValueError) as exc:
                raise ValueError(f"invalid capture line {line_number}") from exc
    return tuple(events)


def binding_for_event(event: RawInputEvent, button_id: str) -> Dict[str, str]:
    """Return the config fragment that assigns one captured event."""

    if not button_id.strip():
        raise ValueError("button_id must not be empty")
    return {physical_signature(event): button_id}


@dataclass(frozen=True)
class KeyTestResult:
    expected_button_id: str
    saw_press: bool
    saw_release: bool
    observed_buttons: Tuple[str, ...]
    unknown_signatures: Tuple[str, ...]
    decode_errors: Tuple[str, ...] = ()

    @property
    def passed(self) -> bool:
        return self.saw_press and self.saw_release and not self.decode_errors


def evaluate_key_capture(
    events: Sequence[RawInputEvent],
    expected_button_id: str,
    *,
    physical_bindings: Optional[Mapping[str, str]] = None,
) -> KeyTestResult:
    """Require both edges for one canonical button, without executing it."""

    replayed = replay_capture(events, physical_bindings=physical_bindings)
    expected = [event for event in replayed if event.button_id == expected_button_id]
    observed = tuple(
        dict.fromkeys(
            event.button_id for event in replayed if event.button_id is not None
        )
    )
    unknown = tuple(
        dict.fromkeys(
            physical_signature(event)
            for event in replayed
            if event.button_id is None and not event.decode_error
        )
    )
    decode_errors = tuple(
        dict.fromkeys(
            event.decode_error
            for event in replayed
            if event.decode_error
        )
    )
    return KeyTestResult(
        expected_button_id=expected_button_id,
        saw_press=any(event.is_pressed for event in expected),
        saw_release=any(not event.is_pressed for event in expected),
        observed_buttons=observed,
        unknown_signatures=unknown,
        decode_errors=decode_errors,
    )


class KeyCaptureRecorder:
    """Thread-safe raw-event recorder suitable for the settings UI/probe."""

    def __init__(self, *, include_device_path: bool = False) -> None:
        self._include_device_path = include_device_path
        self._lock = threading.Lock()
        self._records: List[Dict[str, Any]] = []

    def append(self, event: RawInputEvent) -> Dict[str, Any]:
        with self._lock:
            record = event_to_record(
                event,
                len(self._records),
                include_device_path=self._include_device_path,
            )
            self._records.append(record)
            return dict(record)

    @property
    def records(self) -> Tuple[Dict[str, Any], ...]:
        with self._lock:
            return tuple(dict(record) for record in self._records)

    def events(self) -> Tuple[RawInputEvent, ...]:
        return tuple(record_to_event(record) for record in self.records)

    def clear(self) -> None:
        with self._lock:
            self._records.clear()

    def write_jsonl(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            for record in self.records:
                json.dump(record, handle, sort_keys=True)
                handle.write("\n")
