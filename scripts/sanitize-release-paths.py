#!/usr/bin/env python3
"""Remove local build paths from release Mach-O binaries without changing layout."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

USER_PATH = re.compile(rb"/Users/[^\s\x00]+")
PUBLIC_SENTRY_PATH = re.compile(
    rb"^/Users/runner/work/sentry-cocoa/sentry-cocoa/Sources/"
    rb"([A-Za-z0-9_-]+/)+[A-Za-z0-9_+-]+\.(m|mm|c|cpp|h|swift)$"
)
TEMP_REMOTE_PATH = re.compile(rb"/tmp/remote-bridge")
EXAMPLE_DEVICE_ADDRESS = re.compile(rb"AA:BB:CC:DD:EE:FF")
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
BINARY_COMPONENTS = ("MacOS", "Helpers", "Frameworks", "Library")
SCANNED_COMPONENTS = BINARY_COMPONENTS + ("Info.plist", "_CodeSignature")


def is_macho(data: bytes) -> bool:
    return len(data) >= 4 and data[:4] in MACHO_MAGICS


def binary_files(app: Path):
    seen: set[Path] = set()
    for component in BINARY_COMPONENTS:
        root = app / "Contents" / component
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_symlink() or not path.is_file():
                continue
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            if is_macho(path.read_bytes()):
                yield path


def sanitize_file(path: Path) -> int:
    data = path.read_bytes()
    replacements = 0

    def replace_user_path(match: re.Match[bytes]) -> bytes:
        nonlocal replacements
        if PUBLIC_SENTRY_PATH.fullmatch(match.group(0)):
            return match.group(0)
        replacements += 1
        return b"/build/" + match.group(0)[len(b"/Users/"):]

    updated = USER_PATH.sub(replace_user_path, data)
    updated, temp_count = TEMP_REMOTE_PATH.subn(b"/tmp/remote-buildx", updated)
    updated, device_count = EXAMPLE_DEVICE_ADDRESS.subn(b"00:00:00:00:00:00", updated)
    replacements += temp_count + device_count
    if replacements and len(updated) != len(data):
        raise RuntimeError("sanitization changed a Mach-O binary length")
    if updated != data:
        path.write_bytes(updated)
    return replacements


def forbidden_components(app: Path) -> list[str]:
    rejected: list[str] = []
    for component in SCANNED_COMPONENTS:
        target = app / "Contents" / component
        if not target.exists():
            continue
        paths = [target] if target.is_file() else [
            path for path in sorted(target.rglob("*")) if path.is_file() and not path.is_symlink()
        ]
        for path in paths:
            data = path.read_bytes()
            if any(
                not PUBLIC_SENTRY_PATH.fullmatch(match.group(0))
                for match in USER_PATH.finditer(data)
            ) or TEMP_REMOTE_PATH.search(data) or EXAMPLE_DEVICE_ADDRESS.search(data):
                rejected.append(component.lower())
                break
    return rejected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if not (args.app / "Contents").is_dir():
        print("SANITIZE RELEASE PATHS result=failed reason=invalid_app", file=sys.stderr)
        return 2

    binaries = list(binary_files(args.app))
    replacements = 0
    if not args.check:
        for binary in binaries:
            replacements += sanitize_file(binary)

    rejected = forbidden_components(args.app)
    if rejected:
        print(
            "SANITIZE RELEASE PATHS result=failed component=" + rejected[0],
            file=sys.stderr,
        )
        return 1

    action = "checked" if args.check else "passed"
    print(
        f"SANITIZE RELEASE PATHS result={action} binaries={len(binaries)} "
        f"replacements={replacements}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
