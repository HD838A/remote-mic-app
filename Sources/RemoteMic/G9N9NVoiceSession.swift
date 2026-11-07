import Foundation

/// Public ATVV implementation for the Jieli G9N9N. No speech recognizer or text
/// injection here: PCM and voice edges use SayAll's existing delivery pipeline.
final class G9N9NVoiceSession {
    var onWrite: ((Data) -> Void)?
    var onStart: (() -> Void)?
    var onStop: ((ChromecastVoiceEndReason) -> Void)?
    var onSamples: (([Int16], Int) -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var capabilities: ATVVCapabilities?
    private(set) var active = false
    private(set) var generation = 0
    private(set) var stopDeadline: TimeInterval?
    private var sessionID: UInt8 = 0
    private var cancelled = false
    private var accumulator = FrameAccumulator()
    private let decoder = IMAADPCMDecoder()
    private var pendingSync: (Int, Int)?
    private var frames = 0
    private var samples = 0
    private var startedAt: TimeInterval = 0
    private var firstPCM = false

    static func matches(model: String?, manufacturer: String?) -> Bool {
        model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hid_mouse"
            && manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zhuhai_jieli"
    }

    @discardableResult
    func acceptCapabilities(_ data: Data) -> Bool {
        guard let value = ATVVCapabilities.parse(data), value.codecs & 2 != 0,
              value.frameSize > 0, value.frameSize <= 4096,
              ATVVProtocol.supportsAudio(sampleRate: value.sampleRate) else { return false }
        capabilities = value
        onLog?("G9N9N CAPS phase=ready codec=2 frame_bytes=\(value.frameSize)")
        return true
    }

    func control(_ data: Data, now: TimeInterval) {
        guard let caps = capabilities, let opcode = data.first else { return }
        let bytes = Array(data)
        switch opcode {
        case 0x08:
            if stopDeadline != nil { finish(reason: .holdRelease, now: now) }
            guard !active else { return }
            cancelled = false
            begin(now: now)
            onWrite?(ATVVProtocol.microphoneOpen(version: caps.version, codec: caps.selectedCodec))
        case 0x04:
            guard bytes.count >= 4, bytes[2] == caps.selectedCodec else {
                cancel(reason: "invalid_stream_start", now: now)
                return
            }
            sessionID = bytes[3]
            guard !cancelled else {
                onWrite?(ATVVProtocol.microphoneClose(version: caps.version, sessionID: sessionID))
                return
            }
            // An explicit new START separates sessions, even inside the tail window.
            if stopDeadline != nil { finish(reason: .holdRelease, now: now) }
            if !active { begin(now: now) }
        case 0x00:
            guard active, stopDeadline == nil else { return }
            // Keep accepting ordered tail notifications before the host drains audio.
            stopDeadline = now + 0.12
        case 0x0A:
            guard active, bytes.count >= 7, bytes[6] <= 88 else { return }
            flushPartial(now: now)
            pendingSync = (Int(Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5]))), Int(bytes[6]))
        default: break
        }
    }

    func audio(_ data: Data, now: TimeInterval) {
        guard capabilities != nil, active, !cancelled, !data.isEmpty else { return }
        // Do not infer a new session from late audio after STOP or host cancellation.
        if let deadline = stopDeadline, now >= deadline {
            drain(now: now)
            return
        }
        guard data.count <= 4096, let caps = capabilities else { return }
        for frame in accumulator.append(data, frameSize: caps.frameSize) { decode(frame, now: now) }
    }

    func drain(now: TimeInterval) {
        guard let deadline = stopDeadline, now >= deadline else { return }
        finish(reason: .holdRelease, now: now)
    }

    func extend() {
        guard active, stopDeadline == nil, let caps = capabilities,
              let data = ATVVProtocol.microphoneExtend(version: caps.version, sessionID: sessionID)
        else { return }
        onWrite?(data)
        onLog?("G9N9N VOICE phase=sustained generation=\(generation)")
    }

    func cancel(reason: String, now: TimeInterval) {
        // Host usage cleanup also runs after a normal transport stop. It must
        // not poison the next direct STREAM_START as a cancelled late packet.
        guard active else { return }
        cancelled = true
        if active, let caps = capabilities {
            onWrite?(ATVVProtocol.microphoneClose(version: caps.version, sessionID: sessionID))
        }
        finish(reason: .cancelled(reason), now: now)
    }

    func reset(now: TimeInterval) {
        cancel(reason: "disconnect", now: now)
        capabilities = nil
        sessionID = 0
        cancelled = false
    }

    private func begin(now: TimeInterval) {
        active = true
        generation += 1
        frames = 0
        samples = 0
        firstPCM = false
        startedAt = now
        stopDeadline = nil
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        onLog?("G9N9N VOICE phase=started generation=\(generation)")
        onStart?()
    }

    private func decode(_ frame: Data, now: TimeInterval) {
        if let sync = pendingSync {
            decoder.reset(predictor: sync.0, stepIndex: sync.1)
            pendingSync = nil
        }
        let pcm = PCMPostprocessor.process(decoder.decode(frame), gainDB: 0)
        frames += 1
        samples += pcm.count
        if !firstPCM {
            firstPCM = true
            onLog?("G9N9N AUDIO phase=first_pcm generation=\(generation) trigger_down_to_first_pcm_ms=\(Int(max(0, now - startedAt) * 1000))")
        }
        onSamples?(pcm, generation)
    }

    private func flushPartial(now: TimeInterval) {
        let tail = accumulator.pending
        accumulator.reset()
        if !tail.isEmpty { decode(tail, now: now) }
    }

    private func finish(reason: ChromecastVoiceEndReason, now: TimeInterval) {
        guard active else { return }
        if reason.isNormal { flushPartial(now: now) } else { accumulator.reset() }
        active = false
        pendingSync = nil
        stopDeadline = nil
        onLog?("G9N9N VOICE phase=completed generation=\(generation) completion=\(reason.isNormal ? "normal" : "forced") reason=\(reason.logToken) frames=\(frames) samples=\(samples) elapsed_ms=\(Int(max(0, now - startedAt) * 1000))")
        onStop?(reason)
    }
}
