// swift-tools-version: 6.2
import Foundation
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
]
let privateSwiftPMEnabled = ProcessInfo.processInfo.environment[
    "SAYALL_ENABLE_PRIVATE_SWIFTPM"
] == "1"
let privatePlatformPackage = "sayall-private-platform"
let privatePlatformPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH"
]
var remoteMicDependencies: [Target.Dependency] = [
    "AudioExceptionGuard",
    "AppleRemoteSupport",
    "AppleRemoteAudioCore",
    "AppleRemoteHCIProtocol",
    "AppleRemotePacketLogger",
    "SayAllMCPKit",
    .product(name: "Sparkle", package: "Sparkle"),
]
var remoteMicTestDependencies: [Target.Dependency] = [
    "RemoteMic",
    "AppleRemoteAudioCore",
    "AppleRemotePacketLogger",
]
var packageTargets: [Target] = []
let macRemotePackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_MAC_REMOTE_PACKAGE_PATH"
]
let macRemoteEnabled = privateSwiftPMEnabled || !(macRemotePackagePath ?? "").isEmpty
if privateSwiftPMEnabled {
    if let privatePlatformPackagePath, !privatePlatformPackagePath.isEmpty {
        packageDependencies.append(.package(path: privatePlatformPackagePath))
    } else {
        fatalError(
            "SAYALL_ENABLE_PRIVATE_SWIFTPM requires SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH"
        )
    }
    remoteMicDependencies.append(
        .product(name: "SayAllMacRemoteCore", package: privatePlatformPackage)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllMacRemoteUI", package: privatePlatformPackage)
    )
    remoteMicTestDependencies.append(
        .product(name: "SayAllMacRemoteCore", package: privatePlatformPackage)
    )
} else if let macRemotePackagePath, !macRemotePackagePath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: macRemotePackagePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: macRemotePackagePath))
    remoteMicDependencies.append(
        .product(name: "SayAllMacRemoteCore", package: packageIdentity)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllMacRemoteUI", package: packageIdentity)
    )
    remoteMicTestDependencies.append(
        .product(name: "SayAllMacRemoteCore", package: packageIdentity)
    )
} else {
    remoteMicDependencies += ["SayAllMacRemoteCore", "SayAllMacRemoteUI"]
    remoteMicTestDependencies.append("SayAllMacRemoteCore")
    packageTargets += [
        .target(
            name: "SayAllMacRemoteCore",
            path: "Sources/PublicRemoteCompatibility/Core"
        ),
        .target(
            name: "SayAllMacRemoteUI",
            dependencies: ["SayAllMacRemoteCore"],
            path: "Sources/PublicRemoteCompatibility/UI"
        ),
    ]
}
let siriRemotePackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_SIRI_REMOTE_PACKAGE_PATH"
]
let siriRemoteExplicitlyEnabled = ProcessInfo.processInfo.environment[
    "SAYALL_ENABLE_SIRI_REMOTE"
] == "1"
let siriRemoteEnabled = privateSwiftPMEnabled || siriRemoteExplicitlyEnabled ||
    !(siriRemotePackagePath ?? "").isEmpty
if siriRemoteExplicitlyEnabled && (siriRemotePackagePath ?? "").isEmpty && !privateSwiftPMEnabled {
    fatalError("SAYALL_ENABLE_SIRI_REMOTE=1 requires SAYALL_SIRI_REMOTE_PACKAGE_PATH")
}
let privateChromecastEnabled = privateSwiftPMEnabled &&
    ProcessInfo.processInfo.environment["SAYALL_ENABLE_CHROMECAST"] == "1"
let privateButtonProfilesEnabled = privateSwiftPMEnabled &&
    ProcessInfo.processInfo.environment["SAYALL_ENABLE_BUTTON_PROFILES"] == "1"
let privateArtifactPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH"
]
let chromecastPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_CHROMECAST_PACKAGE_PATH"
]
let combinationActionsPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_COMBINATION_ACTIONS_PATH"
]
let buttonProfilesPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_BUTTON_PROFILES_PACKAGE_PATH"
]
if privateSwiftPMEnabled {
    let sourcePaths = [
        combinationActionsPackagePath,
        buttonProfilesPackagePath,
        macRemotePackagePath,
        siriRemotePackagePath,
        chromecastPackagePath,
        privateArtifactPackagePath,
    ]
    if sourcePaths.contains(where: { !($0 ?? "").isEmpty }) {
        fatalError("SAYALL_ENABLE_PRIVATE_SWIFTPM cannot be combined with local private package paths")
    }
}
let sourceMacroCapabilitiesAvailable = privateSwiftPMEnabled ||
    (combinationActionsPackagePath.map {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: $0)
                .appendingPathComponent("Sources/SayAllMacroRemoteMic/RemoteMicRemoteCapabilities.swift")
                .path
        )
    } ?? false)
let privateArtifactsAvailable = !(privateArtifactPackagePath ?? "").isEmpty
let unifiedButtonConfigurationAvailable = privateSwiftPMEnabled || privateArtifactsAvailable || (combinationActionsPackagePath.map {
    FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0)
        .appendingPathComponent("Sources/SayAllMacroRemoteMic/UnifiedButtonConfiguration.swift").path)
} ?? false)
let macroCapabilitiesAvailable = sourceMacroCapabilitiesAvailable || privateArtifactsAvailable
let sourceMacroInputFocusAvailable = privateSwiftPMEnabled ||
    (combinationActionsPackagePath.map {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0)
            .appendingPathComponent("Sources/SayAllMacroRemoteMic/RemoteMicInputFocuser.swift").path)
    } ?? false)
let artifactMacroInputFocusAvailable = privateArtifactPackagePath.map { path in
    ["arm64", "x86_64"].allSatisfy { architecture in
        let interface = URL(fileURLWithPath: path)
            .appendingPathComponent("Artifacts/SayAllMacroRemoteMic.xcframework/macos-arm64_x86_64/SayAllMacroRemoteMic.framework/Modules/SayAllMacroRemoteMic.swiftmodule/\(architecture)-apple-macos.swiftinterface")
        return (try? String(contentsOf: interface, encoding: .utf8))?
            .contains("public typealias RemoteMicInputFocuser =") == true
    }
} ?? false
let macroInputFocusAvailable = sourceMacroInputFocusAvailable || artifactMacroInputFocusAvailable
let sourceMacroHostShortcutsAvailable = [combinationActionsPackagePath, privateSwiftPMEnabled ? privatePlatformPackagePath.map {
    URL(fileURLWithPath: $0).appendingPathComponent("packages/macos-combination-actions").path
} : nil]
    .compactMap { $0 }.contains { path in
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path)
            .appendingPathComponent("Sources/SayAllMacroRemoteMic/RemoteMicKeyboardShortcutPerformer.swift").path)
    }
let artifactMacroHostShortcutsAvailable = privateArtifactPackagePath.map { path in
    ["arm64", "x86_64"].allSatisfy { architecture in
        let interface = URL(fileURLWithPath: path)
            .appendingPathComponent("Artifacts/SayAllMacroRemoteMic.xcframework/macos-arm64_x86_64/SayAllMacroRemoteMic.framework/Modules/SayAllMacroRemoteMic.swiftmodule/\(architecture)-apple-macos.swiftinterface")
        return (try? String(contentsOf: interface, encoding: .utf8))?
            .contains("public typealias RemoteMicKeyboardShortcutPerformer =") == true
    }
} ?? false
// Probe optional interfaces so older local packages remain buildable.
func artifactSupportsAuthorizedAccess(module: String, decision: String) -> Bool {
    guard let privateArtifactPackagePath, !privateArtifactPackagePath.isEmpty else { return false }
    return ["arm64", "x86_64"].allSatisfy { architecture in
        let interface = URL(fileURLWithPath: privateArtifactPackagePath)
            .appendingPathComponent("Artifacts/\(module).xcframework/macos-arm64_x86_64/\(module).framework/Modules/\(module).swiftmodule/\(architecture)-apple-macos.swiftinterface")
        guard let source = try? String(contentsOf: interface, encoding: .utf8),
              let declaration = source.range(of: "public enum \(decision) "),
              let end = source.range(of: "\n}", range: declaration.upperBound..<source.endIndex) else { return false }
        return source[declaration.upperBound..<end.lowerBound].contains("case authorized")
    }
}
let membershipAuthorizedAccessAvailable = artifactSupportsAuthorizedAccess(module: "SayAllMembershipHostAdapter", decision: "MembershipHostButtonProfilesAccessDecision")
let profilesAuthorizedAccessAvailable = artifactSupportsAuthorizedAccess(module: "SayAllButtonProfiles", decision: "ButtonProfilesAccessDecision") ||
    [buttonProfilesPackagePath, privateSwiftPMEnabled ? privatePlatformPackagePath.map {
        URL(fileURLWithPath: $0).appendingPathComponent("packages/macos-button-profiles").path
    } : nil].compactMap { $0 }.contains { path in
        let source = URL(fileURLWithPath: path)
            .appendingPathComponent("Sources/SayAllButtonProfiles/ButtonProfilesAccessDecision.swift")
        return (try? String(contentsOf: source, encoding: .utf8))?.contains("case authorized") == true
    }
