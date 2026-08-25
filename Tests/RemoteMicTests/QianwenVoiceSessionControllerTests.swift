import Testing
@testable import RemoteMic

@Suite("Qianwen voice session")
struct QianwenVoiceSessionControllerTests {
    @Test func shortTapFocusesWhileLongPressKeepsVoice() {
        let threshold = Int(clamping: HIDRemoteTiming.longPressMilliseconds)
        #expect(QianwenVoiceFocusPolicy.shouldFocusInput(
            modeEnabled: true,
            durationMilliseconds: threshold - 1
        ))
        #expect(!QianwenVoiceFocusPolicy.shouldFocusInput(
            modeEnabled: true,
            durationMilliseconds: threshold
        ))
        #expect(!QianwenVoiceFocusPolicy.shouldFocusInput(
            modeEnabled: false,
            durationMilliseconds: 100
        ))
    }

    @Test func weChatCanAcceptVoiceDespiteItsOpaqueAccessibilityTree() {
        #expect(QianwenVoiceFocusPolicy.acceptsOpaqueDestination(
            bundleIdentifier: QianwenVoiceFocusPolicy.weChatBundleIdentifier
        ))
        #expect(!QianwenVoiceFocusPolicy.acceptsOpaqueDestination(
            bundleIdentifier: PresetApplication.codex.bundleIdentifier
        ))
    }

    @Test func drainsThenNeutralizesConfirmsAndRearmsHardwareMapping() {
        var events: [String] = []
        var drainCompletion: (() -> Void)?
        var scheduledAction: (() -> Void)?
        let controller = QianwenVoiceSessionController(
            setMapping: {
                events.append($0 ? "right-command" : "neutral")
                return true
            },
            drainAudio: { drainCompletion = $0 },
            releaseCommand: {
                events.append("release")
                return true
            },
            beforeConfirm: { events.append("capture") },
            confirmVoice: {
                events.append("confirm")
                return true
            },
            schedule: { _, action in scheduledAction = action }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        #expect(controller.stopVoice())
        #expect(events.isEmpty)

        drainCompletion?()
        #expect(events == ["neutral", "release", "capture", "confirm"])

        scheduledAction?()
        #expect(events == ["neutral", "release", "capture", "confirm", "right-command"])
    }

    @Test func neutralizationFailureStillReleasesAndConfirmsWithoutRearming() {
        var events: [String] = []
        var scheduled = false
        let controller = QianwenVoiceSessionController(
            setMapping: {
                events.append($0 ? "right-command" : "neutral")
                return $0
            },
            drainAudio: { $0() },
            releaseCommand: {
                events.append("release")
                return true
            },
            confirmVoice: {
                events.append("confirm")
                return true
            },
            schedule: { _, _ in scheduled = true }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        #expect(controller.stopVoice())
        #expect(events == ["neutral", "release", "confirm"])
        #expect(!scheduled)
    }

    @Test func aNewSessionInvalidatesTheOldDrainAndRearm() {
        var events: [String] = []
        var drains: [() -> Void] = []
        let controller = QianwenVoiceSessionController(
            setMapping: {
                events.append($0 ? "right-command" : "neutral")
                return true
            },
            drainAudio: { drains.append($0) },
            releaseCommand: { true },
            confirmVoice: { true },
            schedule: { _, action in action() }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        #expect(controller.stopVoice())
        #expect(controller.startVoice())
        drains[0]()

        #expect(events.isEmpty)
    }

    @Test func disableAndShutdownReleaseWithoutConfirming() {
        var releases = 0
        var confirms = 0
        let controller = QianwenVoiceSessionController(
            setMapping: { _ in true },
            drainAudio: { $0() },
            releaseCommand: {
                releases += 1
                return true
            },
            confirmVoice: {
                confirms += 1
                return true
            }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        controller.setEnabled(false)
        controller.shutdown()

        #expect(releases == 2)
        #expect(confirms == 0)
    }

    @Test func missingDestinationNeutralizesTheVoiceKeyUntilFocusIsReady() {
        var events: [String] = []
        let controller = QianwenVoiceSessionController(
            setMapping: {
                events.append($0 ? "right-command" : "neutral")
                return true
            },
            drainAudio: { $0() },
            releaseCommand: {
                events.append("release")
                return true
            },
            confirmVoice: { true }
        )

        controller.setEnabled(true)
        #expect(!controller.prepareDestinationIfNeeded(destinationIsReady: true))
        #expect(events.isEmpty)

        #expect(controller.prepareDestinationIfNeeded(destinationIsReady: false))
        #expect(events == ["neutral", "release"])

        #expect(controller.armHardwareMapping())
        #expect(events == ["neutral", "release", "right-command"])
    }
}
