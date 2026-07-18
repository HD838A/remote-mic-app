"""Exercises EndpointPlaybackSink's device-resolution logic with a fake
``sounddevice``-shaped object (it already takes ``sd`` as a parameter, which
makes this possible without the real optional dependency installed) - see
audio_output.py's identical name+host_api disambiguation contract, which
this mirrors for the actual PortAudio device-index lookup used at
``open()`` time (XRBM-014 review RETRY P2 #1).
"""

import unittest

from ovb_rc003 import audio_output
from ovb_rc003.audio_playback import EndpointPlaybackSink


class FakeSoundDevice:
    def __init__(self, devices, host_apis):
        self._devices = devices
        self._host_apis = host_apis

    def query_devices(self):
        return self._devices

    def query_hostapis(self):
        return self._host_apis


def _device(name, max_output_channels, hostapi_index):
    return {"name": name, "max_output_channels": max_output_channels, "hostapi": hostapi_index}


class ResolveDeviceIndexTests(unittest.TestCase):
    def setUp(self):
        self.host_apis = [{"name": "Windows WASAPI"}, {"name": "MME"}]

    def test_resolves_the_sole_matching_name(self):
        sd = FakeSoundDevice(
            devices=[_device("Speakers", 2, 0), _device("Mic In", 0, 0)],
            host_apis=self.host_apis,
        )
        sink = EndpointPlaybackSink("Speakers")
        self.assertEqual(sink._resolve_device_index(sd), 0)

    def test_ignores_input_only_devices_with_same_name(self):
        sd = FakeSoundDevice(
            devices=[_device("Line", 0, 0), _device("Line", 2, 1)],
            host_apis=self.host_apis,
        )
        sink = EndpointPlaybackSink("Line")
        self.assertEqual(sink._resolve_device_index(sd), 1)

    def test_missing_endpoint_fails_closed(self):
        sd = FakeSoundDevice(devices=[_device("Speakers", 2, 0)], host_apis=self.host_apis)
        sink = EndpointPlaybackSink("Nonexistent")
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            sink._resolve_device_index(sd)

    def test_ambiguous_name_without_host_api_fails_closed(self):
        sd = FakeSoundDevice(
            devices=[_device("Speakers", 2, 0), _device("Speakers", 2, 1)],
            host_apis=self.host_apis,
        )
        sink = EndpointPlaybackSink("Speakers")
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            sink._resolve_device_index(sd)

    def test_ambiguous_name_with_host_api_resolves_the_right_index(self):
        sd = FakeSoundDevice(
            devices=[_device("Speakers", 2, 0), _device("Speakers", 2, 1)],
            host_apis=self.host_apis,
        )
        sink = EndpointPlaybackSink("Speakers", host_api="MME")
        self.assertEqual(sink._resolve_device_index(sd), 1)

    def test_saved_host_api_no_longer_present_fails_closed(self):
        sd = FakeSoundDevice(devices=[_device("Speakers", 2, 0)], host_apis=self.host_apis)
        sink = EndpointPlaybackSink("Speakers", host_api="MME")
        with self.assertRaises(audio_output.AudioOutputUnavailableError):
            sink._resolve_device_index(sd)


if __name__ == "__main__":
    unittest.main()
