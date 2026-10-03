import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Unified button configuration")
struct ButtonBindingConfigurationTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "UnifiedButtons.\(UUID().uuidString)")!)
    }

    @Test func explicitDisabledOverrideNeverInherits() {
        let settings = settings()
        settings.setAction(.commandCopy, for: .home)
        settings.configuredActionOverride = { _, _, _ in .disabled }
        #expect(settings.configuredAction(for: .home, trigger: .singleClick) == .disabled)
        settings.configuredActionOverride = { _, _, _ in nil }
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action == .commandCopy)
    }

    @Test func migrationPreservesOldValuesAndIsIdempotent() throws {
        let settings = settings()
        settings.setAction(.commandPaste, for: .home)
        let binding = UnifiedButtonBinding(remoteProfileID: settings.selectedRemoteProfileID,
            button: .home, trigger: .singleClick,
            configured: ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.example"))
        try settings.migrateLegacyMacroBindings([binding])
        try settings.migrateLegacyMacroBindings([binding, binding])
        #expect(settings.unifiedBaseBindings.count == 1)
        #expect(settings.buttonBindings[.home] == .commandPaste)
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).macroID == "macro.example")
    }

    @Test func devicesAndTriggersRemainIndependent() {
        let settings = settings()
        let first = UUID(), second = UUID()
        settings.setBaseBinding(ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
                                for: .home, trigger: .singleClick, profileID: first)
        settings.setBaseBinding(.disabled, for: .home, trigger: .doubleClick, profileID: first)
        settings.setBaseBinding(ConfiguredButtonAction(action: .returnKey, shortcut: nil),
                                for: .home, trigger: .singleClick, profileID: second)
        #expect(settings.action(for: .home, profileID: first) == .commandCopy)
        #expect(settings.action(for: .home, profileID: second) == .returnKey)
        #expect(settings.configuredAction(for: .home, trigger: .doubleClick, profileID: first) == .disabled)
    }

    @Test func versionTwoBackupRetainsMacroAndShortcutParameters() throws {
        let source = settings(), target = settings()
        let shortcut = CustomKeyboardShortcut(keyCode: 0, modifierFlags: .command, keyLabel: "A")
        let binding = ConfiguredButtonAction(action: .combinationAction, shortcut: shortcut, macroID: "macro.example")
        source.setBaseBinding(binding, for: .home, trigger: .singleClick, profileID: nil)
        let data = try source.exportedConfigurationData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 2)
        try target.importConfiguration(from: data)
        #expect(target.unifiedBaseBindings.first?.configured == binding)
    }

    @Test func invalidMacroReferenceIsRejectedDuringImport() throws {
        let source = settings(), target = settings()
        source.setBaseBinding(ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "invalid\n"),
                              for: .home, trigger: .singleClick, profileID: nil)
        try target.importConfiguration(from: source.exportedConfigurationData())
        #expect(target.unifiedBaseBindings.first?.configured == .disabled)
    }
    @Test func unavailableReferenceRemainsExplicitAcrossSceneChanges() {
        let settings = settings()
        settings.setBaseBinding(ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            for: .home, trigger: .singleClick, profileID: nil)
        var active: ConfiguredButtonAction? = ConfiguredButtonAction(
            action: .combinationAction, shortcut: nil, macroID: "macro.deleted")
        settings.configuredActionOverride = { _, _, _ in active }
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).macroID == "macro.deleted")
        #expect(settings.action(for: .home) == .combinationAction)
        active = .disabled
        #expect(settings.action(for: .home) == .disabled)
        active = nil
        #expect(settings.action(for: .home) == .commandCopy)
    }

    @Test func rejectedMacroDoesNotReleaseHIDOrInventPermissionFailure() throws {
        let settings = settings()
        settings.customMappingEnabled = true
        let profileID = try #require(settings.selectedRemoteProfileID)
        settings.setBaseBinding(ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.deleted"),
            for: .ok, trigger: .singleClick, profileID: profileID)
        var attempts = 0
        var logs: [String] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profileID,
            ownsEventSuppressor: false, runtimePermissions: { true },
            actionPerformer: { _, _, _ in attempts += 1; return false },
            diagnosticLogger: { logs.append($0) })
        monitor.connectSimulatedDevice(fingerprint: "macro-test", profileID: profileID)
        let originalStatus = monitor.status
        let press = Data([0x28, 0, 0, 0, 0, 0])
        monitor.handleSimulatedReport(reportID: 1, data: press)
        monitor.handleSimulatedReport(reportID: 1, data: press)
        #expect(attempts == 1)
        #expect(monitor.status == originalStatus)
        #expect(logs.contains { $0.contains("HID ACTION failed") })
        monitor.disconnectSimulatedDevice()
    }

    @Test func resetOneDeviceShadowsLegacyUnscopedMacro() throws {
        let settings = settings()
        let first = settings.registerBluetoothRemote(identifier: UUID())
        let second = settings.registerBluetoothRemote(identifier: UUID())
        let macro = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.example")
        try settings.migrateLegacyMacroBindings([UnifiedButtonBinding(remoteProfileID: nil,
            button: .home, trigger: .singleClick, configured: macro)])
        settings.selectRemoteProfile(first)
        settings.resetBindings()
        #expect(settings.configuredBaseAction(for: .home, trigger: .singleClick, profileID: first).action == AppSettings.defaultBindings[.home])
        #expect(settings.configuredBaseAction(for: .home, trigger: .singleClick, profileID: second) == macro)
    }

}
