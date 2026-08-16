import Foundation
import Testing
@testable import RemoteMic

@Suite("Local transcript capture")
struct TranscriptCaptureCoordinatorTests {
    @Test func capturesOnlyTheContinuousTextInsertedAtTheOriginalSelection() throws {
        let harness = CaptureHarness()
        harness.snapshot = TranscriptCaptureSnapshot(
            focusIdentity: "42:editor",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: "前面后面",
            selection: NSRange(location: 2, length: 0),
            isSafeEditableDestination: true
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        harness.coordinator.startSession(startedAt: startedAt, source: .bluetoothRemote)
        harness.snapshot = TranscriptCaptureSnapshot(
            focusIdentity: "42:editor",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: "前面你好后面",
            selection: NSRange(location: 4, length: 0),
            isSafeEditableDestination: true
        )

        harness.coordinator.finishSession(endedAt: Date(timeIntervalSince1970: 103))
        harness.scheduler.advance(by: 1)

        let capture = try #require(harness.captures.first)
        #expect(harness.captures.count == 1)
        #expect(capture.text == "你好")
        #expect(capture.applicationName == "Notes")
        #expect(capture.bundleIdentifier == "com.apple.Notes")
        #expect(capture.source == .bluetoothRemote)
        #expect(capture.startedAt == startedAt)
    }

    @Test func disabledSensitiveOrChangedFocusSessionsAreNotCaptured() {
        let disabled = CaptureHarness(enabled: false)
        disabled.snapshot = CaptureHarness.safeSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        disabled.coordinator.startSession(startedAt: Date(), source: .nearbyPhone)
        disabled.snapshot = CaptureHarness.safeSnapshot(text: "disabled", selection: NSRange(location: 8, length: 0))
        disabled.coordinator.finishSession(endedAt: Date())
        disabled.scheduler.advance(by: 2)
        #expect(disabled.captures.isEmpty)

        let sensitive = CaptureHarness()
        sensitive.snapshot = TranscriptCaptureSnapshot(
            focusIdentity: "42:password",
            applicationName: "Browser",
            bundleIdentifier: "com.example.Browser",
            text: "",
            selection: NSRange(location: 0, length: 0),
            isSafeEditableDestination: false
        )
        sensitive.coordinator.startSession(startedAt: Date(), source: .webRemote)
        sensitive.coordinator.finishSession(endedAt: Date())
        sensitive.scheduler.advance(by: 2)
        #expect(sensitive.captures.isEmpty)

        let changedFocus = CaptureHarness()
        changedFocus.snapshot = CaptureHarness.safeSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        changedFocus.coordinator.startSession(startedAt: Date(), source: .nearbyPhone)
        changedFocus.snapshot = TranscriptCaptureSnapshot(
            focusIdentity: "43:other-editor",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: "other",
            selection: NSRange(location: 5, length: 0),
            isSafeEditableDestination: true
        )
        changedFocus.coordinator.finishSession(endedAt: Date())
        changedFocus.scheduler.advance(by: 2)
        #expect(changedFocus.captures.isEmpty)
    }

    @Test func continuousChangeRejectsUnrelatedSurroundingEdits() {
        #expect(TranscriptCaptureCoordinator.continuousChange(
            original: "abcXYZ",
            updated: "abcvoiceXYZ",
            originalSelection: NSRange(location: 3, length: 0)
        )?.newText == "voice")
        #expect(TranscriptCaptureCoordinator.continuousChange(
            original: "abcXYZ",
            updated: "changed voice XYZ",
            originalSelection: NSRange(location: 3, length: 0)
        ) == nil)
    }

    @Test func quickSendKeepsTheLastAcceptedTranscriptCandidate() throws {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "",
            selection: NSRange(location: 0, length: 0)
        )
        harness.coordinator.startSession(startedAt: Date(timeIntervalSince1970: 100), source: .bluetoothRemote)
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "快速发送",
            selection: NSRange(location: 4, length: 0)
        )
        harness.coordinator.finishSession(endedAt: Date(timeIntervalSince1970: 103))
        harness.scheduler.advance(by: 0.25)

        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "",
            selection: NSRange(location: 0, length: 0)
        )
        harness.scheduler.advance(by: 0.125)

        let capture = try #require(harness.captures.first)
        #expect(capture.text == "快速发送")
    }

    @Test func nextVoiceSessionCommitsThePreviousAcceptedCandidate() throws {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "",
            selection: NSRange(location: 0, length: 0)
        )
        harness.coordinator.startSession(startedAt: Date(timeIntervalSince1970: 100), source: .bluetoothRemote)
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "第一句",
            selection: NSRange(location: 3, length: 0)
        )
        harness.coordinator.finishSession(endedAt: Date(timeIntervalSince1970: 103))

        harness.coordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 104),
            source: .bluetoothRemote
        )

        let capture = try #require(harness.captures.first)
        #expect(capture.text == "第一句")
    }

    @Test func revertingToTheOriginalNonemptyDraftDoesNotSaveTheCandidate() {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "草稿",
            selection: NSRange(location: 2, length: 0)
        )
        harness.coordinator.startSession(startedAt: Date(), source: .bluetoothRemote)
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "草稿语音",
            selection: NSRange(location: 4, length: 0)
        )
        harness.coordinator.finishSession(endedAt: Date())
        harness.scheduler.advance(by: 0.25)

        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "草稿",
            selection: NSRange(location: 2, length: 0)
        )
        harness.scheduler.advance(by: 0.125)

        #expect(harness.captures.isEmpty)
    }

    @Test func turningTheFeatureOffCancelsAnActivePoll() {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        harness.coordinator.startSession(startedAt: Date(), source: .nearbyPhone)
        harness.snapshot = CaptureHarness.safeSnapshot(text: "voice", selection: NSRange(location: 5, length: 0))
        harness.coordinator.finishSession(endedAt: Date())
        harness.enabled = false
        harness.scheduler.advance(by: 2)

        #expect(harness.captures.isEmpty)
    }
}

private final class CaptureHarness {
    var enabled: Bool
    var snapshot: TranscriptCaptureSnapshot?
    var captures: [CapturedTranscript] = []
    let scheduler = TranscriptManualScheduler()

    lazy var coordinator = TranscriptCaptureCoordinator(
        isEnabled: { [unowned self] in enabled },
        schedule: scheduler.schedule,
        clock: { [unowned self] in scheduler.currentTime },
        snapshot: { [unowned self] in snapshot },
        onCapture: { [unowned self] capture in captures.append(capture) }
    )

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    static func safeSnapshot(text: String, selection: NSRange) -> TranscriptCaptureSnapshot {
        TranscriptCaptureSnapshot(
            focusIdentity: "42:editor",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: text,
            selection: selection,
            isSafeEditableDestination: true
        )
    }
}

private final class TranscriptManualScheduler {
    private struct Entry {
        let id: Int
        let deadline: TimeInterval
        let operation: () -> Void
    }

    private(set) var currentTime: TimeInterval = 0
    private var nextID = 0
    private var entries: [Entry] = []
    private var cancelledIDs = Set<Int>()

    lazy var schedule: TranscriptCaptureCoordinator.Scheduler = { [unowned self] delay, operation in
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
