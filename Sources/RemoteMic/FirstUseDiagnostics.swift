import Darwin
import Foundation

enum VirtualAudioDeviceDiagnosticKind: String, Equatable {
    case miRemoteV2ch = "miremotev_2ch"
    case blackHole2ch = "blackhole_2ch"
    case other
    case unavailable
}

struct VirtualAudioPlaybackCounters: Equatable {
    var scheduledBuffers = 0
    var scheduledSamples = 0
    var playedBuffers = 0
    var playedSamples = 0
    var interruptedBuffers = 0
    var interruptedSamples = 0
}

struct VirtualAudioOutputDiagnosticSnapshot: Equatable {
    var selectedDeviceKind: VirtualAudioDeviceDiagnosticKind = .unavailable
    var actualDeviceKind: VirtualAudioDeviceDiagnosticKind = .unavailable
    var engineRunning = false
    var playerPlaying = false
    var boundToSelectedDevice: Bool?
    var pendingBuffers = 0
    var pendingSamples = 0
    var counters = VirtualAudioPlaybackCounters()
}

enum VoiceAudioDeliveryRoute: String, Equatable {
    case none
    case virtualAudioDirect = "virtual_audio_direct"
    case virtualAudioViaFnTap = "virtual_audio_via_fn_tap"
}

enum VoiceAudioDeliveryResult: String, Equatable {
    case unavailable
    case receiving
    case noSamples = "no_samples"
    case outputNotReady = "output_not_ready"
    case routeMismatch = "route_mismatch"
    case enqueueFailed = "enqueue_failed"
    case playbackInterrupted = "playback_interrupted"
    case playbackPending = "playback_pending"
    case playbackIncomplete = "playback_incomplete"
    case deliveredToSelectedDevice = "delivered_to_selected_device"

    var isConfirmedFailure: Bool {
        switch self {
        case .outputNotReady, .routeMismatch, .enqueueFailed,
             .playbackInterrupted:
            return true
        case .unavailable, .receiving, .noSamples, .playbackPending,
             .playbackIncomplete, .deliveredToSelectedDevice:
            return false
        }
    }
}

struct VoiceAudioDeliveryDiagnostic: Equatable {
    var generation = 0
    var source = "none"
    var route: VoiceAudioDeliveryRoute = .none
    var sessionEnded = false
    var receivedBatches = 0
    var receivedSamples = 0
    var enqueueFailures = 0
    var outputAtStart = VirtualAudioOutputDiagnosticSnapshot()
    var outputAtObservation = VirtualAudioOutputDiagnosticSnapshot()
    var countersAtStart = VirtualAudioPlaybackCounters()

    var scheduledBuffers: Int {
        max(0, outputAtObservation.counters.scheduledBuffers - countersAtStart.scheduledBuffers)
    }

    var scheduledSamples: Int {
        max(0, outputAtObservation.counters.scheduledSamples - countersAtStart.scheduledSamples)
    }

    var playedBuffers: Int {
        max(0, outputAtObservation.counters.playedBuffers - countersAtStart.playedBuffers)
    }

    var playedSamples: Int {
        max(0, outputAtObservation.counters.playedSamples - countersAtStart.playedSamples)
    }

    var interruptedBuffers: Int {
        max(0, outputAtObservation.counters.interruptedBuffers - countersAtStart.interruptedBuffers)
    }

    var interruptedSamples: Int {
        max(0, outputAtObservation.counters.interruptedSamples - countersAtStart.interruptedSamples)
    }

    var result: VoiceAudioDeliveryResult {
        VoiceAudioDeliveryPolicy.result(for: self)
    }
}

