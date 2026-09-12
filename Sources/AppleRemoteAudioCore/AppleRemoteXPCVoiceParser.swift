import Foundation

public struct AppleRemoteXPCVoiceParserStatistics: Equatable {
    public internal(set) var xpcBlobsSeen = 0
    public internal(set) var normalizedRawACLPackets = 0
    public internal(set) var ignoredXPCBlobs = 0
    public internal(set) var packetLoggerRecordsSeen = 0
    public internal(set) var inboundACLPacketsSeen = 0
    public internal(set) var completedATTValues = 0
    public internal(set) var validVoiceWrappers = 0
    public internal(set) var streamsLocked = 0
    public internal(set) var opusPacketsEmitted = 0

    public init() {}
}

/// In-memory parser for the packet blobs returned by macOS's BTPacketLogger XPC service.
/// It accepts full PacketLogger records and the raw live-ACL shapes observed on macOS 26.
public struct AppleRemoteXPCVoiceParser {
    private struct Source: Hashable {
        let connectionHandle: UInt16
        let attributeHandle: UInt16
    }

    private struct ATTValue {
        let connectionHandle: UInt16
        let attributeHandle: UInt16
        let value: Data
    }

    private struct InflightPDU {
        let expectedLength: Int
        var bytes: Data
    }

    private struct VoicePacket {
        let sequence: UInt16
        let opus: Data
    }

    private struct Candidate {
        var lastSequence: UInt16
        var packets: [Data]
        var generation: UInt64
    }

    private var recordBuffer = Data()
    private var inflight: [UInt16: InflightPDU] = [:]
    private var candidates: [Source: Candidate] = [:]
    private var lockedSource: Source?
    private var lockedLastSequence: UInt16?
    private var generation: UInt64 = 0
    public private(set) var statistics = AppleRemoteXPCVoiceParserStatistics()

    public init() {}

    public mutating func ingestXPCPacket(_ blob: Data) -> [Data] {
        statistics.xpcBlobsSeen += 1
        if Self.isCompletePacketLoggerRecord(blob) {
            return ingestPacketLoggerBytes(blob)
        }
        guard let acl = Self.normalizeInboundACL(blob) else {
            statistics.ignoredXPCBlobs += 1
            return []
        }
        statistics.normalizedRawACLPackets += 1
        return ingestPacketLoggerBytes(Self.packetLoggerRecord(forInboundACL: acl))
    }

    public mutating func reset() {
        recordBuffer.removeAll(keepingCapacity: true)
        inflight.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
        lockedSource = nil
        lockedLastSequence = nil
        generation = 0
        statistics = AppleRemoteXPCVoiceParserStatistics()
    }

    private mutating func ingestPacketLoggerBytes(_ bytes: Data) -> [Data] {
        recordBuffer.append(bytes)
        var output: [Data] = []
        while recordBuffer.count >= 4 {
            let bodyLength = Int(Self.bigEndianUInt32(recordBuffer, at: 0))
            guard bodyLength >= 9, bodyLength <= 1_048_576 else {
                recordBuffer.removeAll(keepingCapacity: true)
                inflight.removeAll(keepingCapacity: true)
                return output
            }
            let recordLength = bodyLength + 4
            guard recordBuffer.count >= recordLength else { break }
            let record = Data(recordBuffer.prefix(recordLength))
            recordBuffer = Data(recordBuffer.dropFirst(recordLength))
            statistics.packetLoggerRecordsSeen += 1
            guard record[12] == 0x03 else { continue }
            statistics.inboundACLPacketsSeen += 1
            let payload = Data(record.dropFirst(13))
            for value in consumeACL(payload) {
                output.append(contentsOf: classify(value))
            }
        }
        return output
    }

    private mutating func consumeACL(_ packet: Data) -> [ATTValue] {
        guard packet.count >= 4 else { return [] }
        let handleField = Self.littleEndianUInt16(packet, at: 0)
        let handle = handleField & 0x0FFF
        let boundary = UInt8((handleField >> 12) & 0x03)
        let declaredLength = Int(Self.littleEndianUInt16(packet, at: 2))
        guard declaredLength == packet.count - 4 else {
            inflight.removeValue(forKey: handle)
            return []
        }
        let aclData = Data(packet.dropFirst(4))
        switch boundary {
        case 0b00, 0b10, 0b11:
            guard aclData.count >= 4 else { return [] }
            let l2capLength = Int(Self.littleEndianUInt16(aclData, at: 0))
            let cid = Self.littleEndianUInt16(aclData, at: 2)
            guard cid == 0x0004, l2capLength <= 512 else {
                inflight.removeValue(forKey: handle)
                return []
            }
            let initial = Data(aclData.dropFirst(4))
            guard initial.count <= l2capLength else { return [] }
            if initial.count == l2capLength {
                return completeATT(handle: handle, pdu: initial)
            }
            inflight[handle] = InflightPDU(expectedLength: l2capLength, bytes: initial)
            return []
        case 0b01:
            guard var pdu = inflight.removeValue(forKey: handle),
                  pdu.bytes.count + aclData.count <= pdu.expectedLength else { return [] }
            pdu.bytes.append(aclData)
            if pdu.bytes.count == pdu.expectedLength {
                return completeATT(handle: handle, pdu: pdu.bytes)
            }
            inflight[handle] = pdu
            return []
        default:
            return []
        }
    }

    private mutating func completeATT(handle: UInt16, pdu: Data) -> [ATTValue] {
        guard pdu.count >= 3, pdu[0] == 0x1B || pdu[0] == 0x1D else { return [] }
        statistics.completedATTValues += 1
        return [ATTValue(
            connectionHandle: handle,
            attributeHandle: Self.littleEndianUInt16(pdu, at: 1),
            value: Data(pdu.dropFirst(3))
        )]
    }

