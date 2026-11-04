#!/usr/bin/env python3
"""Sync the installer license text from the official privacy policy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_SOURCE_URL = "https://sayall.app/privacy/policy.json"
DATE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")
LANGUAGES = {
    "zh-Hans": ("zh", "zh-Hans.lproj/License.txt"),
    "en": ("en", "en.lproj/License.txt"),
}


def fail(message):
    print(f"sync-installer-privacy-policy: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_source(source_url, policy_json):
    if policy_json:
        path = Path(policy_json)
        if not path.is_file():
            fail(f"policy JSON does not exist: {path}")
        return path.read_bytes(), str(path)
    request = urllib.request.Request(
        source_url,
        headers={"User-Agent": "SayAll-Installer-Policy-Sync/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read(), source_url
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        fail(f"cannot fetch {source_url}: {error}")


def policy_source_commit(policy_json):
    if not policy_json:
        return "unknown"
    path = Path(policy_json).resolve()
    try:
        repo = subprocess.run(
            ["git", "-C", str(path.parent), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if not repo:
            return "unknown"
        relative = os.path.relpath(path, repo)
        dirty = subprocess.run(
            ["git", "-C", repo, "status", "--porcelain", "--", relative],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if dirty:
            return "working-tree"
        commit = subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return commit if re.fullmatch(r"[0-9a-f]{40}", commit) else "unknown"
    except (subprocess.CalledProcessError, OSError):
        return "unknown"


def normalized_text(text, updated, language):
    if not isinstance(text, str) or not text.strip():
        fail(f"{language}: policy text is empty")
    if not text.endswith("\n"):
        fail(f"{language}: policy text must end with a newline")
    if updated not in text:
        fail(f"{language}: policy text does not contain the update date {updated}")
    if text.count("\r") != 0:
        fail(f"{language}: policy text must use LF line endings")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy-json",
        help="local policy.json produced by the official site; defaults to the deployed URL",
    )
    parser.add_argument(
        "--source-url",
        default=DEFAULT_SOURCE_URL,
        help=f"deployed policy JSON URL (default: {DEFAULT_SOURCE_URL})",
    )
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parent.parent),
        help="repository root (default: parent of this script)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when the snapshot differs instead of writing it",
    )
    args = parser.parse_args()

    raw, source = read_source(args.source_url, args.policy_json)
    source_commit = policy_source_commit(args.policy_json)
    try:
        policy = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid policy JSON from {source}: {error}")
    if policy.get("version") != 1:
        fail(f"unsupported policy JSON version: {policy.get('version')!r}")
    updated = policy.get("updated")
    if not isinstance(updated, str) or not DATE.fullmatch(updated):
        fail(f"invalid policy update date: {updated!r}")
    languages = policy.get("languages")
    if not isinstance(languages, dict):
        fail("policy JSON is missing the languages object")

    resources = Path(args.root) / "packaging/doubao-driver/distribution/Resources"
    if not resources.is_dir():
        fail(f"installer resources directory does not exist: {resources}")

    changes = []
    lock_languages = {}
    canonical = {}
    for lock_name, (json_name, relative_file) in LANGUAGES.items():
        entry = languages.get(json_name)
        if not isinstance(entry, dict):
            fail(f"policy JSON is missing language {json_name}")
        if entry.get("updated") != updated:
            fail(f"{json_name}: update date does not match the policy header")
        text = normalized_text(entry.get("text"), updated, json_name)
        title = entry.get("title")
        if not isinstance(title, str) or not title.strip():
            fail(f"{json_name}: policy title is missing")
        if text.splitlines()[0] != title:
            fail(f"{json_name}: policy text does not start with its title")
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if entry.get("sha256") != digest:
            fail(f"{json_name}: policy JSON sha256 does not match its text")
        canonical[lock_name] = text
        lock_languages[lock_name] = {
            "title": title,
            "file": relative_file,
            "sha256": digest,
        }
        target = resources / relative_file
        existing = target.read_text(encoding="utf-8") if target.exists() else None
        if existing != text:
            changes.append(target)

    lock = {
        "schema": 1,
        "updated": updated,
        "policy_url": "https://sayall.app/privacy/",
        "policy_json_url": args.source_url,
        "source_commit": source_commit,
        "languages": lock_languages,
    }
    lock_path = Path(args.root) / "packaging/doubao-driver/privacy-policy.lock.json"
    lock_bytes = (json.dumps(lock, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if not lock_path.exists() or lock_path.read_bytes() != lock_bytes:
        changes.append(lock_path)

    if not changes:
        print(f"installer privacy policy already current ({updated})")
        return

    if args.check:
        print(f"installer privacy policy is stale ({updated}):", file=sys.stderr)
        for path in changes:
            print(f"  {path}", file=sys.stderr)
        raise SystemExit(1)

    for lock_name, text in canonical.items():
        target = resources / LANGUAGES[lock_name][1]
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    lock_path.write_bytes(lock_bytes)
    print(f"updated installer privacy policy ({updated}) from {source}:")
    for path in changes:
        print(f"  {path}")


if __name__ == "__main__":
    main()
