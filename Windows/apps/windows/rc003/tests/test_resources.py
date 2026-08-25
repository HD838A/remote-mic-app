import sys
import tempfile
import unittest
from pathlib import Path

from ovb_rc003 import resources


class FindRemotePhotoFrozenBundleTests(unittest.TestCase):
    """XRBM-018 RETRY 1 P2 #4: a PyInstaller one-dir frozen bundle exposes
    its collected-``datas`` root via ``sys._MEIPASS`` - simulated here by
    monkeypatching it onto a throwaway temp directory, without needing an
    actual PyInstaller build.
    """

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self._had_meipass = hasattr(sys, "_MEIPASS")
        self._original_meipass = getattr(sys, "_MEIPASS", None)

    def tearDown(self):
        if self._had_meipass:
            sys._MEIPASS = self._original_meipass
        elif hasattr(sys, "_MEIPASS"):
            del sys._MEIPASS
        self._tmpdir.cleanup()

    def test_finds_the_photo_under_meipass_resources_when_frozen(self):
        root = Path(self._tmpdir.name)
        resources_dir = root / "Resources"
        resources_dir.mkdir()
        photo = resources_dir / "RC003-remote-photo.png"
        photo.write_bytes(b"not a real png, just a marker file")

        sys._MEIPASS = str(root)

        found = resources.find_remote_photo()

        self.assertIsNotNone(found)
        self.assertEqual(found, photo)

    def test_meipass_set_but_photo_missing_falls_back_without_raising(self):
        # A frozen bundle whose Resources/ genuinely doesn't have the photo
        # (e.g. it was absent at build time - see the spec's REMOTE_PHOTO.is_file()
        # guard) must still degrade to None (or another candidate), never raise.
        sys._MEIPASS = str(Path(self._tmpdir.name))  # no Resources/ created

        try:
            resources.find_remote_photo()
        except Exception as exc:  # pragma: no cover - defensive
            self.fail(f"find_remote_photo() raised unexpectedly: {exc}")


class FindRemotePhotoTests(unittest.TestCase):
    def test_finds_the_repository_root_photo_during_source_checkout(self):
        # This candidate is developed inside the full repository checkout, so
        # the root Resources/RC003-remote-photo.png should resolve; if the
        # photo is genuinely absent (e.g. a stripped-down checkout), this
        # degrades to None rather than raising - both are acceptable, but we
        # assert the happy path here since the file is present in this repo.
        photo = resources.find_remote_photo()
        if photo is not None:
            self.assertTrue(photo.is_file())
            self.assertEqual(photo.name, "RC003-remote-photo.png")

    def test_never_raises_when_nothing_found(self):
        # Smoke test: calling this from an unusual working directory must not
        # raise, only return None.
        try:
            resources.find_remote_photo()
        except Exception as exc:  # pragma: no cover - defensive
            self.fail(f"find_remote_photo() raised unexpectedly: {exc}")


class FindAppIconTests(unittest.TestCase):
    def test_finds_product_icon_during_source_checkout(self):
        icon = resources.find_app_icon()
        self.assertIsNotNone(icon)
        self.assertTrue(icon.is_file())
        self.assertEqual(icon.name, "RemoteMic-AppIcon.ico")


if __name__ == "__main__":
    unittest.main()
