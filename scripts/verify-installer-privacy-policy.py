#!/usr/bin/env python3
"""Verify that installer license text matches the official privacy policy."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

DEFAULT_SOURCE_URL = "https://sayall.app/privacy/policy.json"
DATE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")
LANGUAGES = {
    "zh-Hans": ("zh", "zh-Hans.lproj/License.txt"),
    "en": ("en", "en.lproj/License.txt"),
}


def fail(message):
    print(f"verify-installer-privacy-policy: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(raw, source):
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid policy JSON from {source}: {error}")
    if value.get("version") != 1:
        fail(f"unsupported policy JSON version from {source}: {value.get('version')!r}")
    updated = value.get("updated")
    if not isinstance(updated, str) or not DATE.fullmatch(updated):
        fail(f"invalid policy update date from {source}: {updated!r}")
    languages = value.get("languages")
    if not isinstance(languages, dict):
        fail(f"policy JSON from {source} is missing the languages object")
    return updated, languages


def fetch_policy(source_url, policy_json):
    if policy_json:
        path = Path(policy_json)
        if not path.is_file():
            fail(f"policy JSON does not exist: {path}")
        return path.read_bytes(), str(path)
    request = urllib.request.Request(
        source_url,
        headers={"User-Agent": "SayAll-Installer-Policy-Verify/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read(), source_url
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        fail(f"cannot fetch {source_url}: {error}")


def read_lock(root):
    lock_path = root / "packaging/doubao-driver/privacy-policy.lock.json"
    if not lock_path.is_file():
        fail(f"missing lock file: {lock_path}")
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid lock file {lock_path}: {error}")
    if lock.get("schema") != 1:
        fail(f"unsupported lock schema: {lock.get('schema')!r}")
    updated = lock.get("updated")
    if not isinstance(updated, str) or not DATE.fullmatch(updated):
        fail(f"invalid lock update date: {updated!r}")
    languages = lock.get("languages")
    if not isinstance(languages, dict):
        fail("lock file is missing the languages object")
    source_commit = lock.get("source_commit")
    if not isinstance(source_commit, str) or not re.fullmatch(
        r"[0-9a-f]{40}|working-tree|unknown", source_commit
    ):
        fail(f"invalid lock source commit: {source_commit!r}")
    return lock, updated, languages


def check_snapshot(resources, updated, languages):
    texts = {}
    date_values = set()
    for lock_name, (json_name, relative_file) in LANGUAGES.items():
        entry = languages.get(lock_name)
        if not isinstance(entry, dict):
            fail(f"lock file is missing language {lock_name}")
        if entry.get("file") != relative_file:
            fail(f"{lock_name}: unexpected license path {entry.get('file')!r}")
        path = resources / relative_file
        if not path.is_file():
            fail(f"missing license text: {path}")
        text = path.read_text(encoding="utf-8")
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if entry.get("sha256") != digest:
            fail(f"{lock_name}: license sha256 does not match the lock file")
        if updated not in text:
            fail(f"{lock_name}: license text does not contain the update date {updated}")
        title = text.splitlines()[0] if text else ""
        if entry.get("title") != title:
            fail(f"{lock_name}: license title does not match the lock file")
        date_match = re.search(r"\d{4}-\d{2}-\d{2}", text)
        if date_match:
            date_values.add(date_match.group(0))
        texts[lock_name] = text
    if date_values != {updated}:
        fail(f"license dates do not match the lock file: {sorted(date_values)}")
    return texts


def check_expanded(expanded, texts):
    distribution = expanded / "Distribution"
    if not distribution.is_file():
        fail(f"missing Distribution in expanded package: {expanded}")
    if '<license file="License.txt"/>' not in distribution.read_text(encoding="utf-8"):
        fail("expanded Distribution does not declare <license file=\"License.txt\"/>")
    for lock_name, (_, relative_file) in LANGUAGES.items():
        packaged = expanded / "Resources" / relative_file
        if not packaged.is_file():
            fail(f"package is missing license text: {packaged}")
        if packaged.read_text(encoding="utf-8") != texts[lock_name]:
            fail(f"packaged license text differs from the snapshot: {packaged}")


def check_remote(policy_json, source_url, texts, updated, lock):
    if lock.get("source_commit") == "working-tree":
        fail(
            "lock records source_commit=working-tree; re-sync from the deployed "
            "policy.json before releasing"
        )
    raw, source = fetch_policy(source_url, policy_json)
    live_updated, live_languages = load_json(raw, source)
    if live_updated != updated:
        fail(
            "official privacy policy date differs from the installer snapshot: "
            f"live={live_updated} installer={updated}"
        )
    for lock_name, (json_name, _) in LANGUAGES.items():
        entry = live_languages.get(json_name)
        if not isinstance(entry, dict):
            fail(f"official policy JSON is missing language {json_name}")
        live_text = entry.get("text")
        if not isinstance(live_text, str):
            fail(f"{json_name}: official policy text is missing")
        live_digest = hashlib.sha256(live_text.encode("utf-8")).hexdigest()
        if entry.get("sha256") != live_digest:
            fail(f"{json_name}: official policy JSON sha256 does not match its text")
        if live_text != texts[lock_name]:
            diff = list(
                difflib.unified_diff(
                    texts[lock_name].splitlines(),
                    live_text.splitlines(),
                    fromfile=f"installer/{lock_name}",
                    tofile=f"official/{lock_name}",
                    lineterm="",
                )
            )
            print("\n".join(diff[:40]), file=sys.stderr)
            fail(f"{lock_name}: installer license text differs from the official policy")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parent.parent),
        help="repository root (default: parent of this script)",
    )
    parser.add_argument("--remote", action="store_true", help="compare with the deployed policy")
    parser.add_argument(
        "--policy-json",
        help="local policy.json for --remote; defaults to the deployed URL",
    )
    parser.add_argument(
        "--source-url",
        default=DEFAULT_SOURCE_URL,
        help=f"deployed policy JSON URL (default: {DEFAULT_SOURCE_URL})",
    )
    parser.add_argument("--expanded", help="verify an expanded package directory")
    parser.add_argument("--package", help="expand and verify an installer package")
    args = parser.parse_args()

    resources = Path(args.root) / "packaging/doubao-driver/distribution/Resources"
    if not resources.is_dir():
        fail(f"installer resources directory does not exist: {resources}")
    lock, updated, languages = read_lock(Path(args.root))
    texts = check_snapshot(resources, updated, languages)

    if args.expanded and args.package:
        fail("use either --expanded or --package, not both")
    if args.expanded:
        check_expanded(Path(args.expanded), texts)
    if args.package:
        package = Path(args.package)
        if not package.is_file():
            fail(f"installer package does not exist: {package}")
        with tempfile.TemporaryDirectory(prefix="sayall-privacy-verify.") as temporary:
            expanded = Path(temporary) / "expanded"
            try:
                subprocess.run(
                    ["/usr/sbin/pkgutil", "--expand", str(package), str(expanded)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            except subprocess.CalledProcessError as error:
                fail(f"cannot expand installer package {package}: {error.stderr.strip()}")
            check_expanded(expanded, texts)

    if args.remote:
        check_remote(args.policy_json, args.source_url, texts, updated, lock)

    print(f"INSTALLER PRIVACY POLICY VERIFY PASS: {updated}")
    print(f"LANGUAGES: {', '.join(sorted(texts))}")
    if args.remote:
        print("REMOTE: official policy matches the installer snapshot")
    if args.package:
        print(f"PACKAGE: {args.package}")
    elif args.expanded:
        print(f"EXPANDED: {args.expanded}")


if __name__ == "__main__":
    main()
