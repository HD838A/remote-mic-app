import Foundation

enum FirstUseFailureReason: String, Codable, Equatable {
    case bluetoothPermissionDenied = "permission.bluetooth_denied"
    case inputMonitoringPermissionDenied = "permission.input_monitoring_denied"
    case accessibilityPermissionDenied = "permission.accessibility_denied"
    case remoteNotFound = "remote.not_found"
    case remoteButtonNotReady = "remote.button_not_ready"
    case audioNoOutputDevice = "audio.no_output_device"
    case audioSelectedDeviceMissing = "audio.selected_device_missing"
    case audioOutputNotReady = "audio.output_not_ready"
    case voiceSessionNotStarted = "voice.session_not_started"
    case voiceNoSamples = "voice.no_samples"
    case voiceSessionNotEnded = "voice.session_not_ended"
    case voiceManualInput = "voice.manual_input"
    case voiceNoTranscript = "voice.no_transcript"
    case voiceInputTargetNotReady = "voice.input_target_not_ready"
    case voiceInputTargetFocusLost = "voice.input_target_focus_lost"
    case voiceExternalToolNoCommit = "voice.external_tool_no_commit"
    case controlsNotConfirmed = "controls.not_confirmed"
    case completeRuntimeRegressed = "complete.runtime_regressed"

    var recoveryStep: OnboardingStep {
        switch self {
        case .bluetoothPermissionDenied,
             .inputMonitoringPermissionDenied,
             .accessibilityPermissionDenied:
            return .permissions
        case .remoteNotFound, .remoteButtonNotReady:
            return .remote
        case .audioNoOutputDevice, .audioSelectedDeviceMissing, .audioOutputNotReady:
            return .audio
        case .voiceSessionNotStarted,
             .voiceNoSamples,
             .voiceSessionNotEnded,
             .voiceManualInput,
             .voiceNoTranscript,
             .voiceInputTargetNotReady,
             .voiceInputTargetFocusLost,
             .voiceExternalToolNoCommit:
            return .voiceTest
        case .controlsNotConfirmed:
            return .controls
        case .completeRuntimeRegressed:
            return .permissions
        }
    }
}

enum FirstUseVoiceAttemptPhase: String, Equatable {
    case idle
    case recording
    case awaitingTranscript = "awaiting_transcript"
    case passed
    case failed
}

enum FirstUseVoiceAttemptResult: String, Codable, Equatable {
    case none
    case passed
    case inputTargetNotReady = "input_target_not_ready"
    case inputTargetFocusLost = "input_target_focus_lost"
    case noSamples = "no_samples"
    case manualInput = "manual_input"
    case externalToolNoCommit = "external_tool_no_commit"

    var failureReason: FirstUseFailureReason? {
        switch self {
        case .none, .passed:
            return nil
        case .inputTargetNotReady:
            return .voiceInputTargetNotReady
        case .inputTargetFocusLost:
            return .voiceInputTargetFocusLost
        case .noSamples:
            return .voiceNoSamples
        case .manualInput:
            return .voiceManualInput
        case .externalToolNoCommit:
            return .voiceExternalToolNoCommit
        }
    }

    var diagnosticBoundary: String {
        self == .externalToolNoCommit
            ? "external_tool_internal_state_unavailable"
            : "sayall_observable_state"
    }
}

struct FirstUseVoiceAttemptDiagnostic: Equatable {
    var attemptID = 0
    var phase: FirstUseVoiceAttemptPhase = .idle
    var triggerPath = "none"
    var triggerReady = false
    var editorMounted = false
    var windowKeyAtStart = false
    var firstResponderAtStart = false
    var firstResponderAtEnd = false
    var focusLost = false
    var firstSampleLatencyMilliseconds: Int?
    var sessionDurationMilliseconds: Int?
    var transcriptWaitMilliseconds: Int?
    var result: FirstUseVoiceAttemptResult = .none

    var failureReason: FirstUseFailureReason? {
        phase == .failed ? result.failureReason : nil
    }
}

