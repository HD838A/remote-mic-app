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


class PreferredOutputEndpointsTests(unittest.TestCase):
    def test_collapses_same_device_across_host_apis_and_prefers_wasapi(self):
        endpoints = [
            audio_output.AudioEndpoint("耳机 (Realtek(R) Audio)", "MME"),
            audio_output.AudioEndpoint("耳机 (Realtek(R) Audio)", "Windows DirectSound"),
            audio_output.AudioEndpoint("耳机 (Realtek(R) Audio)", "Windows WASAPI"),
            audio_output.AudioEndpoint("耳机 (Realtek(R) Audio)", "Windows WDM-KS"),
        ]

        self.assertEqual(
            audio_output.preferred_output_endpoints(endpoints),
            [audio_output.AudioEndpoint("耳机 (Realtek(R) Audio)", "Windows WASAPI")],
        )

    def test_hides_default_aliases_when_real_devices_exist(self):
        endpoints = [
            audio_output.AudioEndpoint("Microsoft Sound Mapper - Output", "MME"),
            audio_output.AudioEndpoint("Primary Sound Driver", "Windows DirectSound"),
            audio_output.AudioEndpoint("Speakers", "Windows WASAPI"),
        ]

        self.assertEqual(
            audio_output.preferred_output_endpoints(endpoints),
            [audio_output.AudioEndpoint("Speakers", "Windows WASAPI")],
        )

    def test_collapses_mme_name_truncated_by_portaudio(self):
        endpoints = [
            audio_output.AudioEndpoint("ARZOPA (HD Audio Driver for Dis", "MME"),
            audio_output.AudioEndpoint(
                "ARZOPA (HD Audio Driver for Display Audio)", "Windows WASAPI"
            ),
        ]

        self.assertEqual(
            audio_output.preferred_output_endpoints(endpoints),
            [
                audio_output.AudioEndpoint(
                    "ARZOPA (HD Audio Driver for Display Audio)", "Windows WASAPI"
                )
            ],
        )

    def test_distinct_numbered_endpoints_are_not_over_collapsed(self):
        endpoints = [
            audio_output.AudioEndpoint("Speakers 1", "Windows WDM-KS"),
            audio_output.AudioEndpoint("Speakers 2", "Windows WDM-KS"),
        ]

        self.assertEqual(audio_output.preferred_output_endpoints(endpoints), endpoints)

    def test_keeps_default_aliases_as_last_resort(self):
        endpoint = audio_output.AudioEndpoint("Primary Sound Driver", "Windows DirectSound")
        self.assertEqual(audio_output.preferred_output_endpoints([endpoint]), [endpoint])


class CableEndpointMatchingTests(unittest.TestCase):
    """XRBM-031 In-scope item 11: matching must tolerate host-API/driver
    decoration Windows commonly appends, without treating an arbitrary
    similarly-named device as VB-CABLE's own endpoint.
    """

    def test_exact_name_matches(self):
        self.assertTrue(audio_output.is_cable_input_endpoint("CABLE Input"))
        self.assertTrue(audio_output.is_cable_output_endpoint("CABLE Output"))

    def test_host_api_decorated_name_matches(self):
        self.assertTrue(
            audio_output.is_cable_input_endpoint("CABLE Input (VB-Audio Virtual Cable)")
        )
        self.assertTrue(
            audio_output.is_cable_output_endpoint("CABLE Output (VB-Audio Virtual Cable)")
        )

    def test_leading_trailing_whitespace_is_tolerated(self):
        self.assertTrue(audio_output.is_cable_input_endpoint("  CABLE Input  "))

    def test_similarly_named_unrelated_device_does_not_match(self):
        self.assertFalse(audio_output.is_cable_input_endpoint("CABLE Input Splitter Pro"))
        self.assertFalse(audio_output.is_cable_input_endpoint("My CABLE Input"))
        self.assertFalse(audio_output.is_cable_input_endpoint("CABLE Output"))

    def test_unrelated_device_name_does_not_match_either_endpoint(self):
        self.assertFalse(audio_output.is_cable_input_endpoint("Speakers (Realtek)"))
        self.assertFalse(audio_output.is_cable_output_endpoint("Speakers (Realtek)"))

    def test_unclosed_decoration_does_not_match(self):
        # A name that merely starts with the decorated prefix but never
        # closes the parenthesis is not a real host-API decoration.
        self.assertFalse(audio_output.is_cable_input_endpoint("CABLE Input (unterminated"))


class EnumerateEndpointsWithoutSounddeviceTests(unittest.TestCase):
    """Both enumerate_output_endpoints() and enumerate_input_endpoints() must
    fail closed (never raise ImportError) when 'sounddevice' is not
    installed - this test suite's own environment has no guarantee either
    way, so it only asserts the failure mode is the documented one when the
    optional dependency truly is absent, by simulating the ImportError via
    sys.modules injection instead of depending on the host environment.
    """

    def test_enumerate_output_endpoints_raises_documented_error_without_sounddevice(self):
        import sys
        import unittest.mock as mock

        with mock.patch.dict(sys.modules, {"sounddevice": None}):
            with self.assertRaises(audio_output.AudioOutputUnavailableError):
                audio_output.enumerate_output_endpoints()

    def test_enumerate_input_endpoints_raises_documented_error_without_sounddevice(self):
        import sys
        import unittest.mock as mock

        with mock.patch.dict(sys.modules, {"sounddevice": None}):
            with self.assertRaises(audio_output.AudioOutputUnavailableError):
                audio_output.enumerate_input_endpoints()


