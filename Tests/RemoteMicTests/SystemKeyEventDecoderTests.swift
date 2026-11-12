import AppKit
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("System key event decoding")
struct SystemKeyEventDecoderTests {
    @Test(arguments: [0, 1, 4, 16], [0xA, 0xB])
    func decodesANeutralCopyOnTheTapThread(keyType: Int, state: Int) throws {
        let data1 = (keyType << 16) | (state << 8)
        let original = try systemEvent(subtype: 8, data1: data1)
        let originalFlags = original.flags
        let originalTimestamp = original.timestamp
        let completed = EventTapRunLoop.shared.performAndWait {
            #expect(!Thread.isMainThread)
            let decoded = SystemKeyEventDecoder.data1(from: original) { snapshot in
                #expect(snapshot !== original)
                #expect(snapshot.type.rawValue == NSEvent.EventType.applicationDefined.rawValue)
                return NSEvent(cgEvent: snapshot)
            }
            #expect(decoded == data1)
        }
        #expect(completed)
        #expect(original.type.rawValue == NSEvent.EventType.systemDefined.rawValue)
        #expect(original.flags == originalFlags)
        #expect(original.timestamp == originalTimestamp)
    }

    @Test(arguments: [Int16(0), 1, 7, 10, 100])
    func ignoresOtherSystemMessages(subtype: Int16) throws {
        let event = try systemEvent(subtype: subtype, data1: 0xA00)
        #expect(SystemKeyEventDecoder.data1(from: event) == nil)
    }

    @Test func ignoresKeyboardInputWithoutConvertingIt() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: false))
        let decoded = SystemKeyEventDecoder.data1(from: event) { _ in
            Issue.record("Keyboard input must bypass system key conversion")
            return nil
        }
        #expect(decoded == nil)
    }

    @Test func failedConversionReturnsNoPayload() throws {
        let event = try systemEvent(subtype: 8, data1: 0xA00)
        #expect(SystemKeyEventDecoder.data1(from: event, convert: { _ in nil }) == nil)
    }

    private func systemEvent(subtype: Int16, data1: Int) throws -> CGEvent {
        let event = try #require(NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: .capsLock,
            timestamp: 1, windowNumber: 0, context: nil,
            subtype: subtype, data1: data1, data2: -1
        ))
        return try #require(event.cgEvent)
    }
}
