import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Unified button configuration")
struct ButtonBindingConfigurationTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "UnifiedButtons.\(UUID().uuidString)")!)
    }

    @Test(arguments: [true, false]) func saveRecoveryDoesNotReloadConfirmedSuccess(success: Bool) {
        var reloads = 0
        var reads = 0
        let result = ButtonMappingWriteRecovery.perform(write: { success }, reload: { reloads += 1; return true }, matches: { reads += 1; return false })
        #expect(result == (success ? .saved : .failed))
        #expect(reloads == (success ? 0 : 1))
        #expect(reads == (success ? 0 : 1))
    }

    @Test func reloadFailureRemainsUnknownWithoutComparingStaleValue() {
        var compared = false
        let result = ButtonMappingWriteRecovery.perform(write: { false }, reload: { false }, matches: { compared = true; return true })
        #expect(result == .unknown)
        #expect(!compared)
    }

    @Test func staleSuccessReceiptCannotClearNewFailure() {
        let target = ButtonMappingSaveTarget(profileID: UUID(), deviceID: UUID(), button: .back, trigger: .singleClick)
        var state = ButtonMappingSaveState()
        state.record(.saved, retry: .action(.disabled), target: target)
        let receipt = state.receipt
        state.record(.failed, retry: .action(.disabled), target: target)
        state.clearSuccess(receipt)
        #expect(state.outcome == .failed)
        #expect(state.retry != nil)
        #expect(state.target == target)
        state.record(.saved, retry: .action(.disabled), target: target)
        state.clearSuccess(state.receipt)
        #expect(state.outcome == nil)
        #expect(state.retry == nil)
    }

    @Test func baseDirectEditPersistsDisabledEscapeAndHoldAcrossRestart() throws {
        let defaults = try #require(UserDefaults(suiteName: "Autosave.\(UUID().uuidString)"))
        let source = AppSettings(defaults: defaults)
        let device = source.selectedRemoteProfileID
        #expect(source.writeBaseBinding(.disabled, for: .back, trigger: .singleClick, profileID: device))
        #expect(source.configuredBaseAction(for: .back, trigger: .singleClick).action == .disabled)
        #expect(source.writeBaseBinding(.init(action: .escape, shortcut: nil), for: .back, trigger: .singleClick, profileID: device))
        #expect(source.writeHoldMode(.once, for: .back, profileID: device))
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.configuredBaseAction(for: .back, trigger: .singleClick).action == .escape)
        #expect(reopened.interactionSettings.modes[RemoteButton.back.rawValue] == "once")
        #expect(!source.writeHoldMode(.repeatSingle, for: .back, profileID: UUID()))
    }

    @Test func publicBuildHidesProfileActionsAndQueriesStayUnavailable() {
        #if !canImport(SayAllButtonProfiles)
        let integration = MacroFeatureIntegration()
        #expect(!integration.isButtonProfilesVisible)
        #expect(integration.mappingProfiles(device: nil).isEmpty)
        #expect(integration.createMappingProfile(named: "Unavailable", copying: nil, bindings: [], holdModes: [:]) == nil)
        if case .unavailable = integration.displayProfileBinding(profile: UUID(), button: .back, trigger: .singleClick) {} else { Issue.record("Missing component must be unavailable") }
        #endif
    }

    @Test func futureHostPayloadDisplaysButCannotBeSilentlyRewritten() throws {
        let value = ConfiguredButtonAction(action: .commandCopy, shortcut: nil)
        let encoded = try JSONEncoder().encode(value)
        #expect(MappingHostBindingCodec.decode(encoded)?.isEditable == true)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["futureField"] = ["mustKeep": true]
        let future = try JSONSerialization.data(withJSONObject: json)
        #expect(MappingHostBindingCodec.decode(future)?.configured == value)
        #expect(MappingHostBindingCodec.decode(future)?.isEditable == false)
        #expect(MappingHostBindingCodec.decode(Data("broken".utf8)) == nil)
    }

    #if SAYALL_BUTTON_PROFILE_AUTOSAVE
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"] != nil))
    @MainActor func mappingProfileAdapterPreservesReadOnlyDisplayAndCompleteCopy() throws {
        // The binary integration runner supplies an isolated storage root.
        let root = try #require(ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"])
        #expect(root.hasPrefix("/"))
        let integration = MacroFeatureIntegration(localeIdentifier: "en")
        integration.loadProfilesForScreenshot()
        integration.updateButtonProfilesAccess(.authorized)
        let disabled = UnifiedButtonBinding(remoteProfileID: nil, button: .ok, trigger: .singleClick, configured: .disabled)
        let id = try #require(integration.createMappingProfile(named: "Integration", copying: nil,
            bindings: [disabled], holdModes: ["ok": "once"]))
        let copy = try #require(integration.createMappingProfile(named: "Integration copy", copying: id,
            bindings: [], holdModes: [:]))
        integration.updateButtonProfilesAccess(.requiresPlus)
        #expect(integration.mappingProfiles(device: UUID()).contains { $0.id == id })
        if case let .explicit(value) = integration.displayProfileBinding(profile: copy, button: .ok, trigger: .singleClick) {
            #expect(value.configured == .disabled)
        } else { Issue.record("Explicit disabled was lost") }
        if case .inherited = integration.displayProfileBinding(profile: copy, button: .ok, trigger: .doubleClick) {} else { Issue.record("Inheritance was lost") }
        if case let .explicit(mode) = integration.displayProfileHoldMode(profile: copy, button: .ok) { #expect(mode == .once) }
        else { Issue.record("Hold was lost") }
        #expect(!integration.writeProfileBinding(nil, profile: copy, button: .ok, trigger: .singleClick, displayName: nil))
        #expect(integration.profileBinding(device: nil, profile: copy, button: .ok, trigger: .singleClick) == nil)
        integration.updateButtonProfilesAccess(.authorized)
        #expect(integration.writeProfileBinding(nil, profile: copy, button: .ok, trigger: .singleClick, displayName: nil))
        #expect(integration.reloadMappingProfiles())
        if case .inherited = integration.displayProfileBinding(profile: copy, button: .ok, trigger: .singleClick) {} else { Issue.record("Clear did not persist") }
    }
    #endif

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

    @Test func deletingMacroReferencesClearsUnifiedAndSecondaryBindings() {
        let settings = settings()
        let macro = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.deleted")
        settings.setBaseBinding(macro, for: .home, trigger: .singleClick, profileID: nil)
        settings.secondaryButtonBindings = [.ok: [.doubleClick: macro]]
        settings.removeMacroReferences(to: "macro.deleted")
        #expect(settings.unifiedBaseBindings.isEmpty)
        #expect(settings.secondaryButtonBindings.isEmpty)
    }

    @Test func historicalMissingReferencesAreRemovedAcrossDevicesAndSurviveRestart() throws {
        let suite = "UnifiedButtons.HistoricalCleanup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerHIDRemote(fingerprint: "cleanup-first")
        let second = settings.registerHIDRemote(fingerprint: "cleanup-second")
        let missing = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "local.missing")
        let valid = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "local.valid")
        settings.setBaseBinding(missing, for: .home, trigger: .singleClick, profileID: first)
        settings.setBaseBinding(valid, for: .up, trigger: .singleClick, profileID: second)
        settings.setBaseBinding(.disabled, for: .down, trigger: .singleClick, profileID: second)
        settings.secondaryButtonBindings = [.ok: [.doubleClick: missing, .longPress: valid]]
        let deviceProfiles = settings.remoteDeviceProfiles.map { profile in
            var updated = profile
            updated.mappings.secondaryButtonBindings["home"] = ["doubleClick": missing, "longPress": valid]
            return updated
        }
        defaults.set(try JSONEncoder().encode(deviceProfiles), forKey: "remoteDeviceProfiles")
        let cleanup = AppSettings(defaults: defaults)
        cleanup.removeMacroReferences(to: "local.missing")
        cleanup.removeMacroReferences(to: "local.missing")
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.unifiedBaseBindings.contains { $0.configured.macroID == "local.missing" })
        #expect(reopened.unifiedBaseBindings.contains { $0.configured == valid })
        #expect(reopened.unifiedBaseBindings.contains { $0.configured == .disabled })
        #expect(reopened.remoteDeviceProfiles.allSatisfy { profile in
            profile.mappings.secondaryButtonBindings.values.allSatisfy {
                !$0.values.contains { $0.macroID == "local.missing" }
            }
        })
        #expect(reopened.remoteDeviceProfiles.contains { profile in
            profile.mappings.secondaryButtonBindings.values.contains { $0.values.contains(valid) }
        })
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

    @Test func selectedProfileKeepsShortcutMappingsAfterReload() throws {
        let suite = "UnifiedButtons.SelectedProfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let profileID = settings.registerHIDRemote(fingerprint: "rc001-mapping")
        settings.selectRemoteProfile(profileID)
        let shortcut = CustomKeyboardShortcut(keyCode: 48, modifierFlags: .command, keyLabel: "Tab")
        let configured = ConfiguredButtonAction(action: .customShortcut, shortcut: shortcut)

        for button in [RemoteButton.tv, .home, .menu, .volumeDown] {
            settings.setBaseBinding(configured, for: button, trigger: .singleClick, profileID: profileID)
        }

        let profile = try #require(settings.remoteDeviceProfiles.first { $0.id == profileID })
        #expect(profile.mappings.parsedButtonBindings[.tv] == .customShortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.tv] == shortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.home] == shortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.menu] == shortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.volumeDown] == shortcut)

        let reopened = AppSettings(defaults: defaults)
        reopened.selectRemoteProfile(profileID)
        for button in [RemoteButton.tv, .home, .menu, .volumeDown] {
            #expect(reopened.configuredAction(for: button, trigger: .singleClick, profileID: profileID) == configured)
        }
    }

    @Test func chosenCombinationActionPersistsForOnlyOriginalButton() throws {
        let suite = "UnifiedButtons.MacroReturn.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let originalDevice = settings.registerHIDRemote(fingerprint: "macro-return-original-device")
        let otherDevice = settings.registerHIDRemote(fingerprint: "macro-return-other-device")
        let baseline = settings.configuredBaseAction(for: .ok, trigger: .doubleClick, profileID: originalDevice)
        let otherBaseline = settings.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: otherDevice)
        let chosen = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "local.return-choice")
        settings.setBaseBinding(chosen, for: .ok, trigger: .singleClick, profileID: originalDevice)

        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: originalDevice) == chosen)
        #expect(reopened.configuredBaseAction(for: .ok, trigger: .doubleClick, profileID: originalDevice) == baseline)
        #expect(reopened.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: otherDevice) == otherBaseline)
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
