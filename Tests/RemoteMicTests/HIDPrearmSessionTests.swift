import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("HID prearm session")
struct HIDPrearmSessionTests {
    @Test func staleSnapshotFromASharedMonitorCannotPrearmAfterStop() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        // 生产结构：多个监视器共享同一个 suppressor（`ownsEventSuppressor: false`），
        // 监视器 `stop()` 不会关闭它，只结束自己的提前登记会话。
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: 0)
        let down = try nativeEvent(native, down: true)

        let session = HIDPrearmSession<Int>()
        session.begin(0)
        let inFlight = try #require(session.current())
        session.end()

        var prearmed = false
        let accepted = session.perform(inFlight) { _ in
            prearmed = true
            suppressor.prearm(nativeEvents: [native])
        }

        #expect(!accepted)
        #expect(!prearmed)
        // 共享 suppressor 仍在运行，但陈旧快照没写进待匹配记录，
        // 用户真实键盘的音量键必须照常放行。
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test func activeSnapshotPrearmsAndSuppressesTheNativeDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: 1)
        let down = try nativeEvent(native, down: true)

        let session = HIDPrearmSession<Int>()
        session.begin(0)
        let ticket = try #require(session.current())
        let accepted = session.perform(ticket) { _ in
            suppressor.prearm(nativeEvents: [native])
        }

        #expect(accepted)
        #expect(suppressor.handle(type: down.type, event: down))
    }

    @Test func restartingTheSessionInvalidatesThePreviousSnapshot() throws {
        let session = HIDPrearmSession<Int>()
        session.begin(0)
        let previous = try #require(session.current())
        session.end()
        session.begin(1)

        var written = false
        #expect(!session.perform(previous) { _ in written = true })
        #expect(!written)
    }

    @Test func snapshotIsUnavailableAndUpdatesAreIgnoredAfterStop() throws {
        let session = HIDPrearmSession<Int>()
        session.begin(0)
        #expect(session.current() != nil)
        session.end()
        #expect(session.current() == nil)

        // 停止后主线程仍然会刷新快照，但不能让会话重新变成可用。
        session.update(1)
        #expect(session.current() == nil)
    }

    private func nativeEvent(_ native: RemoteNativeEvent, down: Bool) throws -> CGEvent {
        switch native {
        case let .keyboard(keyCode):
            return try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
        case let .systemKey(type):
            let data = Int((type << 16) | ((down ? 0xA : 0xB) << 8))
            let event = try #require(NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1
            ))
            return try #require(event.cgEvent)
        }
    }
}
