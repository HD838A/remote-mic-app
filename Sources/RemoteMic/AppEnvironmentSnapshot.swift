import Darwin
import Foundation

struct AppEnvironmentSnapshot: Equatable {
    let operatingSystemVersion: String
    let macModel: String
    let appVersion: String
    let appBuild: String
    let systemLanguage: String
    let appLanguage: String
    let microphoneGainDB: Double
    let microphoneOutputConfigured: Bool
    let microphoneOutputKind: String
    let customMappingEnabled: Bool
    let voiceFnTapModeEnabled: Bool
    let showDockIcon: Bool
    let openMainWindowAtLaunch: Bool
    let checksForPreReleaseUpdates: Bool
    let continuousRecordingEnabled: Bool
    let onboardingComplete: Bool
    let onboardingVoiceTool: String

    var logMessage: String {
        let microphoneGain = String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            microphoneGainDB
        )
        return [
            "APP ENV",
            "os=\(quoted(operatingSystemVersion))",
            "mac_model=\(quoted(macModel))",
            "app_version=\(quoted(appVersion))",
            "app_build=\(quoted(appBuild))",
            "system_language=\(quoted(systemLanguage))",
            "app_language=\(quoted(appLanguage))",
            "microphone_gain_db=\(microphoneGain)",
            "microphone_output_configured=\(microphoneOutputConfigured)",
            "microphone_output_kind=\(quoted(microphoneOutputKind))",
            "custom_mapping_enabled=\(customMappingEnabled)",
            "voice_fn_tap_enabled=\(voiceFnTapModeEnabled)",
            "dock_icon_visible=\(showDockIcon)",
            "open_main_window_at_launch=\(openMainWindowAtLaunch)",
            "prerelease_updates=\(checksForPreReleaseUpdates)",
            "continuous_recording_enabled=\(continuousRecordingEnabled)",
            "onboarding_complete=\(onboardingComplete)",
            "onboarding_voice_tool=\(quoted(onboardingVoiceTool))",
        ].joined(separator: " ")
    }

    static func current(
        settings: AppSettings,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        preferredLanguages: [String] = Locale.preferredLanguages,
        macModel: String = hardwareModel()
    ) -> AppEnvironmentSnapshot {
        AppEnvironmentSnapshot(
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            macModel: macModel,
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "development",
            systemLanguage: preferredLanguages.first ?? "unknown",
            appLanguage: settings.applicationLanguage.rawValue,
            microphoneGainDB: settings.gainDB,
            microphoneOutputConfigured: !settings.selectedAudioDeviceUID.isEmpty,
            microphoneOutputKind: microphoneOutputKind(for: settings.selectedAudioDeviceUID),
            customMappingEnabled: settings.customMappingEnabled,
            voiceFnTapModeEnabled: settings.voiceFnTapModeEnabled,
            showDockIcon: settings.showDockIcon,
            openMainWindowAtLaunch: settings.openMainWindowAtLaunch,
            checksForPreReleaseUpdates: settings.checksForPreReleaseUpdates,
            continuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled,
            onboardingComplete: settings.isOnboardingComplete,
            onboardingVoiceTool: settings.onboardingVoiceTool.rawValue
        )
    }

    private func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "[\"unknown\"]"
        return String(encoded.dropFirst().dropLast())
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: value)
    }

    private static func microphoneOutputKind(for deviceUID: String) -> String {
        guard !deviceUID.isEmpty else { return "not_configured" }
        if deviceUID == DoubaoAudioDevicePolicy.deviceUID {
            return "sayall_virtual"
        }
        if deviceUID.localizedCaseInsensitiveContains("blackhole") {
            return "blackhole"
        }
        return "other"
    }
}
