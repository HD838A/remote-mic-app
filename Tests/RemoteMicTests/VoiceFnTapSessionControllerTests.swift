import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice tap session lifecycle")
struct VoiceFnTapSessionControllerTests {
    @Test func defaultDisabledPreservesExistingVoicePath() {
        let harness = Harness()
        harness.controller.setEnabled(false)

        #expect(!harness.controller.startVoice())
        #expect(!harness.controller.receive([1, 2, 3]))
        #expect(!harness.controller.stopVoice())
        #expect(harness.functionKeyEvents.isEmpty)
        #expect(harness.enqueuedAudio.isEmpty)
    }

    @Test func failedStartTapNeverPostsStopTap() {
        let harness = Harness(functionKeyResults: [false])
        harness.controller.setEnabled(true)

        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.15)
        #expect(harness.failures == [.startTapFailed])
        #expect(harness.functionKeyEvents == [true])

        #expect(!harness.controller.stopVoice())
        harness.scheduler.runAll()
        #expect(harness.functionKeyEvents == [true])
    }

    @Test func synchronousFirstDictationTapFailureReturnsFalse() {
        let harness = Harness(controlKeyResults: [false])
        harness.controller.setEnabled(true)

        #expect(!harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 101
        ))

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.failureOperationIDs == [101])
        #expect(harness.controlKeyEvents == [true])
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    @Test func asynchronousDictationTapFailureReturnsTrueThenReportsFailure() {
        let harness = Harness(controlKeyResults: [true, false])
        harness.controller.setEnabled(true)

        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 102
        ))
        #expect(harness.failures.isEmpty)
        #expect(harness.controller.phase == .starting(1))

        harness.scheduler.advance(by: 0.06)

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.failureOperationIDs == [102])
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    @Test func asynchronousDestinationCancellationReportsTheOriginalOperationID() throws {
        var readinessCompletion: ((VoiceInputDestinationWaitResult) -> Void)?
        var cancellations: [(VoiceInputDestinationCancellation, UInt64?)] = []
        var terminations: [(VoiceFnTapTerminationReason, UInt64?)] = []
        let controller = VoiceFnTapSessionController(
            destinationReadiness: { completion in
                readinessCompletion = completion
                return .waiting(VoiceFnTapScheduledTask {})
            },
            setFunctionKeyPressed: { _ in true },
            enqueueAudio: { _ in },
            drainAudio: { $0() },
            onFailure: { _, _ in },
            onCancellation: { cancellations.append(($0, $1)) },
            onTermination: { reason, _, operationID in
                terminations.append((reason, operationID))
            }
        )
        controller.setEnabled(true)

        #expect(controller.startVoice(operationID: 103))
        #expect(controller.receive([1, 2]))
        let completeReadiness = try #require(readinessCompletion)
        completeReadiness(.cancelled(.timedOut))

        #expect(cancellations.count == 1)
        #expect(cancellations[0].0 == .timedOut)
        #expect(cancellations[0].1 == 103)
        #expect(terminations.isEmpty)
        #expect(controller.phase == .idle)
        #expect(controller.receive([3]))
        #expect(!controller.stopVoice())
    }

    @Test func destinationCancellationReportsActiveThenRapidPendingOperation() throws {
        var readinessCompletion: ((VoiceInputDestinationWaitResult) -> Void)?
        var cancellations: [(VoiceInputDestinationCancellation, UInt64?)] = []
        var terminationOperationIDs: [UInt64?] = []
        let controller = VoiceFnTapSessionController(
            destinationReadiness: { completion in
                readinessCompletion = completion
                return .waiting(VoiceFnTapScheduledTask {})
            },
            setFunctionKeyPressed: { _ in true },
            enqueueAudio: { _ in },
            drainAudio: { $0() },
            onFailure: { _, _ in },
            onCancellation: { cancellations.append(($0, $1)) },
            onTermination: { _, _, operationID in
                terminationOperationIDs.append(operationID)
            }
        )
        controller.setEnabled(true)

        #expect(controller.startVoice(operationID: 508))
        #expect(controller.stopVoice())
        #expect(controller.startVoice(operationID: 509))
        let completeReadiness = try #require(readinessCompletion)
        completeReadiness(.cancelled(.timedOut))

        #expect(cancellations.count == 2)
        #expect(cancellations[0].0 == .timedOut)
        #expect(cancellations[0].1 == 508)
        #expect(cancellations[1].0 == .timedOut)
        #expect(cancellations[1].1 == 509)
        #expect(terminationOperationIDs.isEmpty)
        #expect(controller.phase == .idle)
        #expect(!controller.requiresCleanupBeforeMapping)
    }

    @Test func successfulDictationStopReportsCompletionOnceWithOperationID() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 401
        ))
        harness.scheduler.runAll()
        #expect(harness.completedPatterns.isEmpty)

        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.runAll()
        harness.scheduler.runAll()

        #expect(harness.completedPatterns == [.macOSDictation])
        #expect(harness.completionOperationIDs == [401])
        #expect(harness.terminationOperationIDs.isEmpty)
        #expect(harness.controller.phase == .idle)
    }

    @Test func terminationReasonTokensAreStable() {
        #expect([
            VoiceFnTapTerminationReason.modeDisabled.rawValue,
            VoiceFnTapTerminationReason.modeChanged.rawValue,
            VoiceFnTapTerminationReason.permissionRevoked.rawValue,
            VoiceFnTapTerminationReason.bluetoothNotReady.rawValue,
            VoiceFnTapTerminationReason.appShutdown.rawValue,
            VoiceFnTapTerminationReason.priorSessionFailed.rawValue,
        ] == [
            "mode_disabled",
            "mode_changed",
            "permission_revoked",
            "bluetooth_not_ready",
            "app_shutdown",
            "prior_session_failed",
        ])
    }

    @Test func disabledSessionTerminatesOnlyAfterCleanupAndRemoteStop() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 501))
        harness.scheduler.runAll()

        harness.controller.setEnabled(false) {
            harness.lifecycleEvents.append("completion")
        }
        #expect(harness.terminationOperationIDs.isEmpty)
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.terminationOperationIDs.isEmpty)
        #expect(!harness.controller.stopVoice())

        #expect(harness.terminationReasons == [.modeDisabled])
        #expect(harness.terminatedPatterns == [.function])
        #expect(harness.terminationOperationIDs == [501])
        #expect(harness.completedPatterns.isEmpty)
        #expect(harness.lifecycleEvents == ["termination", "completion"])
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func suspendedDictationTerminatesAfterTheFinalControlRelease() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 502
        ))
        harness.scheduler.runAll()

        harness.controller.suspend()
        #expect(harness.terminationOperationIDs.isEmpty)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.059)
        #expect(harness.terminationOperationIDs.isEmpty)
        harness.scheduler.advance(by: 0.002)
        harness.scheduler.advance(by: 0.078)
        #expect(harness.terminationOperationIDs.isEmpty)
        harness.scheduler.advance(by: 0.002)
        harness.scheduler.advance(by: 0.058)
        #expect(harness.terminationOperationIDs.isEmpty)
        harness.scheduler.advance(by: 0.002)

        #expect(harness.terminationReasons == [.bluetoothNotReady])
        #expect(harness.terminatedPatterns == [.macOSDictation])
        #expect(harness.terminationOperationIDs == [502])
        #expect(harness.completedPatterns.isEmpty)
        #expect(harness.controller.phase == .idle)
    }

    @Test func rapidPendingSessionsKeepFirstTerminationReasonAndOperationOrder() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 503))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 504
        ))

        harness.controller.setEnabled(false, reason: .modeChanged)
        harness.controller.suspend(reason: .permissionRevoked)
        #expect(harness.terminationOperationIDs.isEmpty)
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.terminationReasons == [.modeChanged, .modeChanged])
        #expect(harness.terminatedPatterns == [.function, .macOSDictation])
        #expect(harness.terminationOperationIDs == [503, 504])
        #expect(harness.completedPatterns.isEmpty)

        harness.controller.shutdown()
        #expect(harness.terminationOperationIDs == [503, 504])
    }

    @Test func resumedPendingSessionKeepsEachOperationsFirstTerminationReason() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 514))
        harness.scheduler.runAll()

        harness.controller.suspend()
        harness.controller.resume()
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 515
        ))
        harness.controller.suspend(reason: .permissionRevoked)
        #expect(harness.terminationOperationIDs.isEmpty)

        harness.controller.shutdown()

        #expect(harness.terminationReasons == [
            .bluetoothNotReady,
            .permissionRevoked,
        ])
        #expect(harness.terminatedPatterns == [.function, .macOSDictation])
        #expect(harness.terminationOperationIDs == [514, 515])
        #expect(harness.failures.isEmpty)
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(harness.completedPatterns.isEmpty)

        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.terminationOperationIDs == [514, 515])
    }

    @Test func nilOperationIDsUseSessionIdentityForTerminationDeduplication() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        harness.scheduler.runAll()

        harness.controller.suspend()
        harness.controller.resume()
        #expect(harness.controller.startVoice())
        harness.controller.suspend(reason: .permissionRevoked)
        harness.controller.setEnabled(false, reason: .modeChanged)
        #expect(harness.terminationOperationIDs.isEmpty)

        harness.controller.shutdown()

        #expect(harness.terminationReasons == [
            .bluetoothNotReady,
            .permissionRevoked,
        ])
        #expect(harness.terminatedPatterns == [.function, .function])
        #expect(harness.terminationOperationIDs == [nil, nil])
        #expect(harness.failures.isEmpty)
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(harness.completedPatterns.isEmpty)

        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.terminationOperationIDs == [nil, nil])
    }

    @Test func shutdownUsesAppShutdownTerminationReason() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 505))
        harness.scheduler.runAll()

        harness.controller.shutdown()

        #expect(harness.terminationReasons == [.appShutdown])
        #expect(harness.terminatedPatterns == [.function])
        #expect(harness.terminationOperationIDs == [505])
        #expect(harness.completedPatterns.isEmpty)
        #expect(harness.controller.phase == .idle)
    }

    @Test func rapidPendingSessionsReportCompletionInOperationOrder() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 402
        ))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 403
        ))
        #expect(harness.controller.stopVoice())

        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.completedPatterns == [.macOSDictation])
        #expect(harness.completionOperationIDs == [402])

        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.completedPatterns == [
            .macOSDictation,
            .macOSDictation,
        ])
        #expect(harness.completionOperationIDs == [402, 403])
        #expect(harness.controller.phase == .idle)
    }

    @Test func quickSecondSessionDuringOpeningKeepsItsOwnOperationID() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 404
        ))
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 405
        ))
        #expect(harness.controller.stopVoice())

        harness.scheduler.runAll()
        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.completionOperationIDs == [404])

        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.completionOperationIDs == [404, 405])
        #expect(harness.controller.phase == .idle)
    }

    @Test func duplicateAndQueueFullStartsAreRejected() {
        let activeHarness = Harness()
        activeHarness.controller.setEnabled(true)
        activeHarness.startActiveSession(pattern: .macOSDictation)
        #expect(!activeHarness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 406
        ))

        #expect(activeHarness.controller.stopVoice())
        #expect(activeHarness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 407
        ))
        #expect(!activeHarness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 408
        ))
    }

    @Test func pendingSecondSessionKeepsOldStopFailureOperationID() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 201
        ))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 202
        ))

        harness.completeNextDrain()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [201])
        #expect(harness.completedPatterns.isEmpty)
        #expect(harness.completionOperationIDs.isEmpty)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    @Test func stopFailureTerminatesRapidPendingAfterCleanup() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 510
        ))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 511
        ))

        harness.completeNextDrain()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [510])
        #expect(harness.terminationOperationIDs.isEmpty)
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.terminationReasons == [.priorSessionFailed])
        #expect(harness.terminatedPatterns == [.macOSDictation])
        #expect(harness.terminationOperationIDs == [511])
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func startFailureTerminatesRapidPendingAfterHeldKeyCleanup() {
        let harness = Harness(controlKeyResults: [
            true, false, false, true,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 512
        ))
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 513
        ))

        harness.scheduler.advance(by: 0.06)

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.failureOperationIDs == [512])
        #expect(harness.terminationOperationIDs.isEmpty)
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.terminationReasons == [.priorSessionFailed])
        #expect(harness.terminatedPatterns == [.macOSDictation])
        #expect(harness.terminationOperationIDs == [513])
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func failedOldSessionDoesNotAlsoTerminateButRapidPendingSessionDoes() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 506
        ))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 507
        ))

        harness.controller.setEnabled(false, reason: .modeChanged)
        harness.completeNextDrain()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [506])
        #expect(harness.terminationOperationIDs.isEmpty)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(harness.terminationReasons == [.modeChanged])
        #expect(harness.terminatedPatterns == [.macOSDictation])
        #expect(harness.terminationOperationIDs == [507])
        #expect(harness.completedPatterns.isEmpty)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func pendingSecondSessionReportsItsOwnStartFailureOperationID() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            true, true, true, true,
            false,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 301
        ))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 302
        ))

        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.failureOperationIDs == [302])
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    @Test func disablingDuringOpeningTapCompletesAndClosesThePair() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.15)
        #expect(harness.functionKeyEvents == [true])
        var disabled = false

        harness.controller.setEnabled(false) { disabled = true }
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(!disabled)
        #expect(!harness.controller.stopVoice())
        #expect(disabled)
        harness.scheduler.runAll()
        #expect(harness.functionKeyEvents == [true, false, true, false])
    }

    @Test func disablingDuringOpeningWaitsForAFailedCompensationRelease() {
        let harness = Harness(
            functionKeyResults: [true, true, true, false, false, true]
        )
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 103))
        harness.scheduler.advance(by: 0.15)
        var disabled = false

        harness.controller.setEnabled(false) { disabled = true }

        #expect(!disabled)
        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [103])
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        #expect(disabled)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.functionKeyEvents.filter(\.self).count == 2)
        #expect(harness.terminationOperationIDs.isEmpty)
    }

    @Test func compensationFailureIsReportedBeforeQueuedModeChangeCompletion() {
        let harness = Harness(
            functionKeyResults: [true, true, true, false, true]
        )
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.15)

        harness.controller.setEnabled(false) {
            harness.lifecycleEvents.append("completion")
        }

        #expect(harness.lifecycleEvents == ["failure", "completion"])
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func buffersPreRollAndStopsOnlyAfterDrain() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([1, 2, 3]))
        #expect(harness.enqueuedAudio.isEmpty)

        harness.scheduler.advance(by: 0.15)
        #expect(harness.functionKeyEvents == [true])
        harness.scheduler.advance(by: 0.12)
        #expect(harness.functionKeyEvents == [true, false])
        #expect(harness.enqueuedAudio == [[1, 2, 3]])

        #expect(harness.controller.receive([4, 5]))
        #expect(harness.enqueuedAudio == [[1, 2, 3], [4, 5]])
        #expect(harness.controller.stopVoice())
        #expect(harness.drainCompletions.count == 1)
        #expect(harness.functionKeyEvents == [true, false])

        harness.completeNextDrain()
        #expect(harness.functionKeyEvents == [true, false, true])
        harness.scheduler.advance(by: 0.12)
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(harness.controller.phase == .idle)
    }

    @Test func disablingActiveSessionFinishesMatchingStopTap() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        var disabled = false

        harness.controller.setEnabled(false) { disabled = true }
        #expect(!disabled)
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        #expect(!disabled)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.stopVoice())
        #expect(disabled)
        #expect(harness.functionKeyEvents == [true, false, true, false])
    }

    @Test func repeatedDisableDoesNotReleaseMappingBeforeTheRemoteStops() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        var completionCount = 0

        harness.controller.setEnabled(false) { completionCount += 1 }
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(completionCount == 0)

        harness.controller.setEnabled(false) { completionCount += 1 }
        #expect(completionCount == 0)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        #expect(!harness.controller.stopVoice())
        #expect(completionCount == 2)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func disconnectReconnectAndShutdownCloseActiveSession() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()

        harness.controller.suspend()
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.isSuspended)
        #expect(!harness.controller.startVoice())

        harness.controller.resume()
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.27)
        #expect(harness.controller.phase == .active(2))
        harness.controller.shutdown()
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents.suffix(2) == [true, false])
    }

    @Test func shutdownDuringStopTapDoesNotToggleTheTargetBackOn() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()

        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        #expect(harness.controller.phase == .stopping(1))
        #expect(harness.functionKeyEvents == [true, false, true])

        harness.controller.shutdown()

        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents == [true, false, true, false])
        harness.scheduler.runAll()
        #expect(harness.functionKeyEvents == [true, false, true, false])
    }

    @Test func shutdownFailureReportsInterruptedOperationID() {
        let harness = Harness(functionKeyResults: [true, true, false])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 104))
        harness.scheduler.runAll()

        harness.controller.shutdown()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [104])
        #expect(harness.terminationOperationIDs.isEmpty)
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func shutdownCleanupFailureStillTerminatesRapidPendingSession() {
        let harness = Harness(functionKeyResults: [
            true, true,
            false,
            true, true,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 518))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice(
            pattern: .macOSDictation,
            operationID: 519
        ))

        harness.controller.shutdown()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [518])
        #expect(harness.terminationReasons == [.appShutdown])
        #expect(harness.terminatedPatterns == [.macOSDictation])
        #expect(harness.terminationOperationIDs == [519])
        #expect(harness.lifecycleEvents == ["failure", "termination"])
        #expect(harness.cancellationOperationIDs.isEmpty)
        #expect(harness.completedPatterns.isEmpty)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.completeNextDrain()
        harness.controller.shutdown()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.terminationOperationIDs == [519])
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func rapidConsecutiveSessionsDoNotInterleaveAndKeepSecondPreRoll() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())

        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([9, 8, 7]))
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))

        harness.scheduler.advance(by: 0.15)
        harness.scheduler.advance(by: 0.12)
        #expect(harness.enqueuedAudio.last == [9, 8, 7])
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents == [
            true, false,
            true, false,
            true, false,
            true, false,
        ])
    }

    @Test func macOSDictationCompletesOpeningDoubleTapBeforeFlushingAndStopsAfterDrain() {
        let harness = Harness()
        #expect(VoiceFnTapSessionController.defaultDictationLeadInSampleCount == 4_000)
        harness.controller.setEnabled(true)

        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        #expect(harness.controller.receive([1, 2, 3]))
        #expect(harness.controlKeyEvents == [true])
        #expect(harness.enqueuedAudio.isEmpty)

        harness.scheduler.advance(by: 0.06)
        #expect(harness.controlKeyEvents == [true, false])
        #expect(harness.enqueuedAudio.isEmpty)
        harness.scheduler.advance(by: 0.08)
        #expect(harness.controlKeyEvents == [true, false, true])
        #expect(harness.enqueuedAudio.isEmpty)
        harness.scheduler.advance(by: 0.06)
        #expect(harness.controlKeyEvents == [true, false, true, false])
        #expect(harness.enqueuedAudio == [[0, 0, 0, 0, 1, 2, 3]])

        #expect(harness.controller.stopVoice())
        #expect(harness.drainCompletions.count == 1)
        #expect(harness.controlKeyEvents == [true, false, true, false])
        harness.completeNextDrain()
        #expect(harness.controlKeyEvents == [true, false, true, false, true])
        harness.scheduler.runAll()

        #expect(harness.controlKeyEvents == [
            true, false, true, false,
            true, false, true, false,
        ])
        #expect(harness.completedPatterns == [.macOSDictation])
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents.isEmpty)
    }

    @Test func disablingDuringFirstDictationTapFinishesMatchedDoubleTapSequences() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        #expect(harness.controller.receive([4, 5]))
        var disabled = false

        harness.controller.setEnabled(false) { disabled = true }
        #expect(!disabled)
        #expect(harness.controlKeyEvents == [true])
        harness.scheduler.runAll()
        #expect(harness.enqueuedAudio == [[0, 0, 0, 0, 4, 5]])
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.controlKeyEvents == [
            true, false, true, false,
            true, false, true, false,
        ])
        #expect(harness.completedPatterns.isEmpty)
        #expect(harness.controller.phase == .idle)
        #expect(!disabled)
        #expect(!harness.controller.stopVoice())
        #expect(disabled)
    }

    @Test func quickDictationReleaseDuringEitherOpeningTapStillClosesAfterDrain() {
        for elapsed in [0.0, 0.15] {
            let harness = Harness()
            harness.controller.setEnabled(true)
            #expect(harness.controller.startVoice(pattern: .macOSDictation))
            if elapsed > 0 {
                harness.scheduler.advance(by: elapsed)
            }

            #expect(harness.controller.stopVoice())
            harness.scheduler.runAll()
            #expect(harness.drainCompletions.count == 1)
            harness.completeNextDrain()
            harness.scheduler.runAll()

            #expect(harness.controller.phase == .idle)
            #expect(harness.controlKeyEvents == [
                true, false, true, false,
                true, false, true, false,
            ])
        }
    }

    @Test func suspendingDuringSecondDictationTapFinishesAndClosesTheSession() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        harness.scheduler.advance(by: 0.15)
        #expect(harness.controlKeyEvents == [true, false, true])
        var suspended = false

        harness.controller.suspend { suspended = true }
        #expect(!suspended)
        harness.scheduler.advance(by: 0.06)
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(suspended)
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.isSuspended)
        #expect(harness.controlKeyEvents == [
            true, false, true, false,
            true, false, true, false,
        ])
        #expect(harness.completedPatterns.isEmpty)
    }

    @Test func failedCancellationCleanupDoesNotWaitForAPhysicalStop() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)

        harness.controller.setEnabled(false)
        harness.completeNextDrain()
        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.controller.hasCleanupBlockingNewVoice)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(!harness.controller.hasCleanupBlockingNewVoice)
        #expect(harness.completedPatterns.isEmpty)
    }

    @Test func shutdownDuringFirstAndSecondDictationTapLeavesNoUnmatchedToggle() {
        let firstTapHarness = Harness()
        firstTapHarness.controller.setEnabled(true)
        #expect(firstTapHarness.controller.startVoice(pattern: .macOSDictation))
        firstTapHarness.controller.shutdown()
        firstTapHarness.scheduler.runAll()
        #expect(firstTapHarness.controlKeyEvents == [true, false])
        #expect(firstTapHarness.controller.phase == .idle)

        let betweenTapsHarness = Harness()
        betweenTapsHarness.controller.setEnabled(true)
        #expect(betweenTapsHarness.controller.startVoice(pattern: .macOSDictation))
        betweenTapsHarness.scheduler.advance(by: 0.06)
        betweenTapsHarness.controller.shutdown()
        betweenTapsHarness.scheduler.runAll()
        #expect(betweenTapsHarness.controlKeyEvents == [true, false])
        #expect(betweenTapsHarness.controller.phase == .idle)

        let secondTapHarness = Harness()
        secondTapHarness.controller.setEnabled(true)
        #expect(secondTapHarness.controller.startVoice(pattern: .macOSDictation))
        secondTapHarness.scheduler.advance(by: 0.15)
        #expect(secondTapHarness.controlKeyEvents == [true, false, true])
        secondTapHarness.controller.shutdown()
        secondTapHarness.scheduler.runAll()
        #expect(secondTapHarness.controlKeyEvents == [
            true, false, true, false,
            true, false, true, false,
        ])
        #expect(secondTapHarness.controller.phase == .idle)
    }

    @Test func rapidConsecutiveDictationSessionsKeepPatternsAndPreRollIsolated() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())

        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        #expect(harness.controller.receive([9, 8, 7]))
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.controller.phase == .draining(2))
        #expect(harness.enqueuedAudio.last == [0, 0, 0, 0, 9, 8, 7])
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.controller.phase == .idle)
        #expect(harness.controlKeyEvents.count == 16)
        #expect(harness.controlKeyEvents == [
            true, false, true, false,
            true, false, true, false,
            true, false, true, false,
            true, false, true, false,
        ])
        #expect(harness.functionKeyEvents.isEmpty)
    }

    @Test func pendingVoiceSnapshotsItsOwnTapPattern() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())

        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        #expect(harness.controller.receive([6, 7]))
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(harness.controlKeyEvents == [true, false, true, false])
        #expect(harness.enqueuedAudio.last == [0, 0, 0, 0, 6, 7])
        #expect(harness.controller.phase == .draining(2))

        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.controlKeyEvents == [
            true, false, true, false,
            true, false, true, false,
        ])
        #expect(harness.controller.phase == .idle)
    }

    @Test func failedKeyReleaseKeepsCleanupCompletionPendingUntilReleaseSucceeds() {
        let harness = Harness(
            functionKeyResults: [true, false, false, false, false, true]
        )
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.15)
        harness.scheduler.advance(by: 0.12)

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.requiresCleanupBeforeMapping)
        var cleaned = false

        harness.controller.setEnabled(false) { cleaned = true }
        #expect(!cleaned)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        #expect(!cleaned)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        #expect(cleaned)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.functionKeyEvents.suffix(2) == [true, false])
    }

    @Test func failedOpeningReleaseCompletesTheOpeningAndOneMatchingStopTap() {
        let harness = Harness(
            functionKeyResults: [true, false, true, true, true]
        )
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.15)
        harness.scheduler.advance(by: 0.12)

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.controller.requiresCleanupBeforeMapping)
        var cleaned = false

        harness.controller.setEnabled(false) { cleaned = true }

        #expect(cleaned)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.functionKeyEvents.filter(\.self).count == 2)
        #expect(harness.functionKeyEvents == [true, false, false, true, false])
    }

    @Test func failedFnStopReleaseFinishesWithoutPostingAnotherFnTap() {
        let harness = Harness(
            functionKeyResults: [true, true, true, false, false, true]
        )
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(operationID: 105))
        harness.scheduler.runAll()
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.failureOperationIDs == [105])
        #expect(harness.controller.requiresCleanupBeforeMapping)
        var cleaned = false

        harness.controller.setEnabled(false) { cleaned = true }

        #expect(cleaned)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.functionKeyEvents.filter(\.self).count == 2)
    }

    @Test func runtimeDictationCleanupUsesNormalHoldAndGapTiming() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        #expect(harness.controller.requiresCleanupBeforeMapping)
        let eventCountBeforeCleanup = harness.controlKeyEvents.count
        var cleaned = false

        harness.controller.setEnabled(false) { cleaned = true }
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup)
        #expect(!cleaned)

        harness.scheduler.advance(by: 0)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 1)
        #expect(harness.controlKeyEvents.last == true)
        harness.scheduler.advance(by: 0.059)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 1)
        harness.scheduler.advance(by: 0.002)
        #expect(harness.controlKeyEvents.suffix(2) == [true, false])

        harness.scheduler.advance(by: 0.078)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 2)
        harness.scheduler.advance(by: 0.002)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 3)
        #expect(harness.controlKeyEvents.last == true)
        harness.scheduler.advance(by: 0.058)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 3)
        harness.scheduler.advance(by: 0.002)

        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
        #expect(cleaned)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
    }

    @Test func failedFirstDictationStopReleasePostsOnlyTheRemainingTap() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            true, false, true,
            true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.06)

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.controller.requiresCleanupBeforeMapping)
        let eventCountBeforeCleanup = harness.controlKeyEvents.count
        harness.controller.setEnabled(false)

        harness.scheduler.advance(by: 0.079)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup)
        harness.scheduler.advance(by: 0.002)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 1)
        #expect(harness.controlKeyEvents.last == true)
        harness.scheduler.advance(by: 0.058)
        #expect(harness.controlKeyEvents.count == eventCountBeforeCleanup + 1)
        harness.scheduler.advance(by: 0.002)

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.filter(\.self).count == 4)
        #expect(harness.controlKeyEvents.suffix(3) == [false, true, false])
    }

    @Test func failedSecondDictationOpeningDownDoesNotReplayAfterTheWindowCanExpire() {
        let harness = Harness(controlKeyResults: [
            true, true, false,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        harness.scheduler.runAll()

        #expect(harness.failures == [.startTapFailed])
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents == [
            true, false, true,
        ])
    }

    @Test func failedFirstDictationOpeningReleaseOnlyReleasesTheHeldControl() {
        let harness = Harness(controlKeyResults: [
            true, false, false, true,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        harness.scheduler.runAll()

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.filter(\.self).count == 1)
        #expect(harness.controlKeyEvents == [true, false, false, false])
    }

    @Test func staleCleanupBlocksANewVoiceEvenIfTheControllerIsReenabled() {
        let harness = Harness(controlKeyResults: [
            true, false, false, true,
        ])
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice(pattern: .macOSDictation))
        harness.scheduler.runAll()
        #expect(harness.controller.hasCleanupBlockingNewVoice)

        harness.controller.setEnabled(true)
        #expect(!harness.controller.startVoice(pattern: .macOSDictation))
        #expect(harness.controlKeyEvents == [true, false, false])

        harness.controller.setEnabled(false)
        #expect(!harness.controller.hasCleanupBlockingNewVoice)
    }

    @Test func failedSecondDictationStopDownPostsOnlyTheRemainingTap() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            true, true, false,
            true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents == [
            true, false, true, false,
            true, false, true,
            true, false,
        ])
    }

    @Test func delayedPartialDictationStopRetriesWithAFreshDoubleTap() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            true, true, false,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.runAll()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
    }

    @Test func failedFirstStopReleaseAndRemainingDownUseAFreshPairLater() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            true, false, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.06)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
    }

    @Test func delayedHeldStopReleaseRetainsTheFreshPairFallback() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            true, false, false,
            false,
            true, false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.06)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
    }

    @Test func failedDictationStopRetriesAFullDoubleTapBeforeMappingCleanupCompletes() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()

        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.requiresCleanupBeforeMapping)
        var cleaned = false

        harness.controller.setEnabled(false) { cleaned = true }
        harness.scheduler.runAll()
        #expect(!cleaned)
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(cleaned)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
    }

    @Test func shutdownRetriesAPendingDictationStopBeforeReturning() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.shutdown()

        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
    }

    @Test func shutdownCancelsTimedDictationCleanupBeforeSynchronousRetry() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        let eventCountBeforeShutdown = harness.controlKeyEvents.count
        harness.controller.shutdown()

        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.count == eventCountBeforeShutdown + 4)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
        let eventCountAfterShutdown = harness.controlKeyEvents.count

        harness.scheduler.runAll()

        #expect(harness.controlKeyEvents.count == eventCountAfterShutdown)
    }

    @Test func failedCleanupReleaseResumesWithoutRestartingTheDoubleTap() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, true, false,
            true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(harness.controller.requiresCleanupBeforeMapping)
        let downCountBeforeReleaseRetry = harness.controlKeyEvents.filter(\.self).count

        harness.controller.setEnabled(false)

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.filter(\.self).count == downCountBeforeReleaseRetry)
    }

    @Test func repeatedSecondDownFailuresKeepRestartingAFreshDictationPair() {
        let harness = Harness(controlKeyResults: [
            true, true, true, true,
            false,
            true, true, false,
            true, true, false,
            true, true, true, true,
        ])
        harness.controller.setEnabled(true)
        harness.startActiveSession(pattern: .macOSDictation)
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        #expect(harness.controller.requiresCleanupBeforeMapping)

        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()
        #expect(harness.controller.requiresCleanupBeforeMapping)
        harness.controller.setEnabled(false)
        harness.scheduler.runAll()

        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.controlKeyEvents.suffix(4) == [true, false, true, false])
    }
}

