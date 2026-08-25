import hashlib
import tempfile
import unittest
import unittest.mock as mock
import zipfile
from pathlib import Path

from ovb_rc003 import vb_cable_bundle as vcb


def _make_zip(path: Path, members: dict, *, symlink_members=()) -> None:
    """Builds a real ZIP at ``path``. ``members`` maps archive-internal name
    -> bytes content. ``symlink_members`` maps archive-internal name -> a
    target string, written as a Unix-symlink-mode member (content is the
    link target, not real file data) - the same technique a maliciously
    crafted ZIP would use.
    """

    with zipfile.ZipFile(path, "w") as zf:
        for name, content in members.items():
            zf.writestr(name, content)
        for name, target in symlink_members:
            info = zipfile.ZipInfo(name)
            info.create_system = 3  # unix
            info.external_attr = (vcb._ZIP_SYMLINK_UNIX_MODE | 0o777) << 16
            zf.writestr(info, target)


def _sha256_hex(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PinnedAssetTests(unittest.TestCase):
    def test_pinned_hash_is_a_well_formed_64_char_hex_sha256(self):
        self.assertEqual(len(vcb.VB_CABLE_PACK45.sha256), 64)
        int(vcb.VB_CABLE_PACK45.sha256, 16)  # raises ValueError if not hex

    def test_pinned_url_is_the_official_https_download(self):
        self.assertTrue(vcb.VB_CABLE_PACK45.url.startswith("https://download.vb-audio.com/"))
        self.assertTrue(vcb.VB_CABLE_PACK45.url.endswith(vcb.PINNED_ZIP_FILENAME))

    def test_required_setup_member_is_the_64_bit_official_setup(self):
        self.assertEqual(vcb.REQUIRED_SETUP_MEMBER, "VBCABLE_Setup_x64.exe")


class FindBundleTests(unittest.TestCase):
    def test_returns_none_when_no_candidate_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nope" / vcb.PINNED_ZIP_FILENAME
            result = vcb.find_bundle(_search_paths=iter([missing]))
        self.assertIsNone(result)

    def test_returns_first_existing_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            missing = root / "missing" / vcb.PINNED_ZIP_FILENAME
            present = root / "present" / vcb.PINNED_ZIP_FILENAME
            present.parent.mkdir(parents=True)
            present.write_bytes(b"fake zip bytes")
            result = vcb.find_bundle(_search_paths=iter([missing, present]))
        self.assertEqual(result, present)


class VerifyBundleTests(unittest.TestCase):
    def test_missing_file_is_not_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nope.zip"
            self.assertFalse(vcb.verify_bundle(missing))

    def test_matching_hash_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bundle.zip"
            path.write_bytes(b"some content")
            asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip",
                sha256=_sha256_hex(path),
            )
            self.assertTrue(vcb.verify_bundle(path, asset))

    def test_mismatching_hash_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bundle.zip"
            path.write_bytes(b"some content")
            asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip",
                sha256="0" * 64,
            )
            self.assertFalse(vcb.verify_bundle(path, asset))

    def test_hash_comparison_is_case_insensitive(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bundle.zip"
            path.write_bytes(b"some content")
            asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip",
                sha256=_sha256_hex(path).upper(),
            )
            self.assertTrue(vcb.verify_bundle(path, asset))


