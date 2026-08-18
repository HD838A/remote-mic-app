import Foundation
import Testing
@testable import RemoteMic

@Suite("First voice reflection automation boundary")
struct FirstVoiceReflectionJourneyTests {
    @Test func resolvedOpenCodexFocusVoiceThenTargetClearSavesExactlyOneReflection() throws {
        let harness = FirstVoiceReflectionJourneyHarness()
        let intent = try #require(VoiceInputDestinationIntent.resolve(
            configured: ConfiguredButtonAction(action: .openCodex, shortcut: nil),
            applicationProfile: nil
        ))

        harness.destinationCoordinator.beginTargetSwitch(intent: intent)
        var destinationResult: VoiceInputDestinationWaitResult?
        guard case .waiting = harness.destinationCoordinator.waitUntilReady(
            completion: { destinationResult = $0 }
        ) else {
            Issue.record("The first Codex focus must wait for the launched editor")
            return
        }

        harness.destinationSnapshot = harness.codexDestinationSnapshot(
            role: "AXWindow",
            editable: false
        )
        harness.scheduler.advance(by: 0.05)
        #expect(destinationResult == nil)

        harness.destinationSnapshot = harness.codexDestinationSnapshot()
        // Return is handled by the target app. The host-observable boundary is that the
        // accepted transcript disappears from the same editor after submission.
        harness.transcriptSnapshot = harness.codexTranscriptSnapshot(text: "", cursor: 0)
        harness.scheduler.advance(by: 0.05)
        #expect(destinationResult == .ready)

        harness.captureCoordinator.startSession(
            startedAt: Date(timeIntervalSince1970: 100),
            source: .bluetoothRemote
        )
        harness.transcriptSnapshot = harness.codexTranscriptSnapshot(
            text: "第一段语音",
            cursor: 5
        )
        harness.captureCoordinator.finishSession(
            endedAt: Date(timeIntervalSince1970: 103)
        )
        harness.scheduler.advance(by: 0.25)

        harness.transcriptSnapshot = harness.codexTranscriptSnapshot(text: "", cursor: 0)
        harness.scheduler.advance(by: 0.125)
        harness.scheduler.advance(by: 2)

        let capture = try #require(harness.captures.first)
        #expect(harness.captures.count == 1)
        #expect(capture.text == "第一段语音")
        #expect(capture.applicationName == "Codex")
        #expect(capture.bundleIdentifier == PresetApplication.codex.bundleIdentifier)
        #expect(capture.source == .bluetoothRemote)
    }
}

private final class FirstVoiceReflectionJourneyHarness {
    let scheduler = JourneyManualScheduler()
    var destinationSnapshot = VoiceInputDestinationSnapshot(
        bundleIdentifier: "com.example.previous",
        role: "AXTextArea",
        subrole: "",
        enabled: true,
        editable: true,
        protectedContent: false,
        semanticText: "Message input",
        focusIdentity: "previous-editor"
    )
    var transcriptSnapshot: TranscriptCaptureSnapshot?
    var captures: [CapturedTranscript] = []

    lazy var destinationCoordinator = VoiceInputDestinationCoordinator(
        schedule: scheduler.schedule,
        snapshot: { [unowned self] in destinationSnapshot }
    )
    lazy var captureCoordinator = TranscriptCaptureCoordinator(
        isEnabled: { true },
        schedule: scheduler.schedule,
        clock: { [unowned self] in scheduler.currentTime },
        snapshot: { [unowned self] in transcriptSnapshot },
        onCapture: { [unowned self] in captures.append($0) },
        log: { _ in }
    )

    func codexDestinationSnapshot(
        role: String = "AXTextArea",
        editable: Bool = true
    ) -> VoiceInputDestinationSnapshot {
        VoiceInputDestinationSnapshot(
            bundleIdentifier: PresetApplication.codex.bundleIdentifier,
            role: role,
            subrole: "",
            enabled: true,
            editable: editable,
            protectedContent: false,
            semanticText: "Message input",
            focusIdentity: "codex-editor"
        )
    }

    func codexTranscriptSnapshot(text: String, cursor: Int) -> TranscriptCaptureSnapshot {
        TranscriptCaptureSnapshot(
            focusIdentity: "codex-editor",
            applicationName: "Codex",
            bundleIdentifier: PresetApplication.codex.bundleIdentifier,
            text: text,
            selection: NSRange(location: cursor, length: 0),
            isSafeEditableDestination: true
        )
    }
}

private final class JourneyManualScheduler {
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
        entries.append(Entry(
            id: id,
            deadline: currentTime + delay,
            operation: operation
        ))
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
