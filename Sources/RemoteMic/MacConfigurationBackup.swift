import Foundation

/// A complete Mac backup is deliberately not a marketplace sharing package.
/// Older readers reject its format before interpreting any configuration.
struct MacConfigurationBackup {
    static let format = "sayall-macos-configuration"
    static let maximumBytes = 32 * 1024 * 1024
    let host: Data
    let components: Data?

    func encoded(version: String, build: String) throws -> Data {
        var object: [String: Any] = [
            "format": Self.format, "schemaVersion": 1, "type": "personalBackup",
            "product": "SayAll", "platform": "macOS",
            "source": ["version": version, "build": build],
            "requirements": ["reader": "sayall-macos-configuration/1", "platform": "macOS",
                "minimumAppVersion": "2.0.0"],
            "configuration": try JSONSerialization.jsonObject(with: host)
        ]
        if let components { object["components"] = try JSONSerialization.jsonObject(with: components) }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= Self.maximumBytes else { throw AppConfigurationError.invalidValues }
        return data
    }

    static func decode(_ data: Data, platform: String = "macOS", version: String = "2.0.0") throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == format,
              object["schemaVersion"] as? Int == 1,
              object["type"] as? String == "personalBackup",
              object["product"] as? String == "SayAll",
              object["platform"] as? String == platform, platform == "macOS",
              let source = object["source"] as? [String: String],
              source["version"]?.isEmpty == false, source["build"]?.isEmpty == false,
              let requirements = object["requirements"] as? [String: String],
              requirements["reader"] == "sayall-macos-configuration/1",
              requirements["platform"] == platform,
              requirements["minimumAppVersion"] == "2.0.0",
              version.compare("2.0.0", options: .numeric) != .orderedAscending,
              let host = object["configuration"] as? [String: Any]
        else { throw AppConfigurationError.unsupportedVersion }
        return try .init(host: JSONSerialization.data(withJSONObject: host, options: [.sortedKeys]),
            components: object["components"].map {
                try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            })
    }

    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { throw AppConfigurationError.invalidValues }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw AppConfigurationError.invalidValues }
        return data
    }
}

enum ConfigurationImportDestination: Equatable {
    case settings
    case buttonProfiles

    static func detect(_ data: Data) throws -> Self {
        guard data.count <= MacConfigurationBackup.maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AppConfigurationError.invalidValues }
        if object["format"] as? String == MacConfigurationBackup.format { return .settings }
        guard object["format"] as? String == "sayall-transfer" else { throw AppConfigurationError.invalidValues }
        switch object["type"] as? String {
        case "personalBackup", "macro", "application": return .settings
        case "buttonProfile": return .buttonProfiles
        default: throw AppConfigurationError.invalidValues
        }
    }
}

/// Explicit preference list. Account, pairing, history, permissions and diagnostic state are not settings.
struct CompleteConfigurationPreferences: Codable {
    var remoteDeviceProfiles: [RemoteDeviceProfile]
    var selectedRemoteProfileID: UUID?
    var chromecastAllowSystemReservedKeys: Bool
    var chromecastSystemReservedExceptions: [String]
    var chromecastEnabled: Bool
    var chromecastVoiceMode: ChromecastVoiceMode
    var siriRemoteScrollArrowReversed: Bool
    var siriRemoteEnabled: Bool
    var siriRemoteNeedsUserAction: Bool
    var localTranscriptHistoryEnabled: Bool
    var localOriginalAudioRecordingEnabled: Bool
    var voiceTool: OnboardingVoiceTool?
}
