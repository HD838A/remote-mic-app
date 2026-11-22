import AppKit
import Foundation
import Testing
@testable import RemoteMic

/// These tests pin the user-data contract across the 1.9.21 → 2.0.8 → 2.0.9 upgrade
/// window. A physical remote must keep one profile UUID and every custom category.
@Suite("Remote profile continuity")
struct RemoteProfileContinuityTests {
    private struct Scope {
        let settings: AppSettings
        let defaults: UserDefaults
        let name: String

        func tearDown() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private static func scopedSettings(_ label: String) throws -> Scope {
        let name = "RemoteProfileContinuityTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: name))
        return Scope(settings: AppSettings(defaults: defaults), defaults: defaults, name: name)
    }

    private static func shortcut() -> CustomKeyboardShortcut {
        CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.command],
            keyLabel: "K"
        )
    }

    private static func customMappings(
        primary: ButtonAction = .openCodex
    ) -> RemoteDeviceMappings {
        var bindings = AppSettings.defaultBindings
        bindings[.menu] = primary
        return RemoteDeviceMappings(
            buttonBindings: bindings,
            buttonShortcuts: [.menu: shortcut()],
            buttonApplicationProfileIDs: [.menu: UUID()],
            secondaryButtonBindings: [
                .home: [
                    .longPress: ConfiguredButtonAction(
                        action: .openCommonPhrases,
                        shortcut: nil
                    ),
                ],
                .back: [
                    .longPress: ConfiguredButtonAction(
                        action: .disabled,
                        shortcut: nil
                    ),
                ],
            ],
            buttonRapidPressEnabled: [.menu: true],
            interactionSettings: RemoteButtonInteractionSettings(
                modes: ["up": RemoteButtonHoldMode.repeatSingle.rawValue]
            )
        )
    }

    private static func keyboardShortcutMappings(
        _ shortcut: CustomKeyboardShortcut
    ) -> RemoteDeviceMappings {
        var bindings = AppSettings.defaultBindings
        bindings[.menu] = .customShortcut
        return RemoteDeviceMappings(
            buttonBindings: bindings,
            buttonShortcuts: [.menu: shortcut],
            secondaryButtonBindings: [:]
        )
    }

    private static func defaultMappings() -> RemoteDeviceMappings {
        RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
    }

    private static func binding(
        _ profileID: UUID,
        button: RemoteButton,
        action: ButtonAction
    ) -> UnifiedButtonBinding {
        UnifiedButtonBinding(
            remoteProfileID: profileID,
            button: button,
            trigger: .singleClick,
            configured: ConfiguredButtonAction(action: action, shortcut: nil)
        )
    }

    @Test func legacyProfileKeepsIDAndCustomMappingsAcrossRelaunchAndRegistration() throws {
        let scope = try Self.scopedSettings("legacy-relaunch")
        defer { scope.tearDown() }
        let profileID = UUID()
        let bluetoothIdentifier = UUID()
        let profile = RemoteDeviceProfile(
            id: profileID,
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "legacy-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([profile]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(profileID.uuidString, forKey: "selectedRemoteProfileID")

        for _ in 1...3 {
            let settings = AppSettings(defaults: scope.defaults)
            #expect(settings.remoteDeviceProfiles.map(\.id) == [profileID])
            #expect(settings.selectedRemoteProfileID == profileID)
            let stored = try #require(settings.remoteDeviceProfiles.first)
            #expect(stored.mappings.parsedButtonShortcuts[.menu]?.keyLabel == "K")
            #expect(stored.mappings.parsedButtonApplicationProfileIDs[.menu] != nil)
            #expect(stored.mappings.parsedSecondaryButtonBindings[.home]?[.longPress]?
                .action == .openCommonPhrases)
            #expect(stored.mappings.parsedSecondaryButtonBindings[.back]?[.longPress]?
                .action == .disabled)
            #expect(stored.mappings.parsedButtonRapidPressEnabled[.menu] == true)
            #expect(settings.action(for: .menu) == .openCodex)
            #expect(settings.registerBluetoothRemote(identifier: bluetoothIdentifier) == profileID)
            #expect(settings.registerHIDRemote(fingerprint: "legacy-hid") == profileID)
            #expect(settings.remoteDeviceProfiles.count == 1)
        }
    }

    @Test func olderVersionFallbackIsRecoveredWithoutReplacingActiveIdentity() throws {
        let scope = try Self.scopedSettings("legacy-fallback")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let activeProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let oldProfile = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc001,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "legacy-fallback-hid",
            mappings: Self.customMappings(primary: .openWorkBuddy)
        )
        let fallback = RemoteDeviceProfile(
            id: activeProfileID,
            model: .unknown,
            bluetoothIdentifier: bluetoothIdentifier,
            mappings: Self.defaultMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([fallback]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([oldProfile]),
            forKey: "buttonInteractionMigrationBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.remoteDeviceProfiles.map(\.id) == [activeProfileID])
        #expect(settings.selectedRemoteProfileID == activeProfileID)
        let recovered = try #require(settings.remoteDeviceProfiles.first)
        #expect(recovered.model == .rc001)
        #expect(recovered.mappings.parsedButtonBindings[.menu] == .openWorkBuddy)
        #expect(recovered.mappings.parsedButtonShortcuts[.menu] != nil)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID) == [activeProfileID])
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action == .openRemoteMic)

        let reloaded = AppSettings(defaults: scope.defaults)
        #expect(reloaded.remoteDeviceProfiles.map(\.id) == [activeProfileID])
        #expect(reloaded.selectedRemoteProfileID == activeProfileID)
        #expect(reloaded.action(for: .menu) == .openWorkBuddy)
        #expect(reloaded.configuredAction(for: .home, trigger: .singleClick).action
            == .openRemoteMic)
    }

    @Test func versionOneNinePayloadKeepsIdentityAndCustomMappings() throws {
        let scope = try Self.scopedSettings("v1.9.21-payload")
        defer { scope.tearDown() }
        let profileID = UUID()
        let bluetoothIdentifier = UUID()
        let profile = RemoteDeviceProfile(
            id: profileID,
            model: .rc001,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "v1.9.21-hid",
            mappings: Self.customMappings()
        )
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([profile]))
                as? [[String: Any]]
        )
        payload[0].removeValue(forKey: "hardwareIdentity")
        payload[0].removeValue(forKey: "lastKnownBluetoothName")
        var mappings = try #require(payload[0]["mappings"] as? [String: Any])
        mappings.removeValue(forKey: "interactionSettings")
        payload[0]["mappings"] = mappings
        scope.defaults.set(
            try JSONSerialization.data(withJSONObject: payload),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(profileID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.remoteDeviceProfiles.map(\.id) == [profileID])
        #expect(settings.selectedRemoteProfileID == profileID)
        let stored = try #require(settings.remoteDeviceProfiles.first)
        #expect(stored.bluetoothIdentifier == bluetoothIdentifier)
        #expect(stored.hidFingerprint == "v1.9.21-hid")
        #expect(stored.mappings.parsedButtonBindings[.menu] == .openCodex)
        #expect(stored.mappings.parsedButtonShortcuts[.menu] != nil)
        #expect(stored.mappings.parsedButtonApplicationProfileIDs[.menu] != nil)
        #expect(stored.mappings.parsedSecondaryButtonBindings[.home]?[.longPress]?
            .action == .openCommonPhrases)
        #expect(stored.mappings.parsedSecondaryButtonBindings[.back]?[.longPress]?
            .action == .disabled)
        #expect(stored.mappings.parsedButtonRapidPressEnabled[.menu] == true)

        let reloaded = AppSettings(defaults: scope.defaults)
        #expect(reloaded.remoteDeviceProfiles.map(\.id) == [profileID])
        #expect(reloaded.action(for: .menu) == .openCodex)
    }

    @Test func legacyFallbackRecoversCustomCategoriesWithoutScopedBindings() throws {
        let scope = try Self.scopedSettings("legacy-fallback-no-bindings")
        defer { scope.tearDown() }
        let activeProfileID = UUID()
        let oldProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let fallback = RemoteDeviceProfile(
            id: activeProfileID,
            model: .unknown,
            bluetoothIdentifier: bluetoothIdentifier,
            mappings: Self.defaultMappings()
        )
        let oldProfile = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc001,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "legacy-fallback-only-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([fallback]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([oldProfile]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.remoteDeviceProfiles.map(\.id) == [activeProfileID])
        #expect(settings.selectedRemoteProfileID == activeProfileID)
        let recovered = try #require(settings.remoteDeviceProfiles.first)
        #expect(recovered.model == .rc001)
        #expect(recovered.mappings.parsedButtonBindings[.menu] == .openCodex)
        #expect(recovered.mappings.parsedButtonShortcuts[.menu] != nil)
        #expect(recovered.mappings.parsedButtonApplicationProfileIDs[.menu] != nil)
        #expect(recovered.mappings.parsedSecondaryButtonBindings[.home]?[.longPress]?
            .action == .openCommonPhrases)
        #expect(recovered.mappings.parsedSecondaryButtonBindings[.back]?[.longPress]?
            .action == .disabled)
        #expect(recovered.mappings.parsedButtonRapidPressEnabled[.menu] == true)
        #expect(settings.registerHIDRemote(fingerprint: "legacy-fallback-only-hid")
            == activeProfileID)
        #expect(settings.registerBluetoothRemote(identifier: bluetoothIdentifier)
            == activeProfileID)
        #expect(settings.remoteDeviceProfiles.count == 1)

        let reloaded = AppSettings(defaults: scope.defaults)
        #expect(reloaded.remoteDeviceProfiles.map(\.id) == [activeProfileID])
        #expect(reloaded.action(for: .menu) == .openCodex)
    }

    @Test func legacyFallbackAccumulatesComplementaryHistoryRecords() throws {
        let scope = try Self.scopedSettings("legacy-fallback-accumulate")
        defer { scope.tearDown() }
        let activeProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let fallback = RemoteDeviceProfile(
            id: activeProfileID,
            model: .unknown,
            bluetoothIdentifier: bluetoothIdentifier,
            mappings: Self.defaultMappings()
        )
        let firstHistory = RemoteDeviceProfile(
            id: UUID(),
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "fallback-history-one",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [.menu: Self.shortcut()],
                secondaryButtonBindings: [:]
            )
        )
        let secondHistory = RemoteDeviceProfile(
            id: UUID(),
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "fallback-history-two",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [
                    .home: [
                        .longPress: ConfiguredButtonAction(
                            action: .openCommonPhrases,
                            shortcut: nil
                        ),
                    ],
                ],
                buttonRapidPressEnabled: [.menu: true]
            )
        )
        scope.defaults.set(
            try JSONEncoder().encode([fallback]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([firstHistory]),
            forKey: "buttonInteractionMigrationBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([secondHistory]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        let recovered = try #require(settings.remoteDeviceProfiles.first)
        #expect(recovered.mappings.parsedButtonShortcuts[.menu] != nil)
        #expect(recovered.mappings.parsedSecondaryButtonBindings[.home]?[.longPress]?
            .action == .openCommonPhrases)
        #expect(recovered.mappings.parsedButtonRapidPressEnabled[.menu] == true)
    }

    @Test func duplicateSnapshotRecordsMergeComplementaryCategories() throws {
        let scope = try Self.scopedSettings("legacy-fallback-duplicate-record")
        defer { scope.tearDown() }
        let activeProfileID = UUID()
        let oldProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let fallback = RemoteDeviceProfile(
            id: activeProfileID,
            model: .unknown,
            bluetoothIdentifier: bluetoothIdentifier,
            mappings: Self.defaultMappings()
        )
        let firstRecord = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "duplicate-record-one",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [.menu: Self.shortcut()],
                buttonApplicationProfileIDs: [.menu: UUID()],
                secondaryButtonBindings: [:]
            )
        )
        let secondRecord = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "duplicate-record-two",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [
                    .home: [
                        .longPress: ConfiguredButtonAction(
                            action: .openCommonPhrases,
                            shortcut: nil
                        ),
                    ],
                ],
                buttonRapidPressEnabled: [.menu: true]
            )
        )
        scope.defaults.set(
            try JSONEncoder().encode([fallback]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([firstRecord]),
            forKey: "buttonInteractionMigrationBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([secondRecord]),
            forKey: "remoteDeviceProfiles.corrupt"
        )

        let settings = AppSettings(defaults: scope.defaults)
        let recovered = try #require(settings.remoteDeviceProfiles.first)
        #expect(recovered.mappings.parsedButtonShortcuts[.menu] != nil)
        #expect(recovered.mappings.parsedButtonApplicationProfileIDs[.menu] != nil)
        #expect(recovered.mappings.parsedSecondaryButtonBindings[.home]?[.longPress]?
            .action == .openCommonPhrases)
        #expect(recovered.mappings.parsedButtonRapidPressEnabled[.menu] == true)
    }

    @Test func unreadableProfilesAreNotRewrittenByRecovery() throws {
        let scope = try Self.scopedSettings("unreadable-recovery-guard")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let raw = Data("{\"unexpected\":\"profile array\"}".utf8)
        let oldProfile = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc001,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "unreadable-recovery-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(raw, forKey: "remoteDeviceProfiles")
        scope.defaults.set(bluetoothIdentifier.uuidString, forKey: "peripheralIdentifier")
        scope.defaults.set(
            try JSONEncoder().encode([oldProfile]),
            forKey: "buttonInteractionMigrationBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)

        #expect(scope.defaults.data(forKey: "remoteDeviceProfiles") == raw)
        #expect(settings.unifiedBaseBindings.first?.remoteProfileID == oldProfileID)
        #expect(settings.corruptedSettingKeys.contains("remoteDeviceProfiles"))
    }

    @Test func conflictingHIDFingerprintDoesNotFallBackToBluetoothIdentity() throws {
        let scope = try Self.scopedSettings("identity-contradiction")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let active = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "active-hid",
            mappings: Self.defaultMappings()
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "old-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.unifiedBaseBindings.first?.remoteProfileID == oldProfileID)
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action
            == AppSettings.defaultBindings[.home])
        let activeMappings = try #require(settings.remoteDeviceProfiles.first?.mappings)
        #expect(activeMappings.buttonBindings == Self.defaultMappings().buttonBindings)
        #expect(activeMappings.parsedButtonShortcuts.isEmpty)
        #expect(activeMappings.parsedButtonApplicationProfileIDs.isEmpty)
        #expect(activeMappings.parsedSecondaryButtonBindings.isEmpty)
        #expect(activeMappings.parsedButtonRapidPressEnabled.isEmpty)
    }

    @Test func explicitRapidPressDisableIsNotOverwrittenByRecovery() throws {
        let scope = try Self.scopedSettings("rapid-press-disabled")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        var activeMappings = Self.defaultMappings()
        activeMappings.buttonRapidPressEnabled = [RemoteButton.menu.rawValue: false]
        let active = RemoteDeviceProfile(
            model: .rc003,
            hidFingerprint: "rapid-press-hid",
            mappings: activeMappings
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "rapid-press-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.first?.mappings
            .parsedButtonRapidPressEnabled[.menu] == false)
    }

    @Test func recoveryMergesComplementaryInteractionSettings() throws {
        let scope = try Self.scopedSettings("interaction-complementary")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let active = RemoteDeviceProfile(
            model: .rc003,
            hidFingerprint: "interaction-hid",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "interaction-hid",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:],
                interactionSettings: RemoteButtonInteractionSettings(
                    doubleClickMilliseconds: 400,
                    modes: ["left": RemoteButtonHoldMode.repeatLong.rawValue],
                    migratedRepeatButtons: ["left"]
                )
            )
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        let recovered = try #require(settings.remoteDeviceProfiles.first)

        #expect(recovered.mappings.interactionSettings?.doubleClickMilliseconds == 400)
        #expect(recovered.mappings.interactionSettings?.mode(for: .left) == .repeatLong)
        #expect(recovered.mappings.interactionSettings?.migratedRepeatButtons?
            .contains("left") != true)
        #expect(settings.buttonGestureTiming(for: .rc003).doubleClickMilliseconds == 400)
    }

    @Test func emptyDecodedProfileArrayIsNotRewrittenByRecovery() throws {
        let scope = try Self.scopedSettings("empty-profile-array")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let raw = Data("[]".utf8)
        let oldProfile = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc001,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "empty-array-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(raw, forKey: "remoteDeviceProfiles")
        scope.defaults.set(bluetoothIdentifier.uuidString, forKey: "peripheralIdentifier")
        scope.defaults.set(
            try JSONEncoder().encode([oldProfile]),
            forKey: "buttonInteractionMigrationBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)

        #expect(scope.defaults.data(forKey: "remoteDeviceProfiles") == raw)
        #expect(settings.unifiedBaseBindings.first?.remoteProfileID == oldProfileID)
        #expect(!settings.corruptedSettingKeys.contains("remoteDeviceProfiles"))
    }

    @Test func conflictingScopedBindingIsArchivedInsteadOfDiscarded() throws {
        let scope = try Self.scopedSettings("binding-conflict")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let activeProfileID = UUID()
        let active = RemoteDeviceProfile(
            id: activeProfileID,
            model: .rc003,
            hidFingerprint: "binding-conflict-hid",
            mappings: Self.customMappings(primary: .openCodex)
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "binding-conflict-hid",
            mappings: Self.customMappings(primary: .openWorkBuddy)
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(activeProfileID, button: .home, action: .openCodex),
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.unifiedBaseBindings.count == 1)
        #expect(settings.unifiedBaseBindings.first?.configured.action == .openCodex)
        let conflictData = try #require(scope.defaults.data(
            forKey: AppSettings.remappedScopedBindingConflictsKey
        ))
        let conflicts = try JSONDecoder().decode(
            [UnifiedButtonBinding].self,
            from: conflictData
        )
        #expect(conflicts.map(\.configured.action) == [.openRemoteMic])
    }

    @Test func unreadableConflictArchiveIsPreservedBeforeAppending() throws {
        let scope = try Self.scopedSettings("conflict-archive-unreadable")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let activeProfileID = UUID()
        let rawArchive = Data("not a conflict array".utf8)
        let active = RemoteDeviceProfile(
            id: activeProfileID,
            model: .rc003,
            hidFingerprint: "conflict-archive-hid",
            mappings: Self.customMappings(primary: .openCodex)
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "conflict-archive-hid",
            mappings: Self.customMappings(primary: .openWorkBuddy)
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(activeProfileID, button: .home, action: .openCodex),
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )
        scope.defaults.set(
            rawArchive,
            forKey: AppSettings.remappedScopedBindingConflictsKey
        )

        _ = AppSettings(defaults: scope.defaults)

        #expect(scope.defaults.data(
            forKey: AppSettings.remappedScopedBindingConflictsKey + ".corrupt"
        ) == rawArchive)
        let conflictData = try #require(scope.defaults.data(
            forKey: AppSettings.remappedScopedBindingConflictsKey
        ))
        let conflicts = try JSONDecoder().decode(
            [UnifiedButtonBinding].self,
            from: conflictData
        )
        #expect(conflicts.map(\.configured.action) == [.openRemoteMic])
    }

    @Test func snapshotMergeKeepsTheOnlyAvailableHIDFingerprint() throws {
        let scope = try Self.scopedSettings("snapshot-hid-merge")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let newer = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            mappings: Self.customMappings()
        )
        var older = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "snapshot-hid",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [
                    .home: [
                        .longPress: ConfiguredButtonAction(
                            action: .openCommonPhrases,
                            shortcut: nil
                        ),
                    ],
                ]
            )
        )
        older.hardwareIdentity = "snapshot-hardware-identity"
        let active = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: UUID(),
            hidFingerprint: "snapshot-hid",
            mappings: Self.defaultMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(
            try JSONEncoder().encode([newer]),
            forKey: "remoteDeviceProfilesLatestMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([older]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID)
            == [settings.remoteDeviceProfiles.first?.id])
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action
            == .openRemoteMic)
        #expect(settings.remoteDeviceProfiles.first?.mappings
            .parsedSecondaryButtonBindings[.home]?[.longPress]?.action
            == .openCommonPhrases)
    }

    @Test func recoveryDoesNotTreatExplicitRepeatSingleAsMigrationDefault() throws {
        let scope = try Self.scopedSettings("interaction-explicit-repeat-single")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let active = RemoteDeviceProfile(
            model: .rc003,
            hidFingerprint: "explicit-repeat-hid",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:],
                interactionSettings: RemoteButtonInteractionSettings(
                    modes: ["left": RemoteButtonHoldMode.repeatSingle.rawValue]
                )
            )
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "explicit-repeat-hid",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:],
                interactionSettings: RemoteButtonInteractionSettings(
                    modes: ["left": RemoteButtonHoldMode.repeatLong.rawValue],
                    migratedRepeatButtons: ["left"]
                )
            )
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        let recovered = try #require(settings.remoteDeviceProfiles.first)
        #expect(recovered.mappings.interactionSettings?.mode(for: .left) == .repeatSingle)
        #expect(recovered.mappings.interactionSettings?.migratedRepeatButtons?
            .contains("left") != true)
    }

    @Test func missingActiveHIDStillRecoversByBluetoothIdentifier() throws {
        let scope = try Self.scopedSettings("missing-active-hid")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let activeProfileID = UUID()
        let bluetoothIdentifier = UUID()
        let active = RemoteDeviceProfile(
            id: activeProfileID,
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            mappings: Self.defaultMappings()
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            bluetoothIdentifier: bluetoothIdentifier,
            hidFingerprint: "missing-active-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID) == [activeProfileID])
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action
            == .openRemoteMic)
        #expect(settings.remoteDeviceProfiles.first?.hidFingerprint == "missing-active-hid")
        #expect(settings.registerHIDRemote(fingerprint: "missing-active-hid")
            == activeProfileID)
    }

    @Test func splitBLEAndHIDProfilesRecoverToTheHIDProfile() throws {
        let scope = try Self.scopedSettings("split-identity")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let bleOnlyID = UUID()
        let hidProfileID = UUID()
        let legacyBluetoothIdentifier = UUID()
        let currentBluetoothIdentifier = UUID()
        let oldProfile = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            bluetoothIdentifier: legacyBluetoothIdentifier,
            hidFingerprint: "shared-hid",
            mappings: Self.customMappings()
        )
        let activeBLEOnly = RemoteDeviceProfile(
            id: bleOnlyID,
            model: .unknown,
            bluetoothIdentifier: legacyBluetoothIdentifier,
            mappings: Self.defaultMappings()
        )
        let activeHID = RemoteDeviceProfile(
            id: hidProfileID,
            model: .rc003,
            bluetoothIdentifier: currentBluetoothIdentifier,
            hidFingerprint: "shared-hid",
            mappings: Self.defaultMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([activeBLEOnly, activeHID]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(hidProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([oldProfile]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .menu, action: .openCodex),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(settings.selectedRemoteProfileID == hidProfileID)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID) == [hidProfileID])
        #expect(settings.configuredAction(for: .menu, trigger: .singleClick).action == .openCodex)
        let recovered = try #require(settings.remoteDeviceProfiles.first {
            $0.id == hidProfileID
        })
        #expect(recovered.mappings.parsedButtonShortcuts[.menu] != nil)
        #expect(recovered.mappings.parsedSecondaryButtonBindings[.home]?[.longPress]?
            .action == .openCommonPhrases)
        #expect(recovered.mappings.parsedSecondaryButtonBindings[.back]?[.longPress]?
            .action == .disabled)
        #expect(recovered.mappings.parsedButtonRapidPressEnabled[.menu] == true)
        let untouched = try #require(settings.remoteDeviceProfiles.first {
            $0.id == bleOnlyID
        })
        #expect(untouched.mappings.buttonBindings == Self.defaultMappings().buttonBindings)
        #expect(untouched.mappings.parsedButtonShortcuts.isEmpty)
        #expect(untouched.mappings.parsedButtonApplicationProfileIDs.isEmpty)
        #expect(untouched.mappings.parsedSecondaryButtonBindings.isEmpty)
        #expect(untouched.mappings.parsedButtonRapidPressEnabled.isEmpty)
    }

    @Test func recoveryDoesNotOverwriteExistingCustomMappings() throws {
        let scope = try Self.scopedSettings("keep-current")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let activeProfileID = UUID()
        let active = RemoteDeviceProfile(
            id: activeProfileID,
            model: .rc003,
            hidFingerprint: "keep-current-hid",
            mappings: Self.customMappings(primary: .openCodex)
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "keep-current-hid",
            mappings: Self.customMappings(primary: .openWorkBuddy)
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.action(for: .menu) == .openCodex)
        #expect(settings.remoteDeviceProfiles.first?.mappings.parsedButtonBindings[.menu]
            == .openCodex)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID) == [activeProfileID])
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action
            == .openRemoteMic)
    }

    @Test func ambiguousRecoveryTargetIsNotGuessed() throws {
        let scope = try Self.scopedSettings("ambiguous-target")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let first = RemoteDeviceProfile(
            model: .rc003,
            hidFingerprint: "ambiguous-hid",
            mappings: Self.customMappings(primary: .openCodex)
        )
        let second = RemoteDeviceProfile(
            model: .rc003,
            hidFingerprint: "ambiguous-hid",
            mappings: Self.customMappings(primary: .openWorkBuddy)
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "ambiguous-hid",
            mappings: Self.customMappings(primary: .openRemoteMic)
        )
        scope.defaults.set(
            try JSONEncoder().encode([first, second]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .home, action: .openCommonPhrases),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(settings.unifiedBaseBindings.first?.remoteProfileID == oldProfileID)
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action != .openCommonPhrases)
    }

    @Test func orphanedBindingWithoutRecoverableProfileStaysUntouched() throws {
        let scope = try Self.scopedSettings("unrecoverable")
        defer { scope.tearDown() }
        let activeProfileID = UUID()
        let orphanProfileID = UUID()
        let active = RemoteDeviceProfile(
            id: activeProfileID,
            model: .rc003,
            hidFingerprint: "active-hid",
            mappings: Self.defaultMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeProfileID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(orphanProfileID, button: .home, action: .openRemoteMic),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID) == [orphanProfileID])
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action
            == AppSettings.defaultBindings[.home])
    }

    @Test func sameModelDifferentDevicesStayIsolatedDuringRecovery() throws {
        let scope = try Self.scopedSettings("two-devices")
        defer { scope.tearDown() }
        let oldProfileID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let first = RemoteDeviceProfile(
            id: firstID,
            model: .rc003,
            hidFingerprint: "first-hid",
            mappings: Self.defaultMappings()
        )
        let second = RemoteDeviceProfile(
            id: secondID,
            model: .rc003,
            hidFingerprint: "second-hid",
            mappings: Self.defaultMappings()
        )
        let old = RemoteDeviceProfile(
            id: oldProfileID,
            model: .rc003,
            hidFingerprint: "first-hid",
            mappings: Self.customMappings()
        )
        scope.defaults.set(
            try JSONEncoder().encode([first, second]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(firstID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "remoteDeviceProfilesMergeBackup"
        )
        scope.defaults.set(
            try JSONEncoder().encode([
                Self.binding(oldProfileID, button: .menu, action: .openCodex),
            ]),
            forKey: "unifiedBaseBindings"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(settings.unifiedBaseBindings.map(\.remoteProfileID) == [firstID])
        #expect(settings.action(for: .menu, profileID: firstID) == .openCodex)
        #expect(settings.action(for: .menu, profileID: secondID)
            == AppSettings.defaultBindings[.menu])
        #expect(settings.configuredAction(for: .menu, trigger: .singleClick).action == .openCodex)
    }

    @Test func knownActiveDefaultProfileRecoversShortcutFromHistoricalSnapshot() throws {
        let scope = try Self.scopedSettings("known-default-shortcut")
        defer { scope.tearDown() }
        let activeID = UUID()
        let oldID = UUID()
        let identifier = UUID()
        var activeMappings = Self.defaultMappings()
        activeMappings.buttonBindings[RemoteButton.home.rawValue] = .openCodex
        let active = RemoteDeviceProfile(
            id: activeID,
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "known-default-shortcut-hid",
            mappings: activeMappings
        )
        let old = RemoteDeviceProfile(
            id: oldID,
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "known-default-shortcut-hid",
            mappings: Self.keyboardShortcutMappings(Self.shortcut())
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.shortcut(for: .menu) == Self.shortcut())
        #expect(settings.action(for: .menu) == .customShortcut)
        #expect(settings.action(for: .home) == .openCodex)
        #expect(settings.configuredAction(for: .menu, trigger: .singleClick).shortcut
            == Self.shortcut())
        #expect(settings.remoteDeviceProfiles.first?.mappings
            .parsedButtonShortcuts[.menu] == Self.shortcut())
        #expect(scope.defaults.stringArray(forKey: AppSettings.shortcutRecoveryEvaluatedKey)?
            .contains(activeID.uuidString) == true)

        let reloaded = AppSettings(defaults: scope.defaults)
        #expect(reloaded.shortcut(for: .menu) == Self.shortcut())
        #expect(reloaded.action(for: .menu) == .customShortcut)
        #expect(reloaded.remoteDeviceProfiles.map(\.id) == [activeID])
    }

    @Test func shortcutRecoveryDoesNotReplayAfterUserReset() throws {
        let scope = try Self.scopedSettings("shortcut-reset")
        defer { scope.tearDown() }
        let activeID = UUID()
        let identifier = UUID()
        let active = RemoteDeviceProfile(
            id: activeID,
            model: .rc001,
            bluetoothIdentifier: identifier,
            mappings: Self.defaultMappings()
        )
        let old = RemoteDeviceProfile(
            id: UUID(),
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "shortcut-reset-hid",
            mappings: Self.keyboardShortcutMappings(Self.shortcut())
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.shortcut(for: .menu) == Self.shortcut())

        settings.resetBindings()

        let reloaded = AppSettings(defaults: scope.defaults)
        #expect(reloaded.shortcut(for: .menu) == nil)
        #expect(reloaded.action(for: .menu) == AppSettings.defaultBindings[.menu])
    }

    @Test func conflictingHistoricalShortcutsAreNotGuessed() throws {
        let scope = try Self.scopedSettings("shortcut-conflict")
        defer { scope.tearDown() }
        let activeID = UUID()
        let identifier = UUID()
        let active = RemoteDeviceProfile(
            id: activeID,
            model: .rc001,
            bluetoothIdentifier: identifier,
            mappings: Self.defaultMappings()
        )
        let first = RemoteDeviceProfile(
            id: UUID(),
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "shortcut-conflict-one",
            mappings: Self.keyboardShortcutMappings(Self.shortcut())
        )
        let second = RemoteDeviceProfile(
            id: UUID(),
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "shortcut-conflict-two",
            mappings: Self.keyboardShortcutMappings(
                CustomKeyboardShortcut(
                    keyCode: 38,
                    modifierFlags: [.command],
                    keyLabel: "J"
                )
            )
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([first, second]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.shortcut(for: .menu) == nil)
        #expect(settings.action(for: .menu) == AppSettings.defaultBindings[.menu])
        #expect(scope.defaults.stringArray(forKey: AppSettings.shortcutRecoveryEvaluatedKey)?
            .contains(activeID.uuidString) != true)
    }

    @Test func shortcutRecoveryDoesNotOverwriteCustomAction() throws {
        let scope = try Self.scopedSettings("shortcut-custom-action")
        defer { scope.tearDown() }
        let activeID = UUID()
        let identifier = UUID()
        var activeMappings = Self.defaultMappings()
        activeMappings.buttonBindings[RemoteButton.menu.rawValue] = .openCodex
        let active = RemoteDeviceProfile(
            id: activeID,
            model: .rc001,
            bluetoothIdentifier: identifier,
            mappings: activeMappings
        )
        let old = RemoteDeviceProfile(
            id: UUID(),
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "shortcut-custom-action-hid",
            mappings: Self.keyboardShortcutMappings(Self.shortcut())
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.shortcut(for: .menu) == nil)
        #expect(settings.action(for: .menu) == .openCodex)
        #expect(scope.defaults.stringArray(forKey: AppSettings.shortcutRecoveryEvaluatedKey)?
            .contains(activeID.uuidString) != true)

        settings.resetBindings()
        let reloaded = AppSettings(defaults: scope.defaults)
        #expect(reloaded.shortcut(for: .menu) == nil)
        #expect(reloaded.action(for: .menu) == AppSettings.defaultBindings[.menu])
    }

    @Test func existingCustomShortcutActionRecoversMissingShortcut() throws {
        let scope = try Self.scopedSettings("existing-custom-shortcut-action")
        defer { scope.tearDown() }
        let activeID = UUID()
        let identifier = UUID()
        var activeMappings = Self.defaultMappings()
        activeMappings.buttonBindings[RemoteButton.menu.rawValue] = .customShortcut
        let active = RemoteDeviceProfile(
            id: activeID,
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "existing-custom-shortcut-hid",
            mappings: activeMappings
        )
        let old = RemoteDeviceProfile(
            id: UUID(),
            model: .rc001,
            bluetoothIdentifier: identifier,
            hidFingerprint: "existing-custom-shortcut-hid",
            mappings: Self.keyboardShortcutMappings(Self.shortcut())
        )
        scope.defaults.set(
            try JSONEncoder().encode([active]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(activeID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.shortcut(for: .menu) == Self.shortcut())
        #expect(settings.action(for: .menu) == .customShortcut)
        #expect(settings.configuredAction(for: .menu, trigger: .singleClick).shortcut
            == Self.shortcut())
    }

    @Test func selectingAnotherProfileRecoversItsShortcut() throws {
        let scope = try Self.scopedSettings("shortcut-select-profile")
        defer { scope.tearDown() }
        let firstID = UUID()
        let secondID = UUID()
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        let first = RemoteDeviceProfile(
            id: firstID,
            model: .rc003,
            bluetoothIdentifier: firstIdentifier,
            mappings: Self.defaultMappings()
        )
        let second = RemoteDeviceProfile(
            id: secondID,
            model: .rc003,
            bluetoothIdentifier: secondIdentifier,
            mappings: Self.defaultMappings()
        )
        let oldSecond = RemoteDeviceProfile(
            id: UUID(),
            model: .rc003,
            bluetoothIdentifier: secondIdentifier,
            hidFingerprint: "shortcut-select-profile-hid",
            mappings: Self.keyboardShortcutMappings(Self.shortcut())
        )
        scope.defaults.set(
            try JSONEncoder().encode([first, second]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(firstID.uuidString, forKey: "selectedRemoteProfileID")
        scope.defaults.set(
            try JSONEncoder().encode([oldSecond]),
            forKey: "buttonInteractionMigrationBackup"
        )

        let settings = AppSettings(defaults: scope.defaults)
        #expect(settings.shortcut(for: .menu) == nil)

        settings.selectRemoteProfile(secondID)

        #expect(settings.shortcut(for: .menu) == Self.shortcut())
        #expect(settings.action(for: .menu) == .customShortcut)
        #expect(settings.remoteDeviceProfiles.first {
            $0.id == secondID
        }?.mappings.parsedButtonShortcuts[.menu] == Self.shortcut())
        #expect(settings.shortcut(for: .menu, profileID: firstID) == nil)
    }
}
