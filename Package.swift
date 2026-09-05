// swift-tools-version: 6.2
import Foundation
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
    .package(
        url: "https://github.com/GetSayAll/sayall-mac-remote.git",
        revision: "7d1b3c2e1d88913bafaa3a401c939eb218a1f363"
    ),
]
var remoteMicDependencies: [Target.Dependency] = [
    "AudioExceptionGuard",
    "SayAllMCPKit",
    .product(name: "Sparkle", package: "Sparkle"),
    .product(name: "SayAllMacRemoteCore", package: "sayall-mac-remote"),
    .product(name: "SayAllMacRemoteUI", package: "sayall-mac-remote"),
]
var remoteMicTestDependencies: [Target.Dependency] = [
    "RemoteMic",
    .product(name: "SayAllMacRemoteCore", package: "sayall-mac-remote"),
]
let privateArtifactPackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH"
]
let macOSPlatform: SupportedPlatform = ProcessInfo.processInfo.environment["RELEASE_VARIANT"] == "intel"
    ? .macOS(.v13)
    : .macOS(.v14)

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

if let siriRemotePackagePath = ProcessInfo.processInfo.environment[
    "SAYALL_SIRI_REMOTE_PACKAGE_PATH"
], !siriRemotePackagePath.isEmpty {
    let packageIdentity = URL(fileURLWithPath: siriRemotePackagePath)
        .lastPathComponent
        .lowercased()
    packageDependencies.append(.package(path: siriRemotePackagePath))
    remoteMicDependencies.append(
        .product(name: "SayAllSiriRemote", package: packageIdentity)
    )
}

if let macroPlatformPath = ProcessInfo.processInfo.environment[
    "SAYALL_MACRO_PLATFORM_PATH"
], !macroPlatformPath.isEmpty {
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
        )
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "RemoteMic",
            dependencies: remoteMicDependencies,
            path: "Sources/RemoteMic"
        ),
        .target(
            name: "AudioExceptionGuard",
            path: "Sources/AudioExceptionGuard",
            publicHeadersPath: "include"
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
            dependencies: remoteMicTestDependencies + ["SayAllMCPKit"],
            path: "Tests/RemoteMicTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
