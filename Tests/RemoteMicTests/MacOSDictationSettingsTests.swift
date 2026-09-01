import Foundation
import Testing
@testable import RemoteMic

@Suite("macOS Dictation settings")
struct MacOSDictationSettingsTests {
    @Test func defaultsToOffAndTapModesStayMutuallyExclusive() throws {
        let suiteName = "RemoteMicTests.Dictation.Defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.voiceMacOSDictationModeEnabled)

        settings.voiceFnTapModeEnabled = true
        settings.voiceMacOSDictationModeEnabled = true
        #expect(settings.voiceMacOSDictationModeEnabled)
        #expect(!settings.voiceFnTapModeEnabled)

        settings.voiceFnTapModeEnabled = true
        #expect(settings.voiceFnTapModeEnabled)
        #expect(!settings.voiceMacOSDictationModeEnabled)

        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.voiceFnTapModeEnabled)
        #expect(!resumed.voiceMacOSDictationModeEnabled)
    }

    @Test func exactBluetoothNamesProvideASafeFirstSessionModelFallback() {
        #expect(XiaomiRemoteModel.identified(
            byBluetoothName: "Xiaomi Bluetooth Remote 2 Pro"
        ) == .rc003)
        #expect(XiaomiRemoteModel.identified(
            byBluetoothName: " ARN9 "
        ) == nil)
        #expect(XiaomiRemoteModel.identified(
            byBluetoothName: "Xiaomi Bluetooth Remote 2"
        ) == .rc001)
        #expect(XiaomiRemoteModel.identified(
            byBluetoothName: "小米蓝牙语音遥控器"
        ) == nil)
        #expect(XiaomiRemoteModel.identified(
            byBluetoothName: "MI RC"
        ) == nil)
        #expect(XiaomiRemoteModel.identified(
            byBluetoothName: "小米蓝牙遥控器2"
        ) == nil)
    }

    @Test func persistedTapModesAreEffectiveOnlyWithFnAndDictationWinsConflicts() throws {
        let fnSuite = "RemoteMicTests.Dictation.PersistedFn.\(UUID().uuidString)"
        let fnDefaults = try #require(UserDefaults(suiteName: fnSuite))
        defer { fnDefaults.removePersistentDomain(forName: fnSuite) }
        fnDefaults.set(VoiceKeyMode.function.rawValue, forKey: "voiceKeyMode")
        fnDefaults.set(true, forKey: "voiceFnTapModeEnabled")
        fnDefaults.set(true, forKey: "voiceMacOSDictationModeEnabled")

        let fnSettings = AppSettings(defaults: fnDefaults)
        #expect(fnSettings.voiceMacOSDictationModeEnabled)
        #expect(!fnSettings.voiceFnTapModeEnabled)
        #expect(fnSettings.voiceKeyConfigurationState.macOSDictationModeEnabled)

        let commandSuite = "RemoteMicTests.Dictation.PersistedCommand.\(UUID().uuidString)"
        let commandDefaults = try #require(UserDefaults(suiteName: commandSuite))
        defer { commandDefaults.removePersistentDomain(forName: commandSuite) }
        commandDefaults.set(VoiceKeyMode.leftCommand.rawValue, forKey: "voiceKeyMode")
        commandDefaults.set(true, forKey: "voiceFnTapModeEnabled")
        commandDefaults.set(true, forKey: "voiceMacOSDictationModeEnabled")

        let commandSettings = AppSettings(defaults: commandDefaults)
        #expect(commandSettings.voiceKeyMode == .leftCommand)
        #expect(!commandSettings.voiceFnTapModeEnabled)
        #expect(!commandSettings.voiceMacOSDictationModeEnabled)
        #expect(!commandSettings.voiceKeyConfigurationState.macOSDictationModeEnabled)
    }

    @Test func configurationRoundTripsAndLegacyFilesRemainCompatible() throws {
        let sourceSuite = "RemoteMicTests.Dictation.Export.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let source = AppSettings(defaults: sourceDefaults)
        source.voiceMacOSDictationModeEnabled = true
        let exported = try source.exportedConfigurationData()

        let exportedObject = try #require(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        #expect(exportedObject["voiceMacOSDictationModeEnabled"] as? Bool == true)

        let targetSuite = "RemoteMicTests.Dictation.Import.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let target = AppSettings(defaults: targetDefaults)
        try target.importConfiguration(from: exported)
        #expect(target.voiceMacOSDictationModeEnabled)
        #expect(!target.voiceFnTapModeEnabled)

        var conflictingObject = exportedObject
        conflictingObject["voiceFnTapModeEnabled"] = true
        let conflictingData = try JSONSerialization.data(withJSONObject: conflictingObject)
        let conflictingState = try target.voiceKeyConfigurationState(in: conflictingData)
        #expect(conflictingState.macOSDictationModeEnabled)
        #expect(!conflictingState.fnTapModeEnabled)
        try target.importConfiguration(from: conflictingData)
        #expect(target.voiceMacOSDictationModeEnabled)
        #expect(!target.voiceFnTapModeEnabled)

        var legacyObject = conflictingObject
        legacyObject.removeValue(forKey: "voiceMacOSDictationModeEnabled")
        try target.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(!target.voiceMacOSDictationModeEnabled)
        #expect(target.voiceFnTapModeEnabled)

        var commandObject = conflictingObject
        commandObject["voiceKeyMode"] = VoiceKeyMode.rightCommand.rawValue
        try target.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: commandObject)
        )
        #expect(target.voiceKeyMode == .rightCommand)
        #expect(!target.voiceMacOSDictationModeEnabled)
        #expect(!target.voiceFnTapModeEnabled)
    }

    @Test func mappingPageKeepsTheDictationControlScrollableAndReadable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let mappingPage = try #require(source.range(of: "private var mappingPage"))
        let editorPanel = try #require(source.range(
            of: "private func mappingEditorPanel",
            range: mappingPage.upperBound..<source.endIndex
        ))
        let mappingPageSource = source[mappingPage.lowerBound..<editorPanel.lowerBound]
        #expect(mappingPageSource.contains("ScrollView(.vertical, showsIndicators: false)"))
        #expect(mappingPageSource.contains("mappingFooter"))

        let footer = try #require(source.range(of: "private var mappingFooter"))
        let dictationControl = try #require(source.range(
            of: "private var mappingVoiceMacOSDictationControl",
            range: footer.upperBound..<source.endIndex
        ))
        let footerSource = source[footer.lowerBound..<dictationControl.lowerBound]
        #expect(footerSource.contains("mappingVoiceMacOSDictationControl"))

        let restoreDefaults = try #require(source.range(
            of: "private var mappingRestoreDefaultsButton",
            range: dictationControl.upperBound..<source.endIndex
        ))
        let controlSource = String(source[dictationControl.lowerBound..<restoreDefaults.lowerBound])
        #expect(controlSource.contains("connection.voice_macos_dictation.enabled"))
        #expect(controlSource.contains("settings.voiceMacOSDictationModeEnabled"))
        #expect(controlSource.contains("model.setVoiceMacOSDictationModeEnabled"))
        #expect(controlSource.contains("connection.voice_macos_dictation.hint_short"))
        #expect(controlSource.contains("connection.voice_macos_dictation.hint"))
        #expect(controlSource.contains(".font(.system(size: 12, weight: .medium))"))
        #expect(controlSource.contains(".font(.system(size: 12))"))
        #expect(!controlSource.contains("minimumScaleFactor"))
        #expect(controlSource.contains(".disabled(settings.voiceKeyMode != .function)"))
    }

    @Test func dictationStringsExistInEnglishAndSimplifiedChinese() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localizationPaths = [
            "Resources/en.lproj/Localizable.strings",
            "Resources/zh-Hans.lproj/Localizable.strings",
        ]
        let keys = [
            "voice_button.status.macos_dictation_enabled",
            "voice_button.status.tap_permission",
            "connection.voice_macos_dictation.enabled",
            "connection.voice_macos_dictation.hint",
            "connection.voice_macos_dictation.hint_short",
        ]

        for localizationPath in localizationPaths {
            let localization = try String(
                contentsOf: root.appendingPathComponent(localizationPath),
                encoding: .utf8
            )
            for key in keys {
                #expect(localization.contains("\"\(key)\" ="))
            }
        }
    }
}
