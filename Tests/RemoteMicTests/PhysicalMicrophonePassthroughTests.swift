import Foundation
import Testing
@testable import RemoteMic

@Suite("Physical microphone passthrough")
struct PhysicalMicrophonePassthroughTests {
    private func isolatedSettings(_ label: String) throws -> (AppSettings, UserDefaults, () -> Void) {
        let suiteName = "PhysicalMicrophonePassthroughTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (
            AppSettings(defaults: defaults),
            defaults,
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    @Test func defaultsOffAndPersistsExplicitSelection() throws {
        let (settings, defaults, cleanup) = try isolatedSettings("persistence")
        defer { cleanup() }
        #expect(!settings.physicalMicrophonePassthroughEnabled)
        #expect(settings.selectedPhysicalMicrophoneUID.isEmpty)

        settings.selectedPhysicalMicrophoneUID = "usb-input"
        settings.physicalMicrophonePassthroughEnabled = true

        let restarted = AppSettings(defaults: defaults)
        #expect(restarted.physicalMicrophonePassthroughEnabled)
        #expect(restarted.selectedPhysicalMicrophoneUID == "usb-input")
    }

    @Test func exportImportKeepsPassthroughAndOldPayloadKeepsItOff() throws {
        let (source, _, sourceCleanup) = try isolatedSettings("source")
        defer { sourceCleanup() }
        source.selectedPhysicalMicrophoneUID = "usb-input"
        source.physicalMicrophonePassthroughEnabled = true
        let payload = try source.exportedConfigurationData()

        let (target, _, targetCleanup) = try isolatedSettings("target")
        defer { targetCleanup() }
        try target.importConfiguration(from: payload)
        #expect(target.physicalMicrophonePassthroughEnabled)
        #expect(target.selectedPhysicalMicrophoneUID == "usb-input")

        var legacy = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        legacy.removeValue(forKey: "physicalMicrophonePassthroughEnabled")
        legacy.removeValue(forKey: "selectedPhysicalMicrophoneUID")
        let legacyPayload = try JSONSerialization.data(withJSONObject: legacy)
        try target.importConfiguration(from: legacyPayload)
        #expect(!target.physicalMicrophonePassthroughEnabled)
        #expect(target.selectedPhysicalMicrophoneUID.isEmpty)
    }

    @Test func virtualDevicesAreNotClassifiedAsPhysicalInputs() {
        let virtual = AudioDeviceInfo(id: 1, uid: "MiRemoteV2ch_UID", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb-input", name: "USB Microphone")
        #expect(VirtualAudioDeviceDiagnosticKind.classify(virtual) == .miRemoteV2ch)
        #expect(VirtualAudioDeviceDiagnosticKind.classify(usb) == .other)
    }
}
