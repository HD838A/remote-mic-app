import Foundation

struct G9N9NHCIIdentityWindow {
    private(set) var generation = 0
    private(set) var hasIdentity = false
    mutating func begin() -> Int {
        generation += 1
        hasIdentity = true
        return generation
    }
    mutating func invalidate() {
        generation += 1
        hasIdentity = false
    }
    func accepts(_ attempt: Int) -> Bool { hasIdentity && generation == attempt }
}

/// In-memory ATT filter. A BLE connection handle becomes eligible only after a
/// fresh DIS serial read matches the already admitted G9N9N connection. Neither
/// the serial nor other devices' packets leave this parser or enter diagnostics.
struct G9N9NHCIParser {
    struct LearnedKey: Equatable {
        let usage: UInt16
        let control: ChromecastRemoteControl
    }
    struct Edge: Equatable {
        let control: ChromecastRemoteControl
        let down: Bool
        var cancelled = false
    }
    private struct Fragment {
        let size: Int
        var bytes: Data
    }
    private var expectedSerial = Data()
    private var fragments: [UInt16: Fragment] = [:]
    private var connection: UInt16?
    private var pressed: ChromecastRemoteControl?
    private(set) var identityConflict = false
    private(set) var isBound = false
    private(set) var packetsSeen = 0
    private(set) var observedNotifications: [UInt16: Int] = [:]
    private(set) var observedConsumerUsages = Set<UInt16>()
    private(set) var observedConsumerReportLengths = Set<Int>()
    private(set) var leftReportCount = 0
    private(set) var rightReportCount = 0
    private(set) var releaseReportCount = 0
    private(set) var oneByteReportCount = 0
    private(set) var learnedMappings: [UInt16: ChromecastRemoteControl] = [:]
    private var learning: ChromecastRemoteControl?
    private var learningCandidate: UInt16?
    private var learningRejected = false
    private var learnedKey: LearnedKey?
    private(set) var learningReports = 0

    mutating func setLearnedMappings(_ mappings: [UInt16: ChromecastRemoteControl]) {
        guard mappings.count <= 32 else { return }
        learnedMappings.removeAll()
        for usage in mappings.keys.sorted() where usage > 0 && usage <= 0x029C {
            if let control = mappings[usage], !learnedMappings.values.contains(control) {
                learnedMappings[usage] = control
            }
        }
    }

    mutating func beginLearning(_ control: ChromecastRemoteControl) -> Bool {
        guard isBound, !identityConflict else { return false }
        learning = control
        learningCandidate = nil
        learningRejected = false
        learnedKey = nil
        pressed = nil
        learningReports = 0
        return true
    }

    mutating func cancelLearning() {
        learning = nil
        learningCandidate = nil
        learningRejected = false
        learnedKey = nil
        pressed = nil
    }

    mutating func takeLearnedKey() -> LearnedKey? {
        defer { learnedKey = nil }
        return learnedKey
    }

