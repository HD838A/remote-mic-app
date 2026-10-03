import AppKit
import Foundation
import Testing
@testable import RemoteMic
#if canImport(SayAllMacroRemoteMic)
import SayAllMacroCore
import SayAllMacroRemoteMic
#endif

@Suite("Portable configuration and 1.9.21 compatibility")
struct PortableConfigurationCompatibilityTests {
    private func settings() throws -> (AppSettings, () -> Void) {
        let name = "PortableConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }
    @Test func legacy1921ConfigurationImportsAndRemainsReadableByTheFrozenOldContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Testing/Fixtures/PersonalConfiguration-1.9.21.json")
        let bytes = try Data(contentsOf: url)
        let old = try JSONDecoder().decode(Legacy1921PersonalizedConfiguration.self,from: bytes)
        let (current,cleanup) = try settings(); defer { cleanup() }
        try current.importConfiguration(from: bytes)
        let reencoded = try current.exportedConfigurationData()
        let rollback = try JSONDecoder().decode(Legacy1921PersonalizedConfiguration.self,from: reencoded)
        #expect(rollback.formatVersion == 1)
        #expect(rollback.gainDB == old.gainDB)
        #expect(rollback.buttonShortcuts == old.buttonShortcuts)
        #expect(rollback.secondaryButtonBindings == old.secondaryButtonBindings)
        #expect(rollback.buttonApplicationProfileIDs == old.buttonApplicationProfileIDs)
        #expect(rollback.customApplicationProfiles?.map(\.id) == old.customApplicationProfiles?.map(\.id))
        #expect(rollback.voiceKeyMode == old.voiceKeyMode)
        #expect(rollback.voiceFnTapModeEnabled == old.voiceFnTapModeEnabled)
    }
    @Test func trustedSnapshotRestoresExactHostSettingsWithoutExternalImportFiltering() throws {
        let (current,cleanup) = try settings(); defer { cleanup() }
        let app = CustomApplicationProfile(displayName: "Synthetic",bundleIdentifier: "com.example.synthetic",applicationPath: "")
        current.addCustomApplicationProfile(app)
        current.gainDB = 8
        let before = try current.portableLocalSnapshot()
        current.gainDB = 3
        current.showDockIcon.toggle()
        try current.applyPortableLocalSnapshot(before)
        #expect(try current.portableLocalSnapshot() == before)
    }
#if canImport(SayAllMacroRemoteMic)
    @Test @MainActor func appOnlyMergeRemapsReferencesAndDoesNotChangeUnselectedSettings() throws {
        let (current,cleanup) = try settings(); defer { cleanup() }
        current.gainDB = 8
        let adapter = current.portableHostAdapter(beforeApply: { _ in })
        let shortcut = PortableKeyboardShortcut(id: "transfer.shortcut.test",displayName: "Command",keyCode: 55,keyLabel: "Command",modifiers: [.command],deviceModifierFlags: 8)
        let app = PortableApplication(id: "transfer.app.test",displayName: "Synthetic",bundleIdentifier: "com.example.synthetic",focusStrategy: .keyboardShortcut,shortcutID: shortcut.id)
        let p = PortableTransferPackage(minimumRemoteMicVersion: "1.9.21",roots: [.init(kind: .application,id: app.id)],shortcuts: [shortcut],applications: [app])
        let before = try adapter.snapshot()
        let prepared = try adapter.prepare(p,.init())
        #expect(try adapter.snapshot() == before)
        #expect(prepared.newApplicationCount == 1)
        try adapter.apply(prepared.after)
        #expect(current.gainDB == 8)
        let local = try #require(current.customApplicationProfiles.first)
        #expect(local.id.uuidString == prepared.package.applications[0].id)
        #expect(local.applicationPath.isEmpty)
        #expect(local.focusShortcut?.modifierFlags.rawValue == 1048584)
        #expect(current.buttonApplicationProfileIDs.isEmpty)
        let repeated = try adapter.prepare(p,.init())
        #expect(repeated.newApplicationCount == 0)
        #expect(repeated.after == prepared.after)
    }
    @Test @MainActor func focusBackupsRemainPendingAndExplicitReplacementIsReviewableAndRecoverable() throws {
        let (current,cleanup) = try settings(); defer { cleanup() }
        let existing = CustomApplicationProfile(displayName: "Old",bundleIdentifier: "com.example.old",applicationPath: "")
        current.addCustomApplicationProfile(existing)
        current.setAction(.openCustomApplication,for: .menu,trigger: .doubleClick)
        current.setApplicationProfileID(existing.id,for: .menu,trigger: .doubleClick)
        let adapter = current.portableHostAdapter(beforeApply: { _ in })
        let focus = PortableFocusTarget(id: "transfer.focus.test",displayName: "Composer",bundleIdentifier: "com.example.new",target: .init(role: "AXTextArea",identifier: "compose"))
        let app = PortableApplication(id: "transfer.app.test",displayName: "New",bundleIdentifier: focus.bundleIdentifier,focusStrategy: .recordedAccessibility,focusTargetID: focus.id)
        let p = PortableTransferPackage(minimumRemoteMicVersion: "1.9.21",exportPurpose: .personalBackup,roots: [.init(kind: .application,id: app.id)],focusTargets: [focus],applications: [app])
        var options = RemoteMicPortableImportOptions(); options.applicationReplacements[app.id] = existing.id
        let prepared = try adapter.prepare(p,options)
        #expect(prepared.newApplicationCount == 0)
        #expect(prepared.affectedBindings.contains { $0.contains("menu") })
        try adapter.apply(prepared.after)
        #expect(current.portablePendingApplications.contains(existing.id.uuidString))
        #expect(current.configuredAction(for: .menu,trigger: .doubleClick).applicationProfileID == existing.id)
        #expect(current.customApplicationProfiles.count == 1)
        try adapter.apply(prepared.before)
        #expect(current.customApplicationProfiles[0] == existing)
        #expect(current.portablePendingApplications.isEmpty)
    }
    @Test @MainActor func sharingPreservesInputFieldIntentWithoutPersonalFingerprint() throws {
        let (current,cleanup) = try settings(); defer { cleanup() }
        let target = AccessibilityFocusTarget(role: "AXTextArea",identifier: "private-compose",title: "",description: "",help: "",placeholder: "Message",context: "",windowTitle: "",normalizedFrame: nil)
        let app = CustomApplicationProfile(displayName: "Synthetic",bundleIdentifier: "com.example.synthetic",applicationPath: "/synthetic/path.app",focusStrategy: .recordedAccessibility,accessibilityTarget: target)
        current.addCustomApplicationProfile(app)
        let adapter = current.portableHostAdapter(beforeApply: { _ in })
        var p = try adapter.exportObjects()
        p.exportPurpose = .share; p.hostSettings = nil; p.roots = p.roots.filter { $0.kind == .application }
        let share = try PortableTransferGraph.exporting(p,allDefinitions: [],keyboardShortcuts: [],focusProfiles: [])
        let bytes = try PortableTransferCodec.encode(share)
        #expect(share.applications[0].focusStrategy == .recordedAccessibility)
        #expect(share.focusTargets[0].target == nil)
        let text = String(decoding: bytes,as: UTF8.self)
        #expect(!text.contains("private-compose")); #expect(!text.contains("synthetic/path"))
    }
#endif
}

// Frozen from public v1.9.21@d291e0761ca08e2ea6003e8ef63f42a684111ca9,
// Sources/RemoteMic/AppSettings.swift. Test data is wholly synthetic.
private struct Legacy1921PersonalizedConfiguration: Codable {
    let formatVersion: Int
    let gainDB: Double
    let selectedAudioDeviceUID: String
    let customMappingEnabled: Bool
    let buttonBindings: [String: ButtonAction]
    let buttonShortcuts: [String: CustomKeyboardShortcut]
    let buttonApplicationProfileIDs: [String: UUID]?
    let secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    let buttonRapidPressEnabled: [String: Bool]?
    let customApplicationProfiles: [CustomApplicationProfile]?
    let applicationLanguage: AppLanguage
    let showDockIcon: Bool
    let openMainWindowAtLaunch: Bool?
    let checksForPreReleaseUpdates: Bool?
    let experimentalContinuousRecordingEnabled: Bool?
    let voiceFnTapModeEnabled: Bool?
    let voiceKeyMode: VoiceKeyMode?
    let continuousRecordingPowerBindingBackup: ConfiguredButtonAction?
}
