"""Exercises EndpointPlaybackSink's device-resolution logic with a fake
``sounddevice``-shaped object (it already takes ``sd`` as a parameter, which
makes this possible without the real optional dependency installed) - see
audio_output.py's identical name+host_api disambiguation contract, which
this mirrors for the actual PortAudio device-index lookup used at
``open()`` time (XRBM-014 review RETRY P2 #1).
"""

import unittest

import numpy as np

from ovb_rc003 import audio_output
from ovb_rc003.audio_playback import EndpointPlaybackSink


class FakeSoundDevice:
    def __init__(self, devices, host_apis):
        self._devices = devices
        self._host_apis = host_apis
        self.checked_settings = []

    def query_devices(self):
        return self._devices

    def query_hostapis(self):
        return self._host_apis

    def check_output_settings(self, *, device, channels, dtype, samplerate):
        self.checked_settings.append(
            {
                "device": device,
                "channels": channels,
                "dtype": dtype,
                "samplerate": samplerate,
            }
        )


def _device(name, max_output_channels, hostapi_index, default_samplerate=16000.0):
    return {
        "name": name,
        "max_output_channels": max_output_channels,
        "hostapi": hostapi_index,
        "default_samplerate": default_samplerate,
    }


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


class SelectOutputSampleRateTests(unittest.TestCase):
    def setUp(self):
        self.host_apis = [{"name": "Windows WASAPI"}, {"name": "MME"}]

    def test_prefers_the_endpoint_default_sample_rate_when_supported(self):
        sd = FakeSoundDevice(
            devices=[_device("CABLE Input", 2, 0, default_samplerate=48000.0)],
            host_apis=[{"name": "Windows WASAPI"}],
        )
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")

        self.assertEqual(sink._select_output_sample_rate(sd, 0), 48000)
        self.assertEqual(sd.checked_settings[0]["samplerate"], 48000)

    def test_falls_back_to_16k_when_default_sample_rate_is_rejected(self):
        class RejectDefaultSoundDevice(FakeSoundDevice):
            def check_output_settings(self, *, device, channels, dtype, samplerate):
                super().check_output_settings(
                    device=device, channels=channels, dtype=dtype, samplerate=samplerate
                )
                if samplerate == 48000:
                    raise RuntimeError("unsupported")

        sd = RejectDefaultSoundDevice(
            devices=[_device("CABLE Input", 2, 0, default_samplerate=48000.0)],
            host_apis=[{"name": "Windows WASAPI"}],
        )
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")

        self.assertEqual(sink._select_output_sample_rate(sd, 0), 16000)
        self.assertEqual([c["samplerate"] for c in sd.checked_settings], [48000, 16000])

    def test_resamples_16k_pcm_to_selected_output_rate_before_writing(self):
        class RecordingStream:
            def __init__(self):
                self.writes = []

            def write(self, array):
                self.writes.append(array)

        stream = RecordingStream()
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")
        sink._stream = stream
        sink._output_sample_rate_hz = 48000
        sink._output_channels = 2

        sink.write([0, 16000, -16000])

        self.assertEqual(stream.writes[0].shape, (9, 2))
        self.assertEqual(stream.writes[0][:, 0].tolist(), stream.writes[0][:, 1].tolist())

    def test_selects_stereo_when_the_endpoint_supports_two_channels(self):
        sd = FakeSoundDevice(
            devices=[_device("CABLE Input", 2, 0, default_samplerate=48000.0)],
            host_apis=[{"name": "Windows WASAPI"}],
        )
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")

        self.assertEqual(sink._select_output_channels(sd, 0), 2)

    def test_falls_back_to_mono_for_a_mono_only_endpoint(self):
        sd = FakeSoundDevice(
            devices=[_device("Speaker", 1, 0)],
            host_apis=[{"name": "Windows WASAPI"}],
        )
        sink = EndpointPlaybackSink("Speaker", host_api="Windows WASAPI")

        self.assertEqual(sink._select_output_channels(sd, 0), 1)

    def test_48k_resampler_keeps_interpolation_continuous_between_chunks(self):
        class RecordingStream:
            def __init__(self):
                self.writes = []

            def write(self, array):
                self.writes.append(array[:, 0].tolist())

        stream = RecordingStream()
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")
        sink._stream = stream
        sink._output_sample_rate_hz = 48000

        sink.write([0, 300])
        sink.write([600])

        self.assertEqual(stream.writes[0], [0, 0, 0, 100, 200, 300])
        self.assertEqual(stream.writes[1], [400, 500, 600])

    def test_prime_writes_silence_before_the_host_trigger(self):
        class RecordingStream:
            def __init__(self):
                self.writes = []

            def write(self, array):
                self.writes.append(array)

        stream = RecordingStream()
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")
        sink._stream = stream
        sink._output_sample_rate_hz = 48000
        sink._output_channels = 2

        sink.prime(duration_seconds=0.010, settle_seconds=0)

        self.assertEqual(len(stream.writes), 1)
        self.assertEqual(stream.writes[0].shape, (480, 2))
        self.assertFalse(stream.writes[0].any())

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


class ContinuousWriterQueueTests(unittest.TestCase):
    def _sink(self):
        sink = EndpointPlaybackSink("CABLE Input", host_api="Windows WASAPI")
        sink._continuous_writer = True
        sink._output_sample_rate_hz = 48000
        sink._output_channels = 2
        sink._max_queued_frames = 96000
        sink._stream = object()
        return sink

    def test_dequeue_outputs_silence_when_queue_is_empty(self):
        sink = self._sink()
        outdata = np.ones((16, 2), dtype="int16")

        sink._dequeue_into(outdata)

        self.assertFalse(outdata.any())

    def test_write_enqueues_and_writer_consumes_resampled_stereo(self):
        sink = self._sink()
        outdata = np.zeros((6, 2), dtype="int16")

        sink.write([0, 300])
        sink._dequeue_into(outdata)

        self.assertEqual(outdata[:, 0].tolist(), [0, 0, 0, 100, 200, 300])
        self.assertEqual(outdata[:, 0].tolist(), outdata[:, 1].tolist())
        self.assertEqual(sink._queued_frames, 0)

    def test_queue_drops_oldest_chunks_before_exceeding_bound(self):
        sink = self._sink()
        sink._max_queued_frames = 5
        first = np.ones((4, 2), dtype="int16")
        second = np.full((4, 2), 2, dtype="int16")

        sink._enqueue_array(first)
        sink._enqueue_array(second)

        self.assertEqual(sink._queued_frames, 4)
        self.assertEqual(len(sink._queued_chunks), 1)
        self.assertTrue((sink._queued_chunks[0] == 2).all())

if __name__ == "__main__":
    unittest.main()
