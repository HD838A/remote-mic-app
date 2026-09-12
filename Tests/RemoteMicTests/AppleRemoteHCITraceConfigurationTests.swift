import AppleRemoteHCIProtocol
import Foundation
#if SAYALL_SIRI_REMOTE_ENABLED
import Testing

struct AppleRemoteHCITraceConfigurationTests {
    @Test func enablePreservesExistingKeysAndAddsRequiredTraces() throws {
        let original = try plistData(["Unrelated": "kept"])
        let enabled = try AppleRemoteHCITraceConfiguration.enabledPreferencesData(
            from: original
        )
        let root = try plist(enabled)

        #expect(root["Unrelated"] as? String == "kept")
        let traces = try #require(root["HCITraces"] as? [String: Any])
        for key in AppleRemoteHCITraceConfiguration.requiredTraceKeys {
            #expect(traces[key] as? Bool == true)
        }
    }

    @Test func restoreExistingPlistUsesExactOriginalBytes() throws {
        let original = try plistData(["Original": ["Value": 7]])
        let current = try AppleRemoteHCITraceConfiguration.enabledPreferencesData(
            from: original
        )

        let action = try AppleRemoteHCITraceConfiguration.restoreAction(
            originalPlistPresent: true,
            originalPlistData: original,
            currentPlistData: current
        )
        #expect(action == .write(original))
    }

    @Test func restoreNewEmptyPlistMovesOnlyCreatedFileToTrash() throws {
        let current = try AppleRemoteHCITraceConfiguration.enabledPreferencesData(
            from: nil
        )

        let action = try AppleRemoteHCITraceConfiguration.restoreAction(
            originalPlistPresent: false,
            originalPlistData: nil,
            currentPlistData: current
        )
        #expect(action == .moveCurrentPreferencesToTrash)
    }

    @Test func restoreNewPlistPreservesUnrelatedKeys() throws {
        let current = try AppleRemoteHCITraceConfiguration.enabledPreferencesData(
            from: try plistData(["Unrelated": true])
        )

        let action = try AppleRemoteHCITraceConfiguration.restoreAction(
            originalPlistPresent: false,
            originalPlistData: nil,
            currentPlistData: current
        )
        guard case .write(let restored) = action else {
            Issue.record("expected restored preferences to be written")
            return
        }
        let root = try plist(restored)
        #expect(root["Unrelated"] as? Bool == true)
        #expect(root["HCITraces"] == nil)
    }

    @Test func missingOriginalBytesFailClosed() throws {
        #expect(throws: AppleRemoteHCIConfigurationError.missingOriginalPreferences) {
            try AppleRemoteHCITraceConfiguration.restoreAction(
                originalPlistPresent: true,
                originalPlistData: nil,
                currentPlistData: nil
            )
        }
    }

    private func plistData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    private func plist(_ data: Data) throws -> [String: Any] {
        try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }
}
#endif
