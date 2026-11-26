import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice trigger shortcut settings")
struct VoiceTriggerShortcutSettingsTests {
    private static let translationShortcut = CustomKeyboardShortcut(
        keyCode: 1,
        modifierFlags: [.function, .shift],
        keyLabel: "S"
    )

    private func isolatedSettings(_ label: String) throws -> (AppSettings, TestUserDefaults, String) {
        let suiteName = "VoiceTriggerShortcutSettingsTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suiteName))
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    @Test func shortcutPersistsAndIsActiveOnlyForFnTapMode() throws {
        let (settings, defaults, suiteName) = try isolatedSettings("gating")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = Self.translationShortcut
        #expect(shortcut.isValidVoiceTriggerShortcut)

        settings.voiceTriggerShortcut = shortcut
        settings.voiceKeyMode = .function
        settings.voiceFnTapModeEnabled = false
        #expect(settings.effectiveVoiceTriggerShortcut == nil)

        settings.voiceFnTapModeEnabled = true
        #expect(settings.effectiveVoiceTriggerShortcut == shortcut)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.voiceTriggerShortcut == shortcut)
        #expect(reloaded.effectiveVoiceTriggerShortcut == shortcut)

        reloaded.voiceKeyMode = .leftCommand
        #expect(reloaded.effectiveVoiceTriggerShortcut == nil)
    }

    @Test func modifierChordIsValidAndDisplaysWithoutADuplicatePrimaryKey() throws {
        let (settings, defaults, suiteName) = try isolatedSettings("chord")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chord = CustomKeyboardShortcut(
            keyCode: 63,
            modifierFlags: [.function, .shift],
            keyLabel: "Fn"
        )

        #expect(chord.isValidVoiceTriggerShortcut)
        #expect(chord.isModifierChord)
        #expect(!Self.translationShortcut.isModifierChord)
        #expect(chord.displayName(using: LocalizationStore(settings: settings)) == "⇧fn")
    }

    @Test func bareKeyIsRejectedAndRemovedFromStorage() throws {
        let (settings, defaults, suiteName) = try isolatedSettings("bare")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bare = CustomKeyboardShortcut(keyCode: 1, modifierFlags: [], keyLabel: "S")
        #expect(!bare.isValidVoiceTriggerShortcut)

        settings.voiceTriggerShortcut = bare

        #expect(settings.voiceTriggerShortcut == nil)
        #expect(defaults.object(forKey: "voiceTriggerShortcut") == nil)
    }

    @Test func invalidStoredShortcutIsIgnoredOnLoad() throws {
        let suiteName = "VoiceTriggerShortcutSettingsTests.invalidStored.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bare = CustomKeyboardShortcut(keyCode: 1, modifierFlags: [], keyLabel: "S")
        defaults.set(try JSONEncoder().encode(bare), forKey: "voiceTriggerShortcut")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.voiceTriggerShortcut == nil)
        #expect(defaults.object(forKey: "voiceTriggerShortcut") == nil)
    }

    @Test func exportedConfigurationCarriesTheShortcutAndImportInstallsIt() throws {
        let (source, sourceDefaults, sourceSuite) = try isolatedSettings("export")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        source.voiceKeyMode = .function
        source.voiceFnTapModeEnabled = true
        source.voiceTriggerShortcut = Self.translationShortcut
        let data = try source.exportedConfigurationData()
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["voiceTriggerShortcut"] != nil)

        let (destination, destinationDefaults, destinationSuite) = try isolatedSettings("import")
        defer { destinationDefaults.removePersistentDomain(forName: destinationSuite) }
        try destination.importConfiguration(from: data)

        #expect(destination.voiceTriggerShortcut == Self.translationShortcut)
        #expect(destination.effectiveVoiceTriggerShortcut == Self.translationShortcut)
        #expect(destination.configurationImportNotice == nil)
    }

    @Test func pureModifierChordRequiresAccessibilityBeforePosting() {
        let chord = CustomKeyboardShortcut(
            keyCode: 63,
            modifierFlags: [.function, .shift],
            keyLabel: "Fn"
        )
        var posted = false

        #expect(!KeyboardInjector.sendVoiceTrigger(
            chord,
            accessibilityTrusted: { false },
            eventPoster: { _ in
                posted = true
                return true
            }
        ))
        #expect(!posted)
    }

    @Test func pureModifierChordRoundTripsThroughExportAndImport() throws {
        let (source, sourceDefaults, sourceSuite) = try isolatedSettings("chordExport")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let chord = CustomKeyboardShortcut(
            keyCode: 63,
            modifierFlags: [.function, .shift],
            keyLabel: "Fn"
        )
        source.voiceKeyMode = .function
        source.voiceFnTapModeEnabled = true
        source.voiceTriggerShortcut = chord

        let (destination, destinationDefaults, destinationSuite) = try isolatedSettings("chordImport")
        defer { destinationDefaults.removePersistentDomain(forName: destinationSuite) }
        try destination.importConfiguration(from: source.exportedConfigurationData())

        #expect(destination.voiceTriggerShortcut == chord)
        #expect(destination.effectiveVoiceTriggerShortcut?.isModifierChord == true)
    }

    @Test func importingABareKeyDropsItAndReportsTheRejection() throws {
        let (source, sourceDefaults, sourceSuite) = try isolatedSettings("invalidSource")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        source.voiceKeyMode = .function
        source.voiceFnTapModeEnabled = true
        source.voiceTriggerShortcut = Self.translationShortcut
        var json = try #require(
            JSONSerialization.jsonObject(with: try source.exportedConfigurationData())
                as? [String: Any]
        )
        var rawShortcut = try #require(json["voiceTriggerShortcut"] as? [String: Any])
        rawShortcut["modifierFlagsRawValue"] = 0
        json["voiceTriggerShortcut"] = rawShortcut
        let payload = try JSONSerialization.data(withJSONObject: json)

        let (destination, destinationDefaults, destinationSuite) = try isolatedSettings("invalidImport")
        defer { destinationDefaults.removePersistentDomain(forName: destinationSuite) }
        try destination.importConfiguration(from: payload)

        #expect(destination.voiceTriggerShortcut == nil)
        #expect(destination.effectiveVoiceTriggerShortcut == nil)
        #expect(
            destination.configurationImportNotice?.rejectedEntryStorageKeys
                == ["voiceTriggerShortcut"]
        )
    }
}
