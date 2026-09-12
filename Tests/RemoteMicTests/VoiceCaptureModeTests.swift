import Foundation
import Testing
@testable import RemoteMic

/// The voice key can be a pure trigger: pressing it emits only the trigger key while the
/// remote's audio is never captured or routed, so a dictation tool can listen on the Mac's
/// own microphone. These tests drive the real settings and the real voice-start delegate
/// callbacks; Fn mode is used so no Accessibility-gated injection runs in the test process.
@Suite("Voice key capture mode")
struct VoiceCaptureModeTests {
    private func isolatedSettings(_ label: String) throws -> (AppSettings, UserDefaults, () -> Void) {
        let suiteName = "VoiceCaptureModeTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (
            AppSettings(defaults: defaults),
            defaults,
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    @MainActor
    private static func bridge(
        _ identifier: UUID,
        settings: AppSettings,
        delegate: BridgeAppModel
    ) -> XiaomiBluetoothBridge {
        XiaomiBluetoothBridge(settings: settings, delegate: delegate, targetIdentifier: identifier)
    }

    @Test func captureDefaultsOnAndPersistsAcrossReloads() throws {
        let (settings, defaults, cleanup) = try isolatedSettings("defaults")
        defer { cleanup() }

        #expect(settings.voiceKeyUsesRemoteMicrophone)
        #expect(settings.effectiveVoiceFnTapModeEnabled == settings.voiceFnTapModeEnabled)

        settings.voiceKeyUsesRemoteMicrophone = false
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.voiceKeyUsesRemoteMicrophone)
    }

    @Test func legacyConfigurationWithoutTheFieldKeepsCaptureOnAndRoundTrips() throws {
        let (source, _, cleanupSource) = try isolatedSettings("legacySource")
        defer { cleanupSource() }
        source.voiceKeyUsesRemoteMicrophone = false
        var json = try #require(
            JSONSerialization.jsonObject(with: try source.exportedConfigurationData())
                as? [String: Any]
        )
        #expect(json["voiceKeyUsesRemoteMicrophone"] as? Bool == false)

