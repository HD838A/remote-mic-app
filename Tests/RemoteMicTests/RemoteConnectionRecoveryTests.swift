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
}
