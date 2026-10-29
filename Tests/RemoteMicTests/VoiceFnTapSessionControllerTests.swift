import Foundation
import Testing
@testable import RemoteMic

@Suite("Typeless Fn tap session lifecycle")
struct VoiceFnTapSessionControllerTests {
    @Test
    func eachHoldUsesItsOwnThreshold() throws {
        let defaults = try #require(UserDefaults(suiteName: "Continuation-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.voiceContinuationEnabled = true
        settings.setVoiceContinuationDelay(2)
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        let opening = [true, false]
        for duration in [50.0, 55, 59] {
            #expect(settings.continuationDelay(after: duration) == 2)
            _ = harness.controller.stopVoice(continuationDelay: settings.continuationDelay(after: duration))
            harness.scheduler.advance(by: 1)
            _ = harness.controller.startVoice()
            #expect(harness.functionKeyEvents == opening)
        }
        #expect(settings.continuationDelay(after: 10) == 0)
        _ = harness.controller.stopVoice(continuationDelay: settings.continuationDelay(after: 10))
        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.functionKeyEvents == [true, false, true, false])
        settings.voiceContinuationMinimumDuration = 0
        #expect(settings.continuationDelay(after: 0.1) == 2)
    }

    @Test(arguments: [0.5, 1, 1.5, 2, 2.5, 3])
    func releaseGraceKeepsOneFnPairAcrossPhysicalSegments(delay: TimeInterval) {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice(continuationDelay: delay))
        harness.scheduler.advance(by: delay - 0.1)
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([7, 8]))
        harness.scheduler.advance(by: delay + 1)
        #expect(harness.functionKeyEvents == [true, false])
        #expect(harness.enqueuedAudio.last == [7, 8])
        #expect(harness.controller.stopVoice(continuationDelay: delay))
        harness.scheduler.advance(by: delay)
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(harness.controller.phase == .idle)
    }

    @Test func earlyReleaseCanResumeWhileOpeningTapIsPending() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        harness.scheduler.advance(by: 0.05)
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 3)
        #expect(harness.functionKeyEvents == [true, false])
        #expect(harness.drainCompletions.isEmpty)
    }

    @Test func disconnectCancelsGraceAndClosesExactlyOnce() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        harness.controller.suspend()
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(harness.controller.phase == .idle)
    }

    @Test func disablingContinuationClosesPendingGraceImmediately() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        harness.controller.finishContinuationIfWaiting()
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        harness.scheduler.runAll()
        #expect(harness.functionKeyEvents == [true, false, true, false])
    }

    @Test func disablingWhileWaitingForContinuationStillRunsTheCompletion() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        var disabledCount = 0

        harness.controller.setEnabled(false) { disabledCount += 1 }
        #expect(disabledCount == 0)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)


        #expect(disabledCount == 1)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(!harness.controller.stopVoice())
        #expect(disabledCount == 1)
    }

    @Test func destinationCancellationAfterTheReleaseStillRunsTheCleanup() {
        let harness = Harness(defersDestination: true)
        harness.controller.setEnabled(true)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.phase == .starting(1))
        #expect(harness.controller.stopVoice(continuationDelay: 2))

        harness.resolveDestination(.cancelled(.targetChanged))

        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(harness.functionKeyEvents.isEmpty)
    }

    @Test func continuationWindowCoversASegmentQueuedBehindTheClose() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.phase == .draining(1))
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([4, 5]))
        #expect(harness.controller.stopVoice(continuationDelay: 2))

        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))
        harness.scheduler.advance(by: 0.27)
        #expect(harness.controller.phase == .active(2))
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.enqueuedAudio.last == [4, 5])


        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 3)
        #expect(harness.controller.phase == .active(2))
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.functionKeyEvents == [true, false, true, false, true, false])

        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents == [
            true, false, true, false, true, false, true, false,
        ])
    }

    @Test func aQueuedWindowThatExpiresEndsTheHandedOverSegment() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        harness.scheduler.advance(by: 2)
        #expect(harness.controller.phase == .draining(2))
        #expect(harness.drainCompletions.count == 1)
        #expect(harness.functionKeyEvents == [true, false, true, false, true, false])
    }

    @Test func aQueuedSegmentPressedAgainBeforeHandoverKeepsItselfOpen() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        #expect(harness.controller.startVoice())

        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)
        #expect(harness.controller.phase == .active(2))
        harness.scheduler.advance(by: 3)
        #expect(harness.controller.phase == .active(2))
        #expect(harness.drainCompletions.isEmpty)
    }

    @Test func aQueuedSegmentWhoseWindowClosedBeforeHandoverEndsWithTheOpeningTap() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)

        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)
        #expect(harness.controller.phase == .draining(2))
        #expect(harness.drainCompletions.count == 1)
        #expect(harness.functionKeyEvents == [true, false, true, false, true, false])
    }

    @Test func expiredQueuedSegmentKeepsItsOwnBoundaryAndTheNextPressStartsANewSession() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.phase == .draining(1))


        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([10, 11]))
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)
        #expect(harness.controller.phase == .draining(1))


        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([20, 21]))

        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))
        #expect(harness.enqueuedAudio.isEmpty)
        #expect(harness.logs.contains { $0.contains(
            "operation_id=2 phase=handover result=expired"
        ) })

        harness.scheduler.advance(by: 0.27)
        #expect(harness.enqueuedAudio == [[10, 11]])
        #expect(harness.controller.phase == .draining(2))
        #expect(harness.drainCompletions.count == 1)

        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(3))
        harness.scheduler.advance(by: 0.27)
        #expect(harness.enqueuedAudio == [[10, 11], [20, 21]])
        #expect(harness.controller.phase == .active(3))
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.functionKeyEvents == [
            true, false, true, false, true, false, true, false, true, false,
        ])

        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.5)
        #expect(harness.controller.phase == .draining(3))
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents.count == 12)
    }

    @Test func releaseOfASegmentQueuedBehindTheCloseKeepsItsOwnWindow() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())

        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([1, 2]))
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)

        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([3, 4]))

        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))


        #expect(harness.controller.stopVoice(continuationDelay: 2))

        harness.scheduler.advance(by: 0.27)
        #expect(harness.enqueuedAudio == [[1, 2]])
        #expect(harness.controller.phase == .draining(2))
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(3))

        harness.scheduler.advance(by: 0.27)
        #expect(harness.enqueuedAudio == [[1, 2], [3, 4]])
        #expect(harness.controller.phase == .active(3))
        #expect(harness.drainCompletions.isEmpty)

        harness.scheduler.advance(by: 2)
        #expect(harness.controller.phase == .draining(3))
        #expect(harness.drainCompletions.count == 1)
    }

    @Test func pressDuringExpiredSegmentOpeningKeepsAudioInSeparateSessions() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([10, 11]))
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))

        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([20, 21]))
        harness.scheduler.advance(by: 0.27)
        #expect(harness.enqueuedAudio == [[10, 11]])
        #expect(harness.controller.phase == .draining(2))
        #expect(harness.controller.receive([22, 23]))
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)
        #expect(harness.controller.phase == .active(3))
        #expect(harness.enqueuedAudio == [[10, 11], [20, 21, 22, 23]])
        #expect(harness.functionKeyEvents.count == 10)

        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.5)
        #expect(harness.controller.phase == .draining(3))
        if !harness.drainCompletions.isEmpty { harness.completeNextDrain() }
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents.count == 12)
    }

    @Test(arguments: [0.5, 2.0])
    func queuedTailRepressDuringExpiredSegmentOpeningUsesItsOwnDeadline(delay: TimeInterval) {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([10, 11]))
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([20, 21]))
        #expect(harness.controller.stopVoice(continuationDelay: delay))
        harness.scheduler.advance(by: 0.6)
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))

        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([30, 31]))
        harness.scheduler.advance(by: 0.27)
        #expect(harness.enqueuedAudio == [[10, 11]])
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)

        if delay == 0.5 {
            #expect(harness.enqueuedAudio == [[10, 11], [20, 21]])
            #expect(harness.controller.phase == .draining(3))
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.39)
            #expect(harness.controller.phase == .active(4))
            #expect(harness.enqueuedAudio == [[10, 11], [20, 21], [30, 31]])
        } else {
            #expect(harness.controller.phase == .active(3))
            #expect(harness.enqueuedAudio == [[10, 11], [20, 21, 30, 31]])
        }
        harness.scheduler.advance(by: 3)
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.controller.receive([32, 33]))
        #expect(harness.enqueuedAudio.last == [32, 33])
        #expect(harness.controller.stopVoice())
        if !harness.drainCompletions.isEmpty { harness.completeNextDrain() }
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents.count == (delay == 0.5 ? 16 : 12))
    }

    @Test(arguments: [false, true], [false, true])
    func disablingDropsSegmentsQueuedBehindTheClose(duringReplay: Bool, tailReleased: Bool) {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())

        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([1, 2]))
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([3, 4]))

        if duringReplay {
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
            #expect(harness.controller.phase == .starting(2))
        }
        if tailReleased {
            #expect(harness.controller.stopVoice(continuationDelay: 2))
        }
        var disabledCount = 0
        harness.controller.setEnabled(false) { disabledCount += 1 }
        if !duringReplay {
            #expect(disabledCount == 0)
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
        }

        #expect(harness.controller.phase == .idle)
        #expect(disabledCount == (tailReleased ? 1 : 0))
        #expect(harness.controller.requiresCleanupBeforeMapping == !tailReleased)
        #expect(harness.controller.receive([5, 6]) == !tailReleased)
        #expect(harness.enqueuedAudio.isEmpty)
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(!harness.controller.stopVoice())
        #expect(disabledCount == 1)
        #expect(!harness.controller.requiresCleanupBeforeMapping)
        #expect(!harness.controller.receive([7, 8]))
        #expect(!harness.controller.stopVoice())
        #expect(disabledCount == 1)
    }

    @Test(arguments: [false, true])
    func finishingQueuedContinuationDoesNotReleaseAHeldTail(tailWaiting: Bool) {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([10, 11]))
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.receive([20, 21]))
        if tailWaiting {
            #expect(harness.controller.stopVoice(continuationDelay: 2))
        }

        harness.controller.finishContinuationIfWaiting()
        harness.controller.finishContinuationIfWaiting()
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)
        #expect(harness.controller.phase == .draining(2))
        #expect(harness.enqueuedAudio == [[10, 11]])
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)
        #expect(harness.enqueuedAudio == [[10, 11], [20, 21]])
        if tailWaiting {
            #expect(harness.controller.phase == .draining(3))
        } else {
            #expect(harness.controller.phase == .active(3))
            harness.scheduler.advance(by: 3)
            #expect(harness.controller.phase == .active(3))
            #expect(harness.drainCompletions.isEmpty)
            #expect(harness.controller.receive([22, 23]))
            #expect(harness.enqueuedAudio.last == [22, 23])
            #expect(harness.controller.stopVoice())
        }
        if !harness.drainCompletions.isEmpty { harness.completeNextDrain() }
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents.count == 12)
    }

    @Test func repeatedQueuedReleaseDuringReplayDoesNotArmTheHistoricalSession() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.startVoice())
        #expect(harness.controller.stopVoice(continuationDelay: 0.5))
        harness.scheduler.advance(by: 0.6)
        #expect(harness.controller.startVoice())
        #expect(harness.controller.stopVoice(continuationDelay: 2))
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .starting(2))

        #expect(harness.controller.stopVoice(continuationDelay: 0.01))
        harness.scheduler.advance(by: 0.27)
        #expect(harness.controller.phase == .draining(2))
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.39)
        #expect(harness.controller.phase == .active(3))
        #expect(harness.drainCompletions.isEmpty)
        harness.scheduler.advance(by: 2)
        #expect(harness.controller.phase == .draining(3))
    }

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

    @Test func aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        #expect(harness.controller.phase == .draining(1))

        // The audio output was released mid-drain, so no drain answer ever arrives.
        harness.drainCompletions.removeAll()
        harness.scheduler.advance(by: 2)
        #expect(harness.controller.phase == .stopping(1))
        harness.scheduler.advance(by: 0.12)

        #expect(harness.controller.phase == .idle)
        #expect(harness.functionKeyEvents == [true, false, true, false])
        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.27)
        #expect(harness.controller.phase == .active(2))
    }

    @Test func aTimelyDrainCancelsTheDeadlineBeforeItCanCutTheNextSession() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)
        #expect(harness.controller.phase == .idle)

        #expect(harness.controller.startVoice())
        harness.scheduler.advance(by: 0.27)
        #expect(harness.controller.phase == .active(2))
        harness.scheduler.advance(by: 5)

        #expect(harness.controller.phase == .active(2))
        #expect(harness.drainCompletions.isEmpty)
        #expect(harness.functionKeyEvents == [true, false, true, false, true, false])
    }

    @Test func drainDeadlineAndLateAnswerAreBothObservableWithoutDoubleClosing() {
        let harness = Harness()
        harness.controller.setEnabled(true)
        harness.startActiveSession()
        #expect(harness.controller.stopVoice())
        let lateAnswer = harness.drainCompletions.removeFirst()

        harness.scheduler.advance(by: 2)
        harness.scheduler.advance(by: 0.12)
        lateAnswer()

        #expect(harness.logs.contains { $0.contains(
            "VOICE FN TAP drain operation_id=1 phase=requested result=pending timeout_ms=2000"
        ) })
        #expect(harness.logs.contains { $0.contains(
            "VOICE FN TAP drain operation_id=1 phase=resolved result=timed_out"
        ) })
        #expect(harness.logs.filter { $0.contains(
            "VOICE FN TAP drain operation_id=1 phase=completed result=session_closed"
        ) }.count == 1)
        #expect(harness.logs.contains { $0.contains(
            "VOICE FN TAP drain operation_id=1 phase=ignored result=stale trigger=answered"
        ) })
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
}

