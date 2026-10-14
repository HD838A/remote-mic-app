import Foundation

enum VoiceTargetActivityInterruption: String, Equatable {
    case targetChanged = "target_changed"
    case selectedTextDeleted = "selected_text_deleted"
}

final class VoiceTargetActivityMonitor {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask
    typealias SnapshotProvider = () -> TranscriptCaptureSnapshot?

    private let pollInterval: TimeInterval
    private let schedule: Scheduler
    private let snapshot: SnapshotProvider
    private let onInterruption: (VoiceTargetActivityInterruption) -> Void
    private let log: (String) -> Void
    private var task: VoiceFnTapScheduledTask?
    private var baseline: TranscriptCaptureSnapshot?
    private var previous: TranscriptCaptureSnapshot?
    private var isRunning = false

    init(
        pollInterval: TimeInterval = 0.15,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        snapshot: @escaping SnapshotProvider = TranscriptCaptureSnapshot.system,
        onInterruption: @escaping (VoiceTargetActivityInterruption) -> Void,
        log: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.pollInterval = pollInterval
        self.schedule = schedule
        self.snapshot = snapshot
        self.onInterruption = onInterruption
        self.log = log
    }

    func start() {
        stop()
        guard let initial = snapshot(), initial.isSafeEditableDestination else {
            log("VOICE TARGET MONITOR skipped reason=initial_target_unavailable")
            return
        }
        baseline = initial
        previous = initial
        isRunning = true
        log("VOICE TARGET MONITOR started")
        schedulePoll()
    }

    func stop() {
        guard isRunning || task != nil else { return }
        task?.cancel()
        task = nil
        baseline = nil
        previous = nil
        isRunning = false
        log("VOICE TARGET MONITOR stopped")
    }

    private func schedulePoll() {
        task = schedule(pollInterval) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        guard isRunning,
              let baseline,
              let previous,
              let current = snapshot()
        else {
            guard isRunning else { return }
            schedulePoll()
            return
        }

        if current.focusIdentity != baseline.focusIdentity ||
            current.bundleIdentifier != baseline.bundleIdentifier ||
            !current.isSafeEditableDestination {
            interrupt(.targetChanged)
            return
        }

        if Self.isSelectedTextDeletion(from: previous, to: current) {
            interrupt(.selectedTextDeleted)
            return
        }

        self.previous = current
        schedulePoll()
    }

    private func interrupt(_ reason: VoiceTargetActivityInterruption) {
        guard isRunning else { return }
        stop()
        log("VOICE TARGET MONITOR interrupted reason=\(reason.rawValue)")
        onInterruption(reason)
    }

    static func isSelectedTextDeletion(
        from previous: TranscriptCaptureSnapshot,
        to current: TranscriptCaptureSnapshot
    ) -> Bool {
        guard previous.focusIdentity == current.focusIdentity,
              previous.bundleIdentifier == current.bundleIdentifier,
              previous.selection.length > 0,
              current.selection.length == 0,
              current.selection.location == previous.selection.location
        else { return false }

        let original = previous.text as NSString
        guard previous.selection.location >= 0,
              NSMaxRange(previous.selection) <= original.length
        else { return false }
        let expected = original.replacingCharacters(in: previous.selection, with: "")
        return current.text == expected
    }
}
