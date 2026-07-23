// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemoteMic",
    platforms: [.macOS(.v26)],
    products: [
        .executable(
            name: "RemoteMic",
            targets: ["RemoteMic"]
        )
    ],
    targets: [
        .executableTarget(
            name: "RemoteMic",
            path: "Sources/RemoteMic"
        ),
        .testTarget(
            name: "RemoteMicTests",
            dependencies: ["RemoteMic"],
            path: "Tests/RemoteMicTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
