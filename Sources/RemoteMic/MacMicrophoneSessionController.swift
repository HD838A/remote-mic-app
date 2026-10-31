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
    case inputMonitoring = "input_monitoring"
    case inputUnavailable = "input_unavailable"
    case outputUnavailable = "output_unavailable"
    case targetUnavailable = "target_unavailable"
    case capture
    case interrupted
    case timedOut = "timed_out"
}

enum MacMicrophoneSessionState: Equatable {
    case idle
    case armed
    case preparing
    case recording
    case stopping
    case failed(MacMicrophoneFailure)

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .stopping: return true
        case .idle, .armed, .failed: return false
        }
    }

    var statusKey: String {
        switch self {
        case .idle: return "audio.mac_microphone.idle"
        case .armed: return "audio.mac_microphone.armed"
        case .preparing: return "audio.mac_microphone.preparing"
        case .recording: return "audio.mac_microphone.recording"
        case .stopping: return "audio.mac_microphone.stopping"
        case let .failed(failure): return "audio.mac_microphone.error.\(failure.rawValue)"
        }
    }
}

/// One operation owns microphone permission, capture, and output drain.
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
    private(set) var isEnabled = false
    private var voiceKeyPressed = false
    private var captureRequested = false
    private var preparingSelection = false
    private var requestedTriggerDownAt: TimeInterval?
    private var activeTriggerDownAt: TimeInterval?
    private var firstNonzeroPCMLogged = false
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

    /// These three entries select the input; only a physical voice key starts capture.
    func toggle(from entry: MacMicrophoneEntry) {
        guard state != .stopping else {
            log("MAC MICROPHONE operation_id=\(operationID) phase=rejected reason=stopping entry=\(entry.rawValue)")
            return
        }
        if isEnabled {
            isEnabled = false
            voiceKeyPressed = false
            captureRequested = false
            if state == .armed {
                state = .idle
                log("MAC MICROPHONE operation_id=\(operationID) phase=disabled result=idle entry=\(entry.rawValue)")
                finish()
            } else {
                stop()
            }
        } else {
            isEnabled = true
            voiceKeyPressed = false
            captureRequested = false
            beginPreparation(entry: entry.rawValue, selectionOnly: true)
        }
    }

    func handleVoiceKey(pressed: Bool, gesture: VoiceGestureMode,
                        observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isEnabled, pressed != voiceKeyPressed else { return }
        voiceKeyPressed = pressed
        log("MAC MICROPHONE operation_id=\(operationID) phase=voice_key edge=\(pressed ? "down" : "up") gesture=\(gesture.rawValue) target_response=unknown")
        if gesture == .hold {
            captureRequested = pressed
        } else {
            guard pressed else { return }
            captureRequested.toggle()
        }
        if captureRequested, pressed { requestedTriggerDownAt = observedAt }
        if preparingSelection { return }
        if captureRequested {
            if state == .armed { beginPreparation(entry: "voice_key", selectionOnly: false) }
            // A rapid next press is retained until the previous output has drained.
        } else if state == .preparing || state == .recording {
            stop()
        }
    }

    private func beginPreparation(entry: String, selectionOnly: Bool) {
        guard !isBusy() else {
            isEnabled = false
            captureRequested = false
            state = .failed(.busy)
            log("MAC MICROPHONE phase=rejected reason=busy entry=\(entry)")
            return
        }
        operationID &+= 1
        let operation = operationID
        startedAt = ProcessInfo.processInfo.systemUptime
        terminalFailure = nil
        preparingSelection = selectionOnly
        firstNonzeroPCMLogged = false
        activeTriggerDownAt = selectionOnly ? nil : requestedTriggerDownAt
        state = .preparing
        log("MAC MICROPHONE operation_id=\(operation) phase=requested entry=\(entry) selection_only=\(selectionOnly)")
        deadline = schedule(30) { [weak self] in
            guard let self, self.operationID == operation, self.state == .preparing else { return }
            self.stop(failure: .timedOut)
        }
        prepare { [weak self] failure in
            guard let self, self.operationID == operation, self.state == .preparing else { return }
            if let failure { self.stop(failure: failure); return }
            self.preparingSelection = false
            if selectionOnly, !self.captureRequested {
                self.deadline?.cancel()
                self.deadline = nil
                self.state = .armed
                self.log("MAC MICROPHONE operation_id=\(operation) phase=armed result=waiting_for_voice_key capture_running=false")
                return
            }
            if selectionOnly { self.activeTriggerDownAt = self.requestedTriggerDownAt }
            self.startCapture { [weak self] failure in
                guard let self, self.operationID == operation, self.state == .preparing else { return }
                if let failure { self.stop(failure: failure); return }
                self.deadline?.cancel()
                self.deadline = nil
                self.state = .recording
                self.log("MAC MICROPHONE operation_id=\(operation) phase=started result=capturing mode=physical_voice_key voice_key_injection=none key_event_passthrough=true target_activation=none target_response=unknown")
            }
        }
    }

    func observePCM(_ samples: [Int16], at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !firstNonzeroPCMLogged, let triggerDownAt = activeTriggerDownAt,
              state == .preparing || state == .recording || state == .stopping,
              samples.contains(where: { $0 != 0 }) else { return }
        firstNonzeroPCMLogged = true
        let elapsed = max(0, Int((uptime - triggerDownAt) * 1_000))
        log("MAC MICROPHONE operation_id=\(operationID) phase=first_effective_pcm trigger_down_to_first_pcm_ms=\(elapsed) target_response=unknown")
    }

    func stop(failure: MacMicrophoneFailure? = nil) {
        if failure != nil { isEnabled = false; captureRequested = false }
        if state == .armed, let failure {
            state = .failed(failure)
            finish()
            log("MAC MICROPHONE operation_id=\(operationID) phase=completed result=failed reason=\(failure.rawValue) capture_running=false")
            return
        }
        if state == .stopping {
            if terminalFailure == nil { terminalFailure = failure }
            return
        }
        guard state == .preparing || state == .recording else { return }
        captureRequested = false
        preparingSelection = false
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
                if failure != nil { self.isEnabled = false; self.captureRequested = false }
                self.state = failure.map(MacMicrophoneSessionState.failed) ?? (self.isEnabled ? .armed : .idle)
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - self.startedAt) * 1_000)
                self.log("MAC MICROPHONE operation_id=\(operation) phase=completed result=\(failure == nil ? "stopped" : "failed") completion=\(normal && failure == nil ? "normal" : "forced") reason=\(failure?.rawValue ?? "user_stop") elapsed_ms=\(elapsed) target_response=unknown")
                if self.isEnabled, self.captureRequested {
                    self.beginPreparation(entry: "voice_key_after_drain", selectionOnly: false)
                }
            }
        }
    }
    /// Process termination is a forced cancellation; normal user stop always drains.
    func shutdown() {
        guard state.isActive || state == .armed else { return }
        isEnabled = false
        voiceKeyPressed = false
        captureRequested = false
        let operation = operationID
        operationID &+= 1
        deadline?.cancel()
        deadline = nil
        state = .failed(.interrupted)
        stopCapture {}
        log("MAC MICROPHONE operation_id=\(operation) phase=completed result=failed completion=forced reason=app_stop target_response=unknown")
    }

}
