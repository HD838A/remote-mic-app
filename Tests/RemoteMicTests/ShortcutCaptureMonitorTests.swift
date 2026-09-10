import AppKit
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Shortcut capture monitor")
@MainActor
struct ShortcutCaptureMonitorTests {
    @Test func capturesAndSuppressesAReservedCommandShortcutOnce() throws {
        var captured: [CustomKeyboardShortcut] = []
        let monitor = ShortcutCaptureMonitor(
            onCapture: { captured.append($0) },
            dispatchCallback: { $0() }
        )
        let commandSpace = try #require(keyEvent(keyCode: 49, flags: .maskCommand))

        #expect(monitor.handle(type: .keyDown, event: commandSpace))
        #expect(captured == [
            CustomKeyboardShortcut(
                keyCode: 49,
                modifierFlags: .command,
                keyLabel: "Space"
            ),
        ])

        let secondEvent = try #require(keyEvent(keyCode: 8, flags: .maskCommand))
        #expect(monitor.handle(type: .keyDown, event: secondEvent))
        #expect(captured.count == 1)
    }

    @Test func ignoresAutoRepeatUntilARealKeyDownArrives() throws {
        var captured: [CustomKeyboardShortcut] = []
        let monitor = ShortcutCaptureMonitor(
            onCapture: { captured.append($0) },
            dispatchCallback: { $0() }
        )
        let repeated = try #require(keyEvent(keyCode: 49, flags: .maskCommand))
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        #expect(monitor.handle(type: .keyDown, event: repeated))
        #expect(captured.isEmpty)

        let commandSpace = try #require(keyEvent(keyCode: 49, flags: .maskCommand))
        #expect(monitor.handle(type: .keyDown, event: commandSpace))
        #expect(captured.count == 1)
    }

    @Test func syntheticEventsAreNotCapturedOrSuppressed() throws {
        var captureCount = 0
        let monitor = ShortcutCaptureMonitor(
            onCapture: { _ in captureCount += 1 },
            dispatchCallback: { $0() }
        )
        let synthetic = try #require(keyEvent(keyCode: 49, flags: .maskCommand))
        synthetic.setIntegerValueField(
            .eventSourceUserData,
            value: KeyboardInjector.syntheticEventMarker
        )

        #expect(!monitor.handle(type: .keyDown, event: synthetic))
        #expect(captureCount == 0)
    }

    @Test func missingAccessibilityPermissionStillAllowsForegroundCommandL() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var captured: [CustomKeyboardShortcut] = []
        var removed = false
        let monitor = ShortcutCaptureMonitor(
            onCapture: { captured.append($0) },
            accessibilityTrusted: { false },
            dispatchCallback: { $0() },
            installLocalMonitor: { handler = $0; return NSObject() },
            removeLocalMonitor: { _ in removed = true }
        )
        switch monitor.start() {
        case .success: break
        case .failure: Issue.record("Foreground recording must not require global capture permission")
        }
        let commandL = try #require(keyEvent(keyCode: 37, flags: .maskCommand))
        let event = try #require(NSEvent(cgEvent: commandL))
        let receive = try #require(handler)
        #expect(receive(event) == nil)
        #expect(captured.first?.keyCode == 37)
        #expect(captured.first?.modifierFlags == .command)
        monitor.stop()
        #expect(removed)
    }

    @Test func unavailableGlobalTapFallsBackAndCancellationRemovesLocalMonitor() throws {
        var installed = false
        var removed = false
        let monitor = ShortcutCaptureMonitor(
            onCapture: { _ in Issue.record("Cancelled recording must not capture") },
            accessibilityTrusted: { true },
            createEventTap: { _, _ in nil },
            installLocalMonitor: { _ in installed = true; return NSObject() },
            removeLocalMonitor: { _ in removed = true }
        )
        if case .failure = monitor.start() { Issue.record("Expected foreground fallback") }
        #expect(installed)
        monitor.stop()
        #expect(removed)
    }

    @Test func failureIsReportedWhenNeitherCaptureBackendCanStart() {
        let monitor = ShortcutCaptureMonitor(
            onCapture: { _ in },
            accessibilityTrusted: { false },
            installLocalMonitor: { _ in nil }
        )
        if case let .failure(failure) = monitor.start() {
            #expect(failure == .accessibilityPermissionRequired)
        } else {
            Issue.record("Expected unavailable capture to fail")
        }
    }

    @Test func foregroundCapturePassesSyntheticEventsAndDiscardsQueuedCaptureAfterCancel() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var pending: (() -> Void)?
        var captures = 0
        let monitor = ShortcutCaptureMonitor(
            onCapture: { _ in captures += 1 },
            accessibilityTrusted: { false },
            dispatchCallback: { pending = $0 },
            installLocalMonitor: { handler = $0; return NSObject() },
            removeLocalMonitor: { _ in }
        )
        if case .failure = monitor.start() { Issue.record("Expected foreground fallback") }
        let receive = try #require(handler)
        let synthetic = try #require(keyEvent(keyCode: 37, flags: .maskCommand))
        synthetic.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        let syntheticEvent = try #require(NSEvent(cgEvent: synthetic))
        #expect(receive(syntheticEvent) === syntheticEvent)
        #expect(pending == nil)
        let key = try #require(keyEvent(keyCode: 37, flags: .maskCommand))
        let event = try #require(NSEvent(cgEvent: key))
        #expect(receive(event) == nil)
        let deliver = try #require(pending)
        monitor.stop()
        deliver()
        #expect(captures == 0)
        #expect(receive(event) === event)
    }

    private func keyEvent(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> CGEvent? {
        let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: keyCode,
            keyDown: true
        )
        event?.flags = flags
        return event
    }
}