private final class Harness {
    let scheduler = ManualScheduler()
    var functionKeyEvents: [Bool] = []
    var controlKeyEvents: [Bool] = []
    var functionKeyResults: [Bool]
    var controlKeyResults: [Bool]
    var enqueuedAudio: [[Int16]] = []
    var drainCompletions: [() -> Void] = []
    var failures: [VoiceFnTapFailure] = []
    var failureOperationIDs: [UInt64?] = []
    var cancellationReasons: [VoiceInputDestinationCancellation] = []
    var cancellationOperationIDs: [UInt64?] = []
    var completedPatterns: [VoiceFnTapSessionController.TapPattern] = []
    var completionOperationIDs: [UInt64?] = []
    var terminationReasons: [VoiceFnTapTerminationReason] = []
    var terminatedPatterns: [VoiceFnTapSessionController.TapPattern] = []
    var terminationOperationIDs: [UInt64?] = []
    var lifecycleEvents: [String] = []
    lazy var controller = VoiceFnTapSessionController(
        schedule: scheduler.schedule,
        dictationLeadInSampleCount: 4,
        setFunctionKeyPressed: { [unowned self] pressed in
            functionKeyEvents.append(pressed)
            return functionKeyResults.isEmpty ? true : functionKeyResults.removeFirst()
        },
        setControlKeyPressed: { [unowned self] pressed in
            controlKeyEvents.append(pressed)
            return controlKeyResults.isEmpty ? true : controlKeyResults.removeFirst()
        },
        enqueueAudio: { [unowned self] samples in
            enqueuedAudio.append(samples)
        },
        drainAudio: { [unowned self] completion in
            drainCompletions.append(completion)
        },
        onFailure: { [unowned self] failure, operationID in
            failures.append(failure)
            failureOperationIDs.append(operationID)
            lifecycleEvents.append("failure")
        },
        onCancellation: { [unowned self] reason, operationID in
            cancellationReasons.append(reason)
            cancellationOperationIDs.append(operationID)
        },
        onCompletion: { [unowned self] pattern, operationID in
            completedPatterns.append(pattern)
            completionOperationIDs.append(operationID)
        },
        onTermination: { [unowned self] reason, pattern, operationID in
            terminationReasons.append(reason)
            terminatedPatterns.append(pattern)
            terminationOperationIDs.append(operationID)
            lifecycleEvents.append("termination")
        }
    )