    private mutating func classify(_ input: ATTValue) -> [Data] {
        guard let packet = Self.decodeVoicePacket(input.value) else {
            if lockedSource == Source(
                connectionHandle: input.connectionHandle,
                attributeHandle: input.attributeHandle
            ) {
                lockedSource = nil
                lockedLastSequence = nil
            }
            return []
        }
        statistics.validVoiceWrappers += 1
        let source = Source(
            connectionHandle: input.connectionHandle,
            attributeHandle: input.attributeHandle
        )

        if let lockedSource {
            guard lockedSource == source, let previous = lockedLastSequence else { return [] }
            let distance = packet.sequence &- previous
            guard distance > 0, distance < 0x8000 else {
                self.lockedSource = nil
                lockedLastSequence = nil
                beginCandidate(source: source, packet: packet)
                return []
            }
            lockedLastSequence = packet.sequence
            statistics.opusPacketsEmitted += 1
            return [packet.opus]
        }

        if var candidate = candidates[source], packet.sequence == candidate.lastSequence &+ 1 {
            generation &+= 1
            candidate.lastSequence = packet.sequence
            candidate.packets.append(packet.opus)
            candidate.generation = generation
            candidates[source] = candidate
        } else {
            beginCandidate(source: source, packet: packet)
        }

        guard let candidate = candidates[source], candidate.packets.count >= 3 else { return [] }
        lockedSource = source
        lockedLastSequence = candidate.lastSequence
        candidates.removeAll(keepingCapacity: true)
        statistics.streamsLocked += 1
        statistics.opusPacketsEmitted += candidate.packets.count
        return candidate.packets
    }

    private mutating func beginCandidate(source: Source, packet: VoicePacket) {
        generation &+= 1
        if candidates[source] == nil, candidates.count >= 8,
           let oldest = candidates.min(by: { $0.value.generation < $1.value.generation })?.key {
            candidates.removeValue(forKey: oldest)
        }
        candidates[source] = Candidate(
            lastSequence: packet.sequence,
            packets: [packet.opus],
            generation: generation
        )
    }

    private static func decodeVoicePacket(_ value: Data) -> VoicePacket? {
        let bytes = [UInt8](value)
        var offsets: [Int] = []
        if (99...100).contains(bytes.count) { offsets.append(0) }
        if bytes.starts(with: [0xFA]), (99...100).contains(bytes.count - 1) { offsets.append(1) }
        if bytes.starts(with: [0xA1, 0xFA]), (99...100).contains(bytes.count - 2) { offsets.append(2) }
        for offset in offsets {
            guard bytes.count - offset >= 5 else { continue }
            let length = Int(bytes[offset + 4])
            let opusStart = offset + 5
            let opusEnd = opusStart + length
            guard length > 0, opusEnd <= bytes.count,
                  (bytes[opusStart] & 0xFC) == 0xB8,
                  bytes[opusEnd..<bytes.count].allSatisfy({ $0 == 0 }) else { continue }
            return VoicePacket(
                sequence: UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8),
                opus: Data(bytes[opusStart..<opusEnd])
            )
        }
        return nil
    }

    private static func normalizeInboundACL(_ blob: Data) -> Data? {
        if blob.first == 0x03 {
            let acl = Data(blob.dropFirst())
            if isStructurallyValidACL(acl) { return acl }
        }
        if blob.count >= 9, blob[8] == 0x03 {
            let acl = Data(blob.dropFirst(9))
            if isStructurallyValidACL(acl) { return acl }
        }
        if blob.first == 0x02 {
            let acl = Data(blob.dropFirst())
            if isCompleteDirectionlessATT(acl) { return acl }
        }
        if isCompleteDirectionlessATT(blob) { return blob }
        return nil
    }

    private static func isStructurallyValidACL(_ packet: Data) -> Bool {
        guard packet.count >= 4 else { return false }
        return Int(littleEndianUInt16(packet, at: 2)) == packet.count - 4
    }

    private static func isCompleteDirectionlessATT(_ packet: Data) -> Bool {
        guard packet.count >= 11, isStructurallyValidACL(packet) else { return false }
        let handleField = littleEndianUInt16(packet, at: 0)
        let boundary = UInt8((handleField >> 12) & 0x03)
        guard boundary == 0b00 || boundary == 0b10 || boundary == 0b11 else { return false }
        let aclLength = Int(littleEndianUInt16(packet, at: 2))
        let l2capLength = Int(littleEndianUInt16(packet, at: 4))
        guard littleEndianUInt16(packet, at: 6) == 0x0004,
              l2capLength == aclLength - 4,
              l2capLength >= 3 else { return false }
        return packet[8] == 0x1B || packet[8] == 0x1D
    }

    private static func isCompletePacketLoggerRecord(_ data: Data) -> Bool {
        guard data.count >= 13 else { return false }
        let bodyLength = Int(bigEndianUInt32(data, at: 0))
        return bodyLength >= 9 && bodyLength <= Int.max - 4 && bodyLength + 4 == data.count
    }

    private static func packetLoggerRecord(forInboundACL acl: Data) -> Data {
        let bodyLength = UInt32(9 + acl.count)
        var record = Data([
            UInt8(truncatingIfNeeded: bodyLength >> 24),
            UInt8(truncatingIfNeeded: bodyLength >> 16),
            UInt8(truncatingIfNeeded: bodyLength >> 8),
            UInt8(truncatingIfNeeded: bodyLength),
        ])
        record.append(contentsOf: repeatElement(0, count: 8))
        record.append(0x03)
        record.append(acl)
        return record
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
