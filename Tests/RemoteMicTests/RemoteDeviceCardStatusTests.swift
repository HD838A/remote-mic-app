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
}
