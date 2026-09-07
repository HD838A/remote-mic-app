import Testing
@testable import RemoteMic

struct SystemAudioLifecycleTests {
    @Test func overlappingSuspensionRequiresEveryReasonToClear() {
        var state = SystemAudioSuspensionState()
        state.apply(.screenDidSleep)
        state.apply(.screenDidSleep)
        state.apply(.sessionDidResignActive)
        state.apply(.systemWillSleep)
        state.apply(.systemDidWake)
        state.apply(.screenDidWake)
        #expect(!state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: false))
        state.apply(.sessionDidBecomeActive)
        #expect(state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: false))
        #expect(!state.shouldKeepAudioActive(hasReadyRemote: false, hasActiveVoiceOrTone: false))
    }

    @Test func logicalVoiceIncludingContinuationWaitProtectsAudioUntilFinalStop() {
        var state = SystemAudioSuspensionState()
        state.apply(.screenDidSleep)
        // The bridge keeps logical voice active during the two-second silence gap.
        #expect(state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: true))
        #expect(!state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: false))
        // A real new voice request is allowed to wake output before all screen events arrive.
        #expect(state.shouldKeepAudioActive(hasReadyRemote: false, hasActiveVoiceOrTone: true))
    }
}
