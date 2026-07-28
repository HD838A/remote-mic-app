import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Remote buttons")
struct RemoteButtonsTests {
    @Test func presetApplicationsHaveExpectedNamesAndBundleIdentifiers() {
        let localization = LocalizationStore(settings: AppSettings(defaults: .standard))
        let mappings = Dictionary(uniqueKeysWithValues: PresetApplication.allCases.map {
            ($0.displayName(using: localization), $0.bundleIdentifier)
        })
        #expect(mappings == [
            localization.text("无线麦"): "com.hd838a.RemoteMic",
            "Codex": "com.openai.codex",
            "Claude": "com.anthropic.claudefordesktop",
            "cmux": "com.cmuxterm.app",
            localization.text("微信"): "com.tencent.xinWeChat",
            "Cursor": "com.todesktop.230313mzl4w4u92",
            "Xcode": "com.apple.dt.Xcode",
            "Slack": "com.tinyspeck.slackmacgap",
            localization.text("企业微信"): "com.tencent.WeWorkMac",
            localization.text("网易云音乐"): "com.netease.163music",
            "Chrome": "com.google.Chrome",
            "Safari": "com.apple.Safari",
            "Zed": "dev.zed.Zed",
        ])
        #expect(Set(ButtonAction.allCases.compactMap(\.presetApplication)) == Set(PresetApplication.allCases))
    }

    @Test func remoteMicApplicationActionIsAlwaysAvailable() {
        let localization = LocalizationStore(settings: AppSettings(defaults: .standard))
        #expect(PresetApplication.installedBundleIdentifiers.contains(
            PresetApplication.remoteMic.bundleIdentifier
        ))
        #expect(ButtonAction.pickerActions(
            installedBundleIdentifiers: PresetApplication.installedBundleIdentifiers,
            current: .escape
        ).contains(.openRemoteMic))
        #expect(
            ButtonAction.openRemoteMic.displayName(using: localization) ==
                localization.text("打开无线麦")
        )
    }

    @Test func pickerHidesUnavailableApplicationsAndPreservesCurrentMissingSelection() {
        let installed = Set([PresetApplication.codex.bundleIdentifier])
        let normalSelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .escape
        )
        #expect(normalSelection.contains(.openCodex))
        #expect(!normalSelection.contains(.openClaude))

        let missingSelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .openClaude
        )
        #expect(missingSelection.contains(.openClaude))
        #expect(!missingSelection.contains(.openXcode))
    }

    @Test func applicationActionsNeverRepeat() {
        let applicationActions = ButtonAction.allCases.filter { $0.presetApplication != nil }
        #expect(applicationActions.count == PresetApplication.allCases.count)
        #expect(applicationActions.allSatisfy { !$0.allowsRepeat })
    }

    @Test func buttonActionsKeepRawValueCodableCompatibility() throws {
        let legacy = try JSONDecoder().decode(ButtonAction.self, from: Data(#""appSwitcher""#.utf8))
        #expect(legacy == .appSwitcher)

        let custom = try JSONDecoder().decode(ButtonAction.self, from: Data(#""customShortcut""#.utf8))
        #expect(custom == .customShortcut)

        for action in ButtonAction.allCases {
            let encoded = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(ButtonAction.self, from: encoded) == action)
        }
    }

    @Test func customShortcutNormalizesDisplaysAndConvertsModifiers() throws {
        let localization = LocalizationStore(settings: AppSettings(defaults: .standard))
        let shortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.capsLock, .shift, .command],
            keyLabel: "K"
        )

        #expect(shortcut.displayName(using: localization) == "⇧⌘K")
        #expect(shortcut.modifierFlags == [.shift, .command])
        #expect(shortcut.cgEventFlags == [.maskShift, .maskCommand])
        #expect(try JSONDecoder().decode(
            CustomKeyboardShortcut.self,
            from: JSONEncoder().encode(shortcut)
        ) == shortcut)
    }

    @Test func customShortcutPostsRecordedKeyAndRequiresAccessibility() {
        let shortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.control, .option],
            keyLabel: "K"
        )
        var posted: (CGKeyCode, CGEventFlags)?

        #expect(KeyboardInjector.send(
            .customShortcut,
            shortcut: shortcut,
            accessibilityTrusted: { true },
            keyPoster: { posted = ($0, $1) }
        ))
        #expect(posted?.0 == 40)
        #expect(posted?.1 == [.maskControl, .maskAlternate])

        posted = nil
        #expect(!KeyboardInjector.send(
            .customShortcut,
            shortcut: shortcut,
            accessibilityTrusted: { false },
            keyPoster: { posted = ($0, $1) }
        ))
        #expect(posted == nil)
    }

    @Test func unconfiguredCustomShortcutDoesNotReportPermissionFailure() {
        #expect(KeyboardInjector.send(
            .customShortcut,
            accessibilityTrusted: { false }
        ))
    }

    @Test func missingApplicationIsHandledWithoutPermissionFailure() {
        #expect(KeyboardInjector.send(.openCodex, applicationURL: { _ in nil }))
    }

    @Test func applicationLaunchFailureIsHandledWithoutPermissionFailure() {
        struct LaunchFailure: Error {}
        var attemptedApplication: PresetApplication?

        let handled = KeyboardInjector.send(
            .openCodex,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Codex.app") },
            applicationOpener: { _, application, completion in
                attemptedApplication = application
                completion(LaunchFailure())
            }
        )

        #expect(handled)
        #expect(attemptedApplication == .codex)
    }

    @Test func tvDefaultRemainsAppSwitcher() {
        #expect(AppSettings.defaultBindings[.tv] == .appSwitcher)
    }

    @Test func mapsActiveUsagesToButtonsForUIFeedback() {
        #expect(RemoteButton.buttons(for: [0x52, 0x65, 0xFFFF]) == Set<RemoteButton>([.up, .menu]))
    }

    @Test func HIDCallbacksDoNotDeferReportHandling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/HIDRemoteMonitor.swift"), encoding: .utf8)
        #expect(!source.contains("DispatchQueue.main.async"))
    }

    @Test func parsesRC003ReportOneUsages() {
        let data = Data([0xF1, 0x00, 0x80, 0x00, 0x00, 0x00])
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: data) == Set([UInt16(0xF1), UInt16(0x80)]))
    }

    @Test func acceptsFirmwareReportWithIncludedID() {
        let data = Data([0x01, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: data) == Set([UInt16(0x35)]))
    }

    @Test func rejectsOtherReportsAndMalformedPayloads() {
        #expect(RemoteHIDReportParser.usages(reportID: 2, data: Data([0, 0])) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data()) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data([1])) == nil)
    }

    @Test func everyKnownUsageHasDefaultBinding() {
        for button in Set(RemoteButton.usageMap.values) {
            #expect(AppSettings.defaultBindings[button] != nil, Comment(rawValue: button.rawValue))
        }
    }

    @Test func usesVerifiedRC003UsageTable() {
        #expect(RemoteButton.usageMap == [
            0x28: .ok,
            0x35: .tv,
            0x4A: .home,
            0x4F: .right,
            0x50: .left,
            0x51: .down,
            0x52: .up,
            0x65: .menu,
            0x66: .power,
            0x80: .volumeUp,
            0x81: .volumeDown,
            0xF1: .back,
        ])
    }

    @Test func HIDPermissionGateFailsClosed() {
        #expect(!HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(!HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
    }

    @Test func HIDPermissionRequestsAreSequentialAndOptIn() {
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .none)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .inputMonitoring)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ) == .accessibility)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ) == .none)
    }

    @Test func savedBindingsMergeWithDefaults() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let saved = try JSONEncoder().encode([RemoteButton.back.rawValue: ButtonAction.disabled])
        defaults.set(saved, forKey: "buttonBindings")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.action(for: .back) == .disabled)
        #expect(settings.action(for: .up) == .arrowUp)
    }

    @Test func customShortcutsPersistAndResetWithBindings() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = CustomKeyboardShortcut(
            keyCode: 8,
            modifierFlags: [.command, .shift],
            keyLabel: "C"
        )

        let settings = AppSettings(defaults: defaults)
        settings.setAction(.customShortcut, for: .tv)
        settings.setShortcut(shortcut, for: .tv)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.action(for: .tv) == .customShortcut)
        #expect(restored.shortcut(for: .tv) == shortcut)

        restored.resetBindings()
        #expect(restored.action(for: .tv) == .appSwitcher)
        #expect(restored.shortcut(for: .tv) == nil)
    }

    @Test func secondaryTriggerActionsPersistAndResetWithoutChangingSingleClick() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = CustomKeyboardShortcut(
            keyCode: 9,
            modifierFlags: [.control, .command],
            keyLabel: "V"
        )

        let settings = AppSettings(defaults: defaults)
        settings.setAction(.openCodex, for: .tv, trigger: .doubleClick)
        settings.setAction(.customShortcut, for: .tv, trigger: .longPress)
        settings.setShortcut(shortcut, for: .tv, trigger: .longPress)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.action(for: .tv) == .appSwitcher)
        #expect(restored.configuredAction(for: .tv, trigger: .doubleClick) == ConfiguredButtonAction(
            action: .openCodex,
            shortcut: nil
        ))
        #expect(restored.configuredAction(for: .tv, trigger: .longPress) == ConfiguredButtonAction(
            action: .customShortcut,
            shortcut: shortcut
        ))
        #expect(restored.hasSecondaryAction(for: .tv))

        restored.setAction(.disabled, for: .tv, trigger: .doubleClick)
        #expect(restored.configuredAction(for: .tv, trigger: .doubleClick) == .disabled)
        #expect(restored.hasSecondaryAction(for: .tv))

        restored.resetBindings()
        #expect(restored.action(for: .tv) == .appSwitcher)
        #expect(!restored.hasSecondaryAction(for: .tv))
    }

    @Test func migratesLegacyExclusiveToggleToCustomMappingToggle() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "exclusiveHID")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.customMappingEnabled)
    }

    @Test func nativeEventDescriptorsCoverPotentialDuplicateEvents() {
        #expect(RemoteButton.up.nativeEvent == .keyboard(keyCode: 126))
        #expect(RemoteButton.ok.nativeEvent == .keyboard(keyCode: 36))
        #expect(RemoteButton.menu.nativeEvent == .keyboard(keyCode: KeyboardInjector.contextualMenuKeyCode))
        #expect(RemoteButton.volumeUp.nativeEvent == .systemKey(type: 0))
        #expect(RemoteButton.back.nativeEvent == nil)
    }
}