        // A legacy export carries no such field: capture must stay on, the historical default.
        json.removeValue(forKey: "voiceKeyUsesRemoteMicrophone")
        let (legacyTarget, _, cleanupLegacy) = try isolatedSettings("legacyTarget")
        defer { cleanupLegacy() }
        try legacyTarget.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )
        #expect(legacyTarget.voiceKeyUsesRemoteMicrophone)

        // And a current export round-trips the off state.
        json["voiceKeyUsesRemoteMicrophone"] = false
        let (roundTripTarget, _, cleanupRoundTrip) = try isolatedSettings("roundTripTarget")
        defer { cleanupRoundTrip() }
        try roundTripTarget.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )
        #expect(!roundTripTarget.voiceKeyUsesRemoteMicrophone)
    }

    @Test func fnTapPreferenceIsGatedAtRuntimeNotErasedWhenCaptureIsOff() throws {
        let (settings, _, cleanup) = try isolatedSettings("fnTapGate")
        defer { cleanup() }
        settings.voiceFnTapModeEnabled = true

        settings.voiceKeyUsesRemoteMicrophone = false

        #expect(!settings.effectiveVoiceFnTapModeEnabled)
        // The preference itself survives, so re-enabling capture brings Fn tap back without
        // the user flipping anything.
        #expect(settings.voiceFnTapModeEnabled)

        settings.voiceKeyUsesRemoteMicrophone = true
        #expect(settings.effectiveVoiceFnTapModeEnabled)
    }

    @MainActor
    @Test func pureTriggerStartEmitsNoAudioSessionEvenWithoutAnAudioOutput() throws {
        let (settings, _, cleanup) = try isolatedSettings("pureTrigger")
        defer { cleanup() }
        // No audio device is selected: the capture path would reject this start with
        // rejected_audio_output. The whole point of pure-trigger mode is that it still works,
        // because nothing needs a virtual audio output.
        #expect(settings.selectedAudioDeviceUID.isEmpty)
        settings.voiceKeyUsesRemoteMicrophone = false
        let model = BridgeAppModel(settings: settings)
        let bridge = Self.bridge(UUID(), settings: settings, delegate: model)

        model.bluetoothBridge(bridge, didChange: .ready("小米蓝牙语音遥控器"))
        model.bluetoothBridgeDidStartVoice(bridge)

        #expect(model.voiceTriggerOnlyActive)
        #expect(!model.isStreaming)
    }

    @MainActor
    @Test func pureTriggerIgnoresRemoteAudioAndStopResetsForTheNextPress() throws {
        let (settings, _, cleanup) = try isolatedSettings("pureTriggerStop")
        defer { cleanup() }
        settings.voiceKeyUsesRemoteMicrophone = false
        let model = BridgeAppModel(settings: settings)
        let bridge = Self.bridge(UUID(), settings: settings, delegate: model)

        model.bluetoothBridge(bridge, didChange: .ready("小米蓝牙语音遥控器"))
        model.bluetoothBridgeDidStartVoice(bridge)
        #expect(model.voiceTriggerOnlyActive)

        // The remote keeps streaming so STREAM_STOP can mark the release; the audio itself
        // must never become a voice session.
        model.bluetoothBridge(bridge, didDecode: [Int16](repeating: 1, count: 160))
        #expect(!model.isStreaming)

        model.bluetoothBridgeDidStopVoice(bridge)
        #expect(!model.voiceTriggerOnlyActive)

        // The next press starts fresh.
        model.bluetoothBridgeDidStartVoice(bridge)
        #expect(model.voiceTriggerOnlyActive)
        model.bluetoothBridgeDidStopVoice(bridge)
        #expect(!model.voiceTriggerOnlyActive)
    }

    @MainActor
    @Test func captureOnKeepsTheHistoricalAudioPath() throws {
        let (settings, _, cleanup) = try isolatedSettings("captureOn")
        defer { cleanup() }
        let model = BridgeAppModel(settings: settings)
        let bridge = Self.bridge(UUID(), settings: settings, delegate: model)

        model.bluetoothBridge(bridge, didChange: .ready("小米蓝牙语音遥控器"))
        model.bluetoothBridgeDidStartVoice(bridge)

        // Default behavior is untouched: capture on never enters the pure-trigger state,
        // and with no audio output selected the start is rejected as before.
        #expect(!model.voiceTriggerOnlyActive)
        #expect(!model.isStreaming)
    }

    @MainActor
    @Test func fnTapToggleKeepsThePreferenceUnarmedWhileCaptureIsOff() throws {
        let (settings, _, cleanup) = try isolatedSettings("fnTapSetter")
        defer { cleanup() }
        settings.voiceKeyUsesRemoteMicrophone = false
        let model = BridgeAppModel(settings: settings)

        model.setVoiceFnTapModeEnabled(true)

        #expect(settings.voiceFnTapModeEnabled)
        #expect(!settings.effectiveVoiceFnTapModeEnabled)

        // Turning capture back on lets the same toggle arm through the normal path; this only
        // asserts the gate released, not the Accessibility-dependent arming itself.
        model.setVoiceKeyCapturesRemoteMicrophone(true)
        #expect(settings.effectiveVoiceFnTapModeEnabled)
    }

    @MainActor
    @Test func captureSetterPersistsAndIsIdempotent() throws {
        let (settings, defaults, cleanup) = try isolatedSettings("captureSetter")
        defer { cleanup() }
        let model = BridgeAppModel(settings: settings)

        model.setVoiceKeyCapturesRemoteMicrophone(false)
        #expect(!settings.voiceKeyUsesRemoteMicrophone)
        #expect(!AppSettings(defaults: defaults).voiceKeyUsesRemoteMicrophone)

        model.setVoiceKeyCapturesRemoteMicrophone(false)
        #expect(!settings.voiceKeyUsesRemoteMicrophone)

        model.setVoiceKeyCapturesRemoteMicrophone(true)
        #expect(settings.voiceKeyUsesRemoteMicrophone)
    }
}