enum FirstUseVoiceAttemptPolicy {
    static func terminalResultAfterSession(
        manualInputObserved: Bool,
        samplesReceived: Bool,
        transcriptionAppeared: Bool,
        triggerReady: Bool,
        focusLost: Bool
    ) -> FirstUseVoiceAttemptResult {
        if manualInputObserved { return .manualInput }
        if !samplesReceived { return .noSamples }
        if transcriptionAppeared { return .passed }
        if !triggerReady { return .inputTargetNotReady }
        if focusLost { return .inputTargetFocusLost }
        return .externalToolNoCommit
    }
}

struct FirstUseDiagnosticContext: Equatable {
    let step: OnboardingStep
    let remoteAvailability: OnboardingRemoteAvailability
    let controlMethod: OnboardingControlMethod
    let capabilities: OnboardingCapabilities
    let hasSelectedAudioUID: Bool
    let voiceAttempt: FirstUseVoiceAttemptDiagnostic?

    init(
        step: OnboardingStep,
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        capabilities: OnboardingCapabilities,
        hasSelectedAudioUID: Bool,
        voiceAttempt: FirstUseVoiceAttemptDiagnostic? = nil
    ) {
        self.step = step
        self.remoteAvailability = remoteAvailability
        self.controlMethod = controlMethod
        self.capabilities = capabilities
        self.hasSelectedAudioUID = hasSelectedAudioUID
        self.voiceAttempt = voiceAttempt
    }

    var failureReason: FirstUseFailureReason? {
        switch step {
        case .welcome, .voiceTool, .remoteAvailability:
            return nil
        case .controlMethod:
            if controlMethod == .unselected { return nil }
        case .permissions:
            if controlMethod.requiresBluetoothPermission && !capabilities.bluetoothGranted {
                return .bluetoothPermissionDenied
            }
            if controlMethod.requiresInputMonitoringPermission &&
                !capabilities.inputMonitoringGranted {
                return .inputMonitoringPermissionDenied
            }
            if !capabilities.accessibilityGranted { return .accessibilityPermissionDenied }
        case .remote:
            if !capabilities.remoteConnected { return .remoteNotFound }
            if !capabilities.remoteButtonObserved { return .remoteButtonNotReady }
        case .audio:
            if !hasSelectedAudioUID { return .audioNoOutputDevice }
            if !capabilities.audioOutputSelected { return .audioSelectedDeviceMissing }
            if !controlMethod.usesOnDemandAudioOutput && !capabilities.audioReady {
                return .audioOutputNotReady
            }
        case .voiceTest:
            if let voiceAttempt {
                return voiceAttempt.failureReason
            }
            if !capabilities.voiceSessionStarted { return .voiceSessionNotStarted }
            if !capabilities.voiceSamplesReceived { return .voiceNoSamples }
            if !capabilities.voiceSessionEnded { return .voiceSessionNotEnded }
            if capabilities.manualTranscriptInputObserved { return .voiceManualInput }
            if !capabilities.transcriptionAppeared { return .voiceNoTranscript }
        case .controls:
            if capabilities.testedRemoteButtonCount < 3 { return .controlsNotConfirmed }
        case .complete:
            guard OnboardingFlowPolicy.canContinue(
                from: .complete,
                voiceTool: .other,
                remoteAvailability: remoteAvailability,
                controlMethod: controlMethod,
                capabilities: capabilities
            ) else { return .completeRuntimeRegressed }
        }
        return nil
    }
}

enum FirstUseEventKind: String, Codable {
    case entered
    case passed
    case blocked
    case retry
    case recovered
    case completed
}

struct FirstUseEvent: Codable, Equatable {
    let timestamp: Date
    let kind: FirstUseEventKind
    let step: OnboardingStep
    let elapsedMilliseconds: Int
    let failureReason: FirstUseFailureReason?
    let voiceAttemptID: Int?
    let voiceResult: FirstUseVoiceAttemptResult?

    var deduplicationSignature: String {
        "\(kind.rawValue)|\(step.rawValue)|\(failureReason?.rawValue ?? "none")|" +
            "\(voiceAttemptID.map(String.init) ?? "none")|\(voiceResult?.rawValue ?? "none")"
    }
}

