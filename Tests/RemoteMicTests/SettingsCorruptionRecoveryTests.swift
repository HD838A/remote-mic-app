import Foundation
import Testing
@testable import RemoteMic

/// A stored-but-unreadable payload used to look exactly like a first run, so a version
/// mismatch or truncated write silently reset every mapping with no log and no UI hint.
/// These tests drive the real `AppSettings(defaults:)` load against real undecodable bytes.
@Suite("Settings corruption recovery")
struct SettingsCorruptionRecoveryTests {
    private static let garbage = Data("not json".utf8)

    private func isolatedDefaults(
        _ label: String,
        suiteName: inout String
    ) throws -> UserDefaults {
        suiteName = "SettingsCorruptionRecoveryTests.\(label).\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }

    @Test func unreadableButtonBindingsFallBackToDefaultsAndAreReportedAsCorrupt() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("buttonBindings", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Self.garbage, forKey: "buttonBindings")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.buttonBindings == AppSettings.defaultBindings)
        #expect(settings.corruptedSettingKeys == ["buttonBindings"])
        #expect(defaults.data(forKey: "buttonBindings.corrupt") == Self.garbage)
        // The unreadable bytes must survive the load so the reset stays recoverable.
        #expect(defaults.data(forKey: "buttonBindings") == Self.garbage)
    }

    @Test func structurallyMismatchedCustomApplicationProfilesAreReportedAsCorrupt() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("customApplicationProfiles", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Valid JSON, wrong shape: the array element is missing every required field. This is
        // what an incompatible schema change looks like, and it decodes no better than garbage.
        let payload = Data(#"[{"displayName":"Editor"}]"#.utf8)
        defaults.set(payload, forKey: "customApplicationProfiles")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.corruptedSettingKeys == ["customApplicationProfiles"])
        #expect(defaults.data(forKey: "customApplicationProfiles.corrupt") == payload)
        #expect(defaults.data(forKey: "customApplicationProfiles") == payload)
    }

    @Test func unreadableRemoteDeviceProfilesStillMigrateAndAreReportedAsCorrupt() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("remoteDeviceProfiles", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Valid JSON object where an array is expected.
        let payload = Data(#"{"profiles":[]}"#.utf8)
        defaults.set(payload, forKey: "remoteDeviceProfiles")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.corruptedSettingKeys == ["remoteDeviceProfiles"])
        #expect(defaults.data(forKey: "remoteDeviceProfiles.corrupt") == payload)
        // Unlike `buttonBindings`, this key is pre-initialized to `[]` before the load, so the
        // migration assignment fires its `didSet` and persists over the unreadable payload
        // during the very same launch. The ".corrupt" copy is the only surviving evidence.
        #expect(defaults.data(forKey: "remoteDeviceProfiles") != payload)
        // Same fallback as before: one migrated profile carrying the legacy mappings.
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.selectedRemoteProfileID == settings.remoteDeviceProfiles.first?.id)
        #expect(
            settings.remoteDeviceProfiles.first?.mappings.parsedButtonBindings
                == AppSettings.defaultBindings
        )
        #expect(settings.buttonBindings == AppSettings.defaultBindings)
    }

    @Test func everyCorruptedKeyIsReportedOnceInASingleLoad() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("multipleKeys", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keys = ["buttonBindings", "customApplicationProfiles", "remoteDeviceProfiles"]
        for key in keys {
            defaults.set(Self.garbage, forKey: key)
        }

        let settings = AppSettings(defaults: defaults)

        #expect(Set(settings.corruptedSettingKeys) == Set(keys))
        #expect(settings.corruptedSettingKeys.count == keys.count)
        for key in keys {
            #expect(defaults.data(forKey: "\(key).corrupt") == Self.garbage)
        }
        #expect(settings.buttonBindings == AppSettings.defaultBindings)
        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 1)
    }

    @Test func aFirstRunWithNoStoredDataIsNeverReportedAsCorrupt() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("firstRun", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.corruptedSettingKeys.isEmpty)
        for key in ["buttonBindings", "customApplicationProfiles", "remoteDeviceProfiles"] {
            #expect(defaults.data(forKey: "\(key).corrupt") == nil)
        }
        // The first-run defaults themselves must be unchanged by the new detection path.
        #expect(settings.buttonBindings == AppSettings.defaultBindings)
        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 1)
    }

    @Test func validStoredSettingsReloadWithoutBeingReportedAsCorrupt() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("validReload", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let saved = AppSettings(defaults: defaults)
        saved.setAction(.arrowLeft, for: .up)
        let profileID = saved.addCustomApplicationProfile(
            CustomApplicationProfile(
                displayName: "Editor",
                bundleIdentifier: "com.example.editor",
                applicationPath: "/Applications/Editor.app"
            )
        )

        let reloaded = AppSettings(defaults: defaults)

        #expect(reloaded.buttonBindings[.up] == .arrowLeft)
        #expect(reloaded.customApplicationProfiles.map(\.id) == [profileID])
        #expect(reloaded.corruptedSettingKeys.isEmpty)
        for key in ["buttonBindings", "customApplicationProfiles", "remoteDeviceProfiles"] {
            #expect(defaults.data(forKey: "\(key).corrupt") == nil)
        }
    }

    @Test func unreadableFirstUseEventsFallBackToEmptyAndPreserveTheirBytes() throws {
        var suiteName = ""
        let defaults = try isolatedDefaults("firstUseEvents", suiteName: &suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Self.garbage, forKey: "onboarding.diagnostics.events")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.firstUseEvents.isEmpty)
        #expect(defaults.data(forKey: "onboarding.diagnostics.events.corrupt") == Self.garbage)
        // Onboarding telemetry is not user configuration, so reading it must not raise the
        // user-facing corrupted-settings signal, and repeated reads must not accumulate keys.
        _ = settings.firstUseEvents
        #expect(settings.corruptedSettingKeys.isEmpty)
    }
}

