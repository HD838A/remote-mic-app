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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "RemoteMic",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