private final class Harness {
    let scheduler = ManualScheduler()
    var functionKeyEvents: [Bool] = []
    var functionKeyResults: [Bool]
    var enqueuedAudio: [[Int16]] = []
    var drainCompletions: [() -> Void] = []
    var failures: [VoiceFnTapFailure] = []
    var logs: [String] = []
    private let defersDestination: Bool
    private var destinationCallbacks: [(VoiceInputDestinationWaitResult) -> Void] = []
    lazy var controller = VoiceFnTapSessionController(
        schedule: scheduler.schedule,
        destinationReadiness: { [unowned self] completion in
            guard defersDestination else { return .immediate }
            destinationCallbacks.append(completion)
            return .waiting(VoiceFnTapScheduledTask {})
        },
        setFunctionKeyPressed: { [unowned self] pressed in
            functionKeyEvents.append(pressed)
            return functionKeyResults.isEmpty ? true : functionKeyResults.removeFirst()
        },
        enqueueAudio: { [unowned self] samples in
            enqueuedAudio.append(samples)
        },
        drainAudio: { [unowned self] _, completion in
            drainCompletions.append(completion)
        },
        onFailure: { [unowned self] failure in
            failures.append(failure)
        },
        logger: { [unowned self] message in logs.append(message) },
        uptime: { [unowned self] in scheduler.currentTime }
    )

    init(functionKeyResults: [Bool] = [], defersDestination: Bool = false) {
        self.functionKeyResults = functionKeyResults
        self.defersDestination = defersDestination
    }

    func startActiveSession() {
        #expect(controller.startVoice())
        scheduler.advance(by: 0.15)
        scheduler.advance(by: 0.12)
    }

    func completeNextDrain() {
        #expect(!drainCompletions.isEmpty)
        drainCompletions.removeFirst()()
    }

    func resolveDestination(_ result: VoiceInputDestinationWaitResult) {
        #expect(!destinationCallbacks.isEmpty)
        destinationCallbacks.removeFirst()(result)
    }
}

private final class ManualScheduler {
    private struct Entry {
        let id: Int
        let deadline: TimeInterval
        let operation: () -> Void
    }

    private(set) var currentTime: TimeInterval = 0
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