    init(
        functionKeyResults: [Bool] = [],
        controlKeyResults: [Bool] = []
    ) {
        self.functionKeyResults = functionKeyResults
        self.controlKeyResults = controlKeyResults
    }

    func startActiveSession(pattern: VoiceFnTapSessionController.TapPattern = .function) {
        #expect(controller.startVoice(pattern: pattern))
        scheduler.runAll()
    }

    func completeNextDrain() {
        #expect(!drainCompletions.isEmpty)
        drainCompletions.removeFirst()()
    }
}

private final class ManualScheduler {
    private struct Entry {
        let id: Int
        let deadline: TimeInterval
        let operation: () -> Void
    }

    private var currentTime: TimeInterval = 0
    private var nextID = 0
    private var entries: [Entry] = []
    private var cancelledIDs = Set<Int>()

    lazy var schedule: VoiceFnTapSessionController.Scheduler = { [unowned self] delay, operation in
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, deadline: currentTime + delay, operation: operation))
        return VoiceFnTapScheduledTask { [weak self] in
            self?.cancelledIDs.insert(id)
        }
    }

    func advance(by interval: TimeInterval) {
        let target = currentTime + interval
        while let next = entries
            .filter({ !cancelledIDs.contains($0.id) && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline })
        {
            entries.removeAll { $0.id == next.id }
            currentTime = next.deadline
            next.operation()
        }
        currentTime = target
    }

    func runAll() {
        while let deadline = entries
            .filter({ !cancelledIDs.contains($0.id) })
            .map(\.deadline)
            .min()
        {
            advance(by: max(0, deadline - currentTime))
        }
    }
}