let buttonProfilesTestAccessEnabled = ProcessInfo.processInfo.environment[
    "SAYALL_TEST_BUTTON_PROFILES_FREE"
] == "1"
if buttonProfilesTestAccessEnabled && (buttonProfilesPackagePath ?? "").isEmpty {
    fatalError("free button profile test access requires the source button profiles package")
}
if buttonProfilesTestAccessEnabled && privateArtifactsAvailable {
    fatalError("free button profile test access excludes private membership artifacts")
}
let chromecastEnabled = privateChromecastEnabled || !(chromecastPackagePath ?? "").isEmpty
let macOSPlatform: SupportedPlatform = ProcessInfo.processInfo.environment["RELEASE_VARIANT"] == "intel"
    ? .macOS(.v13)
    : .macOS(.v14)
var remoteMicSwiftSettings: [SwiftSetting] = []
if membershipAuthorizedAccessAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_MEMBERSHIP_AUTHORIZED_ACCESS"))
}
if profilesAuthorizedAccessAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_PROFILES_AUTHORIZED_ACCESS"))
}
if siriRemoteEnabled {
    remoteMicSwiftSettings.append(.define("SAYALL_SIRI_REMOTE_ENABLED"))
}
if chromecastEnabled {
    remoteMicSwiftSettings.append(.define("SAYALL_CHROMECAST_ENABLED"))
}
if macRemoteEnabled {
    remoteMicSwiftSettings.append(.define("SAYALL_MAC_REMOTE_ENABLED"))
}
if macroCapabilitiesAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_MACRO_REMOTE_CAPABILITIES"))
}
if macroInputFocusAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_MACRO_INPUT_FOCUS"))
}
if sourceMacroHostShortcutsAvailable || artifactMacroHostShortcutsAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_MACRO_HOST_SHORTCUTS"))
}
if buttonProfilesTestAccessEnabled {
    remoteMicSwiftSettings.append(.define("SAYALL_TEST_BUTTON_PROFILES_FREE"))
}
if unifiedButtonConfigurationAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_UNIFIED_BUTTON_CONFIGURATION"))
}
var remoteMicLinkerSettings: [LinkerSetting] = []
if privateArtifactsAvailable { remoteMicLinkerSettings.append(.unsafeFlags(["-Xlinker", "-ObjC"])) }

var remoteMicTestSwiftSettings: [SwiftSetting] = []
if sourceMacroHostShortcutsAvailable || artifactMacroHostShortcutsAvailable {
    remoteMicTestSwiftSettings.append(.define("SAYALL_MACRO_HOST_SHORTCUTS"))
}
if unifiedButtonConfigurationAvailable {
    remoteMicTestSwiftSettings.append(.define("SAYALL_UNIFIED_BUTTON_CONFIGURATION"))
}
if siriRemoteEnabled {
    remoteMicTestSwiftSettings.append(.define("SAYALL_SIRI_REMOTE_ENABLED"))
}
if chromecastEnabled {
    remoteMicTestSwiftSettings.append(.define("SAYALL_CHROMECAST_ENABLED"))
}
if macRemoteEnabled {
    remoteMicTestSwiftSettings.append(.define("SAYALL_MAC_REMOTE_ENABLED"))
}

