import CryptoKit
import Foundation

/// A deliberately small, typed event format used by the user-initiated Sentry
/// diagnostic path. It is independent from the encrypted local log file.
struct PublicDiagnosticEvent: Equatable {
    static let schemaVersion = 1

    let operationID: String
    let component: String
    let action: String
    let phase: String
    let result: String
    let reason: String
    let errorDomain: String?
    let errorCode: Int?
    let retryable: Bool?
    let elapsedMS: Int?
    let count: Int?
    let bytes: Int?
    let samples: Int?
    let receivedSamples: Int?
    let scheduledSamples: Int?
    let playedSamples: Int?
    let interruptedSamples: Int?
    let pendingSamples: Int?
    let failureCount: Int?
    let source: String?
    let remoteModelFamily: String?
    let audioDeviceKind: String?
    let voiceTool: String?
    let buildChannel: String?
    let capabilitySignature: String?
    let appVersion: String?
    let appBuild: String?
    let osMajor: String?
    let cpuArchitecture: String?
    let appLanguage: String?

    init?(
        operationID: String = PublicDiagnosticEvent.newOperationID(),
        component: String,
        action: String,
        phase: String,
        result: String,
        reason: String = "none",
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        retryable: Bool? = nil,
        elapsedMS: Int? = nil,
        count: Int? = nil,
        bytes: Int? = nil,
        samples: Int? = nil,
        receivedSamples: Int? = nil,
        scheduledSamples: Int? = nil,
        playedSamples: Int? = nil,
        interruptedSamples: Int? = nil,
        pendingSamples: Int? = nil,
        failureCount: Int? = nil,
        source: String? = nil,
        remoteModelFamily: String? = nil,
        audioDeviceKind: String? = nil,
        voiceTool: String? = nil,
        buildChannel: String? = nil,
        capabilitySignature: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        osMajor: String? = nil,
        cpuArchitecture: String? = nil,
        appLanguage: String? = nil
    ) {
        let required = [operationID, component, action, phase, result, reason]
        guard required.allSatisfy(Self.isSafeToken),
              Self.isSafeToken(errorDomain),
              Self.isSafeToken(source),
              Self.isSafeToken(remoteModelFamily),
              Self.isSafeToken(audioDeviceKind),
              Self.isSafeToken(voiceTool),
              Self.isSafeToken(buildChannel),
              Self.isSafeVersionToken(appVersion),
              Self.isSafeVersionToken(appBuild),
              Self.isSafeToken(osMajor),
              Self.isSafeToken(cpuArchitecture),
              Self.isSafeToken(appLanguage),
              Self.isSafeCapabilitySignature(capabilitySignature),
              Self.isSafeInteger(errorCode),
              Self.isSafeInteger(elapsedMS),
              Self.isSafeInteger(count),
              Self.isSafeInteger(bytes),
              Self.isSafeInteger(samples),
              Self.isSafeInteger(receivedSamples),
              Self.isSafeInteger(scheduledSamples),
              Self.isSafeInteger(playedSamples),
              Self.isSafeInteger(interruptedSamples),
              Self.isSafeInteger(pendingSamples),
              Self.isSafeInteger(failureCount)
        else { return nil }

        self.operationID = operationID
        self.component = component
        self.action = action
        self.phase = phase
        self.result = result
        self.reason = reason
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.retryable = retryable
        self.elapsedMS = elapsedMS
        self.count = count
        self.bytes = bytes
        self.samples = samples
        self.receivedSamples = receivedSamples
        self.scheduledSamples = scheduledSamples
        self.playedSamples = playedSamples
        self.interruptedSamples = interruptedSamples
        self.pendingSamples = pendingSamples
        self.failureCount = failureCount
        self.source = source
        self.remoteModelFamily = remoteModelFamily
        self.audioDeviceKind = audioDeviceKind
        self.voiceTool = voiceTool
        self.buildChannel = buildChannel
        self.capabilitySignature = capabilitySignature
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osMajor = osMajor
        self.cpuArchitecture = cpuArchitecture
        self.appLanguage = appLanguage
    }

