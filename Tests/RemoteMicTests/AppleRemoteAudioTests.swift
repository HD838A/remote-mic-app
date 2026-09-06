#if SAYALL_SIRI_REMOTE_ENABLED
import Foundation
import Testing
@testable import AppleRemoteAudioCore
@testable import RemoteMic

@Suite("Apple Remote audio transport")
struct AppleRemoteAudioTests {
    @Test func stalePCMCallbacksAreRejectedAfterCaptureStops() {
        var gate = AppleRemoteAudioCaptureGenerationGate()

        let firstGeneration = gate.begin()
        #expect(gate.accepts(firstGeneration))

        let closingGeneration = gate.beginClosing()
        #expect(closingGeneration == firstGeneration)
        #expect(gate.phase == .closing)
        #expect(gate.accepts(firstGeneration))

        let resumedGeneration = gate.resume()
        #expect(resumedGeneration == firstGeneration)
        #expect(gate.phase == .active)
        #expect(gate.accepts(firstGeneration))
        _ = gate.beginClosing()

        _ = gate.stop()
        #expect(!gate.accepts(firstGeneration))

        let secondGeneration = gate.begin()
        #expect(secondGeneration != firstGeneration)
        #expect(!gate.accepts(firstGeneration))
        #expect(gate.accepts(secondGeneration))
    }

    @Test func parsesVoiceNotificationFromPacketLoggerLine() {
        let line = "2026-09-05 00:00:00 0x0042 RECV 04 00 1B 34 12 00 00 07 00 04 B8 AA BB CC"

        let frame = AppleRemoteVoiceFrameParser.parse(line)

        #expect(frame?.connectionHandle == "0x0042")
        #expect(frame?.attributeHandle == 0x1234)
        #expect(frame?.sequence == 7)
        #expect(frame?.opusPayload == Data([0xB8, 0xAA, 0xBB, 0xCC]))
    }

    @Test func rejectsNonVoiceNotification() {
        let line = "0x0042 RECV 04 00 1B 34 12 00 00 07 00 90 AA BB"
        #expect(AppleRemoteVoiceFrameParser.parse(line) == nil)
    }

    @Test func reassemblesFragmentedPklgACLRecord() {
        let l2cap = [UInt8](
            [0x0C, 0x00, 0x04, 0x00, 0x1B, 0x34, 0x12, 0x00, 0x00, 0x07, 0x00, 0x04, 0xB8, 0xAA, 0xBB, 0xCC]
        )
        let acl = [UInt8]([0x42, 0x20, UInt8(l2cap.count & 0xFF), UInt8(l2cap.count >> 8)] + l2cap)
        let record = pklgRecord(type: 0x03, payload: acl)
        let extractor = AppleRemotePklgVoiceExtractor()

        #expect(extractor.ingest(Data(record.prefix(7))).isEmpty)
        let frames = extractor.ingest(Data(record.dropFirst(7)))

        #expect(frames.count == 1)
        #expect(frames.first?.connectionHandle == "0x0042")
        #expect(frames.first?.sequence == 7)
        #expect(extractor.recordsScanned == 1)
    }

    @Test func ipcDecoderHandlesFrameFragmentationAndPCM() {
        let encoded = AppleRemoteAudioIPC.pcmFrame(samples: [-2, 0, 32767])
        var buffer = Data(encoded.prefix(3))
        #expect(AppleRemoteAudioIPC.decodeFrames(buffer: &buffer).isEmpty)

        buffer.append(encoded.dropFirst(3))
        let frames = AppleRemoteAudioIPC.decodeFrames(buffer: &buffer)

        #expect(buffer.isEmpty)
        #expect(frames.count == 1)
        #expect(AppleRemoteAudioIPC.samples(from: frames[0]) == [-2, 0, 32767])
    }

