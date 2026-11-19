import Foundation
import Testing
@testable import RemoteMic

@Suite("Unified remote card readiness")
struct RemoteDeviceCardStatusTests {
    @Test func greenStatusRequiresEveryApplicableFunctionToBeReady() {
        let states: [RemoteFunctionReadiness] = [.ready, .checking, .failed, .unknown]
        for buttons in states {
            for voice in states {
                let result = RemoteDeviceCardStatus.resolve(connected: true, buttons: buttons, voice: voice, voiceRequired: true)
                #expect((result == .connected) == (buttons == .ready && voice == .ready))
                #expect(RemoteDeviceCardStatus.resolve(connected: false, buttons: buttons, voice: voice, voiceRequired: true) == .disconnected)
            }
        }
    }

    @Test func failuresRemainVisibleDuringOtherFunctionChecks() {
        #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .failed, voice: .unknown, voiceRequired: true) == .buttonsFailed)
        #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .checking, voice: .failed, voiceRequired: true) == .voiceFailed)
        #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .failed, voice: .failed, voiceRequired: true) == .deviceFailed)
        #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .ready, voice: .checking, voiceRequired: true) == .checking)
        #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .unknown, voice: .ready, voiceRequired: true) == .confirming)
    }

    @Test func unpurchasedAppleVoiceIsExcludedButButtonsAreStillChecked() {
        for voice in [RemoteFunctionReadiness.ready, .failed, .checking, .unknown] {
            #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .ready, voice: voice, voiceRequired: false) == .connected)
            #expect(RemoteDeviceCardStatus.resolve(connected: true, buttons: .failed, voice: voice, voiceRequired: false) == .buttonsFailed)
        }
    }

