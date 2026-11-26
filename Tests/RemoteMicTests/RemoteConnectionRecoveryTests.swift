import Foundation
import Testing
@testable import RemoteMic

@Suite("Bounded remote recovery")
struct RemoteConnectionRecoveryTests {
    @Test func sleepDoesNotSpendTheNextRecoveryWindowAndCannotReviveAnExhaustedOne() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        #expect(budget.claimAttempt(at: 0))
        #expect(budget.connected(at: 1))
        budget.interrupted(suspended: true, at: 40)
        #expect(!budget.isActive)
        #expect(budget.presentationStatus == .waiting)
        budget.resume(at: 1000)
        #expect(budget.deadline == 1060)
        #expect(budget.claimAttempt(at: 1000))
        budget.finish(at: 1060)
        budget.interrupted(suspended: true, at: 1100)
        budget.resume(at: 2000)
        #expect(budget.status == .paused)
        #expect(!budget.claimAttempt(at: 2000))
    }

    @Test func discoveryObserverSurvivesPermissionDenialAndRebuildsAfterAuthorization() {
        let denied = BluetoothCentralRecoveryPolicy.transition(from: .scanning(1), generation: 1,
            event: .unauthorized, shouldRun: true, isDiscoveryObserver: true)
        #expect(!denied.shouldReleaseCentral)
        #expect(denied.phase == .stopped)
        let restored = BluetoothCentralRecoveryPolicy.transition(from: denied.phase, generation: 1,
            event: .poweredOn, shouldRun: true, isDiscoveryObserver: true)
        #expect(restored.shouldStartFreshConnectionCycle)
        let target = BluetoothCentralRecoveryPolicy.transition(from: .connecting(1), generation: 1,
            event: .unauthorized, shouldRun: true)
        #expect(target.shouldReleaseCentral)
    }

    @Test func sharedDiscoveryUsesKnownIdentityAfterRenameButStillRejectsForeignProducts() {
        let id = UUID()
        let renamed = VoiceRemoteAdmission.decide(identifier: id, targetIdentifier: nil,
            knownIdentifiers: [id], advertisesVoiceService: true,
            name: "Study remote", advertisedName: nil)
        #expect(renamed == .adoptSavedIdentity)
        let foreign = VoiceRemoteAdmission.decide(identifier: id, targetIdentifier: nil,
            knownIdentifiers: [id], advertisesVoiceService: true,
            name: "Chromecast", advertisedName: nil)
        #expect(!foreign.isAdopted)
    }

    @Test func absentHistoryDoesNotStartAConnectionWithoutAnObservation() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.status == .waiting)
        #expect(!budget.claimAttempt(at: 0))
        #expect(budget.deadline == nil)
    }

    @Test func automaticRecoveryExhaustsAfterThreeAttemptsAndStaysPaused() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        #expect(budget.claimAttempt(at: 0))
        #expect(budget.retryDelay(at: 8) == 3)
        #expect(budget.claimAttempt(at: 11))
        #expect(budget.retryDelay(at: 19) == 10)
        #expect(budget.claimAttempt(at: 29))
        #expect(budget.retryDelay(at: 37) == nil)
        #expect(budget.status == .paused)
        for time in 38...137 {
            #expect(!budget.begin(manual: false, at: Double(time)))
            #expect(!budget.claimAttempt(at: Double(time)))
        }
        #expect(budget.attemptCount == 3)
    }

    @Test func scanAndBackoffTimeArePartOfTheSameHardDeadline() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 100))
        #expect(budget.deadline == 160)
        #expect(budget.claimAttempt(at: 100))
        #expect(budget.retryDelay(at: 159) == nil)
        #expect(!budget.claimAttempt(at: 160))
        #expect(budget.status == .paused)
    }

    @Test func manualRequestIsOneAttemptAndDoesNotJoinAnInfiniteRetryLoop() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: true, at: 0))
        #expect(budget.deadline == 30)
        #expect(!budget.begin(manual: true, at: 1))
        #expect(budget.claimAttempt(at: 1))
        #expect(budget.retryDelay(at: 9) == nil)
        #expect(budget.status == .notFound)
        #expect(!budget.begin(manual: true, at: 13))
        #expect(budget.begin(manual: true, at: 14))
    }

    @Test func cancelHasNoLaterAutomaticAttemptAndManualCanRecoverAfterCooldown() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: true, at: 0))
        #expect(budget.claimAttempt(at: 1))
        budget.finish(at: 2, cancelled: true)
        #expect(budget.status == .cancelled)
        #expect(!budget.claimAttempt(at: 3))
        #expect(!budget.begin(manual: false, at: 6))
        #expect(budget.begin(manual: true, at: 7))
        #expect(budget.claimAttempt(at: 7))
        budget.connected(at: 8)
        #expect(budget.status == .ready)
    }

    @Test func shortReadyCannotMintNewAttemptsOrExtendDeadline() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        for time in [0.0, 3.0, 6.0] {
            #expect(budget.claimAttempt(at: time))
            budget.connected(at: time + 1)
            budget.disconnected(at: time + 2)
            #expect(budget.deadline == 60)
        }
        #expect(!budget.claimAttempt(at: 9))
        #expect(budget.status == .paused)
    }

    @Test func stableReadyResetsEpisodeButNeverResetsRollingFlapLimit() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        for index in 0..<6 {
            let now = Double(index * 40)
            #expect(budget.claimAttempt(at: now))
            budget.connected(at: now + 1)
            budget.disconnected(at: now + 40)
        }
        #expect(!budget.claimAttempt(at: 240))
        #expect(budget.status == .paused)
        #expect(!budget.begin(manual: false, at: 900))
        #expect(budget.begin(manual: true, at: 900))
        #expect(budget.claimAttempt(at: 900))
    }

    @Test func oneDeviceFailureNeverConsumesAnotherDevicesBudget() {
        let first = RemoteConnectionRecovery()
        let second = RemoteConnectionRecovery()
        #expect(first.begin(manual: false, at: 0))
        #expect(first.claimAttempt(at: 0))
        first.finish(at: 60)
        #expect(second.begin(manual: false, at: 61))
        #expect(second.claimAttempt(at: 61))
        second.connected(at: 62)
        #expect(first.status == .paused)
        #expect(second.status == .ready)
        #expect(second.attemptCount == 1)
    }

    @Test func staleDeadlineGenerationCannotCompleteTheNextManualOperation() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: true, at: 0))
        let oldGeneration = budget.generation
        budget.finish(at: 1, cancelled: true)
        #expect(budget.begin(manual: true, at: 6))
        #expect(oldGeneration != budget.generation)
        #expect(budget.deadline == 36)
        #expect(budget.status == .recovering)
    }

    @Test func queuedReadyAfterDeadlineOrCancellationCannotReportSuccess() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: true, at: 0))
        #expect(budget.claimAttempt(at: 0))
        #expect(!budget.connected(at: 30))
        #expect(budget.status == .notFound)
        #expect(budget.begin(manual: true, at: 35))
        budget.finish(at: 36, cancelled: true)
        #expect(!budget.connected(at: 37))
        #expect(budget.status == .cancelled)
    }

    @Test func systemWakeStartsOneAssistedEpisodeAfterFailureBudgetIsPaused() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        for index in 0..<6 {
            let now = Double(index * 40)
            #expect(budget.claimAttempt(at: now))
            budget.connected(at: now + 1)
            budget.disconnected(at: now + 40)
        }
        #expect(!budget.claimAttempt(at: 240))
        #expect(budget.status == .paused)
        #expect(budget.begin(trigger: .automatic, at: 240) == .paused)

        #expect(budget.begin(trigger: .systemWake, at: 300) == .started)
        #expect(budget.deadline == 330)
        #expect(budget.claimAttempt(at: 300))
        #expect(budget.retryDelay(at: 301) == nil)
        #expect(budget.status == .paused)
        #expect(budget.lastTerminalTrigger == .systemWake)
        #expect(budget.begin(trigger: .automatic, at: 302) == .paused)
    }

    @Test func voiceKeyBypassesPausedBudgetWithCooldown() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        for index in 0..<6 {
            let now = Double(index * 40)
            #expect(budget.claimAttempt(at: now))
            budget.connected(at: now + 1)
            budget.disconnected(at: now + 40)
        }
        #expect(!budget.claimAttempt(at: 240))
        #expect(budget.status == .paused)

        #expect(budget.begin(trigger: .voiceKey, at: 300) == .started)
        #expect(budget.claimAttempt(at: 300))
        #expect(budget.retryDelay(at: 301) == nil)
        #expect(budget.status == .paused)
        #expect(budget.begin(trigger: .voiceKey, at: 302) == .cooldown)
        #expect(budget.begin(trigger: .voiceKey, at: 306) == .started)
        #expect(budget.claimAttempt(at: 306))
    }

    @Test func wakeRecoveryRequiresReadyBeforeSuspensionAndOneAttempt() {
        #expect(RemoteWakeRecoveryPolicy.shouldAttempt(
            wasReadyBeforeSuspension: true,
            wakeAttemptConsumed: false,
            wakeRecoveryFailed: false
        ))
        #expect(!RemoteWakeRecoveryPolicy.shouldAttempt(
            wasReadyBeforeSuspension: true,
            wakeAttemptConsumed: true,
            wakeRecoveryFailed: false
        ))
        #expect(!RemoteWakeRecoveryPolicy.shouldAttempt(
            wasReadyBeforeSuspension: false,
            wakeAttemptConsumed: false,
            wakeRecoveryFailed: false
        ))
        #expect(!RemoteWakeRecoveryPolicy.shouldAttempt(
            wasReadyBeforeSuspension: true,
            wakeAttemptConsumed: false,
            wakeRecoveryFailed: true
        ))
    }

    @Test func wakeWhileStillReadyForcesOneAssistedEpisode() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        #expect(budget.claimAttempt(at: 0))
        #expect(budget.connected(at: 1))
        #expect(budget.status == .ready)

        budget.forceAssistedEpisode(trigger: .systemWake, at: 2)
        #expect(budget.status == .recovering)
        #expect(budget.deadline == 32)
        #expect(budget.claimAttempt(at: 2))
        #expect(budget.retryDelay(at: 3) == nil)
        #expect(budget.status == .paused)
    }

    /// Field replay (build 256, 2026-11-25): six short wakes, each reconnecting
    /// and staying Ready about 60–100 s of uptime, then sleeping. Uptime does not
    /// advance during sleep, so every wake landed in one 10-minute window and the
    /// seventh was paused with attempts=0.
    @Test func stableReadyBeforeSleepDoesNotChargeLaterWakeReconnects() {
        let budget = RemoteConnectionRecovery()
        var now: TimeInterval = 1000
        #expect(budget.begin(manual: false, at: now))
        for wake in 1...12 {
            #expect(budget.claimAttempt(at: now), "wake \(wake) must reconnect")
            #expect(budget.connected(at: now + 0.5))
            now += 70
            budget.interrupted(suspended: true, at: now)
            budget.resume(at: now)
            #expect(budget.status == .recovering)
            #expect(budget.automaticAttemptHistoryCount == 0)
        }
    }

    @Test func briefReadyBeforeSleepStillCountsAgainstTheRollingLimit() {
        let budget = RemoteConnectionRecovery()
        var now: TimeInterval = 0
        #expect(budget.begin(manual: false, at: now))
        for _ in 0..<3 {
            #expect(budget.claimAttempt(at: now))
            #expect(budget.connected(at: now + 1))
            now += 10
            budget.interrupted(suspended: true, at: now)
            budget.resume(at: now)
        }
        // Ready for 9 s never qualifies as stable; the episode continues and
        // the three-attempt cap is enforced.
        #expect(!budget.claimAttempt(at: now))
        #expect(budget.status == .paused)
    }

    @Test func devicePresenceLiftsPausedBudgetOnceWithCooldown() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: false, at: 0))
        for index in 0..<6 {
            let now = Double(index * 40)
            #expect(budget.claimAttempt(at: now))
            budget.connected(at: now + 1)
            budget.disconnected(at: now + 40)
        }
        #expect(!budget.claimAttempt(at: 240))
        #expect(budget.status == .paused)
        let history = budget.automaticAttemptHistoryCount

        #expect(budget.begin(trigger: .devicePresence, at: 300) == .started)
        #expect(budget.deadline == 330)
        #expect(budget.claimAttempt(at: 300))
        #expect(budget.retryDelay(at: 301) == nil)
        #expect(budget.status == .paused)
        #expect(budget.automaticAttemptHistoryCount == history)
        #expect(budget.begin(trigger: .automatic, at: 302) == .paused)
        #expect(budget.begin(trigger: .devicePresence, at: 329) == .cooldown)
        #expect(budget.begin(trigger: .devicePresence, at: 330) == .started)
        #expect(budget.claimAttempt(at: 330))
        #expect(budget.connected(at: 331))
        #expect(budget.status == .ready)
    }

    @Test func devicePresenceNeverOverridesUserCancellation() {
        let budget = RemoteConnectionRecovery()
        #expect(budget.begin(manual: true, at: 0))
        budget.finish(at: 1, cancelled: true)
        #expect(budget.status == .cancelled)
        #expect(budget.begin(trigger: .devicePresence, at: 100) == .notWaiting)
        #expect(budget.status == .cancelled)
    }

    @Test func deferredSystemWakeIsOwnedByTheFinalResume() {
        // MacBook order: system_did_wake while the screen sleeps, then screen_did_wake.
        var tracker = DeferredSystemWakeTracker()
        tracker.noteDeferredResume(.systemDidWake)
        #expect(tracker.isPending)
        let deferred = tracker.consume(onResume: .screenDidWake)
        #expect(deferred)
        #expect(!tracker.isPending)
        #expect(BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .screenDidWake, started: true, deferredSystemWake: deferred
        ))

        // Screen-only sleep never becomes a system wake.
        tracker.noteDeferredResume(.screenDidWake)
        let screenOnly = tracker.consume(onResume: .screenDidWake)
        #expect(!screenOnly)
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .screenDidWake, started: true, deferredSystemWake: false
        ))

        // system_did_wake as the final resume is handled by the event itself.
        tracker.noteDeferredResume(.systemDidWake)
        let wakeIsFinal = tracker.consume(onResume: .systemDidWake)
        #expect(!wakeIsFinal)
        #expect(!tracker.isPending)
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .screenDidWake, started: false, deferredSystemWake: true
        ))
    }
}
