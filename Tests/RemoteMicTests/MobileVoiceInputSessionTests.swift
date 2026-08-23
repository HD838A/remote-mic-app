import Foundation
import Testing
@testable import RemoteMic

@Suite("Mobile voice input session")
struct MobileVoiceInputSessionTests {
    @Test func typelessModePostsTwoFnTapsAndPreservesPreRoll() {
        let harness = MobileVoiceInputSessionHarness(tapModeEnabled: true)

        #expect(harness.session.start())
        #expect(harness.session.receive([1, 2, 3]))
        #expect(harness.functionKeyEvents.isEmpty)
        #expect(harness.enqueuedAudio.isEmpty)

        harness.scheduler.advance(by: 0.15)
        #expect(harness.functionKeyEvents == [true])
        harness.scheduler.advance(by: 0.12)
        #expect(harness.functionKeyEvents == [true, false])
        #expect(harness.enqueuedAudio == [[1, 2, 3]])

        var stopped = false
        #expect(harness.session.stop { stopped = true })
        #expect(!stopped)
        #expect(harness.drainCompletions.count == 1)
        harness.completeNextDrain()
        #expect(harness.functionKeyEvents == [true, false, true])
        harness.scheduler.advance(by: 0.12)

        #expect(stopped)
        #expect(harness.functionKeyEvents == [true, false, true, false])
    }

    @Test func holdModePreservesExistingPhoneVoiceBehavior() {
        let harness = MobileVoiceInputSessionHarness(tapModeEnabled: false)

        #expect(harness.session.start())
        #expect(harness.functionKeyEvents == [true])
        #expect(harness.session.receive([4, 5, 6]))
        #expect(harness.enqueuedAudio == [[4, 5, 6]])

        var stopped = false
        #expect(harness.session.stop { stopped = true })
        #expect(!stopped)
        #expect(harness.functionKeyEvents == [true])
        harness.completeNextDrain()

        #expect(stopped)
        #expect(harness.functionKeyEvents == [true, false])
    }
}

private final class MobileVoiceInputSessionHarness {
    let scheduler = MobileVoiceInputManualScheduler()
    var functionKeyEvents: [Bool] = []
    var enqueuedAudio: [[Int16]] = []
    var drainCompletions: [() -> Void] = []
    var failures: [VoiceFnTapFailure] = []
    lazy var session = MobileVoiceInputSession(
        tapModeEnabled: tapModeEnabled,
        schedule: scheduler.schedule,
        setFunctionKeyPressed: { [unowned self] pressed in
            functionKeyEvents.append(pressed)
            return true
        },
        enqueueAudio: { [unowned self] samples in
            enqueuedAudio.append(samples)
            return true
        },
        drainAudio: { [unowned self] completion in
            drainCompletions.append(completion)
        },
        onTapFailure: { [unowned self] failure in
            failures.append(failure)
        }
    )

    private let tapModeEnabled: Bool

    init(tapModeEnabled: Bool) {
        self.tapModeEnabled = tapModeEnabled
    }

    func completeNextDrain() {
        #expect(!drainCompletions.isEmpty)
        drainCompletions.removeFirst()()
    }
}

private final class MobileVoiceInputManualScheduler {
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
}
