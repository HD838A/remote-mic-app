import Foundation

struct G9N9NHIDUsage: Hashable {
    let page: UInt32
    let usage: UInt32
    var key: String { "\(page):\(usage)" }
}

/// Jieli's verified 214-byte descriptor: report 1 is an eight-byte boot keyboard,
/// report 2 is a 16-bit consumer array followed by a one-byte button array.
/// Mouse and vendor reports are separate and must not clear held keyboard keys.
enum G9N9NHIDReport {
    static func effectiveReportID(reported: UInt32, data: Data) -> UInt32 {
        // Some HID transports provide the ID only as the leading report byte.
        guard reported == 0 else { return reported }
        if data.count == 9, data.first == 1 { return 1 }
        if data.count == 4, data.first == 2 { return 2 }
        return reported
    }

    static func learningCandidate(in usages: Set<G9N9NHIDUsage>) -> G9N9NHIDUsage? {
        let ordinary = usages.filter { $0.page != 7 || !(0xE0...0xE7).contains($0.usage) }
        return (ordinary.isEmpty ? Array(usages) : Array(ordinary)).sorted {
            $0.page == $1.page ? $0.usage < $1.usage : $0.page < $1.page
        }.first
    }

    static func usages(reportID: UInt32, data: Data) -> Set<G9N9NHIDUsage>? {
        let reportID = effectiveReportID(reported: reportID, data: data)
        let length: Int
        switch reportID {
        case 1: length = 8
        case 2: length = 3
        default: return nil
        }
        let bytes: [UInt8]
        if data.count == length + 1, data.first == UInt8(reportID) {
            bytes = Array(data.dropFirst())
        } else if data.count == length {
            bytes = Array(data)
        } else { return nil }
        var result = Set<G9N9NHIDUsage>()
        if reportID == 1 {
            for bit in 0..<8 where bytes[0] & (1 << bit) != 0 {
                result.insert(.init(page: 7, usage: UInt32(0xE0 + bit)))
            }
            for key in bytes.dropFirst(2) where key != 0 {
                // 1–3 are keyboard error/rollover codes, not real keys.
                guard key > 3, key <= 0xEB else { return nil }
                result.insert(.init(page: 7, usage: UInt32(key)))
            }
        } else {
            let consumer = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            guard consumer <= 0x29C, bytes[2] <= 10 else { return nil }
            if consumer != 0 { result.insert(.init(page: 12, usage: consumer)) }
            if bytes[2] != 0 { result.insert(.init(page: 9, usage: UInt32(bytes[2]))) }
        }
        return result
    }
}

struct G9N9NHIDReportState {
    struct Snapshot {
        let pressed: Set<G9N9NHIDUsage>
        let newlyPressed: Set<G9N9NHIDUsage>
    }
    private var reports: [UInt32: Set<G9N9NHIDUsage>] = [:]

    mutating func consume(reportID: UInt32, data: Data) -> Snapshot? {
        let reportID = G9N9NHIDReport.effectiveReportID(reported: reportID, data: data)
        guard let usages = G9N9NHIDReport.usages(reportID: reportID, data: data) else { return nil }
        let previous = reports[reportID] ?? []
        reports[reportID] = usages
        return Snapshot(pressed: reports.values.reduce(into: []) { $0.formUnion($1) },
                        newlyPressed: usages.subtracting(previous))
    }

    mutating func reset() { reports.removeAll() }
}
