// swift-tools-version: 6.2
import Foundation
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
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
]
var packageTargets: [Target] = []
let macRemotePackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_MAC_REMOTE_PACKAGE_PATH"
]
let macRemoteEnabled = !(macRemotePackagePath ?? "").isEmpty
if let macRemotePackagePath, !macRemotePackagePath.isEmpty {
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
let siriRemoteEnabled = siriRemoteExplicitlyEnabled ||
    !(siriRemotePackagePath ?? "").isEmpty
if siriRemoteExplicitlyEnabled && (siriRemotePackagePath ?? "").isEmpty {
    fatalError("SAYALL_ENABLE_SIRI_REMOTE=1 requires SAYALL_SIRI_REMOTE_PACKAGE_PATH")
}
let privateArtifactPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH"
]
let macroPlatformPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_MACRO_PLATFORM_PATH"
]
let macroCapabilitiesAvailable = macroPlatformPackagePath.map {
    FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: $0)
            .appendingPathComponent("Sources/SayAllMacroRemoteMic/RemoteMicRemoteCapabilities.swift")
            .path
    )
} ?? false
let macOSPlatform: SupportedPlatform = ProcessInfo.processInfo.environment["RELEASE_VARIANT"] == "intel"
    ? .macOS(.v13)
    : .macOS(.v14)
var remoteMicSwiftSettings: [SwiftSetting] = []
if siriRemoteEnabled {
    remoteMicSwiftSettings.append(.define("SAYALL_SIRI_REMOTE_ENABLED"))
}
if macRemoteEnabled {
    remoteMicSwiftSettings.append(.define("SAYALL_MAC_REMOTE_ENABLED"))
}
if macroCapabilitiesAvailable {
    remoteMicSwiftSettings.append(.define("SAYALL_MACRO_REMOTE_CAPABILITIES"))
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

if let siriRemotePath = siriRemotePackagePath, !siriRemotePath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: siriRemotePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: siriRemotePath))
    remoteMicDependencies.append(
        .product(name: "SayAllSiriRemote", package: packageIdentity)
    )
}

if let macroPlatformPath = macroPlatformPackagePath, !macroPlatformPath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: macroPlatformPath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: macroPlatformPath))
    remoteMicDependencies.append(
        .product(name: "SayAllMacroRemoteMic", package: packageIdentity)
    )
}

if let membershipPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_MEMBERSHIP_PACKAGE_PATH"
], !membershipPackagePath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: membershipPackagePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: membershipPackagePath))
    remoteMicDependencies.append(
        .product(name: "SayAllMembershipCore", package: packageIdentity)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllMembershipUI", package: packageIdentity)
    )
}

if let privateArtifactPackagePath, !privateArtifactPackagePath.isEmpty {
    let sourcePackageVariables = [
        "SAYALL_MACRO_PLATFORM_PATH",
        "SAYALL_MEMBERSHIP_PACKAGE_PATH",
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
        .product(name: "SayAllMembershipCore", package: packageIdentity)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllMembershipUI", package: packageIdentity)
    )
    remoteMicDependencies.append(
        .product(name: "SayAllMacroRemoteMic", package: packageIdentity)
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
            linkerSettings: [
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
            swiftSettings: siriRemoteEnabled
                ? [.define("SAYALL_SIRI_REMOTE_ENABLED")]
                : []
        ),
    ],
    swiftLanguageModes: [.v5]
)