    @Test func ipcDecoderSkipsUnknownFrameKindsWithoutBreakingFollowingFrame() {
        var input = AppleRemoteAudioIPC.encode(.init(kind: .status, payload: Data("ready".utf8)))
        input.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0xFF])
        input.append(AppleRemoteAudioIPC.encode(.init(kind: .status, payload: Data("stopped".utf8))))
        var buffer = input

        let frames = AppleRemoteAudioIPC.decodeFrames(buffer: &buffer)

        #expect(frames.map(\.payload) == [Data("ready".utf8), Data("stopped".utf8)])
        #expect(buffer.isEmpty)
    }

    @Test func recognizesProfileRequiredPacketLoggerRecord() {
        let record = Data(pklgRecord(
            type: 0xFC,
            payload: Array("Bluetooth Profile Required".utf8)
        ))

        #expect(AppleRemotePacketLoggerRecord.isValid(record))
        #expect(AppleRemotePacketLoggerRecord.isProfileRequired(record))
        #expect(AppleRemotePacketLoggerRecord.isProfileRequired(
            Data("Bluetooth Profile Required\0".utf8)
        ))
    }

    @Test func rejectsMalformedAndUnrelatedPacketLoggerRecords() {
        let unrelated = Data(pklgRecord(type: 0x03, payload: [0x01, 0x02]))
        var malformed = unrelated
        malformed[3] = 0xFF

        #expect(AppleRemotePacketLoggerRecord.isValid(unrelated))
        #expect(!AppleRemotePacketLoggerRecord.isProfileRequired(unrelated))
        #expect(!AppleRemotePacketLoggerRecord.isValid(malformed))
    }

    @Test func xpcParserNormalizesRawACLAndLocksA2854VoiceStream() {
        var parser = AppleRemoteXPCVoiceParser()
        var emitted: [Data] = []

        for sequence in UInt16(7)...UInt16(9) {
            let body = a2854VoiceBody(sequence: sequence, opus: [0xB8, 0xAA, 0xBB, 0xCC])
            let att = [UInt8]([0x1B, 0x35, 0x00] + body)
            let l2cap = [UInt8]([
                UInt8(att.count & 0xFF), UInt8(att.count >> 8), 0x04, 0x00,
            ] + att)
            let acl = [UInt8]([
                0x42, 0x20, UInt8(l2cap.count & 0xFF), UInt8(l2cap.count >> 8),
            ] + l2cap)
            emitted.append(contentsOf: parser.ingestXPCPacket(Data([0x03] + acl)))
        }

        #expect(emitted == Array(repeating: Data([0xB8, 0xAA, 0xBB, 0xCC]), count: 3))
        #expect(parser.statistics.normalizedRawACLPackets == 3)
        #expect(parser.statistics.completedATTValues == 3)
        #expect(parser.statistics.streamsLocked == 1)
    }

    @Test func xpcParserPreservesFirstPacketsWhenSequenceRestartsForNewHold() {
        var parser = AppleRemoteXPCVoiceParser()
        var emitted: [Data] = []

        for sequence in [UInt16(100), 101, 102, 0, 1, 2] {
            let opus = [UInt8](arrayLiteral: 0xB8, UInt8(truncatingIfNeeded: sequence))
            let body = a2854VoiceBody(sequence: sequence, opus: opus)
            let att = [UInt8]([0x1B, 0x35, 0x00] + body)
            let l2cap = [UInt8]([
                UInt8(att.count & 0xFF), UInt8(att.count >> 8), 0x04, 0x00,
            ] + att)
            let acl = [UInt8]([
                0x42, 0x20, UInt8(l2cap.count & 0xFF), UInt8(l2cap.count >> 8),
            ] + l2cap)
            emitted.append(contentsOf: parser.ingestXPCPacket(Data([0x03] + acl)))
        }

        #expect(emitted.suffix(3) == [Data([0xB8, 0]), Data([0xB8, 1]), Data([0xB8, 2])])
        #expect(parser.statistics.streamsLocked == 2)
    }

    private func pklgRecord(type: UInt8, payload: [UInt8]) -> [UInt8] {
        var length = UInt32(9 + payload.count).bigEndian
        var record = Data(bytes: &length, count: 4)
        record.append(contentsOf: Array(repeating: 0, count: 8))
        record.append(type)
        record.append(contentsOf: payload)
        return Array(record)
    }

    private func a2854VoiceBody(sequence: UInt16, opus: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 100)
        body[0] = 0x01
        body[1] = 0x00
        body[2] = UInt8(truncatingIfNeeded: sequence)
        body[3] = UInt8(truncatingIfNeeded: sequence >> 8)
        body[4] = UInt8(opus.count)
        body.replaceSubrange(5..<(5 + opus.count), with: opus)
        return body
    }
}
#endif
