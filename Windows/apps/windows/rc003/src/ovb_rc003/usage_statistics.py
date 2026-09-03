"""Privacy-preserving daily usage aggregates for the Windows client.

Only three numbers are stored per local calendar day: ordinary remote
button presses, completed voice sessions, and voice audio seconds. No text,
audio, application identity, device identifier, or individual event history
is retained.
"""

from __future__ import annotations

import json
import math
import os
import tempfile
import threading
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Callable, Dict, List, Optional


_FILENAME = "usage-statistics.json"
_SCHEMA_VERSION = 1


def statistics_path(config_root: Path) -> Path:
    return config_root / _FILENAME


class UsageStatisticsStore:
    def __init__(
        self,
        config_root: Path,
        *,
        today: Callable[[], date] = date.today,
    ) -> None:
        self._path = statistics_path(config_root)
        self._today = today
        self._lock = threading.Lock()

    def record_button_press(self, *, day: Optional[date] = None) -> None:
        self._update(day or self._today(), button_presses=1)

    def record_voice_session(
        self, duration_seconds: float, *, day: Optional[date] = None
    ) -> None:
        if not math.isfinite(duration_seconds) or duration_seconds <= 0:
            return
        self._update(
            day or self._today(),
            voice_sessions=1,
            voice_seconds=max(0.0, duration_seconds),
        )

    def snapshot(self, *, today: Optional[date] = None) -> Dict[str, object]:
        current_day = today or self._today()
        with self._lock:
            days = dict(self._load_unlocked()["days"])

        start = date(current_day.year, 1, 1)
        end = date(current_day.year, 12, 31)
        cells: List[Dict[str, object]] = []
        month_blocks: List[Dict[str, object]] = []
        totals = {"button_presses": 0, "voice_sessions": 0, "voice_seconds": 0.0}
        active_days = 0
        for month_index in range(12):
            month_start = date(current_day.year, month_index + 1, 1)
            month_end = (
                date(current_day.year, month_index + 2, 1) - timedelta(days=1)
                if month_index < 11
                else end
            )
            month_cells: List[Dict[str, object]] = []
            cell_day = month_start
            while cell_day <= month_end:
                raw = days.get(cell_day.isoformat(), {}) if cell_day <= current_day else {}
                button_presses = _nonnegative_int(raw.get("button_presses", 0))
                voice_sessions = _nonnegative_int(raw.get("voice_sessions", 0))
                voice_seconds = _nonnegative_float(raw.get("voice_seconds", 0.0))
                usage_count = button_presses + voice_sessions
                if cell_day <= current_day:
                    totals["button_presses"] += button_presses
                    totals["voice_sessions"] += voice_sessions
                    totals["voice_seconds"] += voice_seconds
                    if usage_count > 0 or voice_seconds > 0:
                        active_days += 1
                cell = {
                    "date": cell_day.isoformat(),
                    "monthIndex": month_index,
                    "weekIndex": (cell_day.day - 1 + month_start.weekday()) // 7,
                    "dayIndex": cell_day.weekday(),
                    "isFuture": cell_day > current_day,
                    "voiceSeconds": round(voice_seconds, 3),
                    "usageCount": usage_count,
                }
                cells.append(cell)
                month_cells.append(cell)
                cell_day += timedelta(days=1)
            month_blocks.append(
                {
                    "monthIndex": month_index,
                    "label": f"{month_index + 1} 月",
                    "weekCount": max(int(cell["weekIndex"]) for cell in month_cells) + 1,
                    "cells": month_cells,
                }
            )

        visible_cells = [cell for cell in cells if not cell["isFuture"]]
        max_duration = max((float(cell["voiceSeconds"]) for cell in visible_cells), default=0)
        max_frequency = max((int(cell["usageCount"]) for cell in visible_cells), default=0)
        for cell in cells:
            cell["durationLevel"] = _intensity(float(cell["voiceSeconds"]), max_duration)
            cell["frequencyLevel"] = _intensity(float(cell["usageCount"]), max_frequency)
            cell["durationText"] = format_duration(float(cell["voiceSeconds"]))
            cell["frequencyText"] = f"{cell['usageCount']} 次"

        today_raw = days.get(current_day.isoformat(), {})
        today_buttons = _nonnegative_int(today_raw.get("button_presses", 0))
        today_sessions = _nonnegative_int(today_raw.get("voice_sessions", 0))
        today_seconds = _nonnegative_float(today_raw.get("voice_seconds", 0.0))
        return {
            "cells": cells,
            "monthBlocks": month_blocks,
            "yearLabel": str(current_day.year),
            "currentMonthIndex": current_day.month - 1,
            "todayDuration": format_duration(today_seconds),
            "todayFrequency": f"{today_buttons + today_sessions} 次触发",
            "yearDuration": format_duration(float(totals["voice_seconds"])),
            "yearFrequency": f"{int(totals['button_presses']) + int(totals['voice_sessions']):,} 次触发",
            "activeDays": f"{active_days} 天",
            "rangeText": f"{start.isoformat()} — {end.isoformat()}",
        }

    def _update(self, day: date, **increments: float) -> None:
        with self._lock:
            payload = self._load_unlocked()
            days = payload["days"]
            key = day.isoformat()
            current = dict(days.get(key, {}))
            current["button_presses"] = _nonnegative_int(
                current.get("button_presses", 0)
            ) + int(increments.get("button_presses", 0))
            current["voice_sessions"] = _nonnegative_int(
                current.get("voice_sessions", 0)
            ) + int(increments.get("voice_sessions", 0))
            current["voice_seconds"] = round(
                _nonnegative_float(current.get("voice_seconds", 0.0))
                + float(increments.get("voice_seconds", 0.0)),
                3,
            )
            days[key] = current
            self._save_unlocked(payload)

    def _load_unlocked(self) -> Dict[str, object]:
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return {"version": _SCHEMA_VERSION, "days": {}}
        days = raw.get("days", {}) if isinstance(raw, dict) else {}
        if not isinstance(days, dict):
            days = {}
        return {"version": _SCHEMA_VERSION, "days": days}

    def _save_unlocked(self, payload: Dict[str, object]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self._path.name}.", suffix=".tmp", dir=str(self._path.parent)
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, self._path)
        except Exception:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise


def _nonnegative_int(value: object) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError, OverflowError):
        return 0


def _nonnegative_float(value: object) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return number if math.isfinite(number) and number > 0 else 0.0


def _intensity(value: float, maximum: float) -> int:
    if value <= 0 or maximum <= 0:
        return 0
    return min(4, max(1, math.ceil(value / maximum * 4)))


def format_duration(seconds: float) -> str:
    whole = max(0, int(round(seconds)))
    hours, remainder = divmod(whole, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours} 小时 {minutes} 分"
    if minutes:
        return f"{minutes} 分 {secs} 秒"
    return f"{secs} 秒"
