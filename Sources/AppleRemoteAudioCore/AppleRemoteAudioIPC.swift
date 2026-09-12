import Foundation

public enum AppleRemoteAudioIPC {
    public enum Kind: UInt8 {
        case hello = 1
        case start = 2
        case stop = 3
        case status = 4
        case pcm = 5
    }

    public struct Frame: Equatable {
        public let kind: Kind
        public let payload: Data
        public init(kind: Kind, payload: Data = Data()) {
            self.kind = kind
            self.payload = payload
        }
    }

    public static func encode(_ frame: Frame) -> Data {
        var body = Data([frame.kind.rawValue])
        body.append(frame.payload)
        var length = UInt32(body.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(body)
        return result
    }

    public static func pcmFrame(samples: [Int16]) -> Data {
        var payload = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        }
        return encode(Frame(kind: .pcm, payload: payload))
    }

    public static func decodeFrames(buffer: inout Data) -> [Frame] {
        var frames: [Frame] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 24
                | Int(buffer[buffer.index(start, offsetBy: 1)]) << 16
                | Int(buffer[buffer.index(start, offsetBy: 2)]) << 8
                | Int(buffer[buffer.index(start, offsetBy: 3)])
            guard length >= 1, buffer.count >= 4 + length else { break }
            let kindIndex = buffer.index(start, offsetBy: 4)
            let kind = Kind(rawValue: buffer[kindIndex])
            if let kind {
                let payloadStart = buffer.index(start, offsetBy: 5)
                let frameEnd = buffer.index(start, offsetBy: 4 + length)
                frames.append(Frame(kind: kind, payload: Data(buffer[payloadStart..<frameEnd])))
            }
            buffer.removeFirst(4 + length)
        }
        return frames
    }

    public static func samples(from frame: Frame) -> [Int16] {
        guard frame.kind == .pcm, frame.payload.count.isMultiple(of: 2) else { return [] }
        return stride(from: 0, to: frame.payload.count, by: 2).map {
            Int16(bitPattern: UInt16(frame.payload[$0]) | (UInt16(frame.payload[$0 + 1]) << 8))
        }
    }
}