class ExtractBundleTests(unittest.TestCase):
    def _asset_for(self, zip_path: Path) -> vcb.ThirdPartyAsset:
        return vcb.ThirdPartyAsset(
            name="test", version="1", url="https://example.test/x.zip",
            sha256=_sha256_hex(zip_path),
        )

    def test_hash_mismatch_refuses_to_extract(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(zip_path, {vcb.REQUIRED_SETUP_MEMBER: b"exe bytes"})
            bad_asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip", sha256="0" * 64
            )
            with self.assertRaises(vcb.BundleHashMismatchError):
                vcb.extract_bundle(zip_path, asset=bad_asset)

    def test_valid_zip_with_setup_member_extracts_successfully(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {
                    vcb.REQUIRED_SETUP_MEMBER: b"exe bytes",
                    "readme.txt": b"Donationware readme",
                    "cbLE64.inf": b"driver inf",
                },
            )
            extracted = vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))
            self.assertTrue(extracted.directory.is_dir())
            self.assertEqual(extracted.setup_relative_path, vcb.REQUIRED_SETUP_MEMBER)
            self.assertTrue((extracted.directory / vcb.REQUIRED_SETUP_MEMBER).is_file())
            self.assertTrue((extracted.directory / "readme.txt").is_file())

    def test_nested_setup_member_path_is_reported_relative(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(zip_path, {f"VBCABLE_Driver_Pack43/{vcb.REQUIRED_SETUP_MEMBER}": b"exe"})
            extracted = vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))
            self.assertEqual(
                extracted.setup_relative_path,
                f"VBCABLE_Driver_Pack43/{vcb.REQUIRED_SETUP_MEMBER}",
            )
            self.assertTrue(
                (extracted.directory / "VBCABLE_Driver_Pack43" / vcb.REQUIRED_SETUP_MEMBER).is_file()
            )

    def test_missing_setup_member_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(zip_path, {"readme.txt": b"no setup exe here"})
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_empty_zip_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            with zipfile.ZipFile(zip_path, "w"):
                pass
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_absolute_path_member_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {
                    vcb.REQUIRED_SETUP_MEMBER: b"exe",
                    "/etc/evil": b"evil content",
                },
            )
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_windows_drive_absolute_path_member_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {
                    vcb.REQUIRED_SETUP_MEMBER: b"exe",
                    "C:\\Windows\\System32\\evil.dll": b"evil content",
                },
            )
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_dot_dot_traversal_member_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {
                    vcb.REQUIRED_SETUP_MEMBER: b"exe",
                    "../../evil.txt": b"evil content",
                },
            )
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_dot_dot_traversal_with_backslashes_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {
                    vcb.REQUIRED_SETUP_MEMBER: b"exe",
                    "..\\..\\evil.txt": b"evil content",
                },
            )
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_symlink_member_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {vcb.REQUIRED_SETUP_MEMBER: b"exe"},
                symlink_members=[("link.txt", "/etc/passwd")],
            )
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.extract_bundle(zip_path, asset=self._asset_for(zip_path))

    def test_no_extraction_happens_on_hash_mismatch(self):
        # A hash-mismatch rejection must never leave a half-extracted temp
        # directory behind - the check happens strictly before any
        # zipfile.extract() call.
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(zip_path, {vcb.REQUIRED_SETUP_MEMBER: b"exe"})
            bad_asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip", sha256="0" * 64
            )
            before = set(Path(tempfile.gettempdir()).glob("ovb_vbcable_*"))
            with self.assertRaises(vcb.BundleHashMismatchError):
                vcb.extract_bundle(zip_path, asset=bad_asset)
            after = set(Path(tempfile.gettempdir()).glob("ovb_vbcable_*"))
            self.assertEqual(before, after)

    def test_partial_extraction_failure_cleans_up_the_temp_directory(self):
        # XRBM-031 RETRY 1 item 4: a real I/O error partway through
        # extracting a validated ZIP must not leave the freshly created
        # temp directory behind.
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "bundle.zip"
            _make_zip(
                zip_path,
                {vcb.REQUIRED_SETUP_MEMBER: b"exe bytes", "readme.txt": b"hi"},
            )
            asset = self._asset_for(zip_path)

            created_dirs = []
            real_mkdtemp = vcb.tempfile.mkdtemp

            def _tracking_mkdtemp(*args, **kwargs):
                path = real_mkdtemp(*args, **kwargs)
                created_dirs.append(path)
                return path

            with mock.patch.object(vcb.tempfile, "mkdtemp", side_effect=_tracking_mkdtemp):
                with mock.patch.object(
                    vcb.zipfile.ZipFile, "extract", side_effect=OSError("disk full")
                ):
                    with self.assertRaises(OSError):
                        vcb.extract_bundle(zip_path, asset=asset)

            self.assertEqual(len(created_dirs), 1)
            self.assertFalse(Path(created_dirs[0]).exists())


