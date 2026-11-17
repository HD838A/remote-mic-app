#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BASE_COMMIT="${RELEASE_METADATA_BASE:-}"

cd "$ROOT"

python3 - "$BASE_COMMIT" <<'PY'
import plistlib
import re
import subprocess
import sys
from pathlib import Path

base_rev = sys.argv[1]
info_path = Path("Resources/Info.plist")
zh_history = Path("Resources/zh-Hans.lproj/ReleaseHistory.md")
en_history = Path("Resources/en.lproj/ReleaseHistory.md")


def load_plist(data):
    value = plistlib.loads(data)
    if not isinstance(value, dict):
        raise ValueError("Info.plist root is not a dictionary")
    return value


def version_tuple(value):
    parts = value.split(".")
    if len(parts) != 3 or any(not part.isdigit() for part in parts):
        raise ValueError(f"invalid semantic version: {value}")
    return tuple(int(part) for part in parts)


try:
    head = load_plist(info_path.read_bytes())
except Exception as exc:
    raise SystemExit(f"unable to read {info_path}: {exc}")

version = head.get("CFBundleShortVersionString")
build = head.get("CFBundleVersion")
if not isinstance(version, str) or not isinstance(build, str) or not build.isdigit() or not build.isascii():
    raise SystemExit("Info.plist version/build must be numeric strings")
try:
    head_version = version_tuple(version)
except ValueError as exc:
    raise SystemExit(str(exc))
head_build = int(build)
if head_build <= 0:
    raise SystemExit("CFBundleVersion must be positive")

if base_rev and base_rev != "0" * 40:
    try:
        base_data = subprocess.check_output(
            ["git", "show", f"{base_rev}:Resources/Info.plist"],
            stderr=subprocess.DEVNULL,
        )
        base = load_plist(base_data)
        base_version = base.get("CFBundleShortVersionString")
        base_build = base.get("CFBundleVersion")
        if not isinstance(base_version, str) or not isinstance(base_build, str) or not base_build.isdigit():
            raise ValueError("base Info.plist version/build is invalid")
        base_version_tuple = version_tuple(base_version)
        base_build_int = int(base_build)
    except Exception as exc:
        raise SystemExit(f"unable to read base release metadata: {exc}")
    if head_version < base_version_tuple or (
        head_version == base_version_tuple and head_build <= base_build_int
    ):
        raise SystemExit(
            "release version/build must increase: "
            f"base {base_version} ({base_build}), head {version} ({build})"
        )

version_heading = re.compile(rf"^## {re.escape(version)}(?:[^0-9.]|$)")
forbidden_notes = re.compile(
    r"((连续|连点|点击|轻点).{0,24}(版本号|当前版本).{0,24}(次|隐藏|入口))|"
    r"((tap|click).{0,24}(version|build).{0,24}(times|hidden|secret|invite|enrollment))|"
    r"(隐藏入口|秘密手势|secret gesture|hidden entry|invitation-code entry)",
    re.IGNORECASE,
)
for history in (zh_history, en_history):
    if not history.is_file():
        raise SystemExit(f"missing release history: {history}")
    text = history.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not any(version_heading.match(line) for line in lines):
        raise SystemExit(f"{history} has no heading for {version}")
    if forbidden_notes.search(text):
        raise SystemExit(f"{history} contains an internal trigger or confidential enrollment detail")

print(f"RELEASE METADATA PASS version={version} build={build}")
PY
