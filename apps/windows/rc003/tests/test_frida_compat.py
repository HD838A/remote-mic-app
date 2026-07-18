import hashlib
import tempfile
import unittest
from pathlib import Path

from ovb_rc003 import frida_compat


class AssetDescriptorTests(unittest.TestCase):
    def test_uses_official_release_url(self):
        self.assertTrue(
            frida_compat.FRIDA_GADGET.url.startswith(
                "https://github.com/frida/frida/releases/download/"
            )
        )

    def test_sha256_is_pinned_and_well_formed(self):
        self.assertEqual(len(frida_compat.FRIDA_GADGET.sha256), 64)
        int(frida_compat.FRIDA_GADGET.sha256, 16)  # raises if not valid hex


class VerifyAssetTests(unittest.TestCase):
    def test_false_when_missing(self):
        missing = Path("/nonexistent/frida-gadget.dll.xz")
        self.assertFalse(frida_compat.verify_asset(missing, frida_compat.FRIDA_GADGET))

    def test_false_when_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "asset.bin"
            path.write_bytes(b"not the real gadget")
            self.assertFalse(frida_compat.verify_asset(path, frida_compat.FRIDA_GADGET))

    def test_true_when_hash_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "asset.bin"
            content = b"pretend gadget bytes"
            path.write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            asset = frida_compat.ThirdPartyAsset(
                name="test", version="0", url="https://example.invalid/a", sha256=digest,
                license_name="x", license_url="https://example.invalid/license",
            )
            self.assertTrue(frida_compat.verify_asset(path, asset))


class BackKeyCompatLayerTests(unittest.TestCase):
    def test_no_path_configured_is_unavailable(self):
        layer = frida_compat.BackKeyCompatLayer(gadget_path=None)
        self.assertFalse(layer.available)
        self.assertEqual(layer.status, "unavailable_no_path_configured")
        self.assertFalse(layer.start())

    def test_missing_file_is_unavailable(self):
        layer = frida_compat.BackKeyCompatLayer(gadget_path=Path("/nonexistent/gadget.dll.xz"))
        self.assertFalse(layer.available)
        self.assertEqual(layer.status, "unavailable_missing_or_hash_mismatch")
        self.assertFalse(layer.start())

    def test_verified_gadget_still_degrades_in_this_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "asset.bin"
            content = b"pretend gadget bytes"
            path.write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            asset = frida_compat.ThirdPartyAsset(
                name="test", version="0", url="https://example.invalid/a", sha256=digest,
                license_name="x", license_url="https://example.invalid/license",
            )
            layer = frida_compat.BackKeyCompatLayer(gadget_path=path, asset=asset)
            self.assertTrue(layer.available)
            self.assertEqual(layer.status, "verified_but_injector_not_implemented_in_candidate")
            # Even when verified, start() must still return False: the
            # injector is intentionally unimplemented in this candidate, so
            # the back key stays unmapped rather than silently no-oping.
            self.assertFalse(layer.start())


if __name__ == "__main__":
    unittest.main()
