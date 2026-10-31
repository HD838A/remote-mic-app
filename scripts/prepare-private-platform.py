#!/usr/bin/env python3
"""Release and verify the versioned Mac dependency before packaging."""
import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPOSITORY = "GetSayAll/sayall-private-platform"
RELEASE_ASSET = "sayall-private-platform-{tag}.release.zip"
SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
# Mac runtime, resources, package resolution, helpers and binary packaging.
MAC_PATHS = (
    "Package.swift", "Package.resolved",
    "packages/macos-remote/", "packages/macos-combination-actions/",
    "packages/macos-button-profiles/", "packages/macos-common-phrases/",
    "packages/macos-membership/", "packages/audio-input-kit/siri-remote/",
    "packages/audio-input-kit/chromecast/", "tools/release/",
)


def run(*args, cwd=None, timeout=90, capture=True):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=capture,
                            timeout=timeout, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
                            **({} if capture else {"stdout": sys.stderr, "stderr": sys.stderr}))
    if result.returncode:
        # Git and credential helper errors can contain URLs and credentials.
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode})")
    return result.stdout.strip() if capture else ""


def git(repo, *args):
    return run("git", "-C", str(repo), *args)


def version_key(version):
    if not SEMVER.fullmatch(version):
        raise RuntimeError("Use a standard SwiftPM release tag X.Y.Z; private-v* is historical only")
    return tuple(map(int, version.split(".")))


def relevant(path):
    # Package manifests added to the unified Mac package change Package.swift.
    if path.endswith((".md", ".html")):
        return False
    return any(path == scope or (scope.endswith("/") and path.startswith(scope))
               for scope in MAC_PATHS)


def mac_changes(repo, old, new):
    # --no-renames ensures a move out of a Mac directory still counts.
    return [p for p in git(repo, "diff", "--no-renames", "--name-only", old, new).splitlines()
            if relevant(p)]


