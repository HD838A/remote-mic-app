import Foundation

struct AppEnvironmentSnapshot: Equatable {
    let operatingSystemMajor: String
    let cpuArchitecture: String
    let appVersion: String
    let appBuild: String
    let appLanguage: String
    let audioDeviceKind: String
    let voiceTool: String
    let buildChannel: String
    let capabilitySignature: String

    var publicEvent: PublicDiagnosticEvent? {
        PublicDiagnosticEvent(
            component: "environment",
            action: "snapshot",
            phase: "completed",
            result: "observed",
            reason: "app_launch",
            audioDeviceKind: audioDeviceKind,
            voiceTool: voiceTool,
            buildChannel: buildChannel,
            capabilitySignature: capabilitySignature,
            appVersion: appVersion,
            appBuild: appBuild,
            osMajor: operatingSystemMajor,
            cpuArchitecture: cpuArchitecture,
            appLanguage: appLanguage
        )
    }

    static func current(
        settings: AppSettings,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        preferredLanguages _: [String] = Locale.preferredLanguages,
        macModel _: String = ""
    ) -> AppEnvironmentSnapshot {
        let appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development"
        let buildChannel = stableBuildChannel(
            bundle.object(forInfoDictionaryKey: "SayAllBuildChannel") as? String
        )
        let capabilities = ["audio", "bluetooth", "public_key_encrypted_logs"]

        return AppEnvironmentSnapshot(
            operatingSystemMajor: String(processInfo.operatingSystemVersion.majorVersion),
            cpuArchitecture: cpuArchitecture,
            appVersion: stableToken(appVersion),
            appBuild: stableToken(appBuild),
            appLanguage: stableToken(settings.applicationLanguage.rawValue),
            audioDeviceKind: audioDeviceKind(for: settings.selectedAudioDeviceUID),
            voiceTool: stableToken(settings.onboardingVoiceTool.rawValue),
            buildChannel: buildChannel,
            capabilitySignature: PublicDiagnosticEvent.capabilitySignature(capabilities)
        )
    }

    private static var cpuArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func stableBuildChannel(_ value: String?) -> String {
        switch value?.lowercased() {
        case "private": return "private"
        case "beta": return "beta"
        default: return "public"
        }
    }

    private static func stableToken(_ value: String) -> String {
        let token = String(value.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        })
        return token.isEmpty ? "unknown" : String(token.prefix(64))
    }

    static func audioDeviceKind(for deviceUID: String) -> String {
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
