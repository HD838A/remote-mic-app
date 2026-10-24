import Foundation
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Keyboard event suppressor")
struct KeyboardEventSuppressorTests {
    @Test func expiredWindowStopsOrdinaryMissLogsWithoutSuppressingInput() throws {
        var now: TimeInterval = 10
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        let ordinary = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: true))
        #expect(!suppressor.handle(type: .keyDown, event: ordinary))
        #expect(logs.filter { $0.contains("HID FILTER miss") }.count == 1)
        logs.removeAll()
        now = 11
        for _ in 0..<100 {
            #expect(!suppressor.handle(type: .keyDown, event: ordinary))
        }
        #expect(logs.isEmpty)
    }

    @Test func matchingEdgesAreFilteredAndStopClearsDiagnosticState() throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { logs.append($0) })
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: false))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        #expect(suppressor.handle(type: .keyDown, event: down))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .up)
        #expect(suppressor.handle(type: .keyUp, event: up))
        suppressor.stop()
        logs.removeAll()
        #expect(!suppressor.handle(type: .keyDown, event: down))
        #expect(logs.isEmpty)
    }

    @Test func syntheticInputBypassesFilterWithoutConsumingPendingEdge() throws {
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { _ in })
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        #expect(!suppressor.handle(type: .keyDown, event: event))
        let realEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        #expect(suppressor.handle(type: .keyDown, event: realEvent))
    }

    @Test func activeArmWindowIncludesOnlyUnexpiredEntries() {
        let event: RemoteNativeEvent = .keyboard(keyCode: 42)

        #expect(
            KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 9.999
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 10
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 11
            )
        )
    }

    @Test func activeWindowIgnoresExpiredEntriesWhenAnotherEntryRemains() {
        let expired: RemoteNativeEvent = .keyboard(keyCode: 42)
        let active: RemoteNativeEvent = .systemKey(type: 2)

        #expect(
            KeyboardEventSuppressor.hasActiveArmedWindow(
                [
                    (event: expired, until: 10),
                    (event: active, until: 12),
                ],
                now: 11
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [
                    (event: expired, until: 10),
                    (event: active, until: 12),
                ],
                now: 12
            )
        )
    }
}
