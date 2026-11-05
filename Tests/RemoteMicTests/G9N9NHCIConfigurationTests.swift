import AppleRemoteHCIProtocol
import Foundation
import Testing

struct G9N9NHCIConfigurationTests {
    @Test func buttonModeDisablesPacketAndAudioFilesAndRestoresOriginal() throws {
        let original = try PropertyListSerialization.data(
            fromPropertyList: ["Unrelated": 7, "HCITraces": ["HCIFileTraces": true]],
            format: .binary, options: 0)
        let enabled = try AppleRemoteHCITraceConfiguration.liveButtonPreferencesData(from: original)
        let root = try #require(PropertyListSerialization.propertyList(from: enabled, format: nil) as? [String: Any])
        let traces = try #require(root["HCITraces"] as? [String: Bool])
        #expect(root["Unrelated"] as? Int == 7)
        #expect(traces["HCILiveTraces"] == true)
        #expect(traces["HCIFileTraces"] == false)
        #expect(traces["RawAudioTrace"] == false)
        #expect(try AppleRemoteHCITraceConfiguration.restoreAction(
            originalPlistPresent: true, originalPlistData: original, currentPlistData: enabled) == .write(original))
    }

    @Test func buttonModeRejectsCorruptOriginalInsteadOfReplacingIt() {
        #expect(throws: AppleRemoteHCIConfigurationError.malformedPreferences) {
            try AppleRemoteHCITraceConfiguration.liveButtonPreferencesData(from: Data([0, 1, 2]))
        }
    }
}
