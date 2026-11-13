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

    @Test func glowWarningStartTracksContinuationThresholdWhenEnabled() throws {
        let suite = "VoiceContinuationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceGlowWarningStart == 50)

        settings.setVoiceContinuationMinimumDuration(30)
        #expect(settings.voiceGlowWarningStart == 50)

        settings.voiceFnTapModeEnabled = true
        settings.voiceContinuationEnabled = true
        #expect(settings.voiceGlowWarningStart == 30)

        settings.setVoiceContinuationMinimumDuration(-10)
        #expect(settings.voiceContinuationMinimumDuration == 0)
        #expect(settings.voiceGlowWarningStart == 50)

        settings.setVoiceContinuationMinimumDuration(80)
        #expect(settings.voiceContinuationMinimumDuration == 60)
        #expect(settings.voiceGlowWarningStart == 50)
    }
}
