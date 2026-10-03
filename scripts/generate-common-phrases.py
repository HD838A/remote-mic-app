#!/usr/bin/env python3
"""Validate the public phrase source and emit the sole runtime JSON resource."""
import json
import sys
from pathlib import Path


def generate(source):
    sections = {}
    section = None
    for line in source.splitlines():
        if line.startswith("## "):
            section = line[3:].strip()
            sections[section] = []
        elif section and line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            sections[section].append(cells)
    rows = sections.get("常用语表", [])
    if len(rows) < 3 or rows[0] != ["#", "中文完整句", "中文短显示", "English", "Short Display"]:
        raise ValueError("invalid_phrase_header")
    entries = []
    for index, cells in enumerate(rows[2:], 1):
        if len(cells) != 5 or not all(cells) or cells[0] != str(index):
            raise ValueError("invalid_phrase_row")
        entries.append(dict(id=f"builtin-{index}", chineseText=cells[1], chineseLabel=cells[2],
                            englishText=cells[3], englishLabel=cells[4]))
    mapping = sections.get("默认键位", [])
    if len(mapping) != 7 or mapping[0] != ["按键", "编号", "中文完整句"] or len(entries) < 5:
        raise ValueError("invalid_binding_table")
    keys = {"OK": "ok", "左": "left", "上": "up", "右": "right", "下": "down"}
    bindings = {}
    numbers = set()
    for cells in mapping[2:]:
        if len(cells) != 3 or cells[0] not in keys or cells[1] not in {"1", "2", "3", "4", "5"}:
            raise ValueError("invalid_binding_row")
        number = int(cells[1])
        key = keys[cells[0]]
        if key in bindings or number in numbers or cells[2] != entries[number - 1]["chineseText"]:
            raise ValueError("inconsistent_binding")
        numbers.add(number)
        bindings[key] = f"builtin-{number}"
    if set(bindings) != set(keys.values()) or numbers != set(range(1, 6)):
        raise ValueError("incomplete_bindings")
    return {"schemaVersion": 1, "entries": entries, "bindings": bindings}


if __name__ == "__main__":
    try:
        source = sys.stdin.read() if sys.argv[1] == "-" else Path(sys.argv[1]).read_text(encoding="utf-8")
        print(json.dumps(generate(source), ensure_ascii=False, sort_keys=True, indent=2))
    except (ValueError, OSError, IndexError):
        print("common phrases source validation failed", file=sys.stderr)
        sys.exit(1)
