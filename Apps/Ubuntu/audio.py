# SPDX-License-Identifier: GPL-3.0-only
"""Connection-scoped access to the same ATVV implementation compiled on macOS."""
import ctypes as c
from pathlib import Path


class Audio:
    def __init__(self, library):
        self.lib = c.CDLL(str(Path(library).resolve()))
        ptr, size, byte = c.c_void_p, c.c_ssize_t, c.c_ubyte
        signatures = {
            'sayall_audio_new': (ptr, []), 'sayall_audio_free': (None, [ptr]),
            'sayall_capabilities': (size, [ptr, c.c_char_p, size]),
            'sayall_command': (size, [ptr, byte, byte, c.POINTER(byte)]),
            'sayall_audio_reset': (None, [ptr, c.c_int32, byte]),
            'sayall_decode': (size, [ptr, c.c_char_p, size, c.POINTER(c.c_int16), size]),
        }
        for name, (result, args) in signatures.items():
            fn = getattr(self.lib, name)
            fn.restype, fn.argtypes = result, args
        self.handle = self.lib.sayall_audio_new()
        self.out = (c.c_int16 * 2048)()

    def close(self):
        if self.handle:
            self.lib.sayall_audio_free(self.handle)
            self.handle = None

    def configure(self, packet):
        return self.lib.sayall_capabilities(self.handle, packet, len(packet))

    def command(self, opcode, session=0):
        output = (c.c_ubyte * 6)()
        count = self.lib.sayall_command(self.handle, opcode, session, output)
        return bytes(output[:count])

    def reset(self, predictor=0, step=0):
        self.lib.sayall_audio_reset(self.handle, predictor, step)

    def decode(self, packet):
        count = self.lib.sayall_decode(self.handle, packet, len(packet), self.out, len(self.out))
        if count < 0:
            raise ValueError('Invalid or unnegotiated audio packet')
        return c.string_at(self.out, count * 2)
