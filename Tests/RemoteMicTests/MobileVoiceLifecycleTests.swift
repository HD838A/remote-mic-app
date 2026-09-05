import Testing
@testable import RemoteMic

@Suite("Mobile voice stop and restart lifecycle")
struct MobileVoiceLifecycleTests {
    @Test(arguments: [
        MobileVoiceSource.nearbyPhone,
        MobileVoiceSource.nearbyWatch,
        MobileVoiceSource.web,
    ])
    func sameSourceCanRestartImmediatelyAfterStopDrain(_ source: MobileVoiceSource) throws {
        var state = MobileVoiceLifecycleState()
        state.markStarted(source)

        let generation = try #require(state.beginStop(source).generation)
        #expect(state.requestStart(source) == .deferUntilStopped)
        #expect(state.completeStop(source, generation: generation) == .restart(source))

        state.markStarted(source)
        #expect(state.activeSource == source)
        #expect(state.stoppingSource == nil)
        #expect(state.pendingRestartSource == nil)
    }

    @Test(arguments: [
        (MobileVoiceSource.nearbyPhone, MobileVoiceSource.web),
        (MobileVoiceSource.nearbyPhone, MobileVoiceSource.nearbyWatch),
        (MobileVoiceSource.web, MobileVoiceSource.nearbyPhone),
        (MobileVoiceSource.nearbyWatch, MobileVoiceSource.web),
    ])
    func anotherSourceRemainsBusyUntilStopDrainCompletes(
        active: MobileVoiceSource,
        requested: MobileVoiceSource
    ) throws {
        var state = MobileVoiceLifecycleState()
        state.markStarted(active)
        let generation = try #require(state.beginStop(active).generation)

        #expect(state.requestStart(requested) == .busy)
        #expect(state.completeStop(active, generation: generation) == .stopped)
        #expect(state.requestStart(requested) == .startNow)
    }

    @Test func duplicateStopCancelsDeferredRestartWithoutLeavingAGhostSession() throws {
        var state = MobileVoiceLifecycleState()
        state.markStarted(.web)
        let generation = try #require(state.beginStop(.web).generation)
        #expect(state.requestStart(.web) == .deferUntilStopped)

        #expect(state.beginStop(.web) == .ignoredAlreadyStopping(
            cancelledPendingRestart: true
        ))
        #expect(state.completeStop(.web, generation: generation) == .stopped)
        #expect(state.activeSource == nil)
        #expect(state.stoppingSource == nil)
        #expect(state.pendingRestartSource == nil)
        #expect(state.requestStart(.web) == .startNow)
    }

    @Test func staleDrainCompletionCannotStopANewerSession() throws {
        var state = MobileVoiceLifecycleState()
        state.markStarted(.nearbyPhone)
        let staleGeneration = try #require(state.beginStop(.nearbyPhone).generation)
        _ = state.reset()
        state.markStarted(.web)

        #expect(state.completeStop(.nearbyPhone, generation: staleGeneration) == .ignored)
        #expect(state.activeSource == .web)
    }

    @Test func suspendDuringStoppingAndRestartKeepsActiveAudioRequired() throws {
        var lifecycle = MobileVoiceLifecycleState()
        var suspension = SystemAudioSuspensionState()
        lifecycle.markStarted(.nearbyPhone)
        let generation = try #require(lifecycle.beginStop(.nearbyPhone).generation)
        #expect(lifecycle.requestStart(.nearbyPhone) == .deferUntilStopped)

        let suspensionChanged = suspension.apply(.systemWillSleep)
        #expect(suspensionChanged)
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: lifecycle.activeSource != nil,
            testToneActive: false,
            systemSuspended: suspension.isSuspended,
            keepAliveWhileConnected: false
        ))

        #expect(lifecycle.completeStop(
            .nearbyPhone,
            generation: generation
        ) == .restart(.nearbyPhone))
        lifecycle.markStarted(.nearbyPhone)
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: lifecycle.activeSource != nil,
            testToneActive: false,
            systemSuspended: suspension.isSuspended,
            keepAliveWhileConnected: false
        ))

        let restartedGeneration = try #require(
            lifecycle.beginStop(.nearbyPhone).generation
        )
        #expect(lifecycle.completeStop(
            .nearbyPhone,
            generation: restartedGeneration
        ) == .stopped)
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: lifecycle.activeSource != nil,
            testToneActive: false,
            systemSuspended: suspension.isSuspended,
            keepAliveWhileConnected: false
        ))
    }
}

private extension MobileVoiceStopDisposition {
    var generation: UInt64? {
        guard case let .begin(generation) = self else { return nil }
        return generation
    }
}
