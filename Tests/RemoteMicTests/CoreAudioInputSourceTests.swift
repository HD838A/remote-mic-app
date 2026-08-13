import Foundation
import Testing
@testable import RemoteMic

@Suite("Continuous Core Audio input")
struct CoreAudioInputSourceTests {
    @Test func featureIsFailClosedUntilEveryRequirementIsReady() {
        #expect(CoreAudioInputGate.block(
            enabled: false,
            authorized: true,
            inputUID: "input",
            outputUID: "output",
            outputReady: true
        ) == .disabled)
        #expect(CoreAudioInputGate.block(
            enabled: true,
            componentAvailable: false,
            authorized: true,
            inputUID: "input",
            outputUID: "output",
            outputReady: true
        ) == .componentUnavailable)
        #expect(CoreAudioInputGate.block(
            enabled: true,
            componentAvailable: true,
            authorized: false,
            inputUID: "input",
            outputUID: "output",
            outputReady: true
        ) == .permission)
        #expect(CoreAudioInputGate.block(
            enabled: true,
            componentAvailable: true,
            authorized: true,
            inputUID: "",
            outputUID: "output",
            outputReady: true
        ) == .inputMissing)
        #expect(CoreAudioInputGate.block(
            enabled: true,
            componentAvailable: true,
            authorized: true,
            inputUID: "input",
            outputUID: "",
            outputReady: false
        ) == .outputMissing)
        #expect(CoreAudioInputGate.block(
            enabled: true,
            componentAvailable: true,
            authorized: true,
            inputUID: "shared",
            outputUID: "shared",
            outputReady: true
        ) == .sameDevice)
        #expect(CoreAudioInputGate.block(
            enabled: true,
            componentAvailable: true,
            authorized: true,
            inputUID: "input",
            outputUID: "output",
            outputReady: true
        ) == nil)
    }

    @Test func highPrioritySourcesPreemptAndResumeContinuousInput() {
        var arbiter = ContinuousInputArbiter()
        #expect(arbiter.setEnabled(true) == .none)
        #expect(arbiter.setReady(true) == .start)
        #expect(arbiter.capturing)
        #expect(arbiter.setPreempting(.bluetoothRemote, active: true) == .stop)
        #expect(!arbiter.capturing)
        #expect(arbiter.setPreempting(.nearbyPhone, active: true) == .none)
        #expect(arbiter.setPreempting(.bluetoothRemote, active: false) == .none)
        #expect(arbiter.setPreempting(.nearbyPhone, active: false) == .start)
        #expect(arbiter.capturing)
    }

    @Test func disableAndTeardownStopFailClosed() {
        var arbiter = ContinuousInputArbiter()
        _ = arbiter.setEnabled(true)
        _ = arbiter.setReady(true)
        #expect(arbiter.setEnabled(false) == .stop)
        #expect(arbiter.setEnabled(false) == .none)
        #expect(arbiter.setEnabled(true) == .start)
        #expect(arbiter.teardown() == .stop)
        #expect(!arbiter.capturing)
        #expect(arbiter.preemptors.isEmpty)
    }

    @Test func importedLegacyConfigurationKeepsContinuousBridgeDisabled() throws {
        let sourceSuite = "CoreAudioInputSourceTests.source.\(UUID().uuidString)"
        let targetSuite = "CoreAudioInputSourceTests.target.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            targetDefaults.removePersistentDomain(forName: targetSuite)
        }
        let source = AppSettings(defaults: sourceDefaults)
        var object = try #require(
            JSONSerialization.jsonObject(with: source.exportedConfigurationData()) as? [String: Any]
        )
        object.removeValue(forKey: "continuousMicrophoneBridgeEnabled")
        object.removeValue(forKey: "selectedInputDeviceUID")

        let target = AppSettings(defaults: targetDefaults)
        target.continuousMicrophoneBridgeEnabled = true
        target.selectedInputDeviceUID = "old-input"
        try target.importConfiguration(from: JSONSerialization.data(withJSONObject: object))

        #expect(!target.continuousMicrophoneBridgeEnabled)
        #expect(target.selectedInputDeviceUID.isEmpty)
    }
}
