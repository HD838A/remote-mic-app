import AppKit
import Foundation
import Testing
@testable import RemoteMic

/// An exported configuration file is the only payload this app adopts from outside the Mac it
/// runs on, and it carries the application references and keyboard shortcuts a remote button
/// later launches or synthesizes. These tests drive the real `importConfiguration(from:)` with
/// real bytes and assert on the installed state afterwards — never on the text of the source.
@Suite("Configuration import validation")
struct ConfigurationImportValidationTests {
    /// Command + comma, exercised end to end through export and import.
    private static let commandCommaShortcut = CustomKeyboardShortcut(
        keyCode: 43,
        modifierFlags: .command,
        keyLabel: ","
    )

    private func isolatedSettings(_ label: String) throws -> (AppSettings, () -> Void) {
        let suiteName = "ConfigurationImportValidationTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (
            AppSettings(defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    /// A configuration with one custom application bound to Menu and a Command-comma shortcut
    /// bound to Power, exported as the real product would export it.
    private func exportedConfiguration(
        applicationPath: String,
        bundleIdentifier: String = "com.example.agent",
        displayName: String = "Example Agent"
    ) throws -> (json: [String: Any], profileID: UUID, cleanup: () -> Void) {
        let (settings, cleanup) = try isolatedSettings("source")
        let profile = CustomApplicationProfile(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationPath,
            focusStrategy: .keyboardShortcut,
            focusShortcut: Self.commandCommaShortcut
        )
        settings.addCustomApplicationProfile(profile)
        settings.setAction(.openCustomApplication, for: .menu, trigger: .singleClick)
        settings.setApplicationProfileID(profile.id, for: .menu, trigger: .singleClick)
        settings.setAction(.customShortcut, for: .power, trigger: .singleClick)
        settings.setShortcut(Self.commandCommaShortcut, for: .power, trigger: .singleClick)
        settings.setAction(.customShortcut, for: .tv, trigger: .doubleClick)
        settings.setShortcut(Self.commandCommaShortcut, for: .tv, trigger: .doubleClick)
        settings.gainDB = 7
        let json = try #require(
            JSONSerialization.jsonObject(with: try settings.exportedConfigurationData())
                as? [String: Any]
        )
        return (json, profile.id, cleanup)
    }

    /// Builds a real application bundle on disk so the identity check has something to read.
    private func makeApplicationBundle(bundleIdentifier: String?) throws -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigurationImportValidationTests-\(UUID().uuidString)")
        let bundleURL = root.appendingPathComponent("Payload.app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleName": "Payload"]
        if let bundleIdentifier {
            info["CFBundleIdentifier"] = bundleIdentifier
        }
        try PropertyListSerialization
            .data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
        return (bundleURL, { try? FileManager.default.removeItem(at: root) })
    }

