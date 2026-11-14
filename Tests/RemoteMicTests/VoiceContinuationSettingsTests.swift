import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice continuation settings")
struct VoiceContinuationSettingsTests {
    @Test func defaultsToOneSecondAndPersistsSelectedDelay() throws {
        let suite = "VoiceContinuationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.voiceContinuationEnabled)
        #expect(settings.voiceContinuationDelay == 1)
        settings.setVoiceContinuationDelay(0.5)
        #expect(AppSettings(defaults: defaults).voiceContinuationDelay == 0.5)
        settings.setVoiceContinuationDelay(3)
        #expect(AppSettings(defaults: defaults).voiceContinuationDelay == 3)
    }

    @Test func limitsDelayToSupportedRange() throws {
        let suite = "VoiceContinuationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setVoiceContinuationDelay(0)
        #expect(settings.voiceContinuationDelay == 0.5)
        settings.setVoiceContinuationDelay(4)
        #expect(settings.voiceContinuationDelay == 3)
    }
}