    @Test func audioRecoveryButtonOnlyTargetsAudioOutputVoiceFailures() {
        #expect(RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: false,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "audio.output.selected_unavailable"
        ))
        #expect(RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: false,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "audio.output.start_failed"
        ))

        for status in [
            RemoteDeviceCardStatus.connected,
            .confirming,
            .checking,
            .deviceFailed,
            .disconnected,
        ] {
            #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
                connected: true,
                history: false,
                voiceRequired: true,
                cardStatus: status,
                audioOutputReady: false,
                selectedAudioDeviceUID: "MiRemoteV2ch_UID",
                audioStatusKey: "audio.output.selected_unavailable"
            ))
        }

        #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: false,
            history: false,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "audio.output.selected_unavailable"
        ))
        #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: true,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "audio.output.selected_unavailable"
        ))
        #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: false,
            voiceRequired: false,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "audio.output.selected_unavailable"
        ))
        #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: false,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: true,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "siri_remote.audio.unavailable"
        ))
        #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: false,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "",
            audioStatusKey: "audio.output.selected_unavailable"
        ))
        #expect(!RemoteVoiceRecoveryPolicy.shouldOfferAudioRecovery(
            connected: true,
            history: false,
            voiceRequired: true,
            cardStatus: .voiceFailed,
            audioOutputReady: false,
            selectedAudioDeviceUID: "MiRemoteV2ch_UID",
            audioStatusKey: "audio.output.current_format"
        ))
    }

    @Test func HIDWarningsAndPermissionsAreNotReportedAsHealthy() {
        #expect(RemoteFunctionReadiness.buttons(statusKey: "button_mapping.status.connected") == .ready)
        #expect(RemoteFunctionReadiness.buttons(statusKey: "button_mapping.status.connected_system_actions_may_remain") == .failed)
        #expect(RemoteFunctionReadiness.buttons(statusKey: "button_mapping.error.device_read_failed") == .failed)
        #expect(RemoteFunctionReadiness.buttons(statusKey: "button_mapping.permission.input_monitoring_required") == .failed)
        #expect(RemoteFunctionReadiness.buttons(statusKey: nil) == .unknown)
    }

    @Test func fastReadinessSkipsTransientCheckingAndConfirming() {
        var policy = RemoteCardStatusSettlingPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(policy.observe(.disconnected, at: start).display == .settled(.disconnected))

        let checking = policy.observe(.checking, at: start.addingTimeInterval(0.05))
        #expect(checking.display == .verifyingConnection)
        #expect(checking.refreshAfter != nil)

        let confirming = policy.observe(.confirming, at: start.addingTimeInterval(0.2))
        #expect(confirming.display == .verifyingConnection)

        let connected = policy.observe(.connected, at: start.addingTimeInterval(0.4))
        #expect(connected.display == .settled(.connected))
        #expect(connected.refreshAfter == nil)
    }

    @Test func persistentVerificationAppearsAfterGracePeriod() {
        var policy = RemoteCardStatusSettlingPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        #expect(policy.observe(.checking, at: start).display == .verifyingConnection)
        #expect(policy.observe(.checking, at: start.addingTimeInterval(0.79)).display == .verifyingConnection)

        let settled = policy.observe(.checking, at: start.addingTimeInterval(0.8))
        #expect(settled.display == .settled(.checking))
        #expect(settled.refreshAfter == nil)
    }

    @Test func observedCheckingWindowDoesNotFlashOrange() {
        var policy = RemoteCardStatusSettlingPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 2_500)
        // Longest decrypted 2.0.8 build 404 checking → connected window was 259 ms.
        #expect(policy.observe(.checking, at: start).display == .verifyingConnection)
        #expect(policy.observe(.checking, at: start.addingTimeInterval(0.259)).display == .verifyingConnection)
        #expect(policy.observe(.connected, at: start.addingTimeInterval(0.259)).display == .settled(.connected))
    }

    @Test func shortRecheckKeepsLastVerifiedStatus() {
        var policy = RemoteCardStatusSettlingPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        #expect(policy.observe(.connected, at: start).display == .settled(.connected))
        #expect(policy.observe(.confirming, at: start.addingTimeInterval(1)).display == .settled(.connected))
        #expect(policy.observe(.connected, at: start.addingTimeInterval(1.5)).display == .settled(.connected))

        var persistentPolicy = RemoteCardStatusSettlingPolicy()
        #expect(persistentPolicy.observe(.connected, at: start).display == .settled(.connected))
        #expect(persistentPolicy.observe(.confirming, at: start.addingTimeInterval(1)).display == .settled(.connected))
        let persistent = persistentPolicy.observe(.confirming, at: start.addingTimeInterval(1.8))
        #expect(persistent.display == .settled(.confirming))
    }

    @Test func failuresAndVerifyingStateStayTruthful() {
        var policy = RemoteCardStatusSettlingPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 4_000)
        #expect(policy.observe(.voiceFailed, at: start).display == .settled(.voiceFailed))
        #expect(policy.observe(.confirming, at: start.addingTimeInterval(0.1)).display == .settled(.voiceFailed))
        #expect(RemoteDeviceCardStatusDisplay.verifyingConnection.status == .connected)
        #expect(RemoteDeviceCardStatusDisplay.verifyingConnection.isVerifying)
    }

    @Test func factoryBluetoothNameSurvivesRestartAndUnavailableObservations() throws {
        let suite = "UnifiedRemoteCards.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let id = settings.registerBluetoothRemote(identifier: UUID())
        settings.updateRemoteProfileModel(id, model: .rc003)
        #expect(settings.updateRemoteProfileSystemName(id, name: "小米蓝牙遥控器2 pro"))
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == id })?.customName == "")
        #expect(!settings.updateRemoteProfileSystemName(id, name: nil))
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.remoteDeviceProfiles.first(where: { $0.id == id })?.lastKnownBluetoothName == "小米蓝牙遥控器2 pro")
    }

    @Test func serialMetadataIsNotAddedToDisplayCache() throws {
        let suite = "UnifiedRemoteCards.Serial.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let id = settings.registerAppleSiriRemote(fingerprint: "test-display-cache")
        settings.updateRemoteProfileSystemName(id, name: "电视遥控器")
        settings.updateRemoteProfileSystemName(id, name: "SERIAL-EXAMPLE", serialNumber: "SERIAL-EXAMPLE")
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == id })?.lastKnownBluetoothName == "电视遥控器")
    }

    @Test func oldProfileWithoutNameCacheStillDecodes() throws {
        let mappings = RemoteDeviceMappings(buttonBindings: AppSettings.defaultBindings, buttonShortcuts: [:], secondaryButtonBindings: [:])
        let profile = RemoteDeviceProfile(model: .rc003, customName: "旧设备", mappings: mappings)
        let decoded = try JSONDecoder().decode(RemoteDeviceProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.lastKnownBluetoothName == nil)
        #expect(decoded.customName == "旧设备")
        #expect(decoded.mappings == profile.mappings)
    }

    @Test func voiceRecoveryActionIsWiredThroughTheNarrowPolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let cardSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteDeviceCard.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("let canRecoverVoice = !appleNeedsEnable && model.remoteCardCanRecoverAudio("))
        #expect(settingsSource.contains("voiceRecoveryTitle: canRecoverVoice ? localization.text(\"remote.card.recover_voice\") : nil"))
        #expect(settingsSource.contains("voiceRecoveryHelp: canRecoverVoice ? localization.text(\"remote.card.recover_voice.help\") : nil"))
        #expect(settingsSource.contains("onRecoverVoice: { model.recoverRemoteVoiceAudio() }"))
        #expect(cardSource.contains("if let voiceRecoveryTitle"))
        #expect(cardSource.contains("Button(voiceRecoveryTitle, action: onRecoverVoice)"))
    }

    @Test func readinessDiagnosticSeparatesProfileBindingFromAudioReadiness() {
        let snapshot = RemoteCardReadinessSnapshot(
            status: .confirming,
            model: "rc003",
            connected: true,
            history: true,
            buttons: .unknown,
            buttonReason: "hid_monitor_missing",
            voice: .ready,
            voiceReason: "bluetooth_bridge_ready",
            profileHasHID: false,
            profileHasBluetooth: true,
            hidMonitorPresent: false,
            buttonReadinessCached: false,
            appleConnected: false,
            audioStatusKey: "audio.output.current_format",
            audioReady: true,
            audioSelected: true,
            bridgeState: "ready",
            siriAudioClass: "unknown",
            profileCount: 2,
            connectedProfileCount: 1
        )
        let line = snapshot.diagnosticLine(cardIndex: 0, operationID: 7)
        #expect(line.contains("state=confirming"))
        #expect(line.contains("buttons=unknown"))
        #expect(line.contains("button_reason=hid_monitor_missing"))
        #expect(line.contains("voice=ready"))
        #expect(line.contains("voice_reason=bluetooth_bridge_ready"))
        #expect(line.contains("profile_hid=false"))
        #expect(line.contains("profile_bt=true"))
        #expect(line.contains("hid_monitor=false"))
        #expect(line.contains("audio_ready=true"))
        #expect(line.contains("bridge=ready"))
        #expect(!line.contains("device_name="))
        #expect(!line.contains("/Users/"))
    }
}
