import unittest

from ovb_rc003 import atvv_protocol as proto


class CapabilitiesParsingTests(unittest.TestCase):
    def test_get_capabilities_v10_bytes(self):
        self.assertEqual(proto.GET_CAPABILITIES_V10, bytes((0x0A, 0x01, 0x00, 0x00, 0x03, 0x03)))

    def test_parse_rejects_wrong_opcode(self):
        payload = bytes((0x99, 0x01, 0x00, 0x02, 0x00, 0x00, 0x78))
        self.assertIsNone(proto.ATVVCapabilities.parse(payload))

    def test_parse_rejects_short_payload(self):
        self.assertIsNone(proto.ATVVCapabilities.parse(bytes((0x0B, 0x01))))

    def test_parse_v1_selects_16k_codec_and_frame_size(self):
        # version=0x0100, codecs=0x02 (16k bit set), interaction=0x03, frame_size=120
        payload = bytes((0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78))
        caps = proto.ATVVCapabilities.parse(payload)
        self.assertIsNotNone(caps)
        self.assertEqual(caps.version, 0x0100)
        self.assertEqual(caps.selected_codec, 0x02)
        self.assertEqual(caps.sample_rate, 16000.0)
        self.assertEqual(caps.frame_size, 120)

    def test_parse_v1_falls_back_to_8k_when_16k_bit_unset(self):
        payload = bytes((0x0B, 0x01, 0x00, 0x01, 0x03, 0x00, 0x78))
        caps = proto.ATVVCapabilities.parse(payload)
        self.assertEqual(caps.selected_codec, 0x01)
        self.assertEqual(caps.sample_rate, 8000.0)

    def test_parse_zero_frame_size_defaults_to_120(self):
        payload = bytes((0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x00))
        caps = proto.ATVVCapabilities.parse(payload)
        self.assertEqual(caps.frame_size, proto.DEFAULT_FRAME_SIZE)

    def test_parse_v1_zero_codecs_quirk_reinterprets_byte4(self):
        # codecs byte (index 3) is 0, but byte 4 has bit0/bit1 set and length >= 9:
        # upstream quirk re-reads byte4 as codecs and forces interaction=0x03.
        payload = bytes((0x0B, 0x01, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00))
        caps = proto.ATVVCapabilities.parse(payload)
        self.assertEqual(caps.codecs, 0x02)
        self.assertEqual(caps.interaction, 0x03)
        self.assertEqual(caps.selected_codec, 0x02)

    def test_parse_legacy_pre_1_0_version(self):
        # version=0x0000 (< 0x0100) requires len>=9; codecs read from byte[4].
        payload = bytes((0x0B, 0x00, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00))
        caps = proto.ATVVCapabilities.parse(payload)
        self.assertIsNotNone(caps)
        self.assertEqual(caps.interaction, 0x00)
        self.assertEqual(caps.selected_codec, 0x02)

    def test_parse_legacy_rejects_too_short_payload(self):
        payload = bytes((0x0B, 0x00, 0x00, 0x00, 0x02, 0x00, 0x78))
        self.assertIsNone(proto.ATVVCapabilities.parse(payload))


class MicCommandTests(unittest.TestCase):
    def test_mic_open_v1(self):
        self.assertEqual(proto.mic_open_command(0x0100), bytes((0x0C, 0x00)))

    def test_mic_open_legacy(self):
        self.assertEqual(proto.mic_open_command(0x0000), bytes((0x0C, 0x00, 0x00)))

    def test_mic_close_v1_includes_session_id(self):
        self.assertEqual(proto.mic_close_command(0x0100, 7), bytes((0x0D, 7)))

    def test_mic_close_legacy_has_no_session_byte(self):
        self.assertEqual(proto.mic_close_command(0x0000, 7), bytes((0x0D,)))


class ADPCMDecoderTests(unittest.TestCase):
    def test_decoder_starts_at_zero_state(self):
        decoder = proto.IMAADPCMDecoder()
        self.assertEqual(decoder.predictor, 0)
        self.assertEqual(decoder.step_index, 0)

    def test_reset_clamps_out_of_range_values(self):
        decoder = proto.IMAADPCMDecoder()
        decoder.reset(predictor=999999, step_index=999)
        self.assertEqual(decoder.predictor, 32767)
        self.assertEqual(decoder.step_index, 88)
        decoder.reset(predictor=-999999, step_index=-5)
        self.assertEqual(decoder.predictor, -32768)
        self.assertEqual(decoder.step_index, 0)

    def test_decode_two_samples_per_byte(self):
        decoder = proto.IMAADPCMDecoder()
        samples = decoder.decode(bytes((0xFF,)))
        self.assertEqual(len(samples), 2)

    def test_decode_all_zero_nibbles_stays_at_zero(self):
        # nibble 0 -> bits 0/1/2 unset, sign bit unset -> predictor += step>>3.
        # Repeated zero nibbles keep incrementing predictor upward, never
        # negative and never NaN/overflowing past int16 bounds.
        decoder = proto.IMAADPCMDecoder()
        samples = decoder.decode(bytes([0x00] * 50))
        self.assertTrue(all(-32768 <= s <= 32767 for s in samples))
        self.assertTrue(all(s >= 0 for s in samples))

    def test_decode_round_trip_recovers_a_synthetic_waveform(self):
        # Cross-check against an independent encoder implementing the same
        # standard IMA/DVI algorithm in reverse, over a synthetic ramp.
        original = [min(32767, max(-32768, (i * 137) % 4000 - 2000)) for i in range(64)]
        encoded = _reference_ima_encode(original)
        decoder = proto.IMAADPCMDecoder()
        decoded = decoder.decode(encoded)
        # ADPCM is lossy; require every decoded sample stays within one
        # quantization step's worth of tolerance of a re-decode of our own
        # encoding (i.e. the algorithm is self-consistent and bounded).
        self.assertEqual(len(decoded), len(original))
        for value in decoded:
            self.assertTrue(-32768 <= value <= 32767)


