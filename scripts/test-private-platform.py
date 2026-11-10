#!/usr/bin/env python3
"""Exercise release ordering and public fallback with isolated Git repositories."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
import uuid
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("private_platform", ROOT / "scripts/prepare-private-platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
contents_spec = importlib.util.spec_from_file_location("release_contents", ROOT / "scripts/verify-release-contents.py")
contents = importlib.util.module_from_spec(contents_spec)
contents_spec.loader.exec_module(contents)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".private-dependencies/preflight-tests" / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.remote = self.directory / "remote.git"
        self.repo = self.directory / "checkout"
        self.command("git", "init", "--bare", str(self.remote))
        self.command("git", "clone", str(self.remote), str(self.repo))
        self.git("config", "user.name", "Release Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("VERSION", "2.2.0\n")
        self.write("Package.swift", "// package fixture\n")
        self.write("packages/macos-remote/Sources/runtime.swift", "baseline\n")
        self.commit()
        self.git("branch", "-M", "main")
        self.git("tag", "-a", "2.2.0", "-m", "baseline")
        self.git("push", "-u", "origin", "main", "--tags")
        self.baseline = self.git("rev-parse", "HEAD")
        self.swift_calls = []

    def tearDown(self):
        # Test repositories and failed fixtures remain recoverable.
        trash = Path.home() / ".Trash"
        trash.mkdir(exist_ok=True)
        shutil.move(str(self.directory), trash / f"sayall-private-preflight-{self.directory.name}")

    def command(self, *args, cwd=None):
        return subprocess.run(args, cwd=cwd, check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()

    def git(self, *args):
        return self.command("git", "-C", str(self.repo), *args)

    def write(self, name, value):
        target = self.repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-m", "fixture change")

    def advance(self, version=None):
        self.write("packages/macos-remote/Sources/runtime.swift", "new Mac runtime\n")
        if version:
            self.write("VERSION", version + "\n")
        self.commit()
        self.git("push", "origin", "main")

    def fake_swift(self, *args, **kwargs):
        if args[0] == "swift":
            self.swift_calls.append(args)
            return ""
        return self.original_run(*args, **kwargs)

    def publish(self):
        self.original_run = platform.run
        with patch.object(platform, "run", side_effect=self.fake_swift):
            return platform.release(self.repo)

    def test_unchanged_reuses_tag_without_validation(self):
        self.assertEqual(self.publish(), "2.2.0")
        self.assertEqual(self.swift_calls, [])

    def test_web_and_document_changes_do_not_release_mac(self):
        self.write("apps/web/source.ts", "website\n")
        self.write("packages/macos-remote/README.md", "documentation\n")
        self.commit()
        self.git("push", "origin", "main")
        self.assertEqual(self.publish(), "2.2.0")
        self.assertEqual(platform.mac_changes(self.repo, self.baseline, "HEAD"), [])

    def test_mac_test_changes_do_not_require_a_new_tag(self):
        self.write("packages/macos-remote/Tests/RemoteMicTests/runtimeTests.swift", "test\n")
        self.commit()
        self.git("push", "origin", "main")
        self.assertEqual(platform.mac_changes(self.repo, self.baseline, "HEAD"), [])
        self.assertEqual(self.publish(), "2.2.0")
        self.assertEqual(self.swift_calls, [])

    def test_mac_change_requires_reviewed_version_bump(self):
        self.advance()
        with self.assertRaisesRegex(RuntimeError, "Bump VERSION through a private PR"):
            self.publish()
        self.assertEqual(self.git("tag", "--list"), "2.2.0")

    def test_release_pushes_standard_tag_after_validation_and_is_idempotent(self):
        self.advance("2.2.1")
        sha = self.git("rev-parse", "HEAD")
        self.assertEqual(self.publish(), "2.2.1")
        self.assertEqual(self.command("git", "--git-dir", str(self.remote), "rev-parse", "2.2.1^{commit}"), sha)
        self.assertEqual([call[1] for call in self.swift_calls], ["test", "build"])
        self.assertTrue(all("--disable-keychain" in call for call in self.swift_calls))
        self.assertEqual([call[call.index("-c") + 1] for call in self.swift_calls],
                         ["debug", "release"])
        self.swift_calls.clear()
        self.assertEqual(self.publish(), "2.2.1")
        self.assertEqual(self.swift_calls, [])

    def test_validation_failure_never_creates_tag(self):
        self.advance("2.2.1")
        original = platform.run
        def failed(*args, **kwargs):
            if args[0] == "swift":
                raise RuntimeError("validation failed")
            return original(*args, **kwargs)
        with patch.object(platform, "run", side_effect=failed):
            with self.assertRaisesRegex(RuntimeError, "validation failed"):
                platform.release(self.repo)
        self.assertEqual(self.git("tag", "--list"), "2.2.0")

    def test_read_only_tag_push_failure_is_not_public_fallback(self):
        self.advance("2.2.1")
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "Private tag push failed"):
            self.publish()
        self.assertEqual(self.command("git", "--git-dir", str(self.remote), "tag", "--list"), "2.2.0")
        # A failed push leaves an immutable local tag that can be retried.
        hook.write_text("#!/bin/sh\nexit 0\n")
        self.assertEqual(self.publish(), "2.2.1")

    def test_check_checkout_rejects_main_dirty_and_stale_tag(self):
        self.advance("2.2.1")
        with self.assertRaisesRegex(RuntimeError, "clean checkout"):
            platform.verify_checkout(self.repo, "2.2.0")
        self.git("checkout", "--detach", "2.2.0")
        with self.assertRaisesRegex(RuntimeError, "Unreleased Mac changes"):
            platform.verify_checkout(self.repo, "2.2.0")
        self.write("untracked.swift", "unreviewed\n")
        with self.assertRaisesRegex(RuntimeError, "clean checkout"):
            platform.verify_checkout(self.repo, "2.2.0")

    def test_local_checkout_accepts_only_an_explicit_clean_commit(self):
        self.advance()
        sha = self.git("rev-parse", "HEAD")
        self.assertEqual(platform.verify_checkout(self.repo, "2.2.0", "local", sha), sha)
        for channel in ("release", "internalQA"):
            with self.assertRaisesRegex(RuntimeError, "only allowed for the local"):
                platform.verify_checkout(self.repo, "2.2.0", channel, sha)
        with self.assertRaisesRegex(RuntimeError, "full commit SHA"):
            platform.verify_checkout(self.repo, "2.2.0", "local", sha[:8])
        with self.assertRaisesRegex(RuntimeError, "clean checkout"):
            platform.verify_checkout(self.repo, "2.2.0", "local", self.baseline)
        self.write("untracked.swift", "unreviewed\n")
        with self.assertRaisesRegex(RuntimeError, "clean checkout"):
            platform.verify_checkout(self.repo, "2.2.0", "local", sha)

    def test_local_channel_without_explicit_commit_still_requires_the_tag(self):
        self.advance()
        with self.assertRaisesRegex(RuntimeError, "clean checkout"):
            platform.verify_checkout(self.repo, "2.2.0", "local")

    def test_move_out_of_mac_scope_is_detected(self):
        self.git("mv", "packages/macos-remote/Sources/runtime.swift", "runtime.swift")
        self.commit()
        self.assertTrue(platform.mac_changes(self.repo, self.baseline, "HEAD"))

    def test_scope_includes_resources_membership_and_build_tools(self):
        for path in ("Package.resolved", "packages/macos-membership/Package.swift",
                     "packages/audio-input-kit/chromecast/Sources/Resources/remote.png",
                     "tools/release/build-private-xcframeworks.sh"):
            self.assertTrue(platform.relevant(path), path)
        for path in ("apps/web/source.ts", "services/membership-api/index.ts",
                     "packages/macos-membership/README.md",
                     "packages/macos-remote/Tests/RemoteMicTests/runtimeTests.swift"):
            self.assertFalse(platform.relevant(path), path)

    def test_tag_requires_standard_semver_version_and_root_manifest(self):
        for tag in ("private-v2.2.0", "v2.2.0", "02.2.0", "2.2.0-rc.1"):
            with self.assertRaises(RuntimeError):
                platform.verify_tag(self.repo, tag)
        self.git("tag", "2.2.1")
        with self.assertRaisesRegex(RuntimeError, "match VERSION"):
            platform.verify_tag(self.repo, "2.2.1")

    def test_semver_230_consumes_tag_with_retired_version(self):
        self.advance()
        sha = self.git("rev-parse", "HEAD")
        self.git("tag", "-a", "2.3.0", "-m", "VERSION retired")
        self.git("push", "origin", "2.3.0")
        self.assertEqual(platform.verify_checkout(self.repo, "2.3.0"), sha)
        self.assertEqual(self.publish(), "2.3.0")
        self.assertEqual(self.swift_calls, [])

    def test_semver_230_mac_changes_require_private_publisher(self):
        self.git("tag", "-a", "2.3.0", "-m", "VERSION retired")
        self.git("push", "origin", "2.3.0")
        self.advance("2.3.1")
        with self.assertRaisesRegex(RuntimeError, "Publish a new standard tag in the private repository"):
            self.publish()
        self.assertNotIn("2.3.1", self.git("tag", "--list").splitlines())

    def test_semver_230_still_requires_main_ancestry_and_root_manifest(self):
        self.git("checkout", "-b", "unmerged")
        self.write("unmerged.txt", "unmerged\n")
        self.commit()
        self.git("tag", "2.3.0")
        with self.assertRaises(RuntimeError):
            platform.verify_tag(self.repo, "2.3.0")
        self.git("checkout", "main")
        self.git("mv", "Package.swift", "Retired.swift")
        self.commit()
        self.git("push", "origin", "main")
        self.git("tag", "2.3.1")
        with self.assertRaises(RuntimeError):
            platform.verify_tag(self.repo, "2.3.1")

    def test_origin_accepts_checkout_action_urls_and_rejects_other_repositories(self):
        for url in ("https://github.com/" + platform.REPOSITORY,
                    "git@github.com:" + platform.REPOSITORY + ".git"):
            self.git("remote", "set-url", "origin", url)
            platform.verify_origin(self.repo)
        self.git("remote", "set-url", "origin", "https://github.com/example/other.git")
        with self.assertRaisesRegex(RuntimeError, "unexpected origin"):
            platform.verify_origin(self.repo)

    def test_conflicting_local_tag_is_never_overwritten(self):
        self.advance("2.2.1")
        self.git("tag", "2.2.1", self.baseline)
        with self.assertRaisesRegex(RuntimeError, "never move or overwrite"):
            self.publish()
        self.assertEqual(self.git("rev-parse", "2.2.1"), self.baseline)

    def test_main_advancing_during_validation_prevents_publication(self):
        self.advance("2.2.1")
        original = platform.run
        def advance_main(*args, **kwargs):
            if args[:2] == ("swift", "build"):
                self.write("apps/web/main.ts", "concurrent commit\n")
                self.commit()
                self.git("push", "origin", "main")
                return ""
            if args[0] == "swift":
                return ""
            return original(*args, **kwargs)
        with patch.object(platform, "run", side_effect=advance_main):
            with self.assertRaisesRegex(RuntimeError, "main advanced"):
                platform.release(self.repo)
        self.assertEqual(self.git("tag", "--list"), "2.2.0")

    def make_host(self):
        host = self.directory / "host"
        (host / "config").mkdir(parents=True)
        (host / "config/release-dependencies.json").write_text(json.dumps({
            "dependencies": {"sayAllPrivatePlatform": {"repository": platform.REPOSITORY, "version": "2.2.0"}}
        }))
        return host

    def private_probe(self, args, **kwargs):
        if args[:2] == ["git", "ls-remote"] and platform.REPOSITORY in args[2]:
            return subprocess.CompletedProcess(args, 0, self.baseline + " refs/heads/main", "")
        return self.real_subprocess(args, **kwargs)

    def test_package_uses_manifest_tag_and_reuses_prepared_artifacts(self):
        host = self.make_host()
        original = platform.run
        self.real_subprocess = subprocess.run
        calls = []
        def build(*args, **kwargs):
            if args[0].endswith("build-private-xcframeworks.sh"):
                calls.append("build")
                release_dir = Path(args[1]) / "release"
                release_dir.mkdir(parents=True)
                (release_dir / "SHA256SUMS").write_text("fixture\n")
                return ""
            if args[0].endswith("prepare-private-artifact-package.sh"):
                calls.append("prepare")
                Path(args[2]).mkdir()
                return ""
            return original(*args, **kwargs)
        with patch.object(platform.subprocess, "run", side_effect=self.private_probe), \
             patch.object(platform, "fetch_checkout", return_value=self.repo), \
             patch.object(platform, "run", side_effect=build), \
             patch.dict(os.environ, {"CODE_SIGN_IDENTITY": "test fixture identity"}):
            result = platform.package(host, "auto")
            self.assertEqual(result["tag"], "2.2.0")
            self.assertEqual(result["commit"], self.baseline)
            self.assertEqual(self.git("rev-parse", "HEAD"), self.baseline)
            self.assertEqual(platform.package(host, "auto"), result)
        self.assertEqual(calls, ["build", "prepare"])

    def test_stale_host_pin_stops_before_packaging(self):
        host = self.make_host()
        self.advance("2.2.1")
        self.publish()
        self.real_subprocess = subprocess.run
        with patch.object(platform.subprocess, "run", side_effect=self.private_probe), \
             patch.object(platform, "fetch_checkout", return_value=self.repo):
            with self.assertRaisesRegex(RuntimeError, "Upgrade config/release-dependencies.json"):
                platform.package(host, "auto")
        self.assertFalse((host / ".private-dependencies/artifacts").exists())


class AccessTests(unittest.TestCase):
    def test_no_read_permission_uses_public_mode(self):
        for message in ("fatal: Repository not found", "fatal: unable to get password from user"):
            denied = subprocess.CompletedProcess([], 128, "", message)
            with patch.object(platform.subprocess, "run", return_value=denied):
                self.assertEqual(platform.package(ROOT, "auto")["mode"], "public")
                with self.assertRaises(RuntimeError):
                    platform.package(ROOT, "required")

    def test_network_failure_does_not_hide_as_no_permission(self):
        network = subprocess.CompletedProcess([], 128, "", "Could not resolve host: github.com")
        with patch.object(platform.subprocess, "run", return_value=network):
            with self.assertRaises(RuntimeError):
                platform.package(ROOT, "auto")

    def test_public_mode_never_probes_private_repository(self):
        with patch.object(platform.subprocess, "run", side_effect=AssertionError("unexpected network")):
            self.assertEqual(platform.package(ROOT, "public")["mode"], "public")

    def test_readable_private_failure_is_not_downgraded(self):
        accessible = subprocess.CompletedProcess([], 0, "abc refs/heads/main", "")
        with patch.object(platform.subprocess, "run", return_value=accessible), \
             patch.object(platform, "fetch_checkout", side_effect=RuntimeError("corrupt checkout")):
            with self.assertRaisesRegex(RuntimeError, "corrupt checkout"):
                platform.package(ROOT, "auto")


class PublishedArtifactTests(unittest.TestCase):
    """Exercise the published-release reuse path without network access."""

    def setUp(self):
        self.directory = ROOT / ".private-dependencies/preflight-tests" / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.tag = "9.9.9"
        identity = patch.object(platform, "verify_published_tag", return_value="a" * 40)
        identity.start()
        self.addCleanup(identity.stop)

    def tearDown(self):
        # Failed fixtures stay recoverable instead of being deleted in place.
        trash = Path.home() / ".Trash"
        trash.mkdir(exist_ok=True)
        shutil.move(str(self.directory), trash / f"sayall-private-artifacts-{self.directory.name}")

    def manifest_digest(self):
        return hashlib.sha256(self.manifest).hexdigest()

    def write_archive(self, destination):
        destination.mkdir(parents=True, exist_ok=True)
        archive = destination / platform.RELEASE_ASSET.format(tag=self.tag)
        helper_bytes = b"helper\n"
        helper_digest = hashlib.sha256(helper_bytes).hexdigest()
        self.manifest = f"{helper_digest}  ./Helpers/AppleRemoteHCIService\n".encode()
        helper = zipfile.ZipInfo("release/Helpers/AppleRemoteHCIService")
        helper.external_attr = 0o100755 << 16
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("release/SHA256SUMS", self.manifest)
            bundle.writestr("release/provenance.json", json.dumps({
                "source_repository": platform.REPOSITORY,
                "source_commit": "a" * 40,
                "repository_state": {"dirty": False},
            }))
            bundle.writestr(helper, helper_bytes)
        checksums = destination / f"{archive.name}.sha256"
        checksums.write_text(
            f"{platform.sha256_file(archive)}  {archive.name}\n{self.manifest_digest()}  SHA256SUMS\n")
        return archive

    def fake_gh(self, *args, cwd=None, timeout=90, capture=True):
        self.write_archive(Path(args[args.index("--dir") + 1]))
        return ""

    def test_download_reuses_published_checksums(self):
        with patch.object(platform, "run", side_effect=self.fake_gh), \
                patch.object(platform.shutil, "which", return_value="/opt/homebrew/bin/gh"):
            archive, manifest_digest = platform.download_release_archive(self.tag, self.directory)
            self.assertTrue(archive.is_file())
            self.assertEqual(manifest_digest, self.manifest_digest())
            extracted = platform.extract_release_archive(archive, self.directory / "staging")
            self.assertEqual((extracted / "SHA256SUMS").read_bytes(), self.manifest)
            helper = extracted / "Helpers" / "AppleRemoteHCIService"
            self.assertTrue(os.access(helper, os.X_OK), "packaged helpers must stay executable")

    def test_tampered_archive_is_rejected(self):
        archive = self.write_archive(self.directory)
        checksums = self.directory / f"{archive.name}.sha256"
        checksums.write_text(
            f"{'0' * 64}  {archive.name}\n{self.manifest_digest()}  SHA256SUMS\n")
        with patch.object(platform, "run"), \
                patch.object(platform.shutil, "which", return_value="/opt/homebrew/bin/gh"):
            with self.assertRaisesRegex(RuntimeError, "archive does not match its published checksum"):
                platform.download_release_archive(self.tag, self.directory)

    def test_release_without_checksums_is_rejected(self):
        (self.directory / platform.RELEASE_ASSET.format(tag=self.tag)).write_bytes(b"archive")
        with patch.object(platform, "run"), \
                patch.object(platform.shutil, "which", return_value="/opt/homebrew/bin/gh"):
            with self.assertRaisesRegex(RuntimeError, "does not publish"):
                platform.download_release_archive(self.tag, self.directory)

    def test_missing_gh_stops_artifact_consumption(self):
        with patch.object(platform.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "gh CLI"):
                platform.download_release_archive(self.tag, self.directory)

    def test_archive_entries_must_stay_inside_release(self):
        for name in ("release/../escape", "other/file.txt", "/absolute"):
            archive = self.directory / f"unsafe-{uuid.uuid4().hex}.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr(name, b"x")
            with self.assertRaisesRegex(RuntimeError, "unsafe entry"):
                platform.extract_release_archive(archive, self.directory / uuid.uuid4().hex)


    def test_fetch_artifacts_materializes_the_release_directory(self):
        archive = self.write_archive(self.directory / "download")
        digest = self.manifest_digest()
        output = self.directory / "output"
        with patch.object(platform, "download_release_archive", return_value=(archive, digest)):
            result = platform.fetch_artifacts(self.tag, output)
        self.assertEqual(result["manifestSHA256"], digest)
        self.assertEqual(Path(result["release"]), output.resolve() / "release")
        self.assertTrue((output / "release" / "SHA256SUMS").is_file())
        self.assertTrue(os.access(output / "release" / "Helpers" / "AppleRemoteHCIService", os.X_OK))

    def test_fetch_artifacts_refuses_a_non_empty_output(self):
        output = self.directory / "output"
        output.mkdir()
        (output / "leftover").write_text("x")
        with self.assertRaisesRegex(RuntimeError, "must be absent or empty"):
            platform.fetch_artifacts(self.tag, output)

    def test_artifact_provenance_is_bound_to_the_clean_tag(self):
        provenance = {
            "source_repository": platform.REPOSITORY,
            "source_commit": "a" * 40,
            "repository_state": {"dirty": False},
        }
        path = self.directory / "provenance.json"
        path.write_text(json.dumps(provenance))
        platform.verify_artifact_identity(self.directory, "a" * 40)
        for key, value in (
            ("source_repository", "example/other"),
            ("source_commit", "b" * 40),
            ("repository_state", {"dirty": True}),
        ):
            path.write_text(json.dumps({**provenance, key: value}))
            with self.assertRaisesRegex(RuntimeError, "provenance does not match"):
                platform.verify_artifact_identity(self.directory, "a" * 40)

    def test_checksum_paths_cannot_escape_or_repeat(self):
        checksum = self.directory / "SHA256SUMS"
        for name in ("../outside", "/absolute", "./../outside", "folder\\outside"):
            checksum.write_text(f"{'a' * 64}  {name}\n")
            with self.assertRaisesRegex(RuntimeError, "invalid or duplicate path"):
                platform.read_release_checksums(checksum)
        checksum.write_text((f"{'a' * 64}  ./same\n") * 2)
        with self.assertRaisesRegex(RuntimeError, "invalid or duplicate path"):
            platform.read_release_checksums(checksum)


class PublishedIdentityTests(unittest.TestCase):
    def setUp(self):
        self.commit = "a" * 40
        self.main = "b" * 40
        self.responses = {
            "git/ref/tags/2.7.9": {"object": {"type": "tag", "sha": "c" * 40}},
            "git/tags/" + "c" * 40: {"tag": "2.7.9", "object": {"type": "commit", "sha": self.commit}},
            "git/ref/heads/main": {"object": {"sha": self.main}},
            f"compare/{self.commit}...{self.main}?per_page=1&page=2": {
                "status": "ahead", "merge_base_commit": {"sha": self.commit},
            },
            "git/trees/" + self.commit: {"tree": [{"path": "Package.swift", "type": "blob"}]},
        }
        self.api = patch.object(platform, "github_json", side_effect=lambda path: self.responses[path])
        self.api.start()
        self.addCleanup(self.api.stop)

    def comparison(self):
        return self.responses[f"compare/{self.commit}...{self.main}?per_page=1&page=2"]

    def test_tag_and_main_are_verified_without_source_checkout(self):
        with patch.object(platform, "git", side_effect=AssertionError("private source access")):
            self.assertEqual(platform.verify_published_tag("2.7.9"), self.commit)

    def test_private_main_advancement_preserves_the_selected_binary_tag(self):
        self.assertEqual(platform.verify_published_tag("2.7.9"), self.commit)

    def test_ancestry_query_rejects_responses_that_include_file_diffs(self):
        self.comparison()["files"] = []
        with self.assertRaisesRegex(RuntimeError, "must exclude source diffs"):
            platform.verify_published_tag("2.7.9")

    def test_non_ancestor_and_lightweight_tags_are_rejected(self):
        self.comparison()["status"] = "diverged"
        with self.assertRaisesRegex(RuntimeError, "ancestor"):
            platform.verify_published_tag("2.7.9")
        self.responses["git/ref/tags/2.7.9"]["object"]["type"] = "commit"
        with self.assertRaisesRegex(RuntimeError, "annotated"):
            platform.verify_published_tag("2.7.9")

    def test_missing_root_package_is_rejected(self):
        self.responses["git/trees/" + self.commit]["tree"] = []
        with self.assertRaisesRegex(RuntimeError, "root package"):
            platform.verify_published_tag("2.7.9")

    def test_distribution_never_falls_back_to_source_compilation(self):
        directory = ROOT / ".private-dependencies/preflight-tests" / uuid.uuid4().hex
        (directory / "config").mkdir(parents=True)
        (directory / "config/release-dependencies.json").write_text(json.dumps({
            "dependencies": {"sayAllPrivatePlatform": {"version": "2.7.9"}},
        }))
        try:
            with patch.object(platform, "fetch_checkout", side_effect=AssertionError("private checkout")), \
                 patch.object(platform, "fetch_artifacts", side_effect=RuntimeError("attachment unavailable")):
                with self.assertRaisesRegex(RuntimeError, "attachment unavailable"):
                    platform.package(directory, "required", channel="release")
        finally:
            trash = Path.home() / ".Trash"
            trash.mkdir(exist_ok=True)
            shutil.move(str(directory), trash / f"sayall-distribution-boundary-{directory.name}")


class PublicWorkflowBoundaryTests(unittest.TestCase):
    def test_packaging_defaults_to_public(self):
        source = (ROOT / "scripts/build-app.sh").read_text()
        line = next(line for line in source.splitlines() if line.startswith("SAYALL_PRIVATE_PLATFORM_MODE="))
        environment = dict(os.environ)
        environment.pop("SAYALL_PRIVATE_PLATFORM_MODE", None)
        result = subprocess.run(["/bin/zsh", "-c", line + '; print -r -- "$SAYALL_PRIVATE_PLATFORM_MODE"'],
                                env=environment, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "public")

    def test_public_workflows_exclude_private_sources(self):
        for name in ("mac-release-package.yml", "mac-private-ci.yml"):
            source = (ROOT / ".github/workflows" / name).read_text()
            for forbidden in ("build-private-xcframeworks", "SAYALL_ENABLE_PRIVATE_SWIFTPM", ".private-dependencies/sayall-private-platform", ".private-dependencies/sayall-ai"):
                self.assertNotIn(forbidden, source)

    def test_private_binary_diagnostics_stay_out_of_public_logs(self):
        source = (ROOT / ".github/workflows/mac-release-package.yml").read_text()
        for log in ("private-artifact-preparation.log", "private-signed-release.log"):
            self.assertIn(f'> "$RUNNER_TEMP/{log}" 2>&1', source)
        self.assertIn('echo "SIGNED RELEASE result=failed"', source)

    def test_distribution_rejects_explicit_source_paths_before_building(self):
        for channel in ("release", "internalQA"):
            environment = dict(os.environ)
            for key in list(environment):
                if key.startswith("SAYALL_"):
                    environment.pop(key)
            environment.update({
                "SAYALL_BUILD_CHANNEL": channel,
                "SAYALL_PRIVATE_PLATFORM_MODE": "required",
                "SAYALL_MAC_REMOTE_PACKAGE_PATH": "/private-source-fixture",
                "CODE_SIGN_IDENTITY": "-",
                "REMOTE_MIC_SENTRY_DSN": "https://fixture@sentry.example.invalid/1",
            })
            result = subprocess.run(["/bin/zsh", str(ROOT / "scripts/build-app.sh")],
                                    env=environment, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Distribution packaging requires published private binaries", result.stderr)


class PublicationFlowTests(unittest.TestCase):
    """Run the complete production publisher with isolated Git/API/download peers."""
    command = ReleaseTests.command
    git = ReleaseTests.git

    def setUp(self):
        self.directory = ROOT / ".private-dependencies/preflight-tests" / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.repo = self.directory / "checkout"
        self.remote = self.directory / "origin.git"
        self.command("git", "init", "--bare", str(self.remote))
        self.command("git", "init", "-b", "main", str(self.repo))
        self.git("config", "user.name", "Publication Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("remote", "add", "origin", str(self.remote))
        scripts = self.repo / "scripts"
        scripts.mkdir()
        shutil.copyfile(ROOT / "scripts/publish-preview-release.sh", scripts / "publish-preview-release.sh")
        for name, body in {
            "recover-preview-stage.sh": 'mkdir -p "$6/stage-record"; cp -R "$FIXTURE/bundle" "$6/bundle"; echo "{}" > "$6/stage-record/preview-stage-record.json"',
            "record-preview-ui-attestation.sh": "exit 0",
            "verify-public-release-source.sh": "exit 0",
            "verify-preview-cdn-availability.sh": 'if [[ "${FIXTURE_MODE}" == "contract" ]]; then exit 1; fi',
        }.items():
            path = scripts / name
            path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
            path.chmod(0o755)
        self.git("add", ".")
        self.git("commit", "-m", "publication fixture")
        self.git("push", "-u", "origin", "main")
        commit = self.git("rev-parse", "HEAD")
        public = self.directory / "bundle/public"
        public.mkdir(parents=True)
        names = [f"payload-{index}.txt" for index in range(8)] + ["appcast.xml", "appcast-intel.xml"]
        assets = []
        for name in names:
            data = ("signed fixture " + name).encode()
            (public / name).write_bytes(data)
            assets.append({"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {"schemaVersion": 2, "tag": "v9.9.9", "sourceCommit": commit,
                    "version": "9.9.9", "build": "999", "assets": assets}
        manifest_path = public.parent / "staged-assets.json"
        manifest_path.write_text(json.dumps(manifest))
        (public.parent / "release-notes.md").write_text("- Fixture release.\n")
        self.attestation = self.directory / "attestation.json"
        self.attestation.write_text(json.dumps({
            "schemaVersion": 4, "result": "passed", "mode": "preview", "tag": "v9.9.9",
            "sourceBranch": "main", "sourceKind": "main", "sourceBaseTag": "", "sourceBaseCommit": "",
            "sourceCommit": commit, "sourceWorkflowCommit": commit, "sourceRunId": 1,
            "sourceRunAttempt": 1, "signedArtifactId": 2, "signedArtifactDigest": "sha256:" + "a" * 64,
            "assetManifestSHA256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "stagedAt": "2026-11-10T00:00:00Z", "target": {"version": "9.9.9", "build": "999"},
        }))
        (self.directory / "state.json").write_text(json.dumps({"release": None, "events": []}))
        for name in ("gh", "curl"):
            path = self.directory / name
            path.write_text(self.peer_source)
            path.chmod(0o755)

    def tearDown(self):
        trash = Path.home() / ".Trash"
        trash.mkdir(exist_ok=True)
        shutil.move(str(self.directory), trash / f"sayall-publication-{self.directory.name}")

    def state(self):
        return json.loads((self.directory / "state.json").read_text())

    def publish(self, mode="success"):
        return subprocess.run(["/bin/bash", str(self.repo / "scripts/publish-preview-release.sh"), str(self.attestation)],
                              env={**os.environ, "REPOSITORY_ROOT": str(self.repo), "FIXTURE": str(self.directory),
                                   "GH_BIN": str(self.directory / "gh"), "CURL_BIN": str(self.directory / "curl"),
                                   "GITHUB_REPOSITORY": "HD838A/remote-mic-app", "RELEASE_ALLOW_LOCAL_FIXTURE": "1",
                                   "FIXTURE_MODE": mode}, capture_output=True, text=True, timeout=30)

    def test_draft_readback_precedes_publication_and_retry_preserves_ids(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.state()
        self.assertFalse(state["release"]["isDraft"])
        self.assertTrue(state["release"]["isPrerelease"])
        self.assertEqual(len(state["release"]["assets"]), 11)
        self.assertEqual(state["events"].count("authenticated"), 11)
        self.assertGreater(state["events"].index("publish"), max(index for index, event in enumerate(state["events"]) if event == "authenticated"))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["release"], state["release"])
        self.assertEqual(self.state()["events"].count("upload"), 11)

    def test_partial_upload_stays_draft_and_resumes_without_overwriting(self):
        result = self.publish("partial")
        self.assertNotEqual(result.returncode, 0)
        state = self.state()
        self.assertTrue(state["release"]["isDraft"])
        self.assertNotIn("publish", state["events"])
        existing = state["release"]["assets"][:]
        self.assertEqual(len(existing), 2)
        state["release"]["isPrerelease"] = False
        (self.directory / "state.json").write_text(json.dumps(state))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["release"]["assets"][:2], existing)
        self.assertTrue(self.state()["release"]["isPrerelease"])
        self.assertEqual(self.state()["events"].count("upload"), 11)

    def test_bad_count_digest_and_authenticated_bytes_never_become_public(self):
        for mode in ("count", "digest", "authenticated"):
            with self.subTest(mode=mode):
                result = self.publish(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.state()["release"]["isDraft"])
                self.assertNotIn("publish", self.state()["events"])

    def test_public_download_failure_retracts_same_release_to_draft(self):
        result = self.publish("cdn")
        self.assertNotEqual(result.returncode, 0)
        state = self.state()
        self.assertTrue(state["release"]["isDraft"])
        self.assertEqual(state["release"]["databaseId"], 123)
        self.assertEqual(state["events"][-1], "draft")
        self.assertIn("publish", state["events"])
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["release"]["databaseId"], 123)
        self.assertEqual(self.state()["events"].count("upload"), 11)

    def test_retraction_api_failure_emits_an_actionable_release_id(self):
        result = self.publish("retract")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRAFT RETRACTION FAILED", result.stderr)
        self.assertIn("123", result.stderr)
        self.assertEqual(self.state()["release"]["databaseId"], 123)
        self.assertFalse(self.state()["release"]["isDraft"])

    def test_incompatible_contract_stops_before_remote_identity_creation(self):
        result = self.publish("contract")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(self.state()["release"])
        self.assertEqual(self.state()["events"], [])

    def test_termination_leaves_uploaded_assets_in_draft(self):
        result = self.publish("terminate")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertTrue(self.state()["release"]["isDraft"])
        self.assertNotIn("publish", self.state()["events"])

    def test_metadata_mismatch_is_retracted_without_overwriting_notes(self):
        self.assertEqual(self.publish().returncode, 0)
        state = self.state()
        state["release"]["body"] = "Other reviewed notes"
        (self.directory / "state.json").write_text(json.dumps(state))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state()["release"]["isDraft"])
        self.assertEqual(self.state()["release"]["body"], "Other reviewed notes")
        self.assertEqual(self.state()["events"].count("upload"), 11)

    def test_legacy_manifest_uses_its_own_payload_count(self):
        manifest_path = self.directory / "bundle/staged-assets.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["schemaVersion"] = 1
        for index in range(3):
            name = f"legacy-{index}.txt"
            data = b"legacy signed fixture"
            (self.directory / "bundle/public" / name).write_bytes(data)
            manifest["assets"].append({"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        manifest_path.write_text(json.dumps(manifest))
        attestation = json.loads(self.attestation.read_text())
        attestation["assetManifestSHA256"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        self.attestation.write_text(json.dumps(attestation))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.state()["release"]["assets"]), 14)

    peer_source = r'''#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

root = Path(os.environ["FIXTURE"])
mode = os.environ["FIXTURE_MODE"]
state_path = root / "state.json"
state = json.loads(state_path.read_text())
args = sys.argv[1:]
release = state["release"]

def save():
    state_path.write_text(json.dumps(state))

if Path(sys.argv[0]).name == "curl":
    url = next(value for value in args if value.startswith("https://"))
    name = url.rsplit("/", 1)[1]
    output = Path(args[args.index("--output") + 1])
    if mode in ("cdn", "retract") and "download.sayall.app/mac/releases/" in url:
        output.write_bytes(b"wrong CDN bytes")
    elif "/v1.0.0/" in url or "/channels/stable/" in url:
        output.write_bytes(b"stable " + name.encode())
    else:
        shutil.copyfile(root / "uploaded" / name, output)
    sys.exit(0)

if args[0] == "api":
    endpoint = next(value for value in args if value.startswith("repos/"))
    fields = dict(args[index + 1].split("=", 1) for index, value in enumerate(args) if value in ("-f", "-F"))
    if endpoint.endswith("releases/latest"):
        print(json.dumps({"tag_name": "v1.0.0", "draft": False, "prerelease": False}))
    elif endpoint.endswith("git/refs"):
        subprocess.run(["git", "--git-dir", str(root / "origin.git"), "update-ref", fields["ref"], fields["sha"]], check=True)
        print("{}")
    elif "/releases/assets/" in endpoint:
        asset = next(asset for asset in release["assets"] if asset["apiUrl"].endswith("/" + endpoint.rsplit("/", 1)[1]))
        assert release["isDraft"], "authenticated check must precede publication"
        state["events"].append("authenticated")
        save()
        if mode == "terminate":
            os.kill(os.getppid(), signal.SIGTERM)
            sys.exit(143)
        sys.stdout.buffer.write(b"bad" if mode == "authenticated" else (root / "uploaded" / asset["name"]).read_bytes())
    elif "/releases/tags/" in endpoint:
        if release is None:
            print("HTTP/2.0 404 Not Found")
            sys.exit(1)
        print(json.dumps(release))
    elif endpoint.endswith("releases/123"):
        if "--method" in args:
            if mode == "retract" and fields["draft"] == "true" and "publish" in state["events"]:
                sys.exit(1)
            release["isDraft"] = fields["draft"] == "true"
            if "prerelease" in fields:
                release["isPrerelease"] = fields["prerelease"] == "true"
            state["events"].append("draft" if release["isDraft"] else "publish")
            save()
        print(json.dumps({"id": 123, "draft": release["isDraft"], "prerelease": release["isPrerelease"]}))
    else:
        raise AssertionError(args)
elif args[:2] == ["release", "create"]:
    assert "--draft" in args
    assert release is None
    state["release"] = {"databaseId": 123, "isDraft": True, "isPrerelease": True, "tagName": "v9.9.9",
                        "name": args[args.index("--title") + 1], "body": Path(args[args.index("--notes-file") + 1]).read_text(), "assets": []}
    state["events"].append("create-draft")
    save()
elif args[:2] == ["release", "view"]:
    if release is None:
        sys.exit(1)
    result = json.loads(json.dumps(release))
    if len(result["assets"]) == 11:
        if mode == "count":
            result["assets"].pop()
        if mode == "digest":
            result["assets"][0]["digest"] = "sha256:" + "0" * 64
    print(json.dumps(result))
elif args[:2] == ["release", "upload"]:
    assert release["isDraft"], "upload must happen under Draft protection"
    if mode == "partial" and len(release["assets"]) == 2:
        sys.exit(1)
    source = Path(args[3])
    assert not any(asset["name"] == source.name for asset in release["assets"]), "immutable assets cannot be overwritten"
    (root / "uploaded").mkdir(exist_ok=True)
    shutil.copyfile(source, root / "uploaded" / source.name)
    data = source.read_bytes()
    release["assets"].append({"id": "RA_fixture_" + str(len(release["assets"])),
                              "apiUrl": "https://api.github.com/repos/HD838A/remote-mic-app/releases/assets/" + str(1000 + len(release["assets"])),
                              "name": source.name, "size": len(data),
                              "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
    state["events"].append("upload")
    save()
else:
    raise AssertionError(args)
'''


class ReleaseContentTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".private-dependencies/preflight-tests" / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.scratch = self.directory / "scratch"
        self.scratch.mkdir()

    def tearDown(self):
        trash = Path.home() / ".Trash"
        trash.mkdir(exist_ok=True)
        shutil.move(str(self.directory), trash / f"sayall-release-contents-{self.directory.name}")

    def archive(self, name, data=b"fixture", destination="fixture.zip"):
        path = self.directory / destination
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(name, data)
        return path

    def test_private_development_inputs_are_rejected(self):
        for name in ("SayAll.app/source.swift", "archive.xcframework/module", "app.dSYM/Contents/info", "module.swiftinterface", "build.log", ".env", "release.p12"):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                contents.verify_asset(self.archive(name), self.scratch)

    def test_nested_archives_are_inspected(self):
        inner = self.archive("private.swift", destination="inner.zip")
        outer = self.archive("SayAll.app/Contents/Resources/inner.zip", inner.read_bytes(), "outer.zip")
        with self.assertRaisesRegex(RuntimeError, "development input"):
            contents.verify_asset(outer, self.scratch)

    def test_credentials_and_local_build_paths_are_rejected(self):
        for data in (b"ghp_" + b"a" * 36, b"/Users/example/private/source.swift\0"):
            with self.assertRaises(RuntimeError):
                contents.verify_asset(self.archive("SayAll.app/Contents/MacOS/RemoteMic", data), self.scratch)

    def test_public_vendor_paths_and_runtime_bytes_are_accepted(self):
        data = b"/Users/runner/work/sentry-cocoa/sentry-cocoa/Sources/Sentry/SentryClient.m\0runtime\0"
        contents.verify_asset(self.archive("SayAll.app/Contents/MacOS/RemoteMic", data), self.scratch)

    def test_public_driver_documentation_example_is_accepted_without_allowing_private_paths(self):
        example = b"Note that the directory is the root `/Library` not `/Users/user/Library`.\n"
        contents.verify_asset(self.archive("MiRemoteV2ch.driver/Contents/Resources/README.md", example), self.scratch)
        for data in (b"/Users/user/Library/private.swift", b"/Users/user/project",
                     b"/Users/runner/work/private/source.swift", b"/Users/another/Library`.",
                     example + b"/Users/example/private/source.swift\0"):
            with self.subTest(data=data), self.assertRaisesRegex(RuntimeError, "local build path"):
                contents.verify_asset(self.archive("README.md", data), self.scratch)

    def test_content_rejection_reports_only_a_fixed_reason(self):
        for entry, data, reason in (("PRIVATE_CANARY.swift", b"fixture", "development-input"),
                                    ("README.md", b"/Users/PRIVATE_CANARY/source.swift", "local-path")):
            with self.subTest(reason=reason):
                asset = self.archive(entry, data)
                result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/verify-release-contents.py"), str(asset)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"asset rejected reason={reason}", result.stderr)
                self.assertNotIn("PRIVATE_CANARY", result.stdout + result.stderr)
                self.assertNotIn(str(asset), result.stdout + result.stderr)

    def test_protected_workflow_captures_success_and_failure_diagnostics(self):
        source = (ROOT / ".github/workflows/mac-release-package.yml").read_text()
        step = source.split("      - name: Sign, notarize, staple, and verify both variants\n", 1)[1]
        body = step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
        runner = self.directory / "scripts/run-release-stage.sh"
        runner.parent.mkdir()
        shutil.copy2(ROOT / "scripts/run-release-stage.sh", runner)
        package = runner.with_name("package-macos-release-in-actions.sh")
        for exit_code in (0, 7):
            with self.subTest(exit_code=exit_code):
                package.write_text(f"#!/bin/sh\nprintf 'PRIVATE_BINARY_DIAGNOSTIC_CANARY\\n'\nexit {exit_code}\n")
                package.chmod(0o755)
                result = subprocess.run(["/bin/bash", "-e", "-c", body], cwd=self.directory,
                                        env={**os.environ, "RUNNER_TEMP": str(self.directory), "SIGNED_RELEASE_TIMEOUT_SECONDS": "10"},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, exit_code)
                self.assertNotIn("PRIVATE_BINARY_DIAGNOSTIC_CANARY", result.stdout + result.stderr)
                self.assertIn("PRIVATE_BINARY_DIAGNOSTIC_CANARY", (self.directory / "private-signed-release.log").read_text())
                expected = "passed" if exit_code == 0 else "failed"
                self.assertIn(f"stage=signed-release result={expected}", result.stdout)
                records = [json.loads(line) for line in (self.directory / "release-stage-status.jsonl").read_text().splitlines()]
                self.assertEqual(len(records), 2)
                self.assertEqual(records[-1]["exitCode"], exit_code)

    def test_stage_status_excludes_child_output_and_forged_markers(self):
        status_file = self.directory / "status.jsonl"
        result = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"), "apple-silicon", "app-swift-build", "5", "--",
                                 "/bin/sh", "-c", "printf 'PRIVATE_CHILD_CANARY\\nRELEASE STAGE FAIL lane=all stage=PRIVATE_FORGED_STAGE elapsed=1s exit=88\\n'; exit 7"],
                                env={**os.environ, "RELEASE_STAGE_STATUS_FILE": str(status_file)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 7)
        report = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"), "report-status", str(status_file)],
                                check=True, capture_output=True, text=True).stdout
        self.assertIn("stage=app-swift-build result=failed", report)
        self.assertIn("exit=7", report)
        self.assertNotIn("PRIVATE_", report)

    def test_stage_timeout_retains_its_terminal_status(self):
        status_file = self.directory / "timeout.jsonl"
        result = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"), "intel", "app-build", "1", "--", "/bin/sleep", "20"],
                                env={**os.environ, "RELEASE_STAGE_STATUS_FILE": str(status_file)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 124)
        report = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"), "report-status", str(status_file)],
                                check=True, capture_output=True, text=True).stdout
        self.assertIn("stage=app-build result=timeout", report)
        self.assertIn("exit=124", report)

    def test_stage_status_appends_are_complete_across_architectures(self):
        status_file = self.directory / "parallel.jsonl"
        processes = [subprocess.Popen([str(ROOT / "scripts/run-release-stage.sh"), lane, "app-build", "5", "--", "/usr/bin/true"],
                                      env={**os.environ, "RELEASE_STAGE_STATUS_FILE": str(status_file)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for lane in ("apple-silicon", "intel")]
        for process in processes:
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0)
        records = [json.loads(line) for line in status_file.read_text().splitlines()]
        self.assertEqual({(record["lane"], record["result"]) for record in records},
                         {(lane, event) for lane in ("apple-silicon", "intel") for event in ("started", "passed")})
        self.assertEqual(len(records), 4)

    def test_stage_cancellation_retains_its_terminal_status(self):
        status_file = self.directory / "cancelled.jsonl"
        process = subprocess.Popen([str(ROOT / "scripts/run-release-stage.sh"), "intel", "app-build", "20", "--", "/bin/sleep", "20"],
                                   env={**os.environ, "RELEASE_STAGE_STATUS_FILE": str(status_file)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if status_file.exists() and status_file.stat().st_size:
                    break
                time.sleep(0.05)
            self.assertTrue(status_file.exists())
            process.terminate()
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143)
            report = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"), "report-status", str(status_file)],
                                    check=True, capture_output=True, text=True).stdout
            self.assertIn("stage=app-build result=cancelled", report)
            self.assertIn("exit=143", report)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=10)

    def test_stage_status_rejects_unexpected_data_without_echoing_it(self):
        status_file = self.directory / "invalid.jsonl"
        status_file.write_text(json.dumps({"schemaVersion": 1, "lane": "all", "stage": "signed-release", "result": "failed",
                                           "elapsedSeconds": 1, "timeoutSeconds": 10, "exitCode": 1, "rawLog": "PRIVATE_INVALID_CANARY"}) + "\n")
        result = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"), "report-status", str(status_file)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PRIVATE_INVALID_CANARY", result.stdout + result.stderr)
        self.assertNotIn(str(status_file), result.stdout + result.stderr)

    def test_app_verifier_records_failure_lines_without_child_output(self):
        source = (ROOT / "scripts/verify-app.sh").read_text()
        prefix = source.split('if [[ "$#" -gt 1 ]]; then', 1)[0]
        # Execute the production traps, followed by synthetic checks. The
        # original source prefix still resolves release-variant.sh from ROOT.
        prefix = prefix.replace('ROOT="${0:A:h:h}"', 'ROOT="$VERIFY_FIXTURE_ROOT"')
        fixture = self.directory / "verify-fixture.sh"
        status_file = self.directory / "verify-status.jsonl"
        cases = (
            ("false", 1, 2),
            ("exit 7", 7, 2),
            ("false | true", 1, 2),
            ("probe() { false; }\nprobe", 1, 2),
            ("probe() { exit 9; }\nprobe", 9, 3),
            ("value=$(false)", 1, 2),
            ("if false; then exit 3; fi\ntrue", 0, None),
            ("value=$(false || true)\ntrue", 0, None),
            ("exit 0", 0, None),
        )
        for lane in ("apple-silicon", "intel"):
            for body, expected, line_offset in cases:
                with self.subTest(lane=lane, body=body):
                    status_file.write_text("")
                    fixture.write_text(prefix + 'print "PRIVATE_VERIFY_CANARY"\n' + body + "\n")
                    result = subprocess.run(["/bin/zsh", str(fixture)],
                                            env={**os.environ, "VERIFY_FIXTURE_ROOT": str(ROOT),
                                                 "RELEASE_VARIANT": lane,
                                                 "RELEASE_STAGE_STATUS_FILE": str(status_file)},
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected)
                    records = [json.loads(line) for line in status_file.read_text().splitlines()]
                    self.assertEqual(len(records), 1 if expected else 0)
                    if expected:
                        record = records[0]
                        self.assertEqual(record["lane"], lane)
                        self.assertEqual(record["exitCode"], expected)
                        self.assertEqual(record["checkLine"], len(prefix.splitlines()) + line_offset)
                        report = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"),
                                                 "report-status", str(status_file)],
                                                check=True, capture_output=True, text=True)
                        self.assertIn(f"line={record['checkLine']} exit={expected}", report.stdout)
                        self.assertNotIn("PRIVATE_", report.stdout + report.stderr)
                        self.assertNotIn(str(fixture), report.stdout + report.stderr)
        fixture.write_text(prefix + "exit 7\n")
        status_file.write_text("")
        processes = [subprocess.Popen(["/bin/zsh", str(fixture)],
                                      env={**os.environ, "VERIFY_FIXTURE_ROOT": str(ROOT),
                                           "RELEASE_VARIANT": lane,
                                           "RELEASE_STAGE_STATUS_FILE": str(status_file)},
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for lane in ("apple-silicon", "intel")]
        for process in processes:
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 7)
        records = [json.loads(line) for line in status_file.read_text().splitlines()]
        self.assertEqual(len(records), 2)
        self.assertEqual({record["lane"] for record in records}, {"apple-silicon", "intel"})
        # A diagnostic write failure must preserve the original validation exit.
        result = subprocess.run(["/bin/zsh", str(fixture)],
                                env={**os.environ, "VERIFY_FIXTURE_ROOT": str(ROOT),
                                     "RELEASE_STAGE_STATUS_FILE": str(self.directory / "absent/status")},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 7)

    def test_app_verifier_status_rejects_non_numeric_or_unexpected_fields(self):
        status_file = self.directory / "invalid-check.jsonl"
        record = {"schemaVersion": 1, "lane": "apple-silicon", "stage": "app-verify",
                  "checkLine": 100, "exitCode": 1}
        for key, value in (("checkLine", "PRIVATE_CANARY"), ("checkLine", True),
                           ("checkLine", 0), ("exitCode", 0), ("exitCode", 256),
                           ("lane", "PRIVATE_CANARY"), ("stage", "PRIVATE_CANARY"),
                           ("rawLog", "PRIVATE_CANARY")):
            with self.subTest(key=key, value=value):
                status_file.write_text(json.dumps(record) + "\n" + json.dumps({**record, key: value}) + "\n")
                result = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"),
                                         "report-status", str(status_file)],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), "RELEASE STATUS result=unavailable")
                self.assertNotIn("PRIVATE_", result.stdout + result.stderr)

    def test_app_content_rejection_reports_fixed_component_groups(self):
        source = (ROOT / "scripts/verify-app.sh").read_text()
        start = source.index("# Sentry's pinned SDK contains public CI __FILE__ paths")
        end = source.index('if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then', start)
        block = source[start:end]
        fixture = self.directory / "content-check.sh"
        fixture.write_text("set -euo pipefail\n" + block)
        app = self.directory / "fixture.app"
        for component in ("MacOS", "Helpers", "Frameworks", "Resources", "Library", "_CodeSignature"):
            (app / "Contents" / component).mkdir(parents=True)
        (app / "Contents/Info.plist").write_text("fixture")
        status_file = self.directory / "content-status.jsonl"
        rg_configuration = self.directory / "rg-config"
        rg_configuration.write_text("--line-number\n")
        cases = (
            (None, None, b"", None, False),
            ("MacOS/RemoteMic", "macos", b"/Users/runner/work/sentry-cocoa/PRIVATE_CONTENT_CANARY", 11, False),
            ("MacOS/RemoteMic", "macos", b"/Users/runner/work/remote-mic-app/PRIVATE_CONTENT_CANARY", 12, False),
            ("MacOS/RemoteMic", "macos", b"/Users/runner/work/_temp/PRIVATE_CONTENT_CANARY", 13, False),
            ("MacOS/RemoteMic", "macos", b"/Users/PRIVATE_CONTENT_CANARY/source.swift", 14, False),
            ("Resources/fixture.txt", "resources", b"AA:BB:CC:DD:EE:FF", 16, False),
            ("Helpers/fixture", "helpers", b"/tmp/remote-bridge-fixture", 15, False),
            ("MacOS/RemoteMic", "macos", b"/Users/PRIVATE_CONTENT_CANARY/source.swift", 17, True),
        )
        for target, expected_group, data, expected_code, configured_output in cases:
            with self.subTest(target=target):
                (app / "Contents/MacOS/RemoteMic").write_bytes(
                    b"/Users/runner/work/sentry-cocoa/sentry-cocoa/Sources/Sentry/SentryClient.m\0")
                (app / "Contents/Resources/fixture.txt").write_text("safe")
                (app / "Contents/Helpers/fixture").write_text("safe")
                if target:
                    (app / "Contents" / target).write_bytes(data)
                status_file.write_text("")
                environment = {**os.environ, "ROOT": str(ROOT), "APP": str(app),
                               "RELEASE_VARIANT": "intel", "RELEASE_STAGE_STATUS_FILE": str(status_file)}
                if configured_output:
                    environment["RIPGREP_CONFIG_PATH"] = str(rg_configuration)
                result = subprocess.run(["/bin/zsh", str(fixture)],
                                        env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if target else 0)
                self.assertNotIn("PRIVATE_CONTENT_CANARY", result.stdout + result.stderr)
                self.assertNotIn(str(app), result.stdout + result.stderr)
                records = [json.loads(line) for line in status_file.read_text().splitlines()]
                if expected_group:
                    failed = [(record["stage"], record["exitCode"]) for record in records
                              if record["result"] == "failed"]
                    self.assertEqual(failed, [(f"app-content-{expected_group}", expected_code)])
                    report = subprocess.run([str(ROOT / "scripts/run-release-stage.sh"),
                                             "report-status", str(status_file)],
                                            check=True, capture_output=True, text=True)
                    self.assertIn(f"stage=app-content-{expected_group} result=failed", report.stdout)
                    self.assertNotIn("PRIVATE_CONTENT_CANARY", report.stdout + report.stderr)
                else:
                    self.assertEqual(records, [])
        supervisor = self.directory / "timeout-fixture/scripts/run-release-stage.sh"
        supervisor.parent.mkdir(parents=True)
        supervisor.write_text("#!/bin/sh\nexit 124\n")
        supervisor.chmod(0o755)
        result = subprocess.run(["/bin/zsh", str(fixture)],
                                env={**os.environ, "ROOT": str(supervisor.parent.parent),
                                     "APP": str(app), "RELEASE_VARIANT": "intel"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("bundle contains a forbidden", result.stderr)
        self.assertNotIn("PRIVATE_CONTENT_CANARY", result.stdout + result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "Installer inspection requires macOS pkgutil")
    def test_public_driver_documentation_in_native_installer_is_accepted(self):
        payload = self.directory / "payload"
        documentation = payload / "MiRemoteV2ch.driver/Contents/Resources/README.md"
        documentation.parent.mkdir(parents=True)
        documentation.write_text("Note that the directory is the root `/Library` not `/Users/user/Library`.\n")
        installer = self.directory / "fixture.pkg"
        subprocess.run(["pkgbuild", "--root", str(payload), "--identifier", "invalid.example.public-documentation", "--version", "1", str(installer)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        contents.verify_asset(installer, self.scratch)

    @unittest.skipUnless(sys.platform == "darwin", "Installer inspection requires macOS pkgutil")
    def test_installer_payload_is_inspected(self):
        payload = self.directory / "payload"
        payload.mkdir()
        (payload / "private.swift").write_text("fixture")
        installer = self.directory / "fixture.pkg"
        subprocess.run(["pkgbuild", "--root", str(payload), "--identifier", "invalid.example.boundary-fixture", "--version", "1", str(installer)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with self.assertRaisesRegex(RuntimeError, "development input"):
            contents.verify_asset(installer, self.scratch)


if __name__ == "__main__":
    unittest.main()
