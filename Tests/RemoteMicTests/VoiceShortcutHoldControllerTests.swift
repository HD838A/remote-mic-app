import AppKit
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Voice shortcut hold controller")
struct VoiceShortcutHoldControllerTests {
    @Test func syntheticModifiersUseFlagsChangedEvents() {
        #expect(KeyboardInjector.syntheticKeyEvent(code: 59, isDown: true, flags: .maskControl)?.type == .flagsChanged)
        #expect(KeyboardInjector.syntheticKeyEvent(code: 59, isDown: false, flags: [])?.type == .flagsChanged)
        #expect(KeyboardInjector.syntheticKeyEvent(code: 62, isDown: true, flags: .maskControl)?.type == .flagsChanged)
        #expect(KeyboardInjector.syntheticKeyEvent(code: 9, isDown: true, flags: [])?.type == .keyDown)
        #expect(KeyboardInjector.syntheticKeyEvent(code: 9, isDown: false, flags: [])?.type == .keyUp)
    }

    @Test func standaloneLeftControlStaysDownUntilRelease() {
        var events: [PostedKeyState] = []
        let controller = VoiceShortcutHoldController { code, isDown, flags in
            events.append(PostedKeyState(code: code, isDown: isDown, flags: flags))
            return true
        }

        #expect(controller.press(StandaloneKeyboardModifier.leftControl.shortcut))
        #expect(controller.press(StandaloneKeyboardModifier.leftControl.shortcut))
        #expect(controller.heldShortcut == StandaloneKeyboardModifier.leftControl.shortcut)
        #expect(events == [
            PostedKeyState(code: 59, isDown: true, flags: .maskControl),
        ])

        #expect(controller.release())
        #expect(controller.heldShortcut == nil)
        #expect(events == [
            PostedKeyState(code: 59, isDown: true, flags: .maskControl),
            PostedKeyState(code: 59, isDown: false, flags: []),
        ])
    }

    @Test func combinationPressesModifiersBeforeMainKeyAndReleasesInReverse() {
        var events: [PostedKeyState] = []
        let controller = VoiceShortcutHoldController { code, isDown, flags in
            events.append(PostedKeyState(code: code, isDown: isDown, flags: flags))
            return true
        }
        let shortcut = CustomKeyboardShortcut(
            keyCode: 9,
            modifierFlags: [.control, .shift, .command],
            keyLabel: "V"
        )

        #expect(controller.press(shortcut))
        #expect(controller.release())
        #expect(events == [
            PostedKeyState(code: 59, isDown: true, flags: .maskControl),
            PostedKeyState(code: 56, isDown: true, flags: [.maskControl, .maskShift]),
            PostedKeyState(
                code: 55,
                isDown: true,
                flags: [.maskControl, .maskShift, .maskCommand]
            ),
            PostedKeyState(
                code: 9,
                isDown: true,
                flags: [.maskControl, .maskShift, .maskCommand]
            ),
            PostedKeyState(
                code: 9,
                isDown: false,
                flags: [.maskControl, .maskShift, .maskCommand]
            ),
            PostedKeyState(code: 55, isDown: false, flags: [.maskControl, .maskShift]),
            PostedKeyState(code: 56, isDown: false, flags: .maskControl),
            PostedKeyState(code: 59, isDown: false, flags: []),
        ])
    }

    @Test func partialPressFailureReleasesEveryModifierAlreadyPressed() {
        var events: [PostedKeyState] = []
        let controller = VoiceShortcutHoldController { code, isDown, flags in
            events.append(PostedKeyState(code: code, isDown: isDown, flags: flags))
            return !(code == 55 && isDown)
        }
        let shortcut = CustomKeyboardShortcut(
            keyCode: 9,
            modifierFlags: [.control, .command],
            keyLabel: "V"
        )

        #expect(!controller.press(shortcut))
        #expect(controller.heldShortcut == nil)
        #expect(events == [
            PostedKeyState(code: 59, isDown: true, flags: .maskControl),
            PostedKeyState(code: 55, isDown: true, flags: [.maskControl, .maskCommand]),
            PostedKeyState(code: 59, isDown: false, flags: []),
        ])
    }

    @Test func conflictWarningsDistinguishDangerousSystemAndTypingCases() {
        #expect(VoiceShortcutConflictPolicy.warning(
            for: StandaloneKeyboardModifier.leftControl.shortcut
        ) == nil)
        #expect(VoiceShortcutConflictPolicy.warning(
            for: KeyboardShortcutPreset.quitApplication.shortcut
        ) == .dangerousSystemAction)
        #expect(VoiceShortcutConflictPolicy.warning(
            for: KeyboardShortcutPreset.spotlight.shortcut
        ) == .knownSystemShortcut)
        #expect(VoiceShortcutConflictPolicy.warning(
            for: KeyboardShortcutPreset.copy.shortcut
        ) == .applicationCommand)
        #expect(VoiceShortcutConflictPolicy.warning(
            for: CustomKeyboardShortcut(keyCode: 0, modifierFlags: [], keyLabel: "A")
        ) == .unmodifiedKey)
    }

    @Test func hidVoiceEdgesReleaseOnNormalKeyUpAndDisconnect() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let profileID = UUID()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true }
        )
        var edges: [RemoteEventEdge] = []
        monitor.onVoiceButtonEdge = { edges.append($0) }
        monitor.connectSimulatedDevice(fingerprint: "voice", profileID: profileID)

        let press = Data([0x3E, 0, 0, 0, 0, 0])
        let release = Data([0, 0, 0, 0, 0, 0])
        monitor.handleSimulatedReport(reportID: 1, data: press)
        monitor.handleSimulatedReport(reportID: 1, data: press)
        monitor.handleSimulatedReport(reportID: 1, data: release)
        #expect(edges == [.down, .up])

        monitor.handleSimulatedReport(reportID: 1, data: press)
        monitor.disconnectSimulatedDevice()
        #expect(edges == [.down, .up, .down, .up])
    }
}

private struct PostedKeyState: Equatable {
    let code: CGKeyCode
    let isDown: Bool
    let flags: CGEventFlags
}
