import Foundation
import Testing
@testable import RemoteMic

@Suite("Agent switcher settings")
struct AgentSwitcherSettingsTests {
    @Test func defaultsUseCursorAndCodex() throws {
        let settings = try makeSettings()
        #expect(settings.agentSwitcherBundleIdentifiers == [
            PresetApplication.cursor.bundleIdentifier,
            PresetApplication.codex.bundleIdentifier,
        ])
    }

    @Test func emptySelectionPersists() throws {
        let suite = "AgentSwitcherSettingsTests.empty.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.setAgentSwitcherBundleIdentifiers([])

        #expect(settings.agentSwitcherBundleIdentifiers == [])
        #expect(AppSettings(defaults: defaults).agentSwitcherBundleIdentifiers == [])
    }

    @Test func selectionNormalizesDuplicatesAndCapsTheList() throws {
        let settings = try makeSettings()
        let manyIdentifiers = (0..<40).map { "com.example.agent.\($0)" }
        settings.setAgentSwitcherBundleIdentifiers(
            ["  com.example.agent.1  ", "", "com.example.agent.1"] + manyIdentifiers
        )

        #expect(settings.agentSwitcherBundleIdentifiers.first == "com.example.agent.1")
        #expect(settings.agentSwitcherBundleIdentifiers.count == 32)
        #expect(Set(settings.agentSwitcherBundleIdentifiers).count == 32)
    }

    @Test func exportedConfigurationCarriesAgentSwitcherSelection() throws {
        let source = try makeSettings()
        source.setAgentSwitcherBundleIdentifiers([
            PresetApplication.cursor.bundleIdentifier,
            PresetApplication.codex.bundleIdentifier,
            PresetApplication.cursor.bundleIdentifier,
        ])

        let exported = try source.exportedConfigurationData()
        let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(object["agentSwitcherBundleIdentifiers"] as? [String] == [
            PresetApplication.cursor.bundleIdentifier,
            PresetApplication.codex.bundleIdentifier,
        ])

        let target = try makeSettings()
        target.setAgentSwitcherBundleIdentifiers([])
        try target.importConfiguration(from: exported)
        #expect(target.agentSwitcherBundleIdentifiers == [
            PresetApplication.cursor.bundleIdentifier,
            PresetApplication.codex.bundleIdentifier,
        ])
    }

    @Test func legacyImportUsesDefaultAgentSwitcherSelection() throws {
        let source = try makeSettings()
        source.setAgentSwitcherBundleIdentifiers([PresetApplication.zed.bundleIdentifier])
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: source.exportedConfigurationData()) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "agentSwitcherBundleIdentifiers")

        let target = try makeSettings()
        target.setAgentSwitcherBundleIdentifiers([])
        try target.importConfiguration(from: try JSONSerialization.data(withJSONObject: legacyObject))

        #expect(target.agentSwitcherBundleIdentifiers == AppSettings.defaultAgentSwitcherBundleIdentifiers)
    }

    @Test func agentSwitcherActionIsIndependentFromSingleAppSelection() throws {
        let settings = try makeSettings()
        let profile = CustomApplicationProfile(
            displayName: "Cursor",
            bundleIdentifier: PresetApplication.cursor.bundleIdentifier,
            applicationPath: "/Applications/Cursor.app"
        )
        settings.addCustomApplicationProfile(profile)
        settings.setApplicationProfileID(profile.id, for: .menu, trigger: .singleClick)
        settings.setAction(.agentSwitcher, for: .menu, trigger: .singleClick)
        settings.setAgentSwitcherBundleIdentifiers([PresetApplication.codex.bundleIdentifier])

        let restored = try makeSettings(defaults: settingsDefaults(settings))
        #expect(restored.configuredAction(for: .menu, trigger: .singleClick).action == .agentSwitcher)
        #expect(restored.configuredAction(for: .menu, trigger: .singleClick).applicationProfileID == profile.id)
        #expect(restored.agentSwitcherBundleIdentifiers == [PresetApplication.codex.bundleIdentifier])
    }

    @Test func actionMetadataMatchesSwitcherBehavior() {
        #expect(ButtonAction.agentSwitcher.category == .custom)
        #expect(ButtonAction.agentSwitcher.isAppInternal)
        #expect(!ButtonAction.agentSwitcher.allowsRepeat)
    }

    private func makeSettings(
        defaults: UserDefaults? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> AppSettings {
        if let defaults {
            return AppSettings(defaults: defaults)
        }
        let suite = "AgentSwitcherSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite), sourceLocation: sourceLocation)
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func settingsDefaults(_ settings: AppSettings) throws -> UserDefaults {
        let suite = "AgentSwitcherSettingsTests.copy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        try AppSettings(defaults: defaults).importConfiguration(from: settings.exportedConfigurationData())
        return defaults
    }
}
