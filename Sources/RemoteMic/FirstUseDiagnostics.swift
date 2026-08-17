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
    case voiceNoTranscript = "voice.no_transcript"
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
        case .voiceSessionNotStarted, .voiceNoSamples, .voiceSessionNotEnded, .voiceNoTranscript:
            return .voiceTest
        case .controlsNotConfirmed:
            return .controls
        case .completeRuntimeRegressed:
            return .permissions
        }
    }
}

struct FirstUseDiagnosticContext: Equatable {
    let step: OnboardingStep
    let remoteAvailability: OnboardingRemoteAvailability
    let controlMethod: OnboardingControlMethod
    let capabilities: OnboardingCapabilities
    let hasSelectedAudioUID: Bool

    init(
        step: OnboardingStep,
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        capabilities: OnboardingCapabilities,
        hasSelectedAudioUID: Bool
    ) {
        self.step = step
        self.remoteAvailability = remoteAvailability
        self.controlMethod = controlMethod
        self.capabilities = capabilities
        self.hasSelectedAudioUID = hasSelectedAudioUID
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
            if !capabilities.voiceSessionStarted { return .voiceSessionNotStarted }
            if !capabilities.voiceSamplesReceived { return .voiceNoSamples }
            if !capabilities.voiceSessionEnded { return .voiceSessionNotEnded }
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

    var deduplicationSignature: String {
        "\(kind.rawValue)|\(step.rawValue)|\(failureReason?.rawValue ?? "none")"
    }
}

struct FirstUseDiagnosticSnapshot {
    let appVersion: String
    let appBuild: String
    let systemMajorVersion: Int
    let architecture: String
    let voiceTool: OnboardingVoiceTool
    let context: FirstUseDiagnosticContext
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
            "tested_button_count=\(capabilities.testedRemoteButtonCount)",
            "bluetooth_status=\(bluetoothStatus)",
            "button_status=\(buttonStatus)",
            "audio_status=\(audioStatus)",
            "recent_events:"
        ]
        lines.append(contentsOf: events.suffix(20).map { event in
            let timestamp = ISO8601DateFormatter().string(from: event.timestamp)
            return "- \(timestamp) \(event.kind.rawValue) step=\(event.step.rawValue) " +
                "elapsed_ms=\(event.elapsedMilliseconds) " +
                "failure=\(event.failureReason?.rawValue ?? "none")"
        })
        return lines.joined(separator: "\n")
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
