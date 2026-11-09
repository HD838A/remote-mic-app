#!/usr/bin/env python3
"""Reject development inputs and credentials inside final public release assets."""
import argparse
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


FORBIDDEN_SUFFIXES = (
    ".swift", ".swiftinterface", ".swiftsourceinfo", ".swiftdoc", ".swiftmodule",
    ".xcframework", ".dsym", ".a", ".log", ".pem", ".p12", ".p8", ".key",
)
CREDENTIAL = re.compile(
    rb"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|sk_live_[A-Za-z0-9]{16,}"
)
LOCAL_PATH = re.compile(rb"/Users/[^\s\x00]+|/private/tmp/[^\s\x00]+|/home/[^\s\x00]+")
PUBLIC_SENTRY_PATH = re.compile(
    rb"/Users/runner/work/sentry-cocoa/sentry-cocoa/Sources/([A-Za-z0-9_-]+/)+[A-Za-z0-9_+-]+\.(m|mm|c|cpp|h|swift)"
)
INSTALLER_USER_PATH = re.compile(rb"/Users/(?:\$[A-Za-z_][A-Za-z0-9_]*|\*)[^\s\x00]*")
# BlackHole v0.7.1's bundled README uses this literal Markdown example.
PUBLIC_DOCUMENTATION_PATH = b"/Users/user/Library`."
REJECTION_CODES = {
    "unsafe archive path": "unsafe-path",
    "development input or credential file": "development-input",
    "credential-like material": "credentials",
    "local build path": "local-path",
    "escaping symbolic link": "escaping-link",
    "escaping archive link": "escaping-link",
    "duplicate archive entry": "duplicate-entry",
    "installer contents could not be inspected": "installer-inspection",
    "disk image contents could not be inspected": "disk-image-inspection",
    "disk image could not be detached": "disk-image-detach",
}


def verify_name(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name:
        raise RuntimeError("unsafe archive path")
    for part in path.parts:
        lower = part.lower()
        if lower in (".git", ".env") or lower.startswith(".env.") or lower.endswith(FORBIDDEN_SUFFIXES):
            raise RuntimeError("development input or credential file")


def verify_stream(stream):
    data = stream.read()
    if CREDENTIAL.search(data):
        raise RuntimeError("credential-like material")
    for match in LOCAL_PATH.finditer(data):
        if (not PUBLIC_SENTRY_PATH.fullmatch(match.group())
                and not INSTALLER_USER_PATH.fullmatch(match.group())
                and match.group() != PUBLIC_DOCUMENTATION_PATH):
            raise RuntimeError("local build path")


def verify_tree(directory, scratch):
    for path in directory.rglob("*"):
        verify_name(path.relative_to(directory).as_posix())
        if path.is_symlink():
            if not path.resolve().is_relative_to(directory.resolve()):
                raise RuntimeError("escaping symbolic link")
        elif path.is_file():
            verify_asset(path, scratch)


def verify_asset(path, scratch):
    verify_name(path.name)
    if path.is_dir():
        verify_tree(path, scratch)
    elif path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise RuntimeError("duplicate archive entry")
            for entry in archive.infolist():
                verify_name(entry.filename)
                if not entry.is_dir():
                    with archive.open(entry) as stream:
                        verify_stream(stream)
                    if PurePosixPath(entry.filename).suffix in (".zip", ".pkg", ".dmg"):
                        parent = Path(tempfile.mkdtemp(dir=scratch, prefix="nested-"))
                        nested = parent / PurePosixPath(entry.filename).name
                        with archive.open(entry) as source, nested.open("wb") as destination:
                            shutil.copyfileobj(source, destination)
                        verify_asset(nested, scratch)
                    if stat.S_ISLNK(entry.external_attr >> 16):
                        target = archive.read(entry).decode()
                        resolved = PurePosixPath(entry.filename).parent / target
                        depth = 0
                        for part in resolved.parts:
                            depth += -1 if part == ".." else 1
                            if depth < 0 or part == "/":
                                raise RuntimeError("escaping archive link")
    elif path.suffix == ".pkg":
        parent = Path(tempfile.mkdtemp(dir=scratch, prefix="installer-"))
        expanded = parent / "expanded"
        result = subprocess.run(
            ["pkgutil", "--expand-full", str(path), str(expanded)], capture_output=True
        )
        if result.returncode:
            raise RuntimeError("installer contents could not be inspected")
        verify_tree(expanded, scratch)
    elif path.suffix == ".dmg":
        mount = Path(tempfile.mkdtemp(dir=scratch, prefix="volume-"))
        result = subprocess.run(
            ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(path)],
            capture_output=True,
        )
        if result.returncode:
            raise RuntimeError("disk image contents could not be inspected")
        try:
            verify_tree(mount, scratch)
        finally:
            detached = subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True)
            if detached.returncode:
                raise RuntimeError("disk image could not be detached")
    else:
        with path.open("rb") as stream:
            verify_stream(stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset", type=Path)
    args = parser.parse_args()
    scratch = Path(tempfile.mkdtemp(prefix="sayall-release-contents-"))
    try:
        verify_asset(args.asset.resolve(), scratch)
    finally:
        trash = Path.home() / ".Trash"
        trash.mkdir(exist_ok=True)
        shutil.move(str(scratch), str(trash / scratch.name))
    print("RELEASE CONTENTS PASS")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
        # Compiler output, archive entry names and local paths stay out of public logs.
        code = REJECTION_CODES.get(str(error), "inspection")
        print(f"RELEASE CONTENTS FAILED: asset rejected reason={code}", file=sys.stderr)
        sys.exit(1)
