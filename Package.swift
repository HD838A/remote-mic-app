// swift-tools-version: 6.2
import Foundation
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
]
var remoteMicDependencies: [Target.Dependency] = [
    "AudioExceptionGuard",
    .product(name: "Sparkle", package: "Sparkle"),
]
var remoteMicTestDependencies: [Target.Dependency] = ["RemoteMic"]
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
        .testTarget(
            name: "RemoteMicTests",
            dependencies: remoteMicTestDependencies,
            path: "Tests/RemoteMicTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