enum VoiceAudioDeliveryPolicy {
    static func result(for diagnostic: VoiceAudioDeliveryDiagnostic) -> VoiceAudioDeliveryResult {
        guard diagnostic.generation > 0 else { return .unavailable }
        guard diagnostic.receivedSamples > 0 else {
            return diagnostic.sessionEnded ? .noSamples : .receiving
        }
        guard diagnostic.outputAtStart.selectedDeviceKind != .unavailable,
              diagnostic.outputAtStart.engineRunning,
              diagnostic.outputAtStart.playerPlaying
        else { return .outputNotReady }
        guard diagnostic.outputAtStart.boundToSelectedDevice == true else { return .routeMismatch }
        guard diagnostic.enqueueFailures == 0 else { return .enqueueFailed }
        guard diagnostic.interruptedSamples == 0 else { return .playbackInterrupted }
        guard diagnostic.sessionEnded else { return .receiving }
        guard diagnostic.scheduledSamples >= diagnostic.receivedSamples else {
            return .playbackIncomplete
        }
        guard diagnostic.outputAtObservation.pendingSamples == 0 else { return .playbackPending }
        guard diagnostic.playedSamples >= diagnostic.receivedSamples else {
            return .playbackIncomplete
        }
        return .deliveredToSelectedDevice
    }
}

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
    case voiceAudioDeliveryFailed = "voice.audio_delivery_failed"
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
             .voiceAudioDeliveryFailed,
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
    case audioDeliveryFailed = "audio_delivery_failed"
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
        case .audioDeliveryFailed:
            return .voiceAudioDeliveryFailed
        case .noSamples:
            return .voiceNoSamples
        case .manualInput:
            return .voiceManualInput
        case .externalToolNoCommit:
            return .voiceExternalToolNoCommit
        }
    }

    var observedFailure: String {
        switch self {
        case .none, .passed: return "none"
        case .inputTargetNotReady: return "input_target_not_ready"
        case .inputTargetFocusLost: return "input_target_not_ready_at_deadline"
        case .audioDeliveryFailed: return "audio_not_delivered_to_selected_device"
        case .noSamples: return "audio_samples_not_received"
        case .manualInput: return "manual_input_observed"
        case .externalToolNoCommit: return "transcript_commit_not_observed"
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
    var focusLossCount = 0
    var focusEditorUnmounted = false
    var focusWindowNotKey = false
    var focusFirstResponderChanged = false
    var focusRecovered = false
    var focusReadyAtEnd = false
    var focusReadyAtDeadline: Bool?
    var firstFocusLossLatencyMilliseconds: Int?
    var totalFocusLossMilliseconds = 0
    var firstSampleLatencyMilliseconds: Int?
    var sessionDurationMilliseconds: Int?
    var transcriptWaitMilliseconds: Int?
    var externalToolVoiceKeyUserConfirmed = false
    var externalToolExpectedVoiceKey = "fn_hold"
    var externalToolGlobalVoiceApplicable = false
    var externalToolGlobalVoiceUserConfirmed = true
    var externalToolMicrophoneUserConfirmed = false
    var audioDelivery = VoiceAudioDeliveryDiagnostic()
    var result: FirstUseVoiceAttemptResult = .none

    var failureReason: FirstUseFailureReason? {
        phase == .failed ? result.failureReason : nil
    }

    var probableCause: String {
        switch result {
        case .audioDeliveryFailed:
            return "audio_\(audioDelivery.result.rawValue)"
        case .externalToolNoCommit:
            if !externalToolVoiceKeyUserConfirmed {
                return "external_tool_voice_key_not_confirmed"
            }
            if externalToolGlobalVoiceApplicable,
               !externalToolGlobalVoiceUserConfirmed {
                return "external_tool_global_voice_not_confirmed"
            }
            return externalToolMicrophoneUserConfirmed
                ? "external_tool_no_commit"
                : "external_tool_microphone_not_confirmed"
        default:
            return result.rawValue
        }
    }

    var probableCauseConfirmed: Bool {
        result != .externalToolNoCommit
    }
}

enum FirstUseVoiceAttemptPolicy {
    static func terminalResultAfterSession(
        manualInputObserved: Bool,
        samplesReceived: Bool,
        transcriptionAppeared: Bool,
        triggerReady: Bool,
        focusReadyAtDeadline: Bool,
        audioDeliveryResult: VoiceAudioDeliveryResult,
        finalObservation: Bool
    ) -> FirstUseVoiceAttemptResult {
        if manualInputObserved { return .manualInput }
        if !samplesReceived { return .noSamples }
        if !triggerReady { return .inputTargetNotReady }
        if audioDeliveryResult.isConfirmedFailure { return .audioDeliveryFailed }
        if finalObservation,
           audioDeliveryResult != .deliveredToSelectedDevice {
            return .audioDeliveryFailed
        }
        if transcriptionAppeared,
           audioDeliveryResult == .deliveredToSelectedDevice {
            return .passed
        }
        if !focusReadyAtDeadline { return .inputTargetFocusLost }
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
    let appLanguage: String
    let generatedAt = Date()
    let onboardingVoiceKeyPolicy = "fn_only"

    var redactedText: String {
        let capabilities = context.capabilities
        var lines = [
            "SayAll first-use diagnostics",
            "diagnostic_schema=3",
            "generated_at=\(Self.timestamp(generatedAt))",
            "app_version=\(appVersion)",
            "app_build=\(appBuild)",
            "source_revision=unknown",
            "build_channel=unknown",
            "release_tag=unknown",
            "bundle_id=\(Bundle.main.bundleIdentifier ?? "unknown")",
            "process_id=\(ProcessInfo.processInfo.processIdentifier)",
            "process_architecture=\(Self.architecture)",
            "hardware_architecture=\(Self.hardwareArchitecture)",
            "running_under_rosetta=\(Self.runningUnderRosetta)",
            "macos_version=\(Self.systemVersion)",
            "macos_build=\(Self.systemBuild)",
            "macos_major=\(systemMajorVersion)",
            "app_language=\(Self.stableToken(appLanguage))",
            "architecture=\(architecture)",
            "step=\(context.step.rawValue)",
            "voice_tool=\(voiceTool.rawValue)",
            "voice_key_mode=\(voiceKeyMode.rawValue)",
            "onboarding_voice_key_policy=\(onboardingVoiceKeyPolicy)",
            "voice_key_policy_compliant=\(voiceKeyMode == .function)",
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
            "voice_focus_loss_count=\(voiceAttempt.focusLossCount)",
            "voice_focus_editor_unmounted=\(voiceAttempt.focusEditorUnmounted)",
            "voice_focus_window_not_key=\(voiceAttempt.focusWindowNotKey)",
            "voice_focus_first_responder_changed=\(voiceAttempt.focusFirstResponderChanged)",
            "voice_focus_recovered=\(voiceAttempt.focusRecovered)",
            "voice_focus_ready_at_end=\(voiceAttempt.focusReadyAtEnd)",
            "voice_focus_ready_at_deadline=\(Self.optionalBoolean(voiceAttempt.focusReadyAtDeadline))",
            "voice_focus_first_loss_latency_ms=\(Self.metric(voiceAttempt.firstFocusLossLatencyMilliseconds))",
            "voice_focus_total_loss_ms=\(voiceAttempt.totalFocusLossMilliseconds)",
            "voice_first_sample_latency_ms=\(Self.metric(voiceAttempt.firstSampleLatencyMilliseconds))",
            "voice_session_duration_ms=\(Self.metric(voiceAttempt.sessionDurationMilliseconds))",
            "voice_session_under_1s=\((voiceAttempt.sessionDurationMilliseconds ?? 1_000) < 1_000)",
            "voice_transcript_wait_ms=\(Self.metric(voiceAttempt.transcriptWaitMilliseconds))",
            "voice_external_tool_voice_key_observable=false",
            "voice_external_tool_voice_key_user_confirmed=\(voiceAttempt.externalToolVoiceKeyUserConfirmed)",
            "voice_external_tool_expected_voice_key=\(voiceAttempt.externalToolExpectedVoiceKey)",
            "voice_external_tool_global_voice_observable=false",
            "voice_external_tool_global_voice_applicable=\(voiceAttempt.externalToolGlobalVoiceApplicable)",
            "voice_external_tool_global_voice_user_confirmed=\(voiceAttempt.externalToolGlobalVoiceUserConfirmed)",
            "voice_external_tool_microphone_observable=false",
            "voice_external_tool_microphone_user_confirmed=\(voiceAttempt.externalToolMicrophoneUserConfirmed)",
            "voice_external_tool_expected_microphone=\(voiceAttempt.audioDelivery.outputAtStart.selectedDeviceKind.rawValue)",
            "voice_external_tool_next_checks=trigger_mode_matches_fn,global_voice_enabled_if_required,microphone_matches_selected_device,voice_input_enabled,session_duration_sufficient",
            "voice_audio_generation=\(voiceAttempt.audioDelivery.generation)",
            "voice_audio_source=\(voiceAttempt.audioDelivery.source)",
            "voice_audio_route=\(voiceAttempt.audioDelivery.route.rawValue)",
            "voice_audio_delivery_result=\(voiceAttempt.audioDelivery.result.rawValue)",
            "voice_audio_received_batches=\(voiceAttempt.audioDelivery.receivedBatches)",
            "voice_audio_received_samples=\(voiceAttempt.audioDelivery.receivedSamples)",
            "voice_audio_enqueue_failures=\(voiceAttempt.audioDelivery.enqueueFailures)",
            "voice_audio_selected_device=\(voiceAttempt.audioDelivery.outputAtStart.selectedDeviceKind.rawValue)",
            "voice_audio_actual_device_at_start=\(voiceAttempt.audioDelivery.outputAtStart.actualDeviceKind.rawValue)",
            "voice_audio_bound_at_start=\(Self.optionalBoolean(voiceAttempt.audioDelivery.outputAtStart.boundToSelectedDevice))",
            "voice_audio_engine_running_at_start=\(voiceAttempt.audioDelivery.outputAtStart.engineRunning)",
            "voice_audio_player_playing_at_start=\(voiceAttempt.audioDelivery.outputAtStart.playerPlaying)",
            "voice_audio_actual_device_at_observation=\(voiceAttempt.audioDelivery.outputAtObservation.actualDeviceKind.rawValue)",
            "voice_audio_bound_at_observation=\(Self.optionalBoolean(voiceAttempt.audioDelivery.outputAtObservation.boundToSelectedDevice))",
            "voice_audio_scheduled_buffers=\(voiceAttempt.audioDelivery.scheduledBuffers)",
            "voice_audio_scheduled_samples=\(voiceAttempt.audioDelivery.scheduledSamples)",
            "voice_audio_played_buffers=\(voiceAttempt.audioDelivery.playedBuffers)",
            "voice_audio_played_samples=\(voiceAttempt.audioDelivery.playedSamples)",
            "voice_audio_interrupted_buffers=\(voiceAttempt.audioDelivery.interruptedBuffers)",
            "voice_audio_interrupted_samples=\(voiceAttempt.audioDelivery.interruptedSamples)",
            "voice_audio_pending_buffers=\(voiceAttempt.audioDelivery.outputAtObservation.pendingBuffers)",
            "voice_audio_pending_samples=\(voiceAttempt.audioDelivery.outputAtObservation.pendingSamples)",
            "voice_terminal_result=\(voiceAttempt.result.rawValue)",
            "voice_observed_failure=\(voiceAttempt.result.observedFailure)",
            "voice_probable_cause=\(voiceAttempt.probableCause)",
            "voice_probable_cause_confirmed=\(voiceAttempt.probableCauseConfirmed)",
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

    private static func optionalBoolean(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func stableToken(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." || $0 == "_"
        }
        let token = String(String.UnicodeScalarView(allowed))
        return token.isEmpty ? "unknown" : token
    }

    private static var systemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname("kern.osversion", bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static var runningUnderRosetta: String {
        if let translated = sysctlInt32("sysctl.proc_translated") {
            return translated == 1 ? "true" : "false"
        }
        return hardwareArchitecture == "arm64" || hardwareArchitecture == "x86_64"
            ? "false"
            : "unknown"
    }

    private static var hardwareArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        if sysctlInt32("hw.optional.arm64") == 1 {
            return "arm64"
        }
        return "x86_64"
        #endif
    }

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
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
