import Foundation

/// Test-only UserDefaults that removes its on-disk plist when the suite is cleaned up.
///
/// `removePersistentDomain(forName:)` clears the in-memory domain but does not delete
/// the corresponding plist in `~/Library/Preferences`. Repeated test runs therefore
/// accumulated hundreds of thousands of test plists and eventually broke `cfprefsd`
/// for the real app. Every test suite must be created through this class so the
/// file is removed on cleanup, with an exit sweep as a safety net for missed cleanup.
final class TestUserDefaults: UserDefaults {
    private static let lock = NSLock()
    private static var registeredSuites = Set<String>()
    private static let registerExitCleanup: Void = {
        atexit { TestUserDefaults.cleanupAll() }
    }()

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        super.init(suiteName: suiteName)
        _ = Self.registerExitCleanup
        Self.lock.lock()
        Self.registeredSuites.insert(suiteName)
        Self.lock.unlock()
    }

    /// Isolated test suites only need in-process readback; force a real sync so
    /// cfprefsd does not recreate a deleted plist after the test process exits.
    override func synchronize() -> Bool {
        _ = super.synchronize()
        return true
    }

    override func removePersistentDomain(forName domainName: String) {
        super.removePersistentDomain(forName: domainName)
        _ = super.synchronize()
        Self.removePlist(for: domainName)
        // Keep the suite registered so the exit sweep also deletes a plist that
        // cfprefsd writes after this immediate cleanup.
    }

    static func cleanupForTesting(_ suiteName: String) {
        lock.lock()
        registeredSuites.remove(suiteName)
        lock.unlock()
        removePlist(for: suiteName)
    }

    private static func removePlist(for suiteName: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: url)
    }

    private static func cleanupAll() {
        Thread.sleep(forTimeInterval: 1)
        lock.lock()
        let suites = registeredSuites
        registeredSuites.removeAll()
        lock.unlock()
        for suite in suites { removePlist(for: suite) }
    }
}