if let privateFeaturePath = ProcessInfo.processInfo.environment[
    "SAYALL_AI_PACKAGE_PATH"
], !privateFeaturePath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: privateFeaturePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: privateFeaturePath))
    remoteMicDependencies.append(
        .product(name: "SayAllAI", package: packageIdentity)
    )
}

if privateSwiftPMEnabled {
    remoteMicDependencies.append(
        .product(name: "SayAllMacroRemoteMic", package: privatePlatformPackage)
    )
    if privateButtonProfilesEnabled {
        remoteMicDependencies.append(
            .product(name: "SayAllButtonProfiles", package: privatePlatformPackage)
        )
    }
    remoteMicDependencies.append(
        .product(name: "SayAllMembershipHostAdapter", package: privatePlatformPackage)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllDiagnosticsTransport", package: privatePlatformPackage)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllSiriRemote", package: privatePlatformPackage)
    )
    remoteMicTestDependencies.append(
        .product(name: "SayAllMacroRemoteMic", package: privatePlatformPackage)
    )
    if privateButtonProfilesEnabled {
        remoteMicTestDependencies.append(
            .product(name: "SayAllButtonProfiles", package: privatePlatformPackage)
        )
    }
    remoteMicTestDependencies.append(
        .product(name: "SayAllSiriRemote", package: privatePlatformPackage)
    )
    if privateChromecastEnabled {
        remoteMicDependencies.append(
            .product(name: "SayAllChromecast", package: privatePlatformPackage)
        )
        remoteMicTestDependencies.append(
            .product(name: "SayAllChromecast", package: privatePlatformPackage)
        )
    }
}

if let siriRemotePath = siriRemotePackagePath, !siriRemotePath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: siriRemotePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: siriRemotePath))
    remoteMicDependencies.append(
        .product(name: "SayAllSiriRemote", package: packageIdentity)
    )
    // 测试目标同样要能引用私有包：能力与型号自报做跨仓一致性校验
    // （见 Tests/RemoteMicTests/SiriCapabilityContractTests.swift）。
    remoteMicTestDependencies.append(
        .product(name: "SayAllSiriRemote", package: packageIdentity)
    )
}

if let chromecastPath = chromecastPackagePath, !chromecastPath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: chromecastPath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: chromecastPath))
    remoteMicDependencies.append(
        .product(name: "SayAllChromecast", package: packageIdentity)
    )
    // 测试目标也要能引用私有包：能力矩阵要与型号自报的能力声明做跨仓一致性校验
    // （见 Tests/RemoteMicTests/ChromecastCapabilityContractTests.swift）。
    remoteMicTestDependencies.append(
        .product(name: "SayAllChromecast", package: packageIdentity)
    )
}


if let combinationActionsPath = combinationActionsPackagePath, !combinationActionsPath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: combinationActionsPath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: combinationActionsPath))
    remoteMicDependencies.append(
        .product(name: "SayAllMacroRemoteMic", package: packageIdentity)
    )
}

if let buttonProfilesPath = buttonProfilesPackagePath,
   !buttonProfilesPath.isEmpty,
   (privateArtifactPackagePath ?? "").isEmpty {
    guard !(combinationActionsPackagePath ?? "").isEmpty else {
        fatalError("SAYALL_BUTTON_PROFILES_PACKAGE_PATH requires SAYALL_COMBINATION_ACTIONS_PATH")
    }
    let packageIdentity = URL(fileURLWithPath: buttonProfilesPath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: buttonProfilesPath))
    remoteMicDependencies.append(
        .product(name: "SayAllButtonProfiles", package: packageIdentity)
    )
}

let unsupportedMembershipSourceVariables = [
    "SAYALL_MEMBERSHIP_PACKAGE_PATH",
    "SAYALL_MEMBERSHIP_ADAPTER_PACKAGE_PATH",
]
if unsupportedMembershipSourceVariables.contains(where: {
    !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
}) {
    fatalError(
        "membership source packages are not supported; " +
            "use SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH"
    )
}

