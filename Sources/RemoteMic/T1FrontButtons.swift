import Foundation

/// T1's keyboard, consumer controls and system controls are independent reports.
/// Directions and Return use the same keyboard report as the back face.
enum T1FrontButtons {
    static let usageToButton: [UInt64: RemoteButton] = [
        0x0000_0001_0000_0081: .power,
        0x0000_0007_0000_0028: .ok,
        0x0000_0007_0000_004F: .right,
        0x0000_0007_0000_0050: .left,
        0x0000_0007_0000_0051: .down,
        0x0000_0007_0000_0052: .up,
        0x0000_0007_0000_0065: .menu,
        0x0000_000C_0000_0224: .back,
        0x0000_000C_0000_0223: .home,
        0x0000_000C_0000_00E2: .mute,
        0x0000_000C_0000_00E9: .volumeUp,
        0x0000_000C_0000_00EA: .volumeDown,
    ]

    static let configurable = Set(usageToButton.values)
    static let nativeMappings = usageToButton.keys.sorted().map {
        HIDUsageMapping(source: $0, destination: 0)
    }

    static func buttons(reportID: UInt32, bytes: [UInt8]) -> Set<RemoteButton>? {
        switch reportID {
        case 1:
            guard let report = payload(reportID: reportID, bytes: bytes, size: 8) else {
                return nil
            }
            let slots = report.dropFirst(2)
            // HID rollover is an invalid snapshot, not a release of the menu key.
            guard !slots.contains(where: { (1...3).contains($0) }) else { return nil }
            return Set(slots.compactMap { usageToButton[0x0000_0007_0000_0000 | UInt64($0)] })
        case 2:
            guard let report = payload(reportID: reportID, bytes: bytes, size: 2) else {
                return nil
            }
            let usage = UInt64(report[report.startIndex]) | UInt64(report[report.startIndex + 1]) << 8
            return usageToButton[0x0000_000C_0000_0000 | usage].map { [$0] } ?? []
        case 3:
            guard let report = payload(reportID: reportID, bytes: bytes, size: 1),
                  let control = report.first else {
                return nil
            }
            return (control & 1) != 0 ? [.power] : []
        default:
            return nil
        }
    }

    private static func payload(reportID: UInt32, bytes: [UInt8], size: Int) -> ArraySlice<UInt8>? {
        if bytes.count == size { return bytes[...] }
        if bytes.count == size + 1, bytes.first.map(UInt32.init) == reportID {
            return bytes.dropFirst()
        }
        return nil
    }
}

struct T1FrontButtonEdge: Equatable {
    let button: RemoteButton
    let phase: RemoteButtonPhase
}

struct T1FrontButtonTracker {
    private var pressedByReport: [UInt32: Set<RemoteButton>] = [:]

    mutating func observe(reportID: UInt32, bytes: [UInt8]) -> [T1FrontButtonEdge] {
        guard let pressed = T1FrontButtons.buttons(reportID: reportID, bytes: bytes) else {
            return []
        }
        let previous = pressedByReport[reportID, default: []]
        pressedByReport[reportID] = pressed
        return previous.subtracting(pressed).sorted { $0.rawValue < $1.rawValue }
            .map { T1FrontButtonEdge(button: $0, phase: .release) }
            + pressed.subtracting(previous).sorted { $0.rawValue < $1.rawValue }
            .map { T1FrontButtonEdge(button: $0, phase: .press) }
    }
}
