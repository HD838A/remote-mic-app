import Foundation

enum AppLinks {
    struct FeedbackDiagnostics {
        enum Architecture: String, Equatable {
            case arm64
            case x86_64
            case unknown
        }

        enum BluetoothPermission: String, Equatable {
            case allowed
            case denied
            case restricted
            case notDetermined = "not_determined"
            case unknown
        }

        let appVersion: String
        let appBuild: String
        let macOSVersion: OperatingSystemVersion
        let architecture: Architecture
        let bluetoothPermission: BluetoothPermission
        let inputMonitoringPermission: Bool
        let accessibilityPermission: Bool
        let physicalRemoteConnected: Bool
        let phoneRemoteConnected: Bool
        let watchRemoteConnected: Bool
        let webRemoteConnected: Bool
        let audioDeviceSelected: Bool
        let audioDeviceAvailable: Bool
        let audioOutputReady: Bool
        let audioStreaming: Bool
        let buttonMappingEnabled: Bool
        let buttonPermissionReady: Bool
        let buttonObserved: Bool
        let logAvailable: Bool

        static var currentArchitecture: Architecture {
            #if arch(arm64)
            .arm64
            #elseif arch(x86_64)
            .x86_64
            #else
            .unknown
            #endif
        }
    }

    static let githubRepository = URL(
        string: "https://github.com/HD838A/remote-mic-app"
    )!
    static let chineseWebsite = URL(string: "https://sayall.app/")!
    static let englishWebsite = URL(string: "https://sayall.app/en/")!
    static let testFlightPublicBeta = URL(
        string: "https://testflight.apple.com/join/J8k8fb7v"
    )!
    private static let feedbackEntry = URL(
        string: "https://my.sayall.app/api/guest-entry?source=mac"
    )!
    static let doubaoInputMethod = URL(
        string: "https://shurufa.doubao.com/?from=sayall.app"
    )!

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }

    static func feedback(diagnostics: FeedbackDiagnostics) -> URL {
        var components = URLComponents(
            url: feedbackEntry,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "source", value: "mac"),
            URLQueryItem(name: "context_version", value: "1"),
            URLQueryItem(name: "app_version", value: stableToken(diagnostics.appVersion)),
            URLQueryItem(name: "app_build", value: stableToken(diagnostics.appBuild)),
            URLQueryItem(name: "macos_version", value: macOSVersion(diagnostics.macOSVersion)),
            URLQueryItem(name: "architecture", value: diagnostics.architecture.rawValue),
            URLQueryItem(
                name: "permission_bluetooth",
                value: diagnostics.bluetoothPermission.rawValue
            ),
            booleanQueryItem(
                name: "permission_input_monitoring",
                value: diagnostics.inputMonitoringPermission
            ),
            booleanQueryItem(
                name: "permission_accessibility",
                value: diagnostics.accessibilityPermission
            ),
            booleanQueryItem(
                name: "physical_remote_connected",
                value: diagnostics.physicalRemoteConnected
            ),
            booleanQueryItem(
                name: "phone_remote_connected",
                value: diagnostics.phoneRemoteConnected
            ),
            booleanQueryItem(
                name: "watch_remote_connected",
                value: diagnostics.watchRemoteConnected
            ),
            booleanQueryItem(
                name: "web_remote_connected",
                value: diagnostics.webRemoteConnected
            ),
            booleanQueryItem(
                name: "audio_device_selected",
                value: diagnostics.audioDeviceSelected
            ),
            booleanQueryItem(
                name: "audio_device_available",
                value: diagnostics.audioDeviceAvailable
            ),
            booleanQueryItem(
                name: "audio_output_ready",
                value: diagnostics.audioOutputReady
            ),
            booleanQueryItem(
                name: "audio_streaming",
                value: diagnostics.audioStreaming
            ),
            booleanQueryItem(
                name: "button_mapping_enabled",
                value: diagnostics.buttonMappingEnabled
            ),
            booleanQueryItem(
                name: "button_permission_ready",
                value: diagnostics.buttonPermissionReady
            ),
            booleanQueryItem(
                name: "button_observed",
                value: diagnostics.buttonObserved
            ),
            booleanQueryItem(name: "log_available", value: diagnostics.logAvailable),
        ]
        return components.url!
    }

    private static func booleanQueryItem(
        name: String,
        value: Bool
    ) -> URLQueryItem {
        URLQueryItem(name: name, value: value ? "true" : "false")
    }

    private static func macOSVersion(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func stableToken(_ value: String) -> String {
        let token = value.unicodeScalars.prefix(40).map { scalar -> Character in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        }
        return token.isEmpty ? "unknown" : String(token)
    }
}
