import Foundation
import Testing
@testable import RemoteMic

struct RemoteSleepConnectionSettingsTests {
    @Test func optInIsMachineLocalAndDefaultsOff() throws {
        let name = "RemoteSleepConnectionPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.sleepConnectionIsolationTarget == nil)
        let remote = UUID()
        settings.sleepConnectionIsolationTarget = remote
        #expect(AppSettings(defaults: defaults).sleepConnectionIsolationTarget == remote)
        settings.sleepConnectionIsolationTarget = nil
        #expect(AppSettings(defaults: defaults).sleepConnectionIsolationTarget == nil)
    }
}