class LaunchVendorSetupTests(unittest.TestCase):
    def _extracted_with_setup(self, tmp: str) -> vcb.ExtractedBundle:
        directory = Path(tmp)
        (directory / vcb.REQUIRED_SETUP_MEMBER).write_bytes(b"exe")
        return vcb.ExtractedBundle(directory=directory, setup_relative_path=vcb.REQUIRED_SETUP_MEMBER)

    def test_missing_setup_exe_after_extraction_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            extracted = vcb.ExtractedBundle(
                directory=Path(tmp), setup_relative_path=vcb.REQUIRED_SETUP_MEMBER
            )
            with self.assertRaises(vcb.BundleZipUnsafeError):
                vcb.launch_vendor_setup(extracted, _start_elevated=lambda p, c: None)

    def test_successful_launch_calls_start_elevated_with_extracted_cwd(self):
        with tempfile.TemporaryDirectory() as tmp:
            extracted = self._extracted_with_setup(tmp)
            calls = []
            vcb.launch_vendor_setup(
                extracted, _start_elevated=lambda p, c: calls.append((p, c))
            )
            self.assertEqual(len(calls), 1)
            launched_path, cwd = calls[0]
            self.assertEqual(launched_path, str(extracted.directory / vcb.REQUIRED_SETUP_MEMBER))
            self.assertEqual(cwd, str(extracted.directory))

    def test_uac_cancellation_is_reported_distinctly(self):
        with tempfile.TemporaryDirectory() as tmp:
            extracted = self._extracted_with_setup(tmp)

            def _cancelled(path, cwd):
                error = OSError("The operation was canceled by the user")
                error.winerror = 1223
                raise error

            with self.assertRaises(vcb.UacCancelledError):
                vcb.launch_vendor_setup(extracted, _start_elevated=_cancelled)

    def test_other_os_error_is_a_generic_launch_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            extracted = self._extracted_with_setup(tmp)

            def _boom(path, cwd):
                raise OSError("something else went wrong")

            with self.assertRaises(vcb.VendorLaunchError):
                vcb.launch_vendor_setup(extracted, _start_elevated=_boom)

    def test_default_start_elevated_requires_windows(self):
        import sys

        with tempfile.TemporaryDirectory() as tmp:
            extracted = self._extracted_with_setup(tmp)
            with mock.patch.object(sys, "platform", "darwin"):
                with self.assertRaises(vcb.VendorLaunchError):
                    vcb.launch_vendor_setup(extracted)

    def test_launch_never_claims_installation_success(self):
        # Structural guarantee, not just a docstring claim: launch_vendor_setup
        # has no success-status return value at all (None on success).
        with tempfile.TemporaryDirectory() as tmp:
            extracted = self._extracted_with_setup(tmp)
            result = vcb.launch_vendor_setup(extracted, _start_elevated=lambda p, c: None)
            self.assertIsNone(result)