    var canonicalLine: String {
        var fields = [
            "PUBLIC_EVENT",
            "schema_version=\(Self.schemaVersion)",
            "operation_id=\(operationID)",
            "component=\(component)",
            "action=\(action)",
            "phase=\(phase)",
            "result=\(result)",
            "reason=\(reason)",
        ]
        append("error_domain", errorDomain, to: &fields)
        append("error_code", errorCode, to: &fields)
        append("retryable", retryable, to: &fields)
        append("elapsed_ms", elapsedMS, to: &fields)
        append("count", count, to: &fields)
        append("bytes", bytes, to: &fields)
        append("samples", samples, to: &fields)
        append("received_samples", receivedSamples, to: &fields)
        append("scheduled_samples", scheduledSamples, to: &fields)
        append("played_samples", playedSamples, to: &fields)
        append("interrupted_samples", interruptedSamples, to: &fields)
        append("pending_samples", pendingSamples, to: &fields)
        append("failure_count", failureCount, to: &fields)
        append("source", source, to: &fields)
        append("remote_model_family", remoteModelFamily, to: &fields)
        append("audio_device_kind", audioDeviceKind, to: &fields)
        append("voice_tool", voiceTool, to: &fields)
        append("build_channel", buildChannel, to: &fields)
        append("capability_signature", capabilitySignature, to: &fields)
        append("app_version", appVersion, to: &fields)
        append("app_build", appBuild, to: &fields)
        append("os_major", osMajor, to: &fields)
        append("cpu_architecture", cpuArchitecture, to: &fields)
        append("app_language", appLanguage, to: &fields)
        return fields.joined(separator: " ")
    }

    var isApprovedForUpload: Bool {
        guard Self.approvedSources.contains(source),
              Self.approvedRemoteModelFamilies.contains(remoteModelFamily),
              Self.approvedAudioDeviceKinds.contains(audioDeviceKind),
              Self.approvedVoiceTools.contains(voiceTool),
              errorDomain == nil,
              errorCode == nil
        else { return false }

        let transition = "\(phase)|\(result)|\(reason)"
        switch (component, action) {
        case ("settings", "load"):
            let categories = ["remote_profiles", "button_mapping", "custom_apps", "usage", "onboarding", "other"]
            let failures = ["data_corrupted", "key_missing", "type_mismatch", "value_missing", "unknown"]
            let approvedFailure = categories.contains { category in
                failures.contains { reason == "\(category)_\($0)" }
            }
            return source == "app" && remoteModelFamily == nil && audioDeviceKind == nil &&
                voiceTool == nil && !hasEnvironmentFields && !hasOperationalMetrics &&
                ((phase == "failed" && result == "defaults_applied" && approvedFailure) ||
                 (phase == "completed" && result == "loaded" && categories.contains(reason)))
        case ("environment", "snapshot"):
            return transition == "completed|observed|app_launch" &&
                source == nil && remoteModelFamily == nil &&
                audioDeviceKind != nil && voiceTool != nil &&
                buildChannel != nil && capabilitySignature != nil &&
                appVersion != nil && appBuild != nil && osMajor != nil &&
                cpuArchitecture != nil && appLanguage != nil &&
                !hasOperationalMetrics
        case ("permission", "input_monitoring"),
             ("permission", "accessibility"):
            return Self.permissionTransitions.contains(transition) &&
                source == "app" && remoteModelFamily == nil &&
                audioDeviceKind == nil && voiceTool == nil &&
                !hasEnvironmentFields && !hasOperationalMetrics
        case ("remote", "connection"):
            return Self.remoteConnectionTransitions.contains(transition) &&
                source == "bluetooth" && remoteModelFamily == "xiaomi" &&
                audioDeviceKind == nil && voiceTool == nil &&
                !hasEnvironmentFields && !hasOperationalMetrics
        case ("audio", "configure"):
            return Self.audioConfigureTransitions.contains(transition) &&
                source == "app" && remoteModelFamily == nil &&
                audioDeviceKind != nil && voiceTool == nil &&
                !hasEnvironmentFields && !hasOperationalMetrics
        case ("voice", "session"):
            return Self.voiceSessionTransitions.contains(transition) &&
                Self.isApprovedVoiceSource(source, remoteModelFamily: remoteModelFamily) &&
                audioDeviceKind != nil && voiceTool != nil &&
                !hasEnvironmentFields
        case ("onboarding", "voice_test"):
            return Self.onboardingVoiceTransitions.contains(transition) &&
                source == "onboarding" && remoteModelFamily == nil &&
                audioDeviceKind != nil && voiceTool != nil &&
                !hasEnvironmentFields
        default:
            return false
        }
    }

