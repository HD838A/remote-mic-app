# SPDX-License-Identifier: GPL-3.0-only
import os
import struct
import unittest

from audio import Audio
from bridge import DEVICE, GATT, SERVICE, UUIDS, Stream, characteristics, remotes


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        codec = Audio(os.environ['SAYALL_TEST_LIBRARY'])
        self.addCleanup(codec.close)
        self.writes, self.output = [], []
        self.stream = Stream(codec, self.writes.append, self.output.append)
        self.caps = bytes.fromhex('0b 01 00 02 03 00 02')
        self.start = bytes.fromhex('04 03 02 07')

    def test_negotiation_and_complete_phrases(self):
        s = self.stream
        s.write(0x0a)
        s.press()
        s.packet(b'\x7f')
        self.assertEqual(self.writes, [bytes.fromhex('0a0100000303')])
        s.control(self.caps)
        s.press()
        s.control(b'\x08')  # a duplicate remote request must not restart the stream
        s.control(self.start)
        s.packet(b'\x7f')
        self.assertEqual(self.output, [])
        s.release()
        s.packet(b'\x11')  # final fragment after physical release
        s.control(b'\x00')
        self.assertEqual(self.writes[1:], [bytes.fromhex('0c00'), bytes.fromhex('0d07')])
        self.assertEqual(len(self.output[0]), 8)
        self.assertEqual(struct.unpack_from('<h', self.output[0])[0], 11)
        s.packet(b'\xff\xff')  # stale after stop
        s.control(self.start)
        s.packet(b'\x7f\x11')
        self.assertEqual(self.output[0], self.output[1])

    def test_sync_discards_partial_frame(self):
        s = self.stream
        s.control(self.caps)
        s.control(self.start)
        s.packet(b'\xff')
        s.control(bytes.fromhex('0a 00 00 00 ff 9c 00'))
        s.packet(b'\x00\x00')
        self.assertEqual(struct.unpack('<4h', self.output[0]), (-100,) * 4)

    def test_rejects_malformed_or_8khz(self):
        s = self.stream
        for packet in [b'\x0b', bytes.fromhex('0b010001030078')]:
            with self.assertRaises(RuntimeError):
                s.control(packet)
        s.control(self.caps)
        with self.assertRaises(RuntimeError):
            s.control(bytes.fromhex('04 03 01 07'))
        self.assertFalse(self.output)

    def test_reply_is_confined_to_selected_device_and_service(self):
        model = {'Paired': True, 'Modalias': 'bluetooth:v2717p32B8d00A4', 'Address': 'A'}
        objects = {'/d': {DEVICE: model}, '/other': {DEVICE: {**model, 'Address': 'B'}},
                   '/s': {SERVICE: {'Device': '/d', 'UUID': UUIDS[0]}},
                   '/s2': {SERVICE: {'Device': '/other', 'UUID': UUIDS[0]}},
                   '/c': {GATT: {'Service': '/s', 'UUID': UUIDS[1]}},
                   '/c2': {GATT: {'Service': '/s2', 'UUID': UUIDS[1]}}}
        self.assertEqual(remotes(objects, 'a'), [('/d', model)])
        self.assertEqual(characteristics(objects, '/d')[UUIDS[1]][0], '/c')