    mutating func identify(serial: Data) {
        reset()
        if (8...64).contains(serial.count), serial.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            expectedSerial = serial
        }
    }

    mutating func reset() {
        expectedSerial.removeAll()
        fragments.removeAll()
        connection = nil
        pressed = nil
        isBound = false
        identityConflict = false
        packetsSeen = 0
        observedNotifications.removeAll()
        resetConsumerObservations()
        cancelLearning()
        learningReports = 0
    }

    mutating func consume(_ blob: Data) -> [Edge] {
        guard !expectedSerial.isEmpty, !identityConflict, blob.count <= 65_552 else { return [] }
        packetsSeen = min(1_000_000_000, packetsSeen + 1)
        let acl: Data
        if blob.count >= 13, Self.be32(blob, 0) == blob.count - 4 {
            if blob[12] == 1, blob.count >= 18, blob[13] == 5 {
                // HCI Disconnection Complete invalidates an old handle before it
                // can be recycled for an unrelated peripheral.
                let handle = Self.le16(blob, 16) & 0x0FFF
                if handle == connection { return unbind() }
                return []
            }
            guard blob[12] == 3 else { return [] }
            acl = Data(blob.dropFirst(13))
        } else if blob.first == 3, Self.validACL(Data(blob.dropFirst())) {
            acl = Data(blob.dropFirst())
        } else if blob.count >= 9, blob[8] == 3, Self.validACL(Data(blob.dropFirst(9))) {
            acl = Data(blob.dropFirst(9))
        } else if blob.first == 2, Self.completeATT(Data(blob.dropFirst())) {
            acl = Data(blob.dropFirst())
        } else if Self.completeATT(blob) {
            acl = blob
        } else { return [] }
        guard Self.validACL(acl) else { return [] }
        let header = Self.le16(acl, 0)
        let handle = header & 0x0FFF
        let boundary = (header >> 12) & 3
        let payload = Data(acl.dropFirst(4))
        let att: Data
        if boundary != 1 {
            guard payload.count >= 4, Self.le16(payload, 2) == 4 else { return [] }
            let size = Int(Self.le16(payload, 0))
            guard size > 0, size <= 512, payload.count - 4 <= size else { return [] }
            let bytes = Data(payload.dropFirst(4))
            if bytes.count < size {
                if fragments[handle] == nil, fragments.count >= 8 { return [] }
                fragments[handle] = Fragment(size: size, bytes: bytes)
                return []
            }
            fragments[handle] = nil
            att = bytes
        } else {
            guard var fragment = fragments.removeValue(forKey: handle),
                  fragment.bytes.count + payload.count <= fragment.size else { return [] }
            fragment.bytes.append(payload)
            if fragment.bytes.count < fragment.size {
                fragments[handle] = fragment
                return []
            }
            att = fragment.bytes
        }
        if att.first == 0x0B, att.dropFirst().elementsEqual(expectedSerial) {
            if let connection, connection != handle {
                let release = unbind()
                identityConflict = true
                return release
            }
            connection = handle
            isBound = true
            return []
        }
        guard connection == handle, isBound, att.count >= 3,
              att[0] == 0x1B || att[0] == 0x1D else { return [] }
        let attribute = Self.le16(att, 1)
        if observedNotifications.count < 16, observedNotifications[attribute] == nil {
            observedNotifications[attribute] = att.count - 3
        }
        guard attribute == 0x002B else { return [] }
        let report = Data(att.dropFirst(3))
        if observedConsumerReportLengths.count < 16 {
            observedConsumerReportLengths.insert(report.count)
        }
        if report.count == 1 { oneByteReportCount = min(1_000_000_000, oneByteReportCount + 1) }
        // A one-byte variant remains unsupported for actions, but its candidate
        // Consumer value helps distinguish that format from no radio report.
        if observedConsumerUsages.count < 32 {
            if report.count == 1 { observedConsumerUsages.insert(UInt16(report[0])) }
            else if report.count == 2 { observedConsumerUsages.insert(Self.le16(report, 0)) }
        }
        // Legacy hid_mouse ATT carries the actual 16-bit Consumer usage, not
        // the report-array index exposed by macOS's virtual HID collection.
        guard report.count == 2 else { return [] }
        let usage = Self.le16(report, 0)
        switch usage {
        case 0: releaseReportCount = min(1_000_000_000, releaseReportCount + 1)
        case 0x0044: leftReportCount = min(1_000_000_000, leftReportCount + 1)
        case 0x0045: rightReportCount = min(1_000_000_000, rightReportCount + 1)
        default: break
        }
        if let learning {
            learningReports = min(1_000_000, learningReports + 1)
            guard !learningRejected else { return [] }
            if usage > 0, usage <= 0x029C {
                // One Consumer array slot; reject a second different key rather
                // than learning an ambiguous multi-button gesture.
                if learningCandidate == nil || learningCandidate == usage {
                    learningCandidate = usage
                } else { learningRejected = true; learningCandidate = nil }
            } else if usage == 0, let candidate = learningCandidate {
                learnedMappings = learnedMappings.filter { $0.value != learning }
                learnedMappings[candidate] = learning
                learnedKey = LearnedKey(usage: candidate, control: learning)
                self.learning = nil
                learningCandidate = nil
            }
            return []
        }
        let next = learnedMappings[usage] ?? Self.consumerControl(usage)
        guard usage == 0 || next != nil else { return [] }
        guard next != pressed else { return [] }
        var edges: [Edge] = []
        if let pressed { edges.append(.init(control: pressed, down: false)) }
        pressed = next
        if let next { edges.append(.init(control: next, down: true)) }
        return edges
    }

    private mutating func unbind() -> [Edge] {
        let edges = pressed.map { [Edge(control: $0, down: false, cancelled: true)] } ?? []
        connection = nil
        pressed = nil
        isBound = false
        fragments.removeAll()
        observedNotifications.removeAll()
        resetConsumerObservations()
        cancelLearning()
        return edges
    }

    private mutating func resetConsumerObservations() {
        observedConsumerUsages.removeAll()
        observedConsumerReportLengths.removeAll()
        leftReportCount = 0
        rightReportCount = 0
        releaseReportCount = 0
        oneByteReportCount = 0
    }

    static func packetCaptureUnixTime(_ blob: Data) -> TimeInterval? {
        guard blob.count >= 13, be32(blob, 0) == blob.count - 4 else { return nil }
        let seconds = be32(blob, 4), microseconds = be32(blob, 8)
        guard seconds >= 1_000_000_000, microseconds < 1_000_000 else { return nil }
        return Double(seconds) + Double(microseconds) / 1_000_000
    }

    static func control(_ value: UInt8) -> ChromecastRemoteControl? {
        switch value {
        case 1: .power
        case 3: .up
        case 4: .down
        case 5: .left
        case 6: .right
        case 7: .select
        case 8: .mute
        case 10: .home
        case 11: .back
        case 12: .volumeUp
        case 13: .volumeDown
        case 14: .youtube
        case 15: .netflix
        case 17: .input
        default: nil
        }
    }

    static func consumerControl(_ usage: UInt16) -> ChromecastRemoteControl? {
        switch usage {
        case 0x019E: .power
        case 0x0042: .up
        case 0x0043: .down
        case 0x0044: .left
        case 0x0045: .right
        case 0x0041: .select
        case 0x00E2: .mute
        case 0x0223: .home
        case 0x0224: .back
        case 0x00E9: .volumeUp
        case 0x00EA: .volumeDown
        case 0x0077: .youtube
        case 0x0078: .netflix
        // Original Google table uses 0x0089; the verified Jieli G9N9N emits
        // 0x0189. Both are explicit Consumer usages, not a byte truncation.
        case 0x0089, 0x0189: .input
        default: nil
        }
    }

    private static func validACL(_ data: Data) -> Bool {
        data.count >= 4 && Int(le16(data, 2)) == data.count - 4
    }
    private static func completeATT(_ data: Data) -> Bool {
        guard data.count >= 9, validACL(data), ((le16(data, 0) >> 12) & 3) != 1,
              le16(data, 6) == 4, Int(le16(data, 4)) == data.count - 8 else { return false }
        return [UInt8(0x0B), 0x1B, 0x1D].contains(data[8])
    }
    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func be32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }
}