def verify_tag(repo, tag, main="origin/main"):
    version_key(tag)
    sha = git(repo, "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    git(repo, "merge-base", "--is-ancestor", sha, main)
    # The private publisher retired root VERSION starting with 2.3.0.
    # Keep the historical contract for older immutable tags.
    if version_key(tag) < (2, 3, 0) and git(repo, "show", f"{sha}:VERSION") != tag:
        raise RuntimeError("Private tag must match VERSION")
    git(repo, "cat-file", "-e", f"{sha}:Package.swift")
    return sha


def verify_checkout(repo, tag, channel="release", local_commit=None):
    if local_commit:
        if channel != "local":
            raise RuntimeError("An explicit private commit is only allowed for the local build channel")
        if not re.fullmatch(r"[0-9a-f]{40}", local_commit):
            raise RuntimeError("Local private source requires a full commit SHA")
        if git(repo, "rev-parse", "HEAD") != local_commit or git(repo, "status", "--porcelain", "--untracked-files=all"):
            raise RuntimeError("Local private packaging requires a clean checkout of the explicit commit")
        git(repo, "cat-file", "-e", f"{local_commit}:Package.swift")
        return local_commit
    sha = verify_tag(repo, tag)
    if git(repo, "rev-parse", "HEAD") != sha or git(repo, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Private packaging requires a clean checkout of the manifest tag")
    if mac_changes(repo, sha, "origin/main"):
        raise RuntimeError("Unreleased Mac changes: release the private package, then upgrade the host manifest through a PR")
    return sha


def release(repo):
    if git(repo, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Private release checkout is dirty")
    main = git(repo, "rev-parse", "origin/main")
    if git(repo, "rev-parse", "HEAD") != main:
        raise RuntimeError("Release only from the exact fetched private origin/main")
    remote_tags = run("git", "ls-remote", "--tags", "origin", cwd=repo)
    tags = [line.split("refs/tags/", 1)[1] for line in remote_tags.splitlines()
            if "refs/tags/" in line and SEMVER.fullmatch(line.split("refs/tags/", 1)[1])]
    if not tags:
        raise RuntimeError("No standard SwiftPM baseline tag; bootstrap a reviewed release first")
    latest = max(tags, key=version_key)
    latest_sha = verify_tag(repo, latest)
    if not mac_changes(repo, latest_sha, main):
        print(f"PRIVATE PLATFORM unchanged tag={latest} commit={latest_sha}", file=sys.stderr)
        return latest
    if version_key(latest) >= (2, 3, 0):
        raise RuntimeError("Mac code changed. Publish a new standard tag in the private repository, then upgrade the host manifest through a PR")
    version = git(repo, "show", f"{main}:VERSION")
    if version_key(version) <= version_key(latest):
        major, minor, patch = version_key(latest)
        raise RuntimeError(f"Mac code changed. Bump VERSION through a private PR first (next patch: {major}.{minor}.{patch + 1}), then rerun release")
    # Existing tags are immutable, including tags not on main.
    local_tag = version in git(repo, "tag", "--list").splitlines()
    if local_tag and git(repo, "rev-parse", f"refs/tags/{version}^{{commit}}") != main:
        raise RuntimeError("Requested private version tag already exists; never move or overwrite it")
    print(f"PRIVATE PLATFORM validating version={version} commit={main}", file=sys.stderr)
    for command in ("test", "build"):
        run("swift", command, "--disable-keychain", "--package-path", str(repo),
            "--scratch-path", str(repo.parent / f".build-release-{main}"),
            "-c", "debug" if command == "test" else "release",
            timeout=1800, capture=False)
    remote_main = run("git", "ls-remote", "origin", "refs/heads/main", cwd=repo).split()[0]
    if remote_main != main:
        raise RuntimeError("Private main advanced during validation; fetch and validate again")
    if not local_tag:
        git(repo, "tag", "-a", version, main, "-m", f"SayAll private platform {version}")
    # No force, no branch pushes. A concurrent release or missing write access fails.
    try:
        git(repo, "push", "origin", f"refs/tags/{version}:refs/tags/{version}")
    except RuntimeError as error:
        raise RuntimeError("Private tag push failed or is unconfirmed. Check write permission and the remote tag, then retry the same version") from error
    remote = run("git", "ls-remote", "origin", f"refs/tags/{version}^{{}}", cwd=repo)
    if not remote or remote.split()[0] != main:
        raise RuntimeError("Published tag could not be verified against the validated commit")
    print(f"PRIVATE PLATFORM published tag={version} commit={main}", file=sys.stderr)
    return version


def verify_origin(repo):
    origin = git(repo, "remote", "get-url", "origin").removesuffix(".git")
    if origin not in (
        f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}",
        f"ssh://git@github.com/{REPOSITORY}",
    ):
        raise RuntimeError("Private checkout has an unexpected origin")


def fetch_checkout(root):
    repo = root / ".private-dependencies" / "release-control" / "sayall-private-platform"
    if not repo.exists():
        repo.parent.mkdir(parents=True, exist_ok=True)
        run("git", "clone", "--sparse", "--filter=blob:none", "--branch", "main", f"https://github.com/{REPOSITORY}.git", str(repo))
        git(repo, "sparse-checkout", "set", *(scope.rstrip("/") for scope in MAC_PATHS if scope.endswith("/")))
    verify_origin(repo)
    git(repo, "fetch", "origin", "main", "--tags")
    if git(repo, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Private release control checkout is dirty")
    git(repo, "checkout", "--detach", "origin/main")
    return repo


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_release_checksums(checksum_file):
    """Parse the publisher's ``<digest>  <name>`` asset into a mapping."""
    entries = {}
    for line in checksum_file.read_text(encoding="utf-8").splitlines():
        digest, separator, name = line.partition("  ")
        if separator and re.fullmatch(r"[0-9a-f]{64}", digest.strip()):
            entries[name.strip().lstrip("./")] = digest.strip()
    return entries


def download_release_archive(tag, destination):
    """Fetch the archive that the private publisher attached to the tag."""
    if shutil.which("gh") is None:
        raise RuntimeError(
            "Published private artifacts require the gh CLI; use --artifacts build to build them locally")
    archive_name = RELEASE_ASSET.format(tag=tag)
    run("gh", "release", "download", tag, "--repo", REPOSITORY,
        "--pattern", archive_name, "--pattern", f"{archive_name}.sha256",
        "--dir", str(destination), "--clobber", timeout=1800)
    archive = destination / archive_name
    checksums = destination / f"{archive_name}.sha256"
    if not archive.is_file() or not checksums.is_file():
        raise RuntimeError(
            f"Release {tag} does not publish {archive_name}; publish it or build the artifacts locally")
    entries = read_release_checksums(checksums)
    archive_digest = entries.get(archive_name)
    manifest_digest = entries.get("SHA256SUMS")
    if not archive_digest or not manifest_digest:
        raise RuntimeError("Published release checksums must cover both the archive and its SHA256SUMS")
    if sha256_file(archive) != archive_digest:
        raise RuntimeError("Published release archive does not match its published checksum")
    return archive, manifest_digest


def extract_release_archive(archive, destination):
    """Extract the archive only when every entry stays inside ``release/``."""
    with zipfile.ZipFile(archive) as bundle:
        for name in bundle.namelist():
            entry = PurePosixPath(name)
            if entry.is_absolute() or ".." in entry.parts or not entry.parts or entry.parts[0] != "release":
                raise RuntimeError(f"Published release archive has an unsafe entry: {name}")
        bundle.extractall(destination)
        # zipfile drops the stored permissions; the packaged helpers must stay
        # executable, and the artifact package rejects non-executable helpers.
        for info in bundle.infolist():
            mode = (info.external_attr >> 16) & 0o777
            target = destination / info.filename
            if mode and not info.is_dir() and target.is_file():
                target.chmod(mode)
    release_dir = destination / "release"
    if not release_dir.is_dir():
        raise RuntimeError("Published release archive does not contain a release directory")
    return release_dir


def package(root, mode, artifacts="build"):
    if mode == "public":
        return {"mode": "public", "reason": "explicit_public"}
    # Only an authentication failure permits the optional public build. Network,
    # rate limit and later source/build failures must remain visible failures.
    probe = subprocess.run(
        ["git", "ls-remote", f"https://github.com/{REPOSITORY}.git", "refs/heads/main"],
        text=True, capture_output=True, timeout=90,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    if probe.returncode:
        denied = any(text in probe.stderr.lower() for text in (
            "repository not found", "authentication failed", "terminal prompts disabled",
            "could not read username", "could not read password", "unable to get password from user"))
        if mode == "auto" and denied:
            return {"mode": "public", "reason": "private_read_unavailable"}
        raise RuntimeError("Private repository access failed; public fallback only applies to missing read permission")
    repo = fetch_checkout(root)
    version = release(repo)
    manifest = json.loads((root / "config/release-dependencies.json").read_text())
    pinned = manifest["dependencies"]["sayAllPrivatePlatform"]["version"]
    sha = verify_tag(repo, pinned)
    if mac_changes(repo, sha, "origin/main"):
        raise RuntimeError(f"Private release {version} is ready. Upgrade config/release-dependencies.json through a host PR before packaging")
    git(repo, "checkout", "--detach", f"refs/tags/{pinned}")
    verify_checkout(repo, pinned)
    if os.environ.get("CODE_SIGN_IDENTITY", "-") == "-":
        raise RuntimeError("Private Siri Remote packaging requires CODE_SIGN_IDENTITY; use SAYALL_PRIVATE_PLATFORM_MODE=public for a public build")
    # The release tag is the version identity; the commit is only its resolution.
    # Keying the cache by tag gives one directory per released version and makes
    # a stale entry obvious, while ``sha`` stays the value verified above.
    output = root / ".private-dependencies" / "artifacts" / pinned
    output.mkdir(parents=True, exist_ok=True)
    release_dir = output / "xcframeworks" / "release"
    prepared = output / "prepared"
    trusted_manifest_digest = None
    if not release_dir.exists():
        if artifacts == "release":
            # The published archive is an immutable per-tag build; reuse it
            # instead of rebuilding both XCFramework lanes from source.
            with tempfile.TemporaryDirectory(dir=output, prefix=".release-download-") as staging:
                staging_path = Path(staging)
                archive, published_manifest_digest = download_release_archive(pinned, staging_path)
                extracted = extract_release_archive(archive, staging_path)
                if sha256_file(extracted / "SHA256SUMS") != published_manifest_digest:
                    raise RuntimeError("Published release manifest does not match its published checksum")
                run("shasum", "-a", "256", "-c", "SHA256SUMS", cwd=extracted, timeout=300)
                (output / "xcframeworks").mkdir(parents=True, exist_ok=True)
                if release_dir.exists():
                    raise RuntimeError("Private release directory appeared during download")
                os.replace(extracted, release_dir)
                trusted_manifest_digest = published_manifest_digest
            print(f"PRIVATE PLATFORM artifacts reused from published release tag={pinned}", file=sys.stderr)
        else:
            run(str(repo / "tools/release/build-private-xcframeworks.sh"),
                str(output / "xcframeworks"), timeout=3600, capture=False)
    elif artifacts == "release":
        print(f"PRIVATE PLATFORM kept existing release directory tag={pinned}", file=sys.stderr)
    if not prepared.exists():
        digest = trusted_manifest_digest or run(
            "shasum", "-a", "256", str(release_dir / "SHA256SUMS")).split()[0]
        run(str(root / "scripts/prepare-private-artifact-package.sh"), str(release_dir),
            str(prepared), digest, timeout=300, capture=False)
    else:
        print(f"PRIVATE PLATFORM prepared cache hit tag={pinned}", file=sys.stderr)
    # build-app verifies the prepared manifest and every packaged byte on reuse.
    return {"mode": "private", "tag": pinned, "commit": sha,
            "checkout": str(repo), "artifacts": str(prepared)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("release", "check", "check-checkout", "package"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--checkout", type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--channel", choices=("local", "internalQA", "release"), default="release")
    parser.add_argument("--local-commit")
    parser.add_argument("--mode", choices=("auto", "public", "required"), default="auto")
    parser.add_argument("--artifacts", choices=("build", "release"), default="build",
                        help="build the XCFrameworks from the tag, or reuse the archive the tag published")
    args = parser.parse_args()
    manifest = json.loads((args.root / "config/release-dependencies.json").read_text())
    dependency = manifest["dependencies"]["sayAllPrivatePlatform"]
    if dependency["repository"] != REPOSITORY:
        raise RuntimeError("Unexpected private dependency repository")
    tag = args.tag or dependency["version"]
    version_key(tag)
    with ExitStack() as stack:
        if args.action == "package" or not args.checkout:
            lock_dir = args.root / ".private-dependencies"
            lock_dir.mkdir(parents=True, exist_ok=True)
            lock = stack.enter_context((lock_dir / "prepare.lock").open("w"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError("Another private platform preflight is running; retry after it finishes") from error
        if args.action == "package":
            print(json.dumps(package(args.root, args.mode, args.artifacts)))
            return
        repo = args.checkout.resolve() if args.checkout else fetch_checkout(args.root)
        verify_origin(repo)
        if args.action == "release":
            print(release(repo))
        elif args.action == "check-checkout":
            sha = verify_checkout(repo, tag, args.channel, args.local_commit)
            print(f"PRIVATE PLATFORM verified channel={args.channel} commit={sha}")
        else:
            sha = verify_tag(repo, tag)
            if mac_changes(repo, sha, "origin/main"):
                raise RuntimeError("Unreleased Mac changes: run prepare-private-platform.py release, then update the host manifest through a PR before packaging")
            print(f"PRIVATE PLATFORM ready tag={tag} commit={sha}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        print("PRIVATE PLATFORM failed: operation timed out; retain the version and inspect remote state before retrying", file=sys.stderr)
        sys.exit(1)
    except OSError as error:
        print(f"PRIVATE PLATFORM failed: system operation failed (errno {error.errno})", file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, ValueError, KeyError) as error:
        print(f"PRIVATE PLATFORM failed: {error}", file=sys.stderr)
        sys.exit(1)
