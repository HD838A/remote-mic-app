import Foundation
import Testing
@testable import RemoteMic

@Suite("Mobile Typeless voice input session")
struct MobileVoiceInputSessionTests {
    @Test func fnTapModeBuffersAudioAndPostsOneTapAtEachBoundary() {
        let harness = MobileVoiceInputSessionHarness()

        #expect(harness.session.start(useFnTap: true))
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

    @Test func holdModePreservesExistingMobileVoiceBehavior() {
        let harness = MobileVoiceInputSessionHarness()

        #expect(harness.session.start(useFnTap: false))
        #expect(harness.heldVoiceEvents == [true])
        #expect(harness.session.receive([4, 5, 6]))
        #expect(harness.enqueuedAudio == [[4, 5, 6]])

        var stopped = false
        #expect(harness.session.stop { stopped = true })
        #expect(!stopped)
        harness.completeNextDrain()

        #expect(stopped)
        #expect(harness.heldVoiceEvents == [true, false])
        #expect(harness.functionKeyEvents.isEmpty)
    }

    @Test func stoppingBeforeTheOpeningTapStillCompletesBothBoundaryTaps() {
        let harness = MobileVoiceInputSessionHarness()

        #expect(harness.session.start(useFnTap: true))
        #expect(harness.session.receive([7, 8]))
        var stopped = false
        #expect(harness.session.stop { stopped = true })

        harness.scheduler.advance(by: 0.15)
        harness.scheduler.advance(by: 0.12)
        #expect(harness.enqueuedAudio == [[7, 8]])
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        #expect(stopped)
        #expect(harness.functionKeyEvents == [true, false, true, false])
    }

    @Test func failedOpeningTapRejectsAudioUntilTheMobileSourceStops() {
        let harness = MobileVoiceInputSessionHarness()
        harness.failedFunctionKeyEventIndices = [1]

        #expect(harness.session.start(useFnTap: true))
        #expect(harness.session.receive([9]))
        harness.scheduler.advance(by: 0.15)

        #expect(harness.failures == [.startTapFailed])
        #expect(harness.enqueuedAudio.isEmpty)
        var stopped = false
        #expect(!harness.session.stop { stopped = true })
        #expect(stopped)
    }

    @Test func failedClosingTapStillCleansUpAndCompletesTheStop() {
        let harness = MobileVoiceInputSessionHarness()
        harness.failedFunctionKeyEventIndices = [4]

        #expect(harness.session.start(useFnTap: true))
        harness.scheduler.advance(by: 0.15)
        harness.scheduler.advance(by: 0.12)
        var stopped = false
        #expect(harness.session.stop { stopped = true })
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        #expect(stopped)
        #expect(harness.failures == [.stopTapFailed])
        #expect(harness.functionKeyEvents == [true, false, true, false, false])
    }

    @Test func failedClosingTapAppliesFallbackBeforeCompletingADeferredRestart() {
        let harness = MobileVoiceInputSessionHarness()
        harness.failedFunctionKeyEventIndices = [4]
        var events: [String] = []
        harness.onFailure = { _ in events.append("fallback") }

        #expect(harness.session.start(useFnTap: true))
        harness.scheduler.advance(by: 0.15)
        harness.scheduler.advance(by: 0.12)
        #expect(harness.session.stop { events.append("restart") })
        harness.completeNextDrain()
        harness.scheduler.advance(by: 0.12)

        #expect(events == ["fallback", "restart"])
    }

    @Test func bridgeUsesFnTapOnlyForEnabledFunctionKeyMode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func startPhoneVoice"))
        let end = try #require(source.range(
            of: "private func requestPhoneVoiceStart",
            range: start.upperBound..<source.endIndex
        ))
        let startSource = source[start.lowerBound..<end.lowerBound]

        #expect(startSource.contains(
            "let useFnTap = settings.voiceFnTapModeEnabled && settings.voiceKeyMode == .function"
        ))
        #expect(startSource.contains("mobileVoiceInputSession.start(useFnTap: useFnTap)"))
        #expect(source.contains(
            "return self.releaseVoiceKeyIfNeeded(owner: .mobile, forceSoftware: true)"
        ))
    }

    @Test func shutdownReleasesAHeldMobileVoiceKeyWithoutRunningStopCompletion() {
        let harness = MobileVoiceInputSessionHarness()

        #expect(harness.session.start(useFnTap: false))
        harness.session.shutdown()

        #expect(harness.heldVoiceEvents == [true, false])
        #expect(!harness.session.receive([10]))
    }
}

private final class MobileVoiceInputSessionHarness {
    let scheduler = MobileVoiceInputManualScheduler()
    var functionKeyEvents: [Bool] = []
    var heldVoiceEvents: [Bool] = []
    var enqueuedAudio: [[Int16]] = []
    var drainCompletions: [() -> Void] = []
    var failures: [VoiceFnTapFailure] = []
    var failedFunctionKeyEventIndices = Set<Int>()
    var onFailure: ((VoiceFnTapFailure) -> Void)?

    lazy var session = MobileVoiceInputSession(
        schedule: scheduler.schedule,
        destinationReadiness: { _ in .immediate },
        setFunctionKeyPressed: { [unowned self] pressed in
            functionKeyEvents.append(pressed)
            return !failedFunctionKeyEventIndices.contains(functionKeyEvents.count)
        },
        setHeldVoiceKeyPressed: { [unowned self] pressed in
            heldVoiceEvents.append(pressed)
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
            onFailure?(failure)
        }
    )

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
