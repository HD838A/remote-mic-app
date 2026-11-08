// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Each BlueZ connection owns its own decoder, negotiated format and partial frame.
private final class Connection {
    var capabilities: ATVVCapabilities?
    var frames = FrameAccumulator()
    let decoder = IMAADPCMDecoder()
}

@_cdecl("sayall_audio_new")
public func newAudio() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Connection()).toOpaque()
}

@_cdecl("sayall_audio_free")
public func freeAudio(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<Connection>.fromOpaque(handle).release()
}

private func connection(_ handle: UnsafeMutableRawPointer) -> Connection {
    Unmanaged<Connection>.fromOpaque(handle).takeUnretainedValue()
}

@_cdecl("sayall_capabilities")
public func capabilities(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int {
    let state = connection(handle)
    state.capabilities = nil
    guard let caps = ATVVCapabilities.parse(Data(bytes: bytes, count: count)),
          ATVVProtocol.supportsAudio(sampleRate: caps.sampleRate), caps.frameSize <= 512 else { return 0 }
    state.capabilities = caps
    return caps.frameSize
}

// Writes at most six command bytes. The caller supplies a six-byte destination.
@_cdecl("sayall_command")
public func command(_ handle: UnsafeMutableRawPointer, _ opcode: UInt8, _ session: UInt8, _ output: UnsafeMutablePointer<UInt8>) -> Int {
    let payload: Data
    if opcode == 0x0a {
        payload = ATVVProtocol.getCapabilitiesV10
    } else {
        guard let caps = connection(handle).capabilities else { return 0 }
        switch opcode {
        case 0x0c: payload = ATVVProtocol.microphoneOpen(version: caps.version, codec: caps.selectedCodec)
        case 0x0d: payload = ATVVProtocol.microphoneClose(version: caps.version, sessionID: session)
        case 0x0e:
            guard let extend = ATVVProtocol.microphoneExtend(version: caps.version, sessionID: session) else { return 0 }
            payload = extend
        default: return 0
        }
    }
    payload.copyBytes(to: output, count: payload.count)
    return payload.count
}

@_cdecl("sayall_audio_reset")
public func reset(_ handle: UnsafeMutableRawPointer, _ predictor: Int32, _ step: UInt8) {
    let state = connection(handle)
    state.frames.reset()
    state.decoder.reset(predictor: Int(predictor), stepIndex: Int(step))
}

@_cdecl("sayall_decode")
public func decode(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ count: Int,
                   _ output: UnsafeMutablePointer<Int16>, _ capacity: Int) -> Int {
    let state = connection(handle)
    guard let caps = state.capabilities, count >= 0, count <= 512,
          (state.frames.pending.count + count) * 2 <= capacity else { return -1 }
    var written = 0
    for frame in state.frames.append(Data(bytes: bytes, count: count), frameSize: caps.frameSize) {
        let samples = PCMPostprocessor.process(state.decoder.decode(frame), gainDB: 0)
        samples.withUnsafeBufferPointer { buffer in
            output.advanced(by: written).update(from: buffer.baseAddress!, count: buffer.count)
        }
        written += samples.count
    }
    return written
}