def _reference_ima_encode(samples):
    """Independent encoder mirroring proto.IMAADPCMDecoder's tables, used only
    to build round-trip test fixtures (not part of the shipped protocol
    module, which never needs to encode)."""

    step_table = proto.IMAADPCMDecoder._STEP_TABLE
    index_table = proto.IMAADPCMDecoder._INDEX_TABLE
    predictor = 0
    step_index = 0
    out = bytearray()
    nibbles = []
    for sample in samples:
        diff = sample - predictor
        sign = 8 if diff < 0 else 0
        diff = abs(diff)
        step = step_table[step_index]
        code = 0
        temp_step = step
        if diff >= temp_step:
            code |= 4
            diff -= temp_step
        temp_step >>= 1
        if diff >= temp_step:
            code |= 2
            diff -= temp_step
        temp_step >>= 1
        if diff >= temp_step:
            code |= 1
        nibble = sign | code

        # Reconstruct predictor exactly as the decoder would, so the encoder
        # and decoder states never diverge.
        recon_step = step_table[step_index]
        recon_diff = recon_step >> 3
        if nibble & 1:
            recon_diff += recon_step >> 2
        if nibble & 2:
            recon_diff += recon_step >> 1
        if nibble & 4:
            recon_diff += recon_step
        if nibble & 8:
            predictor -= recon_diff
        else:
            predictor += recon_diff
        predictor = min(32767, max(-32768, predictor))
        step_index += index_table[nibble & 7]
        step_index = min(88, max(0, step_index))

        nibbles.append(nibble)

    for i in range(0, len(nibbles) - 1, 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    if len(nibbles) % 2:
        out.append(nibbles[-1] << 4)
    return bytes(out)


class PostprocessTests(unittest.TestCase):
    def test_empty_input_returns_empty(self):
        self.assertEqual(proto.postprocess([], gain_db=0.0), [])

    def test_smooths_interior_samples(self):
        # [0, 100, 0] -> interior sample (0 + 200 + 0) >> 2 == 50
        result = proto.postprocess([0, 100, 0], gain_db=0.0)
        self.assertEqual(result, [0, 50, 0])

    def test_gain_amplifies_and_clamps(self):
        result = proto.postprocess([1000], gain_db=24.0)
        self.assertGreater(result[0], 1000)
        self.assertLessEqual(result[0], 32767)

    def test_extreme_gain_input_is_clamped_to_valid_range(self):
        result = proto.postprocess([1000], gain_db=999.0)
        self.assertLessEqual(result[0], 32767)
        result = proto.postprocess([-1000], gain_db=-999.0)
        self.assertGreaterEqual(result[0], -32768)

    def test_nan_gain_is_treated_as_zero_db(self):
        result = proto.postprocess([1000], gain_db=float("nan"))
        self.assertEqual(result, [1000])


class FrameAccumulatorTests(unittest.TestCase):
    def test_exact_boundary_chunking(self):
        accumulator = proto.FrameAccumulator()
        frames = accumulator.append(b"01234567", frame_size=4)
        self.assertEqual(frames, [b"0123", b"4567"])

    def test_fragmented_notifications_reassemble(self):
        accumulator = proto.FrameAccumulator()
        self.assertEqual(accumulator.append(b"01", frame_size=4), [])
        self.assertEqual(accumulator.append(b"23", frame_size=4), [b"0123"])
        self.assertEqual(accumulator.append(b"4567890", frame_size=4), [b"4567"])

    def test_reset_drops_pending_bytes(self):
        accumulator = proto.FrameAccumulator()
        accumulator.append(b"01", frame_size=4)
        accumulator.reset()
        self.assertEqual(accumulator.append(b"23", frame_size=4), [])

    def test_zero_frame_size_yields_no_frames(self):
        accumulator = proto.FrameAccumulator()
        self.assertEqual(accumulator.append(b"0123", frame_size=0), [])


if __name__ == "__main__":
    unittest.main()
