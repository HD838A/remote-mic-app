import Foundation

/// Removes the plist for a short-lived UserDefaults suite.
///
/// `removePersistentDomain(forName:)` clears the in-memory domain but leaves the
/// suite plist in `~/Library/Preferences`. Screenshot and agent-configuration
/// staging suites are temporary, so they must remove the file as well.
enum TemporaryUserDefaults {
    static func removeSuite(_ suiteName: String) {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else { return }
        let url = library
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(suiteName).plist")
        try? FileManager.default.removeItem(at: url)
    }
}