struct FirstUseDiagnosticSnapshot {
    let appVersion: String
    let appBuild: String
    let systemMajorVersion: Int
    let architecture: String
    let voiceTool: OnboardingVoiceTool
    let voiceKeyMode: VoiceKeyMode
    let context: FirstUseDiagnosticContext
    let voiceAttempt: FirstUseVoiceAttemptDiagnostic
    let bluetoothStatus: String
    let buttonStatus: String
    let audioStatus: String
    let events: [FirstUseEvent]

    var redactedText: String {
        let capabilities = context.capabilities
        var lines = [
            "SayAll first-use diagnostics",
            "app_version=\(appVersion)",
            "app_build=\(appBuild)",
            "macos_major=\(systemMajorVersion)",
            "architecture=\(architecture)",
            "step=\(context.step.rawValue)",
            "voice_tool=\(voiceTool.rawValue)",
            "voice_key_mode=\(voiceKeyMode.rawValue)",
            "remote_availability=\(context.remoteAvailability.rawValue)",
            "control_method=\(context.controlMethod.rawValue)",
            "failure=\(context.failureReason?.rawValue ?? "none")",
            "permission_bluetooth=\(capabilities.bluetoothGranted)",
            "permission_input_monitoring=\(capabilities.inputMonitoringGranted)",
            "permission_accessibility=\(capabilities.accessibilityGranted)",
            "control_connected=\(capabilities.remoteConnected)",
            "control_button_observed=\(capabilities.remoteButtonObserved)",
            "audio_device_selected=\(context.hasSelectedAudioUID)",
            "audio_device_available=\(capabilities.audioOutputSelected)",
            "audio_output_ready=\(capabilities.audioReady)",
            "voice_started=\(capabilities.voiceSessionStarted)",
            "voice_samples_received=\(capabilities.voiceSamplesReceived)",
            "voice_ended=\(capabilities.voiceSessionEnded)",
            "transcription_appeared=\(capabilities.transcriptionAppeared)",
            "manual_transcript_input_observed=\(capabilities.manualTranscriptInputObserved)",
            "voice_attempt=\(voiceAttempt.attemptID)",
            "voice_attempt_phase=\(voiceAttempt.phase.rawValue)",
            "voice_trigger_path=\(voiceAttempt.triggerPath)",
            "voice_trigger_ready=\(voiceAttempt.triggerReady)",
            "voice_editor_mounted=\(voiceAttempt.editorMounted)",
            "voice_window_key_at_start=\(voiceAttempt.windowKeyAtStart)",
            "voice_first_responder_at_start=\(voiceAttempt.firstResponderAtStart)",
            "voice_first_responder_at_end=\(voiceAttempt.firstResponderAtEnd)",
            "voice_focus_lost=\(voiceAttempt.focusLost)",
            "voice_first_sample_latency_ms=\(Self.metric(voiceAttempt.firstSampleLatencyMilliseconds))",
            "voice_session_duration_ms=\(Self.metric(voiceAttempt.sessionDurationMilliseconds))",
            "voice_transcript_wait_ms=\(Self.metric(voiceAttempt.transcriptWaitMilliseconds))",
            "voice_terminal_result=\(voiceAttempt.result.rawValue)",
            "voice_probable_cause=\(voiceAttempt.result.rawValue)",
            "voice_diagnostic_boundary=\(voiceAttempt.result.diagnosticBoundary)",
            "tested_button_count=\(capabilities.testedRemoteButtonCount)",
            "bluetooth_status=\(bluetoothStatus)",
            "button_status=\(buttonStatus)",
            "audio_status=\(audioStatus)",
            "recent_events:"
        ]
        lines.append(contentsOf: events.suffix(20).map { event in
            let timestamp = ISO8601DateFormatter().string(from: event.timestamp)
            var line = "- \(timestamp) \(event.kind.rawValue) step=\(event.step.rawValue) " +
                "elapsed_ms=\(event.elapsedMilliseconds) " +
                "failure=\(event.failureReason?.rawValue ?? "none")"
            if let attemptID = event.voiceAttemptID {
                line += " attempt=\(attemptID)"
            }
            if let voiceResult = event.voiceResult {
                line += " voice_result=\(voiceResult.rawValue)"
            }
            return line
        })
        return lines.joined(separator: "\n")
    }

    private static func metric(_ value: Int?) -> String {
        value.map(String.init) ?? "unavailable"
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
