import json
import unittest
from pathlib import Path

from ovb_rc003 import atvv_protocol as proto


_FIXTURE = Path(__file__).parent / "fixtures" / "atvv" / "synthetic-v1.json"


class SyntheticATVVGoldenFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(_FIXTURE.read_text(encoding="utf-8"))

    def test_capabilities_fixture(self):
        payload = bytes.fromhex(self.fixture["capabilities_hex"])
        capabilities = proto.ATVVCapabilities.parse(payload)
        self.assertIsNotNone(capabilities)
        self.assertEqual(capabilities.version, self.fixture["expected_version"])
        self.assertEqual(capabilities.selected_codec, self.fixture["expected_codec"])
        self.assertEqual(capabilities.sample_rate, self.fixture["expected_sample_rate"])
        self.assertEqual(capabilities.frame_size, self.fixture["expected_frame_size"])

    def test_adpcm_fixture(self):
        encoded = bytes.fromhex(self.fixture["adpcm_hex"])
        decoded = proto.IMAADPCMDecoder().decode(encoded)
        self.assertEqual(decoded, self.fixture["expected_pcm"])


if __name__ == "__main__":
    unittest.main()