    private var hasEnvironmentFields: Bool {
        buildChannel != nil || capabilitySignature != nil || appVersion != nil ||
            appBuild != nil || osMajor != nil || cpuArchitecture != nil || appLanguage != nil
    }

    private var hasOperationalMetrics: Bool {
        retryable != nil || elapsedMS != nil || count != nil || bytes != nil || samples != nil ||
            receivedSamples != nil || scheduledSamples != nil || playedSamples != nil ||
            interruptedSamples != nil || pendingSamples != nil || failureCount != nil
    }

    static func parse(_ line: String) -> PublicDiagnosticEvent? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.first == "PUBLIC_EVENT", fields.count >= 7 else { return nil }

        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard Self.allowedKeys.contains(key), values[key] == nil else { return nil }
            values[key] = String(parts[1])
        }

        guard values["schema_version"] == String(Self.schemaVersion),
              let operationID = values["operation_id"],
              let component = values["component"],
              let action = values["action"],
              let phase = values["phase"],
              let result = values["result"],
              let reason = values["reason"],
              let event = PublicDiagnosticEvent(
                  operationID: operationID,
                  component: component,
                  action: action,
                  phase: phase,
                  result: result,
                  reason: reason,
                  errorDomain: values["error_domain"],
                  errorCode: Self.intValue(values["error_code"]),
                  retryable: Self.boolValue(values["retryable"]),
                  elapsedMS: Self.intValue(values["elapsed_ms"]),
                  count: Self.intValue(values["count"]),
                  bytes: Self.intValue(values["bytes"]),
                  samples: Self.intValue(values["samples"]),
                  receivedSamples: Self.intValue(values["received_samples"]),
                  scheduledSamples: Self.intValue(values["scheduled_samples"]),
                  playedSamples: Self.intValue(values["played_samples"]),
                  interruptedSamples: Self.intValue(values["interrupted_samples"]),
                  pendingSamples: Self.intValue(values["pending_samples"]),
                  failureCount: Self.intValue(values["failure_count"]),
                  source: values["source"],
                  remoteModelFamily: values["remote_model_family"],
                  audioDeviceKind: values["audio_device_kind"],
                  voiceTool: values["voice_tool"],
                  buildChannel: values["build_channel"],
                  capabilitySignature: values["capability_signature"],
                  appVersion: values["app_version"],
                  appBuild: values["app_build"],
                  osMajor: values["os_major"],
                  cpuArchitecture: values["cpu_architecture"],
                  appLanguage: values["app_language"]
              )
        else { return nil }

        guard event.canonicalLine == line else { return nil }
        return event
    }

    static func capabilitySignature(_ capabilities: [String]) -> String {
        let material = capabilities.sorted().joined(separator: ",")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let allowedKeys: Set<String> = [
        "schema_version", "operation_id", "component", "action", "phase", "result", "reason",
        "error_domain", "error_code", "retryable", "elapsed_ms", "count", "bytes", "samples",
        "received_samples", "scheduled_samples", "played_samples", "interrupted_samples",
        "pending_samples", "failure_count", "source",
        "remote_model_family", "audio_device_kind", "voice_tool", "build_channel",
        "capability_signature", "app_version", "app_build", "os_major", "cpu_architecture",
        "app_language",
    ]

    private static let approvedSources: Set<String?> = [
        nil, "app", "bluetooth", "iphone", "watch", "web", "chromecast", "onboarding",
    ]
    private static let approvedRemoteModelFamilies: Set<String?> = [
        nil, "unknown", "xiaomi", "apple_remote", "chromecast",
    ]
    private static let approvedAudioDeviceKinds: Set<String?> = [
        nil, "not_configured", "sayall_virtual", "miremotev_2ch", "blackhole",
        "blackhole_2ch", "other", "unavailable",
    ]
    private static let approvedVoiceTools: Set<String?> = [
        nil, "unselected", "doubao", "weixin", "typeless", "other",
    ]

    private static let permissionTransitions: Set<String> = [
        "observed|granted|status_changed",
        "observed|denied|status_changed",
    ]

    private static let remoteConnectionTransitions: Set<String> = [
        "stopped|stopped|bridge_stopped",
        "failed|unavailable|bluetooth_unavailable",
        "started|pending|scanning",
        "started|pending|connecting",
        "started|pending|discovering",
        "completed|connected|ready",
        "started|pending|reconnecting",
        "failed|failed|bridge_failed",
    ]

    private static let audioConfigureTransitions: Set<String> = [
        "completed|ready|voice_start",
        "completed|failed|voice_start",
        "completed|ready|test_tone",
        "completed|failed|test_tone",
        "completed|ready|startup",
        "completed|failed|startup",
        "completed|ready|recovery",
        "completed|failed|recovery",
    ]

    private static let voiceSessionTransitions: Set<String> = [
        "started|accepted|voice_start",
        "started|accepted|voice_start_retry",
        "started|accepted|trigger_observed",
        "started|resumed|rapid_repress",
        "rejected|duplicate|duplicate_start",
        "rejected|busy|another_session_active",
        "rejected|busy|busy",
        "rejected|inactive|stop_without_active_session",
        "rejected|failed|voice_key_not_neutralized",
        "rejected|failed|audio_output_unavailable",
        "rejected|failed|voice_key_press_failed",
        "failed|failed|audio_output_unavailable",
        "failed|failed|voice_key_press_failed",
        "failed|failed|audio_capture_retry_exhausted",
        "failed|failed|no_samples",
        "failed|failed|audio_enqueue_failed",
        "failed|failed|playback_interrupted",
        "failed|failed|audio_incomplete",
        "completed|passed|released",
        "completed|passed|voice_stop",
        "completed|passed|voice_stopped",
        "completed|passed|hold_release",
        "completed|passed|toggle_second_tap",
        "completed|passed|host_stop",
        "completed|passed|cancelled.link_unavailable",
        "completed|passed|app_stop",
        "completed|passed|device_disconnected",
        "completed|passed|session_stopped",
    ]

    private static let onboardingVoiceTransitions: Set<String> = [
        "completed|passed|passed",
        "completed|failed|input_target_not_ready",
        "completed|failed|input_target_focus_lost",
        "completed|failed|audio_delivery_failed",
        "completed|failed|no_samples",
        "completed|failed|manual_input",
        "completed|failed|external_tool_no_commit",
    ]

    private static func isApprovedVoiceSource(
        _ source: String?,
        remoteModelFamily: String?
    ) -> Bool {
        switch source {
        case "bluetooth":
            return remoteModelFamily == "xiaomi" || remoteModelFamily == "apple_remote"
        case "chromecast":
            return remoteModelFamily == "chromecast"
        case "iphone", "watch", "web":
            return remoteModelFamily == nil
        default:
            return false
        }
    }

    private static func newOperationID() -> String {
        String(UUID().uuidString.filter { $0 != "-" }.prefix(12)).lowercased()
    }

    private static func isSafeToken(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value.count <= 64 else { return false }
        let lowered = value.lowercased()
        let forbiddenMarkers = [
            "email", "token", "secret", "password", "cookie", "order", "payment", "checkout",
            "bundle", "package", "path", "uuid", "serial", "hostname", "localizeddescription",
        ]
        guard !forbiddenMarkers.contains(where: { lowered.contains($0) }) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }

    private static func isSafeVersionToken(_ value: String?) -> Bool {
        isSafeToken(value)
    }

    private static func isSafeInteger(_ value: Int?) -> Bool {
        guard let value else { return true }
        return value >= 0 && value <= 10_000_000_000
    }

    private static func isSafeCapabilitySignature(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.count == 64 && value.allSatisfy { $0.isHexDigit && ($0.isLowercase || $0.isNumber) }
    }

    private static func intValue(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value), isSafeInteger(parsed) else { return nil }
        return parsed
    }

    private static func boolValue(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func append<T>(_ key: String, _ value: T?, to fields: inout [String]) {
        guard let value else { return }
        fields.append("\(key)=\(value)")
    }
}

protocol PublicDiagnosticEventSink: AnyObject {
    func record(_ event: PublicDiagnosticEvent)
}