if let privateArtifactPackagePath, !privateArtifactPackagePath.isEmpty {
    let sourcePackageVariables = [
        "SAYALL_COMBINATION_ACTIONS_PATH",
        "SAYALL_BUTTON_PROFILES_PACKAGE_PATH",
    ]
    if sourcePackageVariables.contains(where: {
        !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
    }) {
        fatalError("private artifacts cannot be combined with private source packages")
    }
    let packageIdentity = URL(fileURLWithPath: privateArtifactPackagePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: privateArtifactPackagePath))
    remoteMicDependencies.append(
        .product(name: "SayAllMembershipHostAdapter", package: packageIdentity)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllDiagnosticsTransport", package: packageIdentity)
    )
    remoteMicSwiftSettings.append(.define("SAYALL_MEMBERSHIP_ENABLED"))
    remoteMicSwiftSettings.append(.define("SAYALL_DIAGNOSTICS_ENABLED"))
    remoteMicDependencies.append(.product(name: "SayAllMacroRemoteMic", package: packageIdentity))
    remoteMicDependencies.append(
        .product(name: "SayAllButtonProfiles", package: packageIdentity)
    )
}

if let hardwareSimulationPath = ProcessInfo.processInfo.environment[
    "REMOTE_MIC_HARDWARE_SIMULATION_PATH"
], !hardwareSimulationPath.isEmpty {
    packageDependencies.append(.package(path: hardwareSimulationPath))
    remoteMicTestDependencies.append(
        .product(name: "HardwareSimulation", package: "hardware-simulation")
    )
    remoteMicTestDependencies.append(
        .product(name: "XiaomiVoiceRemoteSimulation", package: "hardware-simulation")
    )
}

let package = Package(
    name: "RemoteMic",
    platforms: [macOSPlatform],
    products: [
        .executable(
            name: "RemoteMic",
            targets: ["RemoteMic"]
        ),
        .executable(
            name: "SayAllMCP",
            targets: ["SayAllMCP"]
        ),
        .executable(
            name: "AppleRemoteHCIService",
            targets: ["AppleRemoteHCIService"]
        ),
    ],
    dependencies: packageDependencies,
    targets: packageTargets + [
        .executableTarget(
            name: "RemoteMic",
            dependencies: remoteMicDependencies,
            path: "Sources/RemoteMic",
            swiftSettings: remoteMicSwiftSettings,
            linkerSettings: remoteMicLinkerSettings + [
                .linkedFramework("Network"),
            ]
        ),
        .target(
            name: "AudioExceptionGuard",
            path: "Sources/AudioExceptionGuard",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AppleRemoteSupport",
            path: "Sources/AppleRemoteSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "AppleRemoteAudioCore",
            path: "Sources/AppleRemoteAudioCore"
        ),
        .target(
            name: "AppleRemoteHCIProtocol",
            path: "Sources/AppleRemoteHCIProtocol"
        ),
        .target(
            name: "AppleRemotePacketLogger",
            dependencies: ["AppleRemoteAudioCore", "AppleRemoteHCIProtocol"],
            path: "Sources/AppleRemoteAudioCapture",
            exclude: ["AppleRemoteVoiceController.swift", "main.swift"],
            sources: ["SayAllBTPacketLoggerClient.swift"],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AppleRemoteAudioCapture",
            dependencies: ["AppleRemoteAudioCore", "AppleRemotePacketLogger"],
            path: "Sources/AppleRemoteAudioCapture",
            exclude: ["SayAllBTPacketLoggerClient.swift"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AppleRemoteHCIService",
            dependencies: ["AppleRemoteHCIProtocol"],
            path: "Sources/AppleRemoteHCIService",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "SayAllMCPKit",
            path: "Sources/SayAllMCPKit"
        ),
        .executableTarget(
            name: "SayAllMCP",
            dependencies: ["SayAllMCPKit"],
            path: "Sources/SayAllMCP"
        ),
        .testTarget(
            name: "RemoteMicTests",
            dependencies: remoteMicTestDependencies + ["SayAllMCPKit", "AppleRemoteHCIProtocol"],
            path: "Tests/RemoteMicTests",
            exclude: macRemoteEnabled ? [] : ["WatchBluetoothVoiceJourneyTests.swift"],
            swiftSettings: remoteMicTestSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
