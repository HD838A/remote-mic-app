import Foundation
import Testing
@testable import RemoteMic

@Suite("Configuration file drop")
struct ConfigurationFileDropTests {
    @Test func acceptsSayAllAndJSONFileURLsCaseInsensitively() {
        for name in [
            "configuration.sayall",
            "configuration.json",
            "configuration.SAYALL",
            "configuration.JSON",
            "configuration.sayall.json",
        ] {
            #expect(
                ConfigurationFileDropPolicy.accepts(
                    URL(fileURLWithPath: "/Users/test/\(name)")
                ),
                "\(name) must be accepted"
            )
        }
    }

    @Test func rejectsNonFileURLsAndOtherExtensions() {
        #expect(!ConfigurationFileDropPolicy.accepts(
            URL(string: "sayall://launch/profile.sayall")!
        ))
        #expect(!ConfigurationFileDropPolicy.accepts(
            URL(fileURLWithPath: "/Users/test/configuration.txt")
        ))
        #expect(!ConfigurationFileDropPolicy.accepts(
            URL(fileURLWithPath: "/Users/test/configuration")
        ))
        #expect(!ConfigurationFileDropPolicy.accepts(
            URL(fileURLWithPath: "/Users/test")
        ))
    }

    @Test func loadsAFileURLFromADroppedProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SayAllDropProviderTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let url = directory.appendingPathComponent("configuration.sayall")
        try Data("{}".utf8).write(to: url)
        let provider = try #require(NSItemProvider(contentsOf: url))

        let loaded = await ConfigurationFileDropLoader.fileURL(from: provider)

        #expect(loaded?.standardizedFileURL == url.standardizedFileURL)
    }
}
