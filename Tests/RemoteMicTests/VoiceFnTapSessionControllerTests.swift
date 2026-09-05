import Foundation
import Testing
@testable import RemoteMic

@Suite("Typeless Fn tap session lifecycle")
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
    lazy var controller = VoiceFnTapSessionController(
        schedule: scheduler.schedule,
        setFunctionKeyPressed: { [unowned self] pressed in
            functionKeyEvents.append(pressed)
            return functionKeyResults.isEmpty ? true : functionKeyResults.removeFirst()
        },
        enqueueAudio: { [unowned self] samples in
            enqueuedAudio.append(samples)
        },
        drainAudio: { [unowned self] completion in
            drainCompletions.append(completion)
        },
        onFailure: { [unowned self] failure in
            failures.append(failure)
        }
    )

    init(functionKeyResults: [Bool] = []) {
        self.functionKeyResults = functionKeyResults
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
