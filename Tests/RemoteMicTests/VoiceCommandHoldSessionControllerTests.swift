import Testing
@testable import RemoteMic

@Suite("Qianwen Right Command hold session")
struct VoiceCommandHoldSessionControllerTests {
    @Test func holdsOnceAndReleasesOnlyAfterAudioDrains() {
        var keyStates: [Bool] = []
        var drainCompletion: (() -> Void)?
        let controller = VoiceCommandHoldSessionController(
            setKeyPressed: {
                keyStates.append($0)
                return true
            },
            drainAudio: { drainCompletion = $0 }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        #expect(controller.startVoice())
        #expect(keyStates == [true])
        #expect(controller.stopVoice())
        #expect(controller.isHeld)

        drainCompletion?()

        #expect(keyStates == [true, false])
        #expect(!controller.isHeld)
    }

    @Test func aNewSessionInvalidatesTheOldDrainCompletion() {
        var keyStates: [Bool] = []
        var drains: [() -> Void] = []
        let controller = VoiceCommandHoldSessionController(
            setKeyPressed: {
                keyStates.append($0)
                return true
            },
            drainAudio: { drains.append($0) }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        #expect(controller.stopVoice())
        #expect(controller.startVoice())
        drains[0]()
        #expect(controller.isHeld)
        #expect(keyStates == [true])

        #expect(controller.stopVoice())
        drains[1]()
        #expect(keyStates == [true, false])
    }

    @Test func disableDisconnectAndShutdownReleaseImmediately() {
        var keyStates: [Bool] = []
        let controller = VoiceCommandHoldSessionController(
            setKeyPressed: {
                keyStates.append($0)
                return true
            },
            drainAudio: { $0() }
        )

        controller.setEnabled(true)
        #expect(controller.startVoice())
        controller.cancelVoice()
        #expect(keyStates == [true, false])

        #expect(controller.startVoice())
        controller.setEnabled(false)
        #expect(keyStates == [true, false, true, false])
        #expect(!controller.isHeld)
    }
}
