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
    @Test @MainActor func clearedUnrelatedShortcutDoesNotBlockImportOrCandidateSelection() throws {
        let (current,cleanup) = try settings(); defer { cleanup() }
        current.setAction(.customShortcut,for: .menu,trigger: .doubleClick)
        current.setShortcut(nil,for: .menu,trigger: .doubleClick)
        let root = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("SayAllTransferTests/\(UUID().uuidString)")
        let controller = RemoteMicPortableTransferController(rootURL: root)
        controller.hostAdapter = current.portableHostAdapter(beforeApply: { _ in })
        let macro = MacroDefinition(macroID: "test.import",version: "1.0.0",name: "Escape",steps: [])
        let p = PortableTransferPackage(minimumRemoteMicVersion: "1.9.21",roots: [.init(kind: .macro,id: macro.macroID)],macros: [macro])
        let before = try current.portableLocalSnapshot()
        #expect((try? controller.preview(p,selected: Set(p.roots),remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro")) != nil)
        #expect((try? controller.exportCandidates(remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro")) != nil)
        #expect(try current.portableLocalSnapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let good = CustomApplicationProfile(displayName: "Good",bundleIdentifier: "com.example.good",applicationPath: "")
        current.addCustomApplicationProfile(good)
        current.addCustomApplicationProfile(.init(displayName: "Pending",bundleIdentifier: "com.example.pending",applicationPath: "",focusStrategy: .keyboardShortcut))
        #expect(try controller.existingObjects(remoteProfileID: nil).count == 2)
        let candidates = try controller.exportCandidates(remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro")
        let appRoot = PortableRoot(kind: .application,id: good.id.uuidString)
        let exported = try PortableTransferCodec.decode(controller.export(candidates,selected: [appRoot],remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro",names: [appRoot:"Renamed"],purpose: .share,includeFocusInformation: false,settingsGroups: []))
        #expect(exported.applications.map(\.displayName) == ["Renamed"])
        #expect(exported.hostSettings == nil)
        let settingsRoot = PortableRoot(kind: .hostSettings,id: "host.settings")
        let general = try PortableTransferCodec.decode(controller.export(candidates,selected: [settingsRoot],remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro",purpose: .personalBackup,includeFocusInformation: false,settingsGroups: ["general"]))
        #expect(general.hostSettings?.general != nil && general.hostSettings?.mappings == nil)
        #expect(general.applications.isEmpty)
        #expect(throws: (any Error).self) {
            try controller.export(candidates,selected: [settingsRoot],remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro",purpose: .personalBackup,includeFocusInformation: false,settingsGroups: ["mappings"])
        }
        #expect(throws: (any Error).self) {
            try controller.export(candidates,selected: Set(candidates.filter { $0.name == "Pending" }.map(\.root)),remoteProfileID: nil,remoteModel: "xiaomi-remote-2-pro",purpose: .share,includeFocusInformation: false,settingsGroups: [])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test @MainActor func selectedProfileHostActionsCarryInlineShortcutAndAppDependencies() throws {
        let (current,cleanup) = try settings(); defer { cleanup() }
        current.setAction(.customShortcut,for: .menu,trigger: .doubleClick)
        let app = CustomApplicationProfile(displayName: "Synthetic",bundleIdentifier: "com.example.synthetic",applicationPath: "")
        current.addCustomApplicationProfile(app)
        let adapter = current.portableHostAdapter(beforeApply: { _ in })
        let shortcut = CustomKeyboardShortcut(keyCode: 36,modifierFlags: .command,keyLabel: "Return")
        let actions = try [
            ConfiguredButtonAction(action: .customShortcut,shortcut: shortcut),
            ConfiguredButtonAction(action: .openCustomApplication,shortcut: nil,applicationProfileID: app.id)
        ].map { try JSONEncoder().encode($0) }
        let objects = try adapter.exportObjects([],[],actions)
        #expect(objects.shortcuts.count == 1 && objects.shortcuts[0].keyCode == 36)
        #expect(objects.applications.map(\.bundleIdentifier) == [app.bundleIdentifier])
        #expect(objects.hostSettings == nil)
        for action in actions {
            let portable = try adapter.exportAction(action)
            if portable.kind == .shortcut { #expect(objects.shortcuts.contains { $0.id == portable.referenceID }) }
            if portable.kind == .application { #expect(objects.applications.contains { $0.id == portable.referenceID }) }
        }
    }
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
        var p = try adapter.exportObjects([app.id.uuidString],[],[])
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
