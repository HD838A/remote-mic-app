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
        #expect(TranscriptCaptureCoordinator.insertedTextChange(
            original: "已有草稿",
            updated: "已有草稿语音"
        )?.newText == "语音")
        #expect(TranscriptCaptureCoordinator.insertedTextChange(
            original: "已有草稿",
            updated: "完全替换"
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

    @Test func qianwenConfirmationCapturesTheCurrentCandidateBeforeTheEditorClears() throws {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "已有草稿",
            selection: NSRange(location: 0, length: 0)
        )
        harness.coordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 100),
            source: .bluetoothRemote
        )
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "已有草稿确认前文字",
            selection: NSRange(location: 9, length: 0)
        )
        harness.coordinator.finishSession(
            endedAt: Date(timeIntervalSince1970: 103),
            allowsInsertionOutsideReportedSelection: true
        )

        harness.coordinator.captureCurrentCandidateBeforeDestinationChange(
            reason: "qianwen_confirm"
        )

        let capture = try #require(harness.captures.first)
        #expect(capture.text == "确认前文字")
        #expect(harness.logs.contains { $0.contains("saved reason=qianwen_confirm") })
    }

    @Test func qianwenWaitsForAStableReplacementWhenTheReportedSelectionIsStale() throws {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "已有草稿",
            selection: NSRange(location: 0, length: 0)
        )
        harness.coordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 100),
            source: .bluetoothRemote
        )
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "已有新语音",
            selection: NSRange(location: 5, length: 0)
        )
        harness.coordinator.finishSession(
            endedAt: Date(timeIntervalSince1970: 103),
            allowsInsertionOutsideReportedSelection: true
        )

        #expect(harness.captures.isEmpty)
        harness.scheduler.advance(by: 1)

        let capture = try #require(harness.captures.first)
        #expect(capture.text == "新语音")
        #expect(harness.logs.contains { $0.contains("saved reason=stable") })
    }

    @Test func ordinaryVoiceStillRejectsAReplacementOutsideTheReportedSelection() {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "已有草稿",
            selection: NSRange(location: 0, length: 0)
        )
        harness.coordinator.startSession(startedAt: Date(), source: .bluetoothRemote)
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "已有新语音",
            selection: NSRange(location: 5, length: 0)
        )

        harness.coordinator.finishSession(endedAt: Date())
        harness.scheduler.advance(by: 1)

        #expect(harness.captures.isEmpty)
        #expect(harness.logs.contains("TRANSCRIPT CAPTURE canceled reason=discontinuous_text_change"))
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

    @Test func initialFocusRetriesBeforeCapturingTheSession() throws {
        let harness = CaptureHarness()
        harness.snapshot = nil
        harness.coordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 100),
            source: .bluetoothRemote
        )

        harness.scheduler.advance(by: 0.25)
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "",
            selection: NSRange(location: 0, length: 0)
        )
        harness.scheduler.advance(by: 0.125)
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "焦点恢复",
            selection: NSRange(location: 4, length: 0)
        )
        harness.coordinator.finishSession(endedAt: Date(timeIntervalSince1970: 103))
        harness.scheduler.advance(by: 1)

        #expect(try #require(harness.captures.first).text == "焦点恢复")
        #expect(harness.logs.contains { $0.contains("target_ready retry=true") })
    }

    @Test func nextSessionTakesOneFinalSnapshotBeforeCancelingThePreviousSession() throws {
        let harness = CaptureHarness()
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "",
            selection: NSRange(location: 0, length: 0)
        )
        harness.coordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 100),
            source: .bluetoothRemote
        )
        harness.coordinator.finishSession(endedAt: Date(timeIntervalSince1970: 101))
        harness.snapshot = CaptureHarness.safeSnapshot(
            text: "来不及轮询",
            selection: NSRange(location: 6, length: 0)
        )

        harness.coordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 102),
            source: .bluetoothRemote
        )

        #expect(try #require(harness.captures.first).text == "来不及轮询")
        #expect(harness.logs.contains { $0.contains("saved reason=next_session_snapshot") })
    }

    @Test func unavailableInitialFocusEndsWithADiagnosticReason() {
        let harness = CaptureHarness(initialSnapshotTimeout: 0.5)
        harness.snapshot = nil
        harness.coordinator.startSession(startedAt: Date(), source: .bluetoothRemote)
        harness.scheduler.advance(by: 1)

        #expect(harness.captures.isEmpty)
        #expect(harness.logs.contains("TRANSCRIPT CAPTURE skipped reason=initial_focus_unavailable"))
    }
}

private final class CaptureHarness {
    var enabled: Bool
    var snapshot: TranscriptCaptureSnapshot?
    var captures: [CapturedTranscript] = []
    var logs: [String] = []
    let scheduler = TranscriptManualScheduler()
    let initialSnapshotTimeout: TimeInterval

    lazy var coordinator = TranscriptCaptureCoordinator(
        initialSnapshotTimeout: initialSnapshotTimeout,
        isEnabled: { [unowned self] in enabled },
        schedule: scheduler.schedule,
        clock: { [unowned self] in scheduler.currentTime },
        snapshot: { [unowned self] in snapshot },
        onCapture: { [unowned self] capture in captures.append(capture) },
        log: { [unowned self] message in logs.append(message) }
    )

    init(enabled: Bool = true, initialSnapshotTimeout: TimeInterval = 1.25) {
        self.enabled = enabled
        self.initialSnapshotTimeout = initialSnapshotTimeout
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