class EnumerateEndpointsUnexpectedFailureTests(unittest.TestCase):
    """XRBM-031 RETRY 1 item 2: a real PortAudio/sounddevice failure other
    than a missing package (e.g. a raw ``PortAudioError`` from
    ``query_hostapis()``/``query_devices()``) must still fail closed as the
    documented ``AudioOutputUnavailableError`` - never propagate as some
    other exception type a caller/diagnostics check does not already
    catch - and the resulting message must never echo the raw exception
    text (which could embed a real device name/path).
    """

    def _install_fake_sounddevice(self, *, query_hostapis=None, query_devices=None):
        import sys
        import types
        import unittest.mock as mock

        fake_sd = types.ModuleType("sounddevice")
        fake_sd.query_hostapis = query_hostapis or (lambda: [{"name": "Windows WASAPI"}])
        fake_sd.query_devices = query_devices or (lambda: [])
        return mock.patch.dict(sys.modules, {"sounddevice": fake_sd})

    def test_query_hostapis_failure_becomes_audio_output_unavailable_error(self):
        def _raise():
            raise RuntimeError("PortAudioError: Device unavailable [Errno -9999] Host API 'Realtek Mic (纪凯的电脑)' not found")

        with self._install_fake_sounddevice(query_hostapis=_raise):
            with self.assertRaises(audio_output.AudioOutputUnavailableError) as ctx:
                audio_output.enumerate_output_endpoints()
        self.assertNotIn("纪凯的电脑", str(ctx.exception))
        self.assertNotIn("PortAudioError", str(ctx.exception))

    def test_query_devices_failure_becomes_audio_output_unavailable_error(self):
        def _raise():
            raise OSError("device enumeration failed for \\\\?\\device\\path")

        with self._install_fake_sounddevice(query_devices=_raise):
            with self.assertRaises(audio_output.AudioOutputUnavailableError) as ctx:
                audio_output.enumerate_input_endpoints()
        self.assertNotIn("\\\\?\\device\\path", str(ctx.exception))

    def test_malformed_device_entry_still_fails_closed(self):
        import types

        def _devices():
            return [types.SimpleNamespace()]  # no .get()/subscript support - malformed shape

        with self._install_fake_sounddevice(query_devices=_devices):
            with self.assertRaises(audio_output.AudioOutputUnavailableError):
                audio_output.enumerate_output_endpoints()


class EnumerateInputEndpointsFilteringTests(unittest.TestCase):
    """enumerate_input_endpoints() must filter on max_input_channels, not
    max_output_channels (the field enumerate_output_endpoints() uses) - a
    fake sounddevice module proves the two functions read different fields
    without needing a real audio device.
    """

    def test_filters_by_input_channels_not_output_channels(self):
        import sys
        import types
        import unittest.mock as mock

        fake_sd = types.ModuleType("sounddevice")
        fake_sd.query_hostapis = lambda: [{"name": "Windows WASAPI"}]
        fake_sd.query_devices = lambda: [
            {"name": "CABLE Output (VB-Audio Virtual Cable)", "hostapi": 0,
             "max_input_channels": 2, "max_output_channels": 0},
            {"name": "CABLE Input (VB-Audio Virtual Cable)", "hostapi": 0,
             "max_input_channels": 0, "max_output_channels": 2},
        ]
        with mock.patch.dict(sys.modules, {"sounddevice": fake_sd}):
            endpoints = audio_output.enumerate_input_endpoints()
        self.assertEqual(len(endpoints), 1)
        self.assertTrue(audio_output.is_cable_output_endpoint(endpoints[0].name))

    def test_output_enumeration_still_filters_by_output_channels(self):
        import sys
        import types
        import unittest.mock as mock

        fake_sd = types.ModuleType("sounddevice")
        fake_sd.query_hostapis = lambda: [{"name": "Windows WASAPI"}]
        fake_sd.query_devices = lambda: [
            {"name": "CABLE Output (VB-Audio Virtual Cable)", "hostapi": 0,
             "max_input_channels": 2, "max_output_channels": 0},
            {"name": "CABLE Input (VB-Audio Virtual Cable)", "hostapi": 0,
             "max_input_channels": 0, "max_output_channels": 2},
        ]
        with mock.patch.dict(sys.modules, {"sounddevice": fake_sd}):
            endpoints = audio_output.enumerate_output_endpoints()
        self.assertEqual(len(endpoints), 1)
        self.assertTrue(audio_output.is_cable_input_endpoint(endpoints[0].name))


class DjiMic2EndpointIdentityTests(unittest.TestCase):
    def test_matches_windows_hands_free_and_plain_product_names(self):
        self.assertTrue(
            audio_output.is_dji_mic_2_input_endpoint("DJI-MIC2-ABCDEF Hands-Free")
        )
        self.assertTrue(audio_output.is_dji_mic_2_input_endpoint("DJI Mic 2"))
        self.assertTrue(audio_output.is_dji_mic_2_input_endpoint("DJI Mic2 (Bluetooth)"))
        self.assertTrue(
            audio_output.is_dji_mic_2_input_endpoint(
                "Microphone (DJI-MIC2-ABCDEF Hands-Free)"
            )
        )
        self.assertTrue(
            audio_output.is_dji_mic_2_input_endpoint(
                "\u9ea6\u514b\u98ce (@System32\\drivers\\bthhfenum.sys;(DJI-MIC2-ABCDEF))"
            )
        )

    def test_rejects_lookalikes_and_other_microphones(self):
        self.assertFalse(audio_output.is_dji_mic_2_input_endpoint("DJI-MIC20"))
        self.assertFalse(
            audio_output.is_dji_mic_2_input_endpoint("Recorder for DJI-MIC20 Hands-Free")
        )
        self.assertFalse(audio_output.is_dji_mic_2_input_endpoint("DJI Mic Mini"))
        self.assertFalse(audio_output.is_dji_mic_2_input_endpoint("Microphone Array"))


if __name__ == "__main__":
    unittest.main()