    private func mutatedProfile(
        in json: [String: Any],
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var json = json
        var profiles = try #require(json["customApplicationProfiles"] as? [[String: Any]])
        var profile = try #require(profiles.first)
        mutate(&profile)
        profiles[0] = profile
        json["customApplicationProfiles"] = profiles
        return try JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Application references

    @Test func anApplicationPathThatIsNotAnApplicationBundleIsNeverInstalled() throws {
        let source = try exportedConfiguration(applicationPath: "/Applications/Example Agent.app")
        defer { source.cleanup() }
        // The shape of the attack: a path that exists and can be executed, bound to a button.
        let payload = try mutatedProfile(in: source.json) { profile in
            profile["applicationPath"] = "/bin/sh"
            profile["bundleIdentifier"] = "com.evil.payload"
        }

        let (settings, cleanup) = try isolatedSettings("shellPath")
        defer { cleanup() }
        try settings.importConfiguration(from: payload)

        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.customApplicationProfile(id: source.profileID) == nil)
        #expect(
            settings.configurationImportNotice?.rejectedEntryStorageKeys
                .contains("customApplicationProfiles") == true
        )
        // Dropping one entry must not cost the user the rest of the file.
        #expect(settings.gainDB == 7)
        #expect(settings.action(for: .power) == .customShortcut)
        #expect(settings.shortcut(for: .power) == Self.commandCommaShortcut)
    }

    @Test func aBundleClaimingSomebodyElsesIdentifierIsKeptButReportedAsMissing() throws {
        let (bundleURL, removeBundle) = try makeApplicationBundle(
            bundleIdentifier: "com.example.actual"
        )
        defer { removeBundle() }
        let source = try exportedConfiguration(
            applicationPath: bundleURL.path,
            bundleIdentifier: "com.apple.Safari"
        )
        defer { source.cleanup() }

        let (settings, cleanup) = try isolatedSettings("identityMismatch")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: source.json)
        )

        // Deleting the binding would buy nothing: `resolveCustomApplicationURL` re-checks the
        // same match before opening anything.
        #expect(settings.customApplicationProfile(id: source.profileID) != nil)
        #expect(
            settings.configurationImportNotice?.applicationsMissingOnThisMac.isEmpty == false
        )
        #expect(
            settings.configurationImportNotice?.rejectedEntryStorageKeys
                .contains("customApplicationProfiles") == false
        )
    }

    @Test func anApplicationBundleWithNoIdentifierAtAllIsKeptButReportedAsMissing() throws {
        let (bundleURL, removeBundle) = try makeApplicationBundle(bundleIdentifier: nil)
        defer { removeBundle() }
        let source = try exportedConfiguration(
            applicationPath: bundleURL.path,
            bundleIdentifier: "com.example.payload"
        )
        defer { source.cleanup() }

        let (settings, cleanup) = try isolatedSettings("noIdentifier")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: source.json)
        )

        #expect(settings.customApplicationProfile(id: source.profileID) != nil)
        #expect(
            settings.configurationImportNotice?.applicationsMissingOnThisMac.isEmpty == false
        )
    }

    /// Script Editor's "Export as Application" builds `com.apple.ScriptEditor.id.<app name>`
    /// from the name verbatim, so a Chinese-named app really does ship a non-ASCII identifier,
    /// and the app's own picker accepts it. Refusing it would delete a working binding on the
    /// market this product is built for.
    @Test func aChineseNamedApplicationSurvivesImport() throws {
        let identifier = "com.apple.ScriptEditor.id.阿里内外"
        let (bundleURL, removeBundle) = try makeApplicationBundle(bundleIdentifier: identifier)
        defer { removeBundle() }
        let source = try exportedConfiguration(
            applicationPath: bundleURL.path,
            bundleIdentifier: identifier,
            displayName: "阿里内外"
        )
        defer { source.cleanup() }

        let (settings, cleanup) = try isolatedSettings("chineseIdentifier")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: source.json)
        )

        #expect(
            settings.customApplicationProfile(id: source.profileID)?.bundleIdentifier
                == identifier
        )
        #expect(settings.configurationImportNotice == nil)
    }

    @Test func aMatchingInstalledApplicationBundleIsAdoptedWithoutAnyNotice() throws {
        let (bundleURL, removeBundle) = try makeApplicationBundle(
            bundleIdentifier: "com.example.installed"
        )
        defer { removeBundle() }
        let source = try exportedConfiguration(
            applicationPath: bundleURL.path,
            bundleIdentifier: "com.example.installed"
        )
        defer { source.cleanup() }

        let (settings, cleanup) = try isolatedSettings("installed")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: source.json)
        )

        #expect(settings.customApplicationProfile(id: source.profileID)?.applicationPath
            == bundleURL.path)
        #expect(settings.configurationImportNotice == nil)
    }

    @Test func anApplicationMissingFromThisMacIsKeptAndReportedRatherThanDiscarded() throws {
        // The cross-Mac case: structurally valid, simply not installed here.
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Not Installed \(UUID().uuidString).app",
            displayName: "Absent Agent"
        )
        defer { source.cleanup() }

        let (settings, cleanup) = try isolatedSettings("missingApplication")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: source.json)
        )

        #expect(settings.customApplicationProfile(id: source.profileID)?.displayName
            == "Absent Agent")
        #expect(settings.applicationProfileID(for: .menu) == source.profileID)
        let notice = try #require(settings.configurationImportNotice)
        #expect(notice.applicationsMissingOnThisMac == ["Absent Agent"])
        #expect(notice.rejectedEntryStorageKeys.isEmpty)
    }

    @Test func malformedApplicationReferencesAreEachRefused() throws {
        let cases: [(label: String, mutate: (inout [String: Any]) -> Void)] = [
            ("relativePath", { $0["applicationPath"] = "Applications/Example Agent.app" }),
            ("traversal", { $0["applicationPath"] = "/Applications/../../tmp/Example Agent.app" }),
            ("notABundle", { $0["applicationPath"] = "/Applications/Example Agent" }),
            ("emptyIdentifier", { $0["bundleIdentifier"] = "" }),
            ("spacedIdentifier", { $0["bundleIdentifier"] = "com example agent" }),
            ("shellIdentifier", { $0["bundleIdentifier"] = "com.example;rm -rf /" }),
            ("oversizedIdentifier", { $0["bundleIdentifier"] = String(repeating: "a", count: 400) }),
            ("oversizedDisplayName", { $0["displayName"] = String(repeating: "名", count: 400) }),
            ("oversizedPath", {
                $0["applicationPath"] = "/Applications/" + String(repeating: "x", count: 2_000) + ".app"
            }),
        ]

        for testCase in cases {
            let source = try exportedConfiguration(
                applicationPath: "/Applications/Example Agent.app"
            )
            defer { source.cleanup() }
            let payload = try mutatedProfile(in: source.json, testCase.mutate)

            let (settings, cleanup) = try isolatedSettings(testCase.label)
            defer { cleanup() }
            try settings.importConfiguration(from: payload)

            #expect(settings.customApplicationProfiles.isEmpty, Comment(rawValue: testCase.label))
            #expect(
                settings.configurationImportNotice?.rejectedEntryStorageKeys
                    .contains("customApplicationProfiles") == true,
                Comment(rawValue: testCase.label)
            )
        }
    }

    @Test func anUntrustedFocusShortcutIsClearedWithoutLosingTheApplication() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        let payload = try mutatedProfile(in: source.json) { profile in
            var shortcut = profile["focusShortcut"] as? [String: Any] ?? [:]
            shortcut["keyCode"] = 60_000
            profile["focusShortcut"] = shortcut
        }

        let (settings, cleanup) = try isolatedSettings("focusShortcut")
        defer { cleanup() }
        try settings.importConfiguration(from: payload)

        let imported = try #require(settings.customApplicationProfile(id: source.profileID))
        #expect(imported.focusShortcut == nil)
        #expect(imported.focusStrategy == .keyboardShortcut)
    }

    // MARK: - Keyboard shortcuts

    @Test func anOutOfRangeKeyCodeLosesOnlyThatShortcut() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var json = source.json
        var shortcuts = try #require(json["buttonShortcuts"] as? [String: Any])
        var power = try #require(shortcuts[RemoteButton.power.rawValue] as? [String: Any])
        power["keyCode"] = 60_000
        shortcuts[RemoteButton.power.rawValue] = power
        json["buttonShortcuts"] = shortcuts

        let (settings, cleanup) = try isolatedSettings("keyCodeRange")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )

        #expect(settings.shortcut(for: .power) == nil)
        #expect(
            settings.configurationImportNotice?.rejectedEntryStorageKeys
                .contains("buttonShortcuts") == true
        )
        // The unrelated double-click shortcut on another button is untouched.
        #expect(
            settings.configuredAction(for: .tv, trigger: .doubleClick).shortcut
                == Self.commandCommaShortcut
        )
    }

    @Test func anOversizedKeyLabelLosesOnlyThatShortcut() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var json = source.json
        var shortcuts = try #require(json["buttonShortcuts"] as? [String: Any])
        var power = try #require(shortcuts[RemoteButton.power.rawValue] as? [String: Any])
        power["keyLabel"] = String(repeating: "A", count: 5_000)
        shortcuts[RemoteButton.power.rawValue] = power
        json["buttonShortcuts"] = shortcuts

        let (settings, cleanup) = try isolatedSettings("keyLabelLength")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )

        #expect(settings.shortcut(for: .power) == nil)
    }

    @Test func anUntrustedSecondaryShortcutLosesOnlyThatTrigger() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var json = source.json
        var secondary = try #require(json["secondaryButtonBindings"] as? [String: Any])
        var tv = try #require(secondary[RemoteButton.tv.rawValue] as? [String: Any])
        var doubleClick = try #require(tv[ButtonTrigger.doubleClick.rawValue] as? [String: Any])
        var shortcut = try #require(doubleClick["shortcut"] as? [String: Any])
        shortcut["keyCode"] = 999
        doubleClick["shortcut"] = shortcut
        tv[ButtonTrigger.doubleClick.rawValue] = doubleClick
        secondary[RemoteButton.tv.rawValue] = tv
        json["secondaryButtonBindings"] = secondary

        let (settings, cleanup) = try isolatedSettings("secondaryShortcut")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )

        // A `customShortcut` action with no shortcut would be a button that silently does
        // nothing, so the whole trigger is dropped.
        #expect(settings.configuredAction(for: .tv, trigger: .doubleClick) == .disabled)
        #expect(
            settings.configurationImportNotice?.rejectedEntryStorageKeys
                .contains("secondaryButtonBindings") == true
        )
        #expect(settings.shortcut(for: .power) == Self.commandCommaShortcut)
    }

    @Test func strayModifierBitsAreMaskedOnImport() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var json = source.json
        var shortcuts = try #require(json["buttonShortcuts"] as? [String: Any])
        var power = try #require(shortcuts[RemoteButton.power.rawValue] as? [String: Any])
        // Caps Lock, numeric pad, a device-dependent side bit and a high bit the app never
        // records, on top of plain Command.
        power["modifierFlagsRawValue"] = 0x0010_0010 | 0x0001_0000 | 0x0020_0000 | 0x8000_0000
        shortcuts[RemoteButton.power.rawValue] = power
        json["buttonShortcuts"] = shortcuts

        let (settings, cleanup) = try isolatedSettings("modifierMask")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )

        let imported = try #require(settings.shortcut(for: .power))
        // The import rebuilds the shortcut through the normal initializer, so exactly the
        // supported mask survives — the same result a fresh recording produces.
        #expect(imported.modifierFlagsRawValue == 0x0010_0000)
    }

    // MARK: - Round trips

    @Test func aLegitimateConfigurationStillRoundTrips() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }

        let (settings, cleanup) = try isolatedSettings("roundTrip")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: source.json)
        )

        #expect(settings.gainDB == 7)
        #expect(settings.action(for: .menu) == .openCustomApplication)
        #expect(settings.applicationProfileID(for: .menu) == source.profileID)
        let shortcut = try #require(settings.shortcut(for: .power))
        #expect(shortcut == Self.commandCommaShortcut)
        #expect(shortcut.modifierFlagsRawValue == Self.commandCommaShortcut.modifierFlagsRawValue)
        #expect(
            settings.customApplicationProfile(id: source.profileID)?.focusShortcut
                == Self.commandCommaShortcut
        )
        // Exporting again must carry the same shortcut back out, so a Mac-to-Mac-to-Mac trip
        // cannot downgrade what the user recorded.
        let reExported = try #require(
            JSONSerialization.jsonObject(with: try settings.exportedConfigurationData())
                as? [String: Any]
        )
        let reExportedShortcuts = try #require(reExported["buttonShortcuts"] as? [String: Any])
        let reExportedPower = try #require(
            reExportedShortcuts[RemoteButton.power.rawValue] as? [String: Any]
        )
        #expect(
            reExportedPower["modifierFlagsRawValue"] as? UInt
                == Self.commandCommaShortcut.modifierFlagsRawValue
        )
    }

    @Test func anOlderFormatPayloadWithoutTheOptionalKeysStillImports() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var legacy = source.json
        for key in [
            "buttonApplicationProfileIDs",
            "customApplicationProfiles",
            "openMainWindowAtLaunch",
            "checksForPreReleaseUpdates",
            "experimentalContinuousRecordingEnabled",
            "voiceFnTapModeEnabled",
            "voiceKeyMode",
            "continuousRecordingPowerBindingBackup",
            "buttonRapidPressEnabled",
        ] {
            legacy.removeValue(forKey: key)
        }

        let (settings, cleanup) = try isolatedSettings("legacyPayload")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacy)
        )

        #expect(settings.gainDB == 7)
        #expect(settings.shortcut(for: .power) == Self.commandCommaShortcut)
        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.voiceKeyMode == .function)
        // An old file that carries nothing untrustworthy must not raise a warning.
        #expect(settings.configurationImportNotice == nil)
    }

    @Test func anUnknownButtonKeyIsReportedAndTheKnownOnesStillApply() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var json = source.json
        var bindings = try #require(json["buttonBindings"] as? [String: Any])
        bindings["moon"] = ButtonAction.commandQuit.rawValue
        json["buttonBindings"] = bindings

        let (settings, cleanup) = try isolatedSettings("unknownButton")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )

        #expect(settings.buttonBindings.count == AppSettings.defaultBindings.count)
        #expect(settings.action(for: .power) == .customShortcut)
        #expect(
            settings.configurationImportNotice?.rejectedEntryStorageKeys
                .contains("buttonBindings") == true
        )
    }

    @Test func anOversizedAudioDeviceIdentifierIsDroppedRatherThanStored() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        var json = source.json
        json["selectedAudioDeviceUID"] = String(repeating: "u", count: 5_000)

        let (settings, cleanup) = try isolatedSettings("audioDeviceUID")
        defer { cleanup() }
        try settings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: json)
        )

        #expect(settings.selectedAudioDeviceUID.isEmpty)
        #expect(settings.configurationImportNotice?.isClean == false)
    }

    @Test func documentLevelFaultsStillRejectTheWholeFile() throws {
        let source = try exportedConfiguration(
            applicationPath: "/Applications/Example Agent.app"
        )
        defer { source.cleanup() }
        let (settings, cleanup) = try isolatedSettings("documentLevel")
        defer { cleanup() }

        var unsupported = source.json
        unsupported["formatVersion"] = 99
        do {
            try settings.importConfiguration(
                from: try JSONSerialization.data(withJSONObject: unsupported)
            )
            Issue.record("an unsupported format version must not be imported")
        } catch AppConfigurationError.unsupportedVersion {}

        var impossibleGain = source.json
        impossibleGain["gainDB"] = 4_096
        do {
            try settings.importConfiguration(
                from: try JSONSerialization.data(withJSONObject: impossibleGain)
            )
            Issue.record("an out-of-range gain must not be imported")
        } catch AppConfigurationError.invalidValues {}

        // Neither attempt may leave a trace of the rejected file behind.
        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.configurationImportNotice == nil)
        #expect(settings.gainDB == 10)
    }

    // MARK: - User-facing notice

    @Test func theImportNoticeRendersInBothShippedLocalizations() throws {
        let expectations: [(localization: String, rejected: String, missing: String)] = [
            (
                "zh-Hans",
                "未通过检查已跳过：自定义应用动作。",
                "以下应用在这台 Mac 上未安装，相关按键暂时不会生效：Absent Agent。"
            ),
            (
                "en",
                "Skipped as untrusted: custom application actions.",
                "These applications are not installed on this Mac, so buttons pointing to them will not work yet: Absent Agent."
            ),
        ]

        for expectation in expectations {
            let table = try localizationTable(expectation.localization)
            let localize: (String) -> String = { table[$0] ?? $0 }

            #expect(
                ConfigurationImportNoticeText.rejectedSummary(
                    for: ["customApplicationProfiles"],
                    localize: localize
                ) == expectation.rejected
            )
            #expect(
                ConfigurationImportNoticeText.missingApplicationSummary(
                    for: ["Absent Agent"],
                    localize: localize
                ) == expectation.missing
            )
            // Nothing to report renders nothing at all.
            #expect(
                ConfigurationImportNoticeText.rejectedSummary(for: [], localize: localize) == nil
            )
            #expect(
                ConfigurationImportNoticeText.missingApplicationSummary(for: [], localize: localize) == nil
            )
            for key in [
                ConfigurationImportNoticeText.titleKey,
                ConfigurationImportNoticeText.nextStepKey,
                "configuration.import.partial",
            ] {
                let value = try #require(table[key])
                #expect(!value.isEmpty)
                #expect(value != key)
            }
        }
    }

    /// Every storage key the import can report has to reach a user-facing item name, otherwise
    /// the notice would show a raw key or fall silent.
    @Test func everyReportedStorageKeyIsNamedForTheUser() throws {
        let reportable = [
            "buttonBindings",
            "buttonShortcuts",
            "buttonApplicationProfileIDs",
            "secondaryButtonBindings",
            "buttonRapidPressEnabled",
            "customApplicationProfiles",
            "continuousRecordingPowerBindingBackup",
            "selectedAudioDeviceUID",
        ]
        let table = try localizationTable("zh-Hans")

        for key in reportable {
            let itemKeys = ConfigurationImportNoticeText.affectedItemKeys(for: [key])
            #expect(itemKeys.count == 1, Comment(rawValue: key))
            for itemKey in itemKeys {
                #expect(table[itemKey] != nil, Comment(rawValue: itemKey))
            }
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
}