/// `corruptedSettingKeys` closes the "no log" half of the original defect; this notice closes the
/// "no UI" half. These tests drive the real assembly and the real shipped strings tables, so a
/// renamed storage key or a missing translation fails here rather than showing a user a raw key.
@Suite("Corrupted settings notice")
struct CorruptedSettingsNoticeTests {
    /// Echoes keys back so item order and the separator stay visible in the assembled result,
    /// independent of whatever wording the strings files happen to carry.
    private func stub(_ key: String) -> String {
        switch key {
        case CorruptedSettingsNotice.summaryKey: return "affected: %1$@"
        case CorruptedSettingsNotice.separatorKey: return " + "
        default: return key
        }
    }

    private func localizationTable(_ localization: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(localization).lproj/Localizable.strings")
        let propertyList = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url),
            options: [],
            format: nil
        )
        return try #require(propertyList as? [String: String])
    }

    @Test func aLoadWithNothingCorruptedShowsNoNoticeAtAll() {
        #expect(CorruptedSettingsNotice.affectedItemKeys(for: []).isEmpty)
        #expect(CorruptedSettingsNotice.summary(for: [], localize: stub) == nil)
    }

    @Test func everyButtonMappingStorageKeyCollapsesIntoOneUserFacingItem() {
        let storageKeys = [
            "buttonBindings",
            "buttonShortcuts",
            "buttonApplicationProfileIDs",
            "secondaryButtonBindings",
            "buttonRapidPressEnabled",
            "continuousRecordingPowerBindingBackup",
        ]

        #expect(
            CorruptedSettingsNotice.affectedItemKeys(for: storageKeys)
                == [CorruptedSettingsNotice.buttonMappingItemKey]
        )
        // Six unreadable keys must not become six near-identical bullet points.
        #expect(
            CorruptedSettingsNotice.summary(for: storageKeys, localize: stub)
                == "affected: \(CorruptedSettingsNotice.buttonMappingItemKey)"
        )
    }

    @Test func itemsReadInAFixedOrderRegardlessOfDiscoveryOrder() {
        let discovered = [
            "usage.voiceSessionRanking",
            "remoteDeviceProfiles",
            "customApplicationProfiles",
            "usage.dailyStatistics",
            "buttonBindings",
        ]
        let expected = [
            CorruptedSettingsNotice.buttonMappingItemKey,
            CorruptedSettingsNotice.customApplicationItemKey,
            CorruptedSettingsNotice.remoteDeviceItemKey,
            CorruptedSettingsNotice.statisticsItemKey,
        ]

        #expect(CorruptedSettingsNotice.affectedItemKeys(for: discovered) == expected)
        #expect(CorruptedSettingsNotice.affectedItemKeys(for: discovered.reversed()) == expected)
        #expect(
            CorruptedSettingsNotice.summary(for: discovered, localize: stub)
                == "affected: \(expected.joined(separator: " + "))"
        )
    }

    @Test func anUnmappedStorageKeyStillRaisesTheWarning() {
        // A future decoded key that nobody remembered to classify must still warn the user,
        // because falling silent is the exact defect this notice exists to close.
        #expect(
            CorruptedSettingsNotice.affectedItemKeys(for: ["settingAddedLater"])
                == [CorruptedSettingsNotice.otherItemKey]
        )
        #expect(CorruptedSettingsNotice.summary(for: ["settingAddedLater"], localize: stub) != nil)
        #expect(
            CorruptedSettingsNotice.affectedItemKeys(for: ["buttonBindings", "settingAddedLater"])
                == [
                    CorruptedSettingsNotice.buttonMappingItemKey,
                    CorruptedSettingsNotice.otherItemKey,
                ]
        )
    }

    @Test func aRealCorruptedLoadIsNamedPreciselyRatherThanGenerically() throws {
        let suiteName = "CorruptedSettingsNoticeTests.corrupted.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for key in ["buttonBindings", "customApplicationProfiles", "usage.dailyStatistics"] {
            defaults.set(Data("not json".utf8), forKey: key)
        }

        let settings = AppSettings(defaults: defaults)

        // End to end across both halves of the fix: whatever the loader publishes must be
        // classifiable. A renamed storage key would fall through to the generic item and fail.
        #expect(
            CorruptedSettingsNotice.affectedItemKeys(for: settings.corruptedSettingKeys) == [
                CorruptedSettingsNotice.buttonMappingItemKey,
                CorruptedSettingsNotice.customApplicationItemKey,
                CorruptedSettingsNotice.statisticsItemKey,
            ]
        )
        #expect(
            !CorruptedSettingsNotice
                .affectedItemKeys(for: settings.corruptedSettingKeys)
                .contains(CorruptedSettingsNotice.otherItemKey)
        )
        #expect(CorruptedSettingsNotice.summary(
            for: settings.corruptedSettingKeys,
            localize: stub
        ) != nil)
    }

    @Test func aRealHealthyLoadKeepsTheNoticeCompletelyHidden() throws {
        let suiteName = "CorruptedSettingsNoticeTests.healthy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let saved = AppSettings(defaults: defaults)
        saved.setAction(.arrowLeft, for: .up)
        let reloaded = AppSettings(defaults: defaults)

        #expect(reloaded.buttonBindings[.up] == .arrowLeft)
        #expect(CorruptedSettingsNotice.summary(
            for: reloaded.corruptedSettingKeys,
            localize: stub
        ) == nil)
    }

    @Test func bothShippedLocalizationsRenderTheWholeSentence() throws {
        let storageKeys = ["buttonBindings", "customApplicationProfiles"]
        let expectations: [(localization: String, summary: String)] = [
            ("zh-Hans", "受影响的是：遥控器按键映射、自定义应用动作。"),
            ("en", "Affected: remote button mappings, custom application actions."),
        ]

        for expectation in expectations {
            let table = try localizationTable(expectation.localization)
            let localize: (String) -> String = { table[$0] ?? $0 }

            #expect(
                CorruptedSettingsNotice.summary(for: storageKeys, localize: localize)
                    == expectation.summary
            )
            #expect(CorruptedSettingsNotice.summary(for: [], localize: localize) == nil)

            // The banner shows three fixed lines beside the list; a missing one would render a
            // raw key, so each must resolve to real wording in this localization.
            for key in [
                CorruptedSettingsNotice.titleKey,
                CorruptedSettingsNotice.recoveryKey,
                CorruptedSettingsNotice.nextStepKey,
            ] {
                let value = try #require(table[key])
                #expect(!value.isEmpty)
                #expect(value != key)
            }

            // Every item must be translated and distinguishable, otherwise two different losses
            // would read identically.
            let itemNames = [
                CorruptedSettingsNotice.buttonMappingItemKey,
                CorruptedSettingsNotice.customApplicationItemKey,
                CorruptedSettingsNotice.remoteDeviceItemKey,
                CorruptedSettingsNotice.statisticsItemKey,
                CorruptedSettingsNotice.otherItemKey,
            ].map(localize)
            #expect(Set(itemNames).count == itemNames.count)
            #expect(!itemNames.contains { $0.hasPrefix("settings.corrupted") })
        }
    }
}
