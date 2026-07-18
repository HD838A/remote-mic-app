import unittest

from ovb_rc003 import audio_output


class ResolveSelectedEndpointTests(unittest.TestCase):
    def setUp(self):
        self.endpoints = [
            audio_output.AudioEndpoint(name="Speakers (Realtek)", host_api="Windows WASAPI"),
            audio_output.AudioEndpoint(name="CABLE Input (VB-Audio Virtual Cable)", host_api="Windows WASAPI"),
        ]

    def test_raises_when_nothing_selected(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint(self.endpoints, None)

    def test_raises_when_selected_name_is_empty_string(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint(self.endpoints, "")

    def test_raises_when_selected_endpoint_missing(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint(self.endpoints, "Nonexistent Device")

    def test_returns_matching_endpoint(self):
        endpoint = audio_output.resolve_selected_endpoint(
            self.endpoints, "CABLE Input (VB-Audio Virtual Cable)"
        )
        self.assertEqual(endpoint.name, "CABLE Input (VB-Audio Virtual Cable)")

    def test_never_falls_back_to_first_endpoint_when_name_does_not_match(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint(self.endpoints, "typo'd name")

    def test_empty_endpoint_list_fails_closed(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint([], "Speakers (Realtek)")


class HostApiDisambiguationTests(unittest.TestCase):
    """Fixed after XRBM-014 review RETRY P2 #1: a bare display name is not
    always unique across PortAudio host APIs (the same physical device can
    appear once under WASAPI and once under MME); host_api disambiguates.
    """

    def setUp(self):
        self.endpoints = [
            audio_output.AudioEndpoint(name="Speakers", host_api="Windows WASAPI"),
            audio_output.AudioEndpoint(name="Speakers", host_api="MME"),
            audio_output.AudioEndpoint(name="Unique Device", host_api="Windows WASAPI"),
        ]

    def test_ambiguous_name_without_host_api_fails_closed(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint(self.endpoints, "Speakers")

    def test_ambiguous_name_with_host_api_resolves_the_right_one(self):
        endpoint = audio_output.resolve_selected_endpoint(self.endpoints, "Speakers", "MME")
        self.assertEqual(endpoint.host_api, "MME")

    def test_saved_host_api_no_longer_present_fails_closed(self):
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            audio_output.resolve_selected_endpoint(self.endpoints, "Speakers", "ASIO")

    def test_unique_name_without_saved_host_api_still_resolves(self):
        endpoint = audio_output.resolve_selected_endpoint(self.endpoints, "Unique Device")
        self.assertEqual(endpoint.name, "Unique Device")

    def test_unique_name_with_host_api_also_resolves(self):
        endpoint = audio_output.resolve_selected_endpoint(
            self.endpoints, "Unique Device", "Windows WASAPI"
        )
        self.assertEqual(endpoint.host_api, "Windows WASAPI")


if __name__ == "__main__":
    unittest.main()
