import Darwin
import Foundation

public enum AppleRemotePacketLoggerRecord {
    private static let headerLength = 13
    private static let profileRequiredType: UInt8 = 0xFC
    private static let profileRequiredPayload = Data("Bluetooth Profile Required".utf8)

    public static func isValid(_ record: Data) -> Bool {
        guard record.count >= headerLength else { return false }
        let declaredLength = Int(record[0]) << 24
            | Int(record[1]) << 16
            | Int(record[2]) << 8
            | Int(record[3])
        return declaredLength >= 9
            && declaredLength <= Int.max - 4
            && declaredLength + 4 == record.count
    }

    public static func isProfileRequired(_ record: Data) -> Bool {
        let payload: Data.SubSequence
        if isValid(record), record[12] == profileRequiredType {
            payload = record.dropFirst(headerLength)
        } else {
            payload = record[record.startIndex..<record.endIndex]
        }
        if payload.elementsEqual(profileRequiredPayload) { return true }
        return payload.count == profileRequiredPayload.count + 1
            && payload.last == 0
            && payload.dropLast().elementsEqual(profileRequiredPayload)
    }
}

public struct AppleRemoteVoiceFrame: Equatable {
    public let connectionHandle: String
    public let attributeHandle: UInt16
    public let sequence: UInt16
    public let opusPayload: Data

    public init(connectionHandle: String, attributeHandle: UInt16, sequence: UInt16, opusPayload: Data) {
        self.connectionHandle = connectionHandle
        self.attributeHandle = attributeHandle
        self.sequence = sequence
        self.opusPayload = opusPayload
    }
}

public enum AppleRemoteVoiceFrameParser {
    private static let notificationSignature: [UInt8] = [0x04, 0x00, 0x1B]

