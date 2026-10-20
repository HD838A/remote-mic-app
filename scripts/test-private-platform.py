#!/usr/bin/env python3
"""Exercise release ordering and public fallback with isolated Git repositories."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("private_platform", ROOT / "scripts/prepare-private-platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)


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
                     "packages/macos-membership/README.md"):
            self.assertFalse(platform.relevant(path), path)

    def test_tag_requires_standard_semver_version_and_root_manifest(self):
        for tag in ("private-v2.2.0", "v2.2.0", "02.2.0", "2.2.0-rc.1"):
            with self.assertRaises(RuntimeError):
                platform.verify_tag(self.repo, tag)
        self.git("tag", "2.2.1")
        with self.assertRaisesRegex(RuntimeError, "match VERSION"):
            platform.verify_tag(self.repo, "2.2.1")

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


if __name__ == "__main__":
    unittest.main()
