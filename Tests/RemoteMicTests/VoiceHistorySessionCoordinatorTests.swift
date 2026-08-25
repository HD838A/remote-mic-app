import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice history session assembly")
struct VoiceHistorySessionCoordinatorTests {
    @Test func combinesTranscriptAndAudioIntoOneSession() throws {
        let harness = VoiceHistoryHarness()
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 103)
        let audio = TranscriptAudioAttachment(
            fileName: "\(sessionID.uuidString).m4a",
            duration: 3,
            expiresAt: endedAt.addingTimeInterval(4 * 60 * 60)
        )

        harness.coordinator.begin(
            sessionID: sessionID,
            startedAt: startedAt,
            source: .bluetoothRemote,
            applicationName: "Fallback",
            bundleIdentifier: "com.example.fallback",
            expectsAudio: true
        )
        harness.coordinator.finish(sessionID: sessionID, endedAt: endedAt)
        harness.coordinator.receiveAudioResult(sessionID: sessionID, attachment: audio)
        #expect(harness.completed.isEmpty)

        harness.coordinator.receiveTranscript(CapturedTranscript(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            source: .bluetoothRemote,
            text: "你好"
        ))

        let completed = try #require(harness.completed.first)
        #expect(harness.completed.count == 1)
        #expect(completed.transcript == "你好")
        #expect(completed.audio == audio)
        #expect(completed.applicationName == "Notes")
    }

    @Test func timeoutKeepsAnAudioSessionWhenTranscriptCannotBeRead() throws {
        let harness = VoiceHistoryHarness()
        let sessionID = UUID()
        let endedAt = Date(timeIntervalSince1970: 103)
        let audio = TranscriptAudioAttachment(
            fileName: "\(sessionID.uuidString).m4a",
            duration: 3,
            expiresAt: endedAt.addingTimeInterval(4 * 60 * 60)
        )
        harness.coordinator.begin(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 100),
            source: .bluetoothRemote,
            applicationName: "Qianwen",
            bundleIdentifier: "com.example.qianwen",
            expectsAudio: true
        )
        harness.coordinator.finish(sessionID: sessionID, endedAt: endedAt)
        harness.coordinator.receiveAudioResult(sessionID: sessionID, attachment: audio)

        harness.scheduler.advance(by: 8.25)

        let completed = try #require(harness.completed.first)
        #expect(completed.transcript == nil)
        #expect(completed.audio == audio)
        #expect(completed.applicationName == "Qianwen")
    }

    @Test func cancellationPreventsLateCompletion() {
        let harness = VoiceHistoryHarness()
        let sessionID = UUID()
        harness.coordinator.begin(
            sessionID: sessionID,
            startedAt: Date(),
            source: .nearbyPhone,
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            expectsAudio: false
        )
        harness.coordinator.finish(sessionID: sessionID, endedAt: Date())
        harness.coordinator.cancelAll()
        harness.scheduler.advance(by: 20)
        #expect(harness.completed.isEmpty)
    }
}

private final class VoiceHistoryHarness {
    let scheduler = VoiceHistoryManualScheduler()
    var completed: [CompletedVoiceHistorySession] = []

    lazy var coordinator = VoiceHistorySessionCoordinator(
        schedule: scheduler.schedule,
        onComplete: { [unowned self] session in completed.append(session) }
    )
}

private final class VoiceHistoryManualScheduler {
    private struct Entry {
        let id: Int
        let deadline: TimeInterval
        let operation: () -> Void
    }

    private var currentTime: TimeInterval = 0
    private var nextID = 0
    private var entries: [Entry] = []
    private var cancelledIDs = Set<Int>()

    lazy var schedule: VoiceHistorySessionCoordinator.Scheduler = {
        [unowned self] delay, operation in
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
