import Foundation
import Testing

@Suite("Test preference cleanup")
struct TestUserDefaultsTests {
    @Test func persistentDomainCleanupRemovesOnDiskPlist() throws {
        let suite = "RemoteMicTests.TestUserDefaults.cleanup.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { TestUserDefaults.cleanupForTesting(suite) }
        let url = plistURL(for: suite)
        try Data("dummy".utf8).write(to: url)

        defaults.removePersistentDomain(forName: suite)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func registeredSuiteCleanupRemovesOnDiskPlist() throws {
        let suite = "RemoteMicTests.TestUserDefaults.registered.\(UUID().uuidString)"
        _ = try #require(TestUserDefaults(suiteName: suite))
        let url = plistURL(for: suite)
        try Data("dummy".utf8).write(to: url)

        TestUserDefaults.cleanupForTesting(suite)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func plistURL(for suite: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
    }
}
