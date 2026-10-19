import Foundation
import Testing
@testable import RemoteMic

@Suite("Complete macOS configuration backup")
struct CompleteConfigurationBackupTests {
    private func settings() throws -> (AppSettings, UserDefaults, String) {
        let name = "SayAll.CompleteBackup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppSettings(defaults: defaults), defaults, name)
    }

    @Test func exportsAndRestoresEveryDeviceAndUnreferencedAppConfiguration() throws {
        let (source, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = source.registerBluetoothRemote(identifier: UUID())
        let second = source.registerBluetoothRemote(identifier: UUID())
        source.selectRemoteProfile(first)
        source.buttonShortcuts[.home] = .init(keyCode: 8, modifierFlags: .command, keyLabel: "C")
        source.setBaseBinding(.init(action: .combinationAction, shortcut: nil, macroID: "macro.nested"),
            for: .home, trigger: .doubleClick, profileID: first)
        source.selectRemoteProfile(second)
        source.buttonShortcuts[.menu] = .init(keyCode: 9, modifierFlags: .command, keyLabel: "V")
        source.setBaseBinding(.init(action: .commandPaste, shortcut: nil),
            for: .menu, trigger: .longPress, profileID: second)
        let app = CustomApplicationProfile(displayName: "Unused app", bundleIdentifier: "com.example.unused", applicationPath: "")
        source.addCustomApplicationProfile(app)
        source.gainDB = 17
        source.setOnboardingVoiceTool(.weixin)
        source.localTranscriptHistoryEnabled = false
        source.localOriginalAudioRecordingEnabled = true
        source.siriRemoteScrollArrowReversed = true
        source.chromecastSystemReservedExceptions = ["left", "right"]
        let data = try MacConfigurationBackup(host: source.completeConfigurationSnapshot(), components: nil)
            .encoded(version: "2.0.0", build: "255")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["platform"] as? String == "macOS")
        #expect(root["product"] as? String == "SayAll")
        #expect((root["source"] as? [String: String])?["build"] == "255")
        #expect(!String(decoding: data, as: UTF8.self).contains("bluetoothIdentifier"))
        let backup = try MacConfigurationBackup.decode(data)
        let (destination, targetDefaults, targetName) = try settings()
        defer { targetDefaults.removePersistentDomain(forName: targetName) }
        let validated = try destination.validatedCompleteConfigurationSnapshot(backup.host)
        try destination.applyPortableLocalSnapshot(validated)
        #expect(destination.remoteDeviceProfiles.map(\.id) == source.remoteDeviceProfiles.map(\.id))
        #expect(destination.selectedRemoteProfileID == second)
        #expect(destination.unifiedBaseBindings == source.unifiedBaseBindings)
        #expect(destination.customApplicationProfiles.map(\.id) == [app.id])
        #expect(destination.gainDB == 17)
        #expect(destination.onboardingVoiceTool == .weixin)
        #expect(!destination.localTranscriptHistoryEnabled)
        #expect(destination.localOriginalAudioRecordingEnabled)
        #expect(destination.siriRemoteScrollArrowReversed)
        #expect(destination.chromecastSystemReservedExceptions == ["left", "right"])
        destination.selectRemoteProfile(first)
        #expect(destination.buttonShortcuts[.home]?.keyCode == 8)
        destination.selectRemoteProfile(second)
        #expect(destination.buttonShortcuts[.menu]?.keyCode == 9)
        let restarted = AppSettings(defaults: targetDefaults)
        #expect(restarted.remoteDeviceProfiles == destination.remoteDeviceProfiles)
        #expect(restarted.unifiedBaseBindings == source.unifiedBaseBindings)
        #expect(restarted.customApplicationProfiles.map(\.id) == [app.id])
    }

    @Test func rejectsOtherPlatformsUnknownReadersAndOldAppsBeforeWriting() throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let data = try MacConfigurationBackup(host: settings.completeConfigurationSnapshot(), components: nil)
            .encoded(version: "2.0.0", build: "255")
        let before = try settings.portableLocalSnapshot()
        #expect(throws: (any Error).self) { try MacConfigurationBackup.decode(data, platform: "Windows") }
        #expect(throws: (any Error).self) { try MacConfigurationBackup.decode(data, version: "1.9.21") }
        #expect(throws: (any Error).self) { try settings.importConfiguration(from: data) }
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["platform"] = "Windows"
        #expect(throws: (any Error).self) { try MacConfigurationBackup.decode(JSONSerialization.data(withJSONObject: json)) }
        json["platform"] = "macOS"
        var requirements = try #require(json["requirements"] as? [String: String])
        requirements["reader"] = "unknown-reader/1"
        json["requirements"] = requirements
        #expect(throws: (any Error).self) { try MacConfigurationBackup.decode(JSONSerialization.data(withJSONObject: json)) }
        requirements["reader"] = "sayall-macos-configuration/1"
        json["requirements"] = requirements
        json["schemaVersion"] = 2
        #expect(throws: (any Error).self) { try MacConfigurationBackup.decode(JSONSerialization.data(withJSONObject: json)) }
        #expect(try settings.portableLocalSnapshot() == before)
    }

    @Test func routesByContentsRatherThanTheSharedExtension() throws {
        func document(_ format: String, _ type: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["format": format, "type": type])
        }
        #expect(try ConfigurationImportDestination.detect(document("sayall-transfer", "personalBackup")) == .settings)
        #expect(try ConfigurationImportDestination.detect(document("sayall-transfer", "buttonProfile")) == .buttonProfiles)
        #expect(try ConfigurationImportDestination.detect(document(MacConfigurationBackup.format, "personalBackup")) == .settings)
        #expect(throws: (any Error).self) { try ConfigurationImportDestination.detect(document("unknown", "buttonProfile")) }
        #expect(throws: (any Error).self) { try ConfigurationImportDestination.detect(Data("broken".utf8)) }
    }

    @Test func regularPortableHostImportPersistsNewMappingsInsteadOfOldDeviceSnapshot() throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        var envelope = try #require(JSONSerialization.jsonObject(with: settings.portableLocalSnapshot()) as? [String: Any])
        var configuration = try #require(envelope["configuration"] as? [String: Any])
        var bindings = try #require(configuration["buttonBindings"] as? [String: String])
        bindings[RemoteButton.home.rawValue] = ButtonAction.commandCopy.rawValue
        configuration["buttonBindings"] = bindings
        envelope["configuration"] = configuration
        try settings.applyPortableLocalSnapshot(JSONSerialization.data(withJSONObject: envelope))
        let restarted = AppSettings(defaults: defaults)
        #expect(restarted.buttonBindings[.home] == .commandCopy)
        #expect(restarted.selectedRemoteProfile?.mappings.buttonBindings[RemoteButton.home.rawValue] == .commandCopy)
    }
}
