import Foundation

public enum AppleRemoteHCIConstants {
    public static let machServiceName = "com.hd838a.SayAll.AppleRemoteHCIService"
    public static let serviceVersion = 1
    public static let expectedTeamIdentifier = "L3QHLDRPAY"
    public static let expectedClientIdentifier = "com.hd838a.RemoteMic"
}

public struct AppleRemoteHCILeaseState {
    public private(set) var activeLeaseCount = 0

    public init() {}

    public mutating func acquire(enable: () throws -> Void) rethrows {
        if activeLeaseCount == 0 {
            try enable()
        }
        activeLeaseCount += 1
    }

    public mutating func release(restore: () throws -> Void) rethrows {
        guard activeLeaseCount > 0 else { return }
        if activeLeaseCount == 1 {
            try restore()
            activeLeaseCount = 0
        } else {
            activeLeaseCount -= 1
        }
    }
}

public enum AppleRemoteHCIConfigurationError: Error, Equatable {
    case malformedPreferences
    case missingOriginalPreferences
}

public enum AppleRemoteHCIRestoreAction: Equatable {
    case none
    case write(Data)
    case moveCurrentPreferencesToTrash
}

public enum AppleRemoteHCITraceConfiguration {
    public static let requiredTraceKeys = [
        "StackDebugEnabled", "HCILiveTraces", "HCIFileTraces",
        "RawAudioTrace", "HIDTrace", "HCISkipAuth",
    ]

    public static func enabledPreferencesData(from originalData: Data?) throws -> Data {
        var preferences = try preferences(from: originalData)
        preferences["HCITraces"] = Dictionary(
            uniqueKeysWithValues: requiredTraceKeys.map { ($0, true) }
        )
        return try serialized(preferences)
    }

    public static func restoreAction(
        originalPlistPresent: Bool,
        originalPlistData: Data?,
        currentPlistData: Data?
    ) throws -> AppleRemoteHCIRestoreAction {
        if originalPlistPresent {
            guard let originalPlistData else {
                throw AppleRemoteHCIConfigurationError.missingOriginalPreferences
            }
            return .write(originalPlistData)
        }
        guard let currentPlistData else { return .none }
        var currentPreferences = try preferences(from: currentPlistData)
        currentPreferences.removeValue(forKey: "HCITraces")
        if currentPreferences.isEmpty {
            return .moveCurrentPreferencesToTrash
        }
        return .write(try serialized(currentPreferences))
    }

    private static func preferences(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ), let preferences = root as? [String: Any] else {
            throw AppleRemoteHCIConfigurationError.malformedPreferences
        }
        return preferences
    }

    private static func serialized(_ preferences: [String: Any]) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: preferences,
                format: .binary,
                options: 0
            )
        } catch {
            throw AppleRemoteHCIConfigurationError.malformedPreferences
        }
    }
}

@objc public protocol AppleRemoteHCIServiceProtocol {
    func prepareConfiguration(reply: @escaping (Bool, String) -> Void)
    func sealAuthorizationRight(reply: @escaping (Bool, String) -> Void)
    func releaseConfiguration(reply: @escaping (Bool, String) -> Void)
}