class PrepareAndLaunchVendorSetupTests(unittest.TestCase):
    def test_missing_bundle_raises_not_found(self):
        with mock.patch.object(vcb, "find_bundle", return_value=None):
            with self.assertRaises(vcb.BundleNotFoundError):
                vcb.prepare_and_launch_vendor_setup()

    def test_full_flow_locates_verifies_extracts_and_launches(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / vcb.PINNED_ZIP_FILENAME
            _make_zip(zip_path, {vcb.REQUIRED_SETUP_MEMBER: b"exe bytes"})
            asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip",
                sha256=_sha256_hex(zip_path),
            )
            calls = []
            with mock.patch.object(vcb, "find_bundle", return_value=zip_path):
                extracted = vcb.prepare_and_launch_vendor_setup(
                    asset=asset, _start_elevated=lambda p, c: calls.append((p, c))
                )
            self.assertEqual(len(calls), 1)
            self.assertTrue(extracted.directory.is_dir())

    def test_hash_mismatch_prevents_any_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / vcb.PINNED_ZIP_FILENAME
            _make_zip(zip_path, {vcb.REQUIRED_SETUP_MEMBER: b"exe bytes"})
            bad_asset = vcb.ThirdPartyAsset(
                name="test", version="1", url="https://example.test/x.zip", sha256="0" * 64
            )
            calls = []
            with mock.patch.object(vcb, "find_bundle", return_value=zip_path):
                with self.assertRaises(vcb.BundleHashMismatchError):
                    vcb.prepare_and_launch_vendor_setup(
                        asset=bad_asset, _start_elevated=lambda p, c: calls.append((p, c))
                    )
            self.assertEqual(calls, [])

    def _fake_extracted_bundle(self) -> vcb.ExtractedBundle:
        directory = Path(tempfile.mkdtemp(prefix="test_ovb_vbcable_"))
        (directory / vcb.REQUIRED_SETUP_MEMBER).write_bytes(b"exe")
        return vcb.ExtractedBundle(directory=directory, setup_relative_path=vcb.REQUIRED_SETUP_MEMBER)

    def test_uac_cancellation_removes_the_extracted_directory(self):
        # XRBM-031 RETRY 1 item 4: no process ever started, so nothing is
        # left to need the extracted directory for.
        extracted = self._fake_extracted_bundle()

        def _cancelled(path, cwd):
            error = OSError("The operation was canceled by the user")
            error.winerror = 1223
            raise error

        with mock.patch.object(vcb, "find_bundle", return_value=Path("/fake/bundle.zip")):
            with mock.patch.object(vcb, "extract_bundle", return_value=extracted):
                with self.assertRaises(vcb.UacCancelledError):
                    vcb.prepare_and_launch_vendor_setup(_start_elevated=_cancelled)

        self.assertFalse(extracted.directory.exists())

    def test_generic_launch_failure_removes_the_extracted_directory(self):
        extracted = self._fake_extracted_bundle()

        def _boom(path, cwd):
            raise OSError("something else went wrong")

        with mock.patch.object(vcb, "find_bundle", return_value=Path("/fake/bundle.zip")):
            with mock.patch.object(vcb, "extract_bundle", return_value=extracted):
                with self.assertRaises(vcb.VendorLaunchError):
                    vcb.prepare_and_launch_vendor_setup(_start_elevated=_boom)

        self.assertFalse(extracted.directory.exists())

    def test_missing_setup_exe_after_extraction_removes_the_extracted_directory(self):
        # extract_bundle() is mocked to return a bundle whose setup exe was
        # somehow removed before launch_vendor_setup() checks for it -
        # launch_vendor_setup() itself raises BundleZipUnsafeError here,
        # and prepare_and_launch_vendor_setup() must still clean up.
        directory = Path(tempfile.mkdtemp(prefix="test_ovb_vbcable_"))
        extracted = vcb.ExtractedBundle(
            directory=directory, setup_relative_path=vcb.REQUIRED_SETUP_MEMBER
        )

        with mock.patch.object(vcb, "find_bundle", return_value=Path("/fake/bundle.zip")):
            with mock.patch.object(vcb, "extract_bundle", return_value=extracted):
                with self.assertRaises(vcb.BundleZipUnsafeError):
                    vcb.prepare_and_launch_vendor_setup(_start_elevated=lambda p, c: None)

        self.assertFalse(directory.exists())

    def test_successful_launch_preserves_the_extracted_directory(self):
        # The elevated vendor process may still need adjacent files for as
        # long as it runs - a successful launch must NOT clean up.
        extracted = self._fake_extracted_bundle()
        try:
            with mock.patch.object(vcb, "find_bundle", return_value=Path("/fake/bundle.zip")):
                with mock.patch.object(vcb, "extract_bundle", return_value=extracted):
                    result = vcb.prepare_and_launch_vendor_setup(
                        _start_elevated=lambda p, c: None
                    )
            self.assertEqual(result, extracted)
            self.assertTrue(extracted.directory.exists())
        finally:
            import shutil

            shutil.rmtree(extracted.directory, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
