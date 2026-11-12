import AppKit
import CoreGraphics

enum SystemKeyEventDecoder {
    static func data1(
        from event: CGEvent,
        convert: (CGEvent) -> NSEvent? = NSEvent.init(cgEvent:)
    ) -> Int? {
        guard event.type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let snapshot = event.copy()
        else { return nil }

        // Both event types carry the same compound payload. Decode a neutral copy
        // so AppKit cannot process Caps Lock transitions on the event-tap thread.
        guard let applicationDefined = CGEventType(
            rawValue: UInt32(NSEvent.EventType.applicationDefined.rawValue)
        ) else { return nil }
        snapshot.type = applicationDefined
        guard let decoded = convert(snapshot), decoded.subtype.rawValue == 8 else {
            return nil
        }
        return decoded.data1
    }
}
