import AppKit
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Shortcut capture monitor")
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

    @Test func capturesAStandaloneLeftControlWhenItIsReleasedWithoutAMainKey() throws {
        var captured: [CustomKeyboardShortcut] = []
        let monitor = ShortcutCaptureMonitor(
            onCapture: { captured.append($0) },
            dispatchCallback: { $0() }
        )
        let down = try #require(keyEvent(
            keyCode: CGKeyCode(StandaloneKeyboardModifier.leftControl.keyCode),
            flags: .maskControl
        ))
        let up = try #require(keyEvent(
            keyCode: CGKeyCode(StandaloneKeyboardModifier.leftControl.keyCode),
            flags: []
        ))

        #expect(monitor.handle(type: .flagsChanged, event: down))
        #expect(captured.isEmpty)
        #expect(monitor.handle(type: .flagsChanged, event: up))
        #expect(captured == [StandaloneKeyboardModifier.leftControl.shortcut])
    }

    @Test func modifierThenMainKeyCapturesTheCombinationInsteadOfTheModifier() throws {
        var captured: [CustomKeyboardShortcut] = []
        let monitor = ShortcutCaptureMonitor(
            onCapture: { captured.append($0) },
            dispatchCallback: { $0() }
        )
        let commandDown = try #require(keyEvent(keyCode: 55, flags: .maskCommand))
        let spaceDown = try #require(keyEvent(keyCode: 49, flags: .maskCommand))

        #expect(monitor.handle(type: .flagsChanged, event: commandDown))
        #expect(monitor.handle(type: .keyDown, event: spaceDown))
        #expect(captured == [KeyboardShortcutPreset.spotlight.shortcut])
    }

    @Test func missingAccessibilityPermissionFailsBeforeCreatingAnEventTap() {
        let monitor = ShortcutCaptureMonitor(
            onCapture: { _ in },
            accessibilityTrusted: { false },
            dispatchCallback: { $0() }
        )

        switch monitor.start() {
        case .success:
            Issue.record("Expected Accessibility permission failure")
        case let .failure(failure):
            #expect(failure == .accessibilityPermissionRequired)
        }
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
