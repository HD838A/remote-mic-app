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

    @Test func glowWarningStartTracksContinuationThresholdOnlyInFollowMode() throws {
        let suite = "VoiceContinuationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceGlowDisplayMode == .lastTenSeconds)
        #expect(settings.voiceGlowWarningStart == 50)
        #expect(settings.voiceGlowThresholdStartSeconds == nil)

        settings.voiceFnTapModeEnabled = true
        settings.voiceContinuationEnabled = true
        settings.setVoiceContinuationMinimumDuration(30)
        #expect(settings.voiceGlowThresholdStartSeconds == 30)
        // In fixed last-10-seconds mode, warning stays at 50s regardless of continuation threshold.
        #expect(settings.voiceGlowWarningStart == 50)

        // Switching to follow-threshold mode tracks the active threshold (including 0s).
        settings.voiceGlowDisplayMode = .followContinuationThreshold
        #expect(settings.voiceGlowWarningStart == 30)
        #expect(AppSettings(defaults: defaults).voiceGlowDisplayMode == .followContinuationThreshold)

        settings.setVoiceContinuationMinimumDuration(-10)
        #expect(settings.voiceContinuationMinimumDuration == 0)
        #expect(settings.voiceGlowWarningStart == 0)
        #expect(settings.voiceGlowThresholdStartSeconds == 0)

        settings.setVoiceContinuationMinimumDuration(80)
        #expect(settings.voiceContinuationMinimumDuration == 60)
        #expect(settings.voiceGlowWarningStart == 50)
        #expect(settings.voiceGlowThresholdStartSeconds == nil)

        // Legacy full-session persistence migrates cleanly when display mode key is absent.
        let legacySuite = "VoiceContinuationSettingsTests.Legacy.\(UUID().uuidString)"
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(true, forKey: "voiceGlowFullSession")
        let migrated = AppSettings(defaults: legacyDefaults)
        #expect(migrated.voiceGlowDisplayMode == .fullSession)
        #expect(migrated.voiceGlowFullSession)
    }

    @Test func hardwareSessionLimitApplicabilityTargetsXiaomiRemotesOnly() {
        #expect(VoiceHardwareSessionLimitApplicability.hasHardwareLimit(model: .rc001))
        #expect(VoiceHardwareSessionLimitApplicability.hasHardwareLimit(model: .rc003))
        #expect(!VoiceHardwareSessionLimitApplicability.hasHardwareLimit(model: .appleSiriRemoteA2854))
        #expect(!VoiceHardwareSessionLimitApplicability.hasHardwareLimit(model: .appleSiriRemoteA2540))
        #expect(!VoiceHardwareSessionLimitApplicability.hasHardwareLimit(model: .chromecastVoiceRemote))
        #expect(!VoiceHardwareSessionLimitApplicability.hasHardwareLimit(model: .unknown))

        #expect(VoiceHardwareSessionLimitApplicability.isApplicable(model: .rc001))
        #expect(VoiceHardwareSessionLimitApplicability.isApplicable(model: .rc003))
        #expect(VoiceHardwareSessionLimitApplicability.isApplicable(model: nil))
        #expect(VoiceHardwareSessionLimitApplicability.isApplicable(model: .unknown))
        #expect(!VoiceHardwareSessionLimitApplicability.isApplicable(model: .appleSiriRemoteA2854))
        #expect(!VoiceHardwareSessionLimitApplicability.isApplicable(model: .appleSiriRemoteA2540))
        #expect(!VoiceHardwareSessionLimitApplicability.isApplicable(model: .chromecastVoiceRemote))
    }
}