    public static func parse(_ line: String) -> AppleRemoteVoiceFrame? {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard let directionIndex = fields.firstIndex(of: "RECV"), directionIndex >= 1,
              directionIndex + 1 < fields.count else { return nil }
        let handle = String(fields[directionIndex - 1])
        guard handle.hasPrefix("0x"), handle.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for field in fields[(directionIndex + 1)...] {
            guard field.count == 2, let byte = UInt8(field, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return parse(bytes: bytes, handle: handle)
    }

    public static func parse(bytes: [UInt8], handle: String) -> AppleRemoteVoiceFrame? {
        guard let signatureIndex = firstIndex(of: notificationSignature, in: bytes),
              signatureIndex + 5 <= bytes.count else { return nil }
        let attributeIndex = signatureIndex + 3
        let attributeHandle = UInt16(bytes[attributeIndex]) | (UInt16(bytes[attributeIndex + 1]) << 8)
        let valueIndex = attributeIndex + 2
        guard valueIndex + 5 <= bytes.count else { return nil }
        let sequence = UInt16(bytes[valueIndex + 2]) | (UInt16(bytes[valueIndex + 3]) << 8)
        let opusLength = Int(bytes[valueIndex + 4])
        let opusIndex = valueIndex + 5
        guard opusLength >= 2, opusIndex + opusLength <= bytes.count,
              bytes[opusIndex] == 0xB8 else { return nil }
        return AppleRemoteVoiceFrame(
            connectionHandle: handle,
            attributeHandle: attributeHandle,
            sequence: sequence,
            opusPayload: Data(bytes[opusIndex..<(opusIndex + opusLength)])
        )
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }
}

public final class AppleRemotePklgVoiceExtractor {
    private var residual = [UInt8]()
    private var assembling: [Int: (length: Int, buffer: [UInt8])] = [:]
    public private(set) var recordsScanned = 0

    public init() {}

    public func ingest(_ data: Data) -> [AppleRemoteVoiceFrame] {
        residual.append(contentsOf: data)
        var frames: [AppleRemoteVoiceFrame] = []
        var offset = 0
        while offset + 4 <= residual.count {
            let length = Int(residual[offset]) << 24 | Int(residual[offset + 1]) << 16
                | Int(residual[offset + 2]) << 8 | Int(residual[offset + 3])
            guard length >= 9 else { break }
            let recordEnd = offset + 4 + length
            guard recordEnd <= residual.count else { break }
            let type = residual[offset + 12]
            if type == 0x03 {
                let payload = Array(residual[(offset + 13)..<recordEnd])
                if let frame = handleACL(payload) { frames.append(frame) }
            }
            recordsScanned += 1
            offset = recordEnd
        }
        if offset > 0 { residual.removeFirst(offset) }
        return frames
    }

    private func handleACL(_ payload: [UInt8]) -> AppleRemoteVoiceFrame? {
        guard payload.count >= 4 else { return nil }
        let header = Int(payload[0]) | (Int(payload[1]) << 8)
        let handle = header & 0x0FFF
        let packetBoundary = (header >> 12) & 0x3
        let aclLength = Int(payload[2]) | (Int(payload[3]) << 8)
        let end = min(4 + aclLength, payload.count)
        guard end > 4 else { return nil }
        let aclData = Array(payload[4..<end])
        if packetBoundary == 0x2 || packetBoundary == 0x0 {
            guard aclData.count >= 2 else { assembling[handle] = nil; return nil }
            let l2capLength = Int(aclData[0]) | (Int(aclData[1]) << 8)
            assembling[handle] = (l2capLength, aclData)
        } else if packetBoundary == 0x1 {
            guard assembling[handle] != nil else { return nil }
            assembling[handle]!.buffer.append(contentsOf: aclData)
        } else { return nil }
        guard let state = assembling[handle], state.buffer.count >= 4 + state.length else { return nil }
        assembling[handle] = nil
        return AppleRemoteVoiceFrameParser.parse(
            bytes: state.buffer,
            handle: String(format: "0x%04X", handle)
        )
    }
}

public final class AppleRemoteOpusDecoder {
    private typealias Create = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Decode = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<Int16>?, Int32, Int32) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let decoder: OpaquePointer
    private let destroy: Destroy
    private let decode: Decode
    public let sampleRate: Int32

    public init?(sampleRate: Int32 = 16_000, libraryPath: String? = nil) {
        let candidates = [libraryPath, ProcessInfo.processInfo.environment["SAYALL_OPUS_LIBRARY"],
                          Self.bundleRelativePath(), "/opt/homebrew/opt/opus/lib/libopus.0.dylib",
                          "/usr/local/opt/opus/lib/libopus.0.dylib"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }),
              let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
              let createSymbol = dlsym(handle, "opus_decoder_create"),
              let destroySymbol = dlsym(handle, "opus_decoder_destroy"),
              let decodeSymbol = dlsym(handle, "opus_decode") else { return nil }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        let decode = unsafeBitCast(decodeSymbol, to: Decode.self)
        var error: Int32 = -1
        guard let decoder = create(sampleRate, 1, &error), error == 0 else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.decoder = decoder
        self.destroy = destroy
        self.decode = decode
        self.sampleRate = sampleRate
    }

    deinit {
        destroy(decoder)
        dlclose(handle)
    }

    public func decode(_ packet: Data) -> [Int16]? {
        guard !packet.isEmpty else { return nil }
        var pcm = [Int16](repeating: 0, count: 1920)
        let count = packet.withUnsafeBytes { raw in
            pcm.withUnsafeMutableBufferPointer { out in
                decode(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), out.baseAddress, Int32(out.count), 0)
            }
        }
        guard count > 0 else { return nil }
        pcm.removeLast(pcm.count - Int(count))
        return pcm
    }

    public func conceal(frameSamples: Int32 = 320) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: Int(frameSamples))
        let count = pcm.withUnsafeMutableBufferPointer { out in
            decode(decoder, nil, 0, out.baseAddress, frameSamples, 0)
        }
        guard count > 0 else { return [] }
        pcm.removeLast(pcm.count - Int(count))
        return pcm
    }

    private static func bundleRelativePath() -> String? {
        guard let executable = CommandLine.arguments.first else { return nil }
        return URL(fileURLWithPath: executable).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Frameworks/libopus.0.dylib").path
    }
}
