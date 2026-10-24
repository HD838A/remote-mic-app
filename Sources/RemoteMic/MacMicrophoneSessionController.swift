import Foundation

enum MacMicrophoneEntry: String {
    case connectionPage = "connection_page"
    case statusMenu = "status_menu"
    case shortcut
}

enum MacMicrophoneFailure: String, Error {
    case busy
    case permission
    case accessibility
    case inputUnavailable = "input_unavailable"
    case outputUnavailable = "output_unavailable"
    case targetUnavailable = "target_unavailable"
    case capture
    case interrupted
    case timedOut = "timed_out"
}

enum MacMicrophoneSessionState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case failed(MacMicrophoneFailure)

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .stopping: return true
        case .idle, .failed: return false
        }
    }

    var statusKey: String {
        switch self {
        case .idle: return "audio.mac_microphone.idle"
        case .preparing: return "audio.mac_microphone.preparing"
        case .recording: return "audio.mac_microphone.recording"
        case .stopping: return "audio.mac_microphone.stopping"
        case let .failed(failure): return "audio.mac_microphone.error.\(failure.rawValue)"
        }
    }
}

/// One operation owns permission, target preparation, capture, and output drain.
/// All dependencies deliver their callbacks on the main queue.
final class MacMicrophoneSessionController {
    typealias Preparation = (@escaping (MacMicrophoneFailure?) -> Void) -> Void
    private let isBusy: () -> Bool
    private let prepare: Preparation
    private let startCapture: (@escaping (MacMicrophoneFailure?) -> Void) -> Void
    private let stopCapture: (@escaping () -> Void) -> Void
    private let drain: (@escaping (Bool) -> Void) -> Void
    private let finish: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask
    private let log: (String) -> Void
    var onStateChange: (MacMicrophoneSessionState) -> Void = { _ in }
    private(set) var state: MacMicrophoneSessionState = .idle {
        didSet { onStateChange(state) }
    }
    private(set) var operationID: UInt64 = 0
    private var startedAt: TimeInterval = 0
    private var deadline: VoiceFnTapScheduledTask?
    private var terminalFailure: MacMicrophoneFailure?

    init(
        isBusy: @escaping () -> Bool,
        prepare: @escaping Preparation,
        startCapture: @escaping (@escaping (MacMicrophoneFailure?) -> Void) -> Void,
        stopCapture: @escaping (@escaping () -> Void) -> Void,
        drain: @escaping (@escaping (Bool) -> Void) -> Void,
        finish: @escaping () -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask = VoiceFnTapScheduledTask.mainQueue,
        log: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.isBusy = isBusy
        self.prepare = prepare
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.drain = drain
        self.finish = finish
        self.schedule = schedule
        self.log = log
    }

    func toggle(from entry: MacMicrophoneEntry) {
        switch state {
        case .preparing, .recording:
            stop()
        case .stopping:
            log("MAC MICROPHONE operation_id=\(operationID) phase=rejected reason=stopping entry=\(entry.rawValue)")
        case .idle, .failed:
            guard !isBusy() else {
                state = .failed(.busy)
                log("MAC MICROPHONE phase=rejected reason=busy entry=\(entry.rawValue)")
                return
            }
            operationID &+= 1
            let operation = operationID
            startedAt = ProcessInfo.processInfo.systemUptime
            terminalFailure = nil
            state = .preparing
            log("MAC MICROPHONE operation_id=\(operation) phase=requested entry=\(entry.rawValue)")
            deadline = schedule(30) { [weak self] in
                guard let self, self.operationID == operation, self.state == .preparing else { return }
                self.stop(failure: .timedOut)
            }
            prepare { [weak self] failure in
                guard let self, self.operationID == operation, self.state == .preparing else { return }
                if let failure { self.stop(failure: failure); return }
                self.startCapture { [weak self] failure in
                    guard let self, self.operationID == operation, self.state == .preparing else { return }
                    if let failure { self.stop(failure: failure); return }
                    self.deadline?.cancel()
                    self.deadline = nil
                    self.state = .recording
                    self.log("MAC MICROPHONE operation_id=\(operation) phase=started result=capturing target_response=unknown")
                }
            }
        }
    }

    func stop(failure: MacMicrophoneFailure? = nil) {
        if state == .stopping {
            if terminalFailure == nil { terminalFailure = failure }
            return
        }
        guard state == .preparing || state == .recording else { return }
        let operation = operationID
        terminalFailure = failure
        deadline?.cancel()
        deadline = nil
        state = .stopping
        log("MAC MICROPHONE operation_id=\(operation) phase=stopping reason=\(failure?.rawValue ?? "user_stop")")
        // The capture barrier must finish before asking the player to drain.
        stopCapture { [weak self] in
            guard let self, self.operationID == operation, self.state == .stopping else { return }
            self.drain { [weak self] normal in
                guard let self, self.operationID == operation, self.state == .stopping else { return }
                self.finish()
                let failure = self.terminalFailure ?? (normal ? nil : .interrupted)
                self.state = failure.map(MacMicrophoneSessionState.failed) ?? .idle
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - self.startedAt) * 1_000)
                self.log("MAC MICROPHONE operation_id=\(operation) phase=completed result=\(failure == nil ? "stopped" : "failed") completion=\(normal && failure == nil ? "normal" : "forced") reason=\(failure?.rawValue ?? "user_stop") elapsed_ms=\(elapsed) target_response=unknown")
            }
        }
    }
    /// Process termination is a forced cancellation; normal user stop always drains.
    func shutdown() {
        guard state.isActive else { return }
        let operation = operationID
        operationID &+= 1
        deadline?.cancel()
        deadline = nil
        state = .failed(.interrupted)
        stopCapture {}
        log("MAC MICROPHONE operation_id=\(operation) phase=completed result=failed completion=forced reason=app_stop target_response=unknown")
    }

}
