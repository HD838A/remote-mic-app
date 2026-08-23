import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Remote buttons")
struct RemoteButtonsTests {
    @Test func exclusiveHIDAccessUsesASeparateUserFacingFailure() {
        #expect(HIDRemoteMonitor.deviceOpenFailureMessageKey(
            result: kIOReturnExclusiveAccess,
            karabinerElementsInstalled: false
        ) == "button_mapping.error.exclusive_access")
        #expect(HIDRemoteMonitor.deviceOpenFailureMessageKey(
            result: kIOReturnExclusiveAccess,
            karabinerElementsInstalled: true
        ) == "button_mapping.error.exclusive_access.karabiner")
        #expect(HIDRemoteMonitor.deviceOpenFailureMessageKey(
            result: kIOReturnSuccess,
            karabinerElementsInstalled: true
        ) == nil)
    }

    @Test func karabinerInstallationDetectionIsBestEffortAndDoesNotRequireItToBeRunning() {
        #expect(HIDRemoteMonitor.isKarabinerElementsInstalled(
            applicationURL: URL(fileURLWithPath: "/custom/Karabiner-Elements.app"),
            fileExists: { _ in false }
        ))
        #expect(HIDRemoteMonitor.isKarabinerElementsInstalled(
            applicationURL: nil,
            fileExists: { path in
                path == "/Applications/Karabiner-Elements.app"
            }
        ))
        #expect(!HIDRemoteMonitor.isKarabinerElementsInstalled(
            applicationURL: nil,
            fileExists: { _ in false }
        ))
    }

    @Test func discoveryProbesMatchedDevicesWithoutBindingTheEnumerationWinner() {
        #expect(HIDRemoteMonitor.deviceMatchDecision(
            reportingFingerprint: "unbound-remote",
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: []
        ) == .probe)
        #expect(HIDRemoteMonitor.deviceMatchDecision(
            reportingFingerprint: "bound-remote",
            activeFingerprint: nil,
            targetFingerprint: "bound-remote",
            excludedFingerprints: []
        ) == .activate("bound-remote"))
        #expect(HIDRemoteMonitor.deviceMatchDecision(
            reportingFingerprint: "already-owned",
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: ["already-owned"]
        ) == .rejected("excluded_fingerprint"))
        #expect(HIDRemoteMonitor.deviceMatchDecision(
            reportingFingerprint: nil,
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: []
        ) == .rejected("fingerprint_unavailable"))
        #expect(HIDRemoteMonitor.deviceMatchDecision(
            reportingFingerprint: "other-remote",
            activeFingerprint: "active-remote",
            targetFingerprint: nil,
            excludedFingerprints: []
        ) == .rejected("active_device_exists"))
    }

    @Test func discoveryRoutesTheRemoteThatWasActuallyPressed() {
        #expect(HIDRemoteMonitor.resolvedFingerprintForReport(
            reportingFingerprint: "pressed-remote",
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: []
        ) == "pressed-remote")
    }

    @Test func discoveryPromotesOnlyAReportContainingAKnownRemoteButton() {
        #expect(!HIDRemoteMonitor.shouldPromoteDiscoveryReport(usages: []))
        #expect(!HIDRemoteMonitor.shouldPromoteDiscoveryReport(usages: [0xFFFF]))
        #expect(HIDRemoteMonitor.shouldPromoteDiscoveryReport(usages: [RemoteButton.ok.hidUsage]))
    }

    @Test func discoveryRejectsAlreadyBoundRemotesAndDedicatedMonitorsStayIsolated() {
        #expect(HIDRemoteMonitor.resolvedFingerprintForReport(
            reportingFingerprint: "already-bound",
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: ["already-bound"]
        ) == nil)
        #expect(HIDRemoteMonitor.resolvedFingerprintForReport(
            reportingFingerprint: "remote-b",
            activeFingerprint: "remote-a",
            targetFingerprint: "remote-a",
            excludedFingerprints: []
        ) == nil)
        #expect(HIDRemoteMonitor.resolvedFingerprintForReport(
            reportingFingerprint: "remote-a",
            activeFingerprint: "remote-a",
            targetFingerprint: "remote-a",
            excludedFingerprints: ["remote-a"]
        ) == "remote-a")
    }

    @Test func HIDReportRoutingExplainsEveryFingerprintRejection() {
        #expect(HIDRemoteMonitor.reportRoutingDecision(
            reportingFingerprint: nil,
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: []
        ) == .rejected("fingerprint_unavailable"))
        #expect(HIDRemoteMonitor.reportRoutingDecision(
            reportingFingerprint: "remote-b",
            activeFingerprint: "remote-a",
            targetFingerprint: nil,
            excludedFingerprints: []
        ) == .rejected("active_fingerprint_mismatch"))
        #expect(HIDRemoteMonitor.reportRoutingDecision(
            reportingFingerprint: "remote-a",
            activeFingerprint: nil,
            targetFingerprint: nil,
            excludedFingerprints: ["remote-a"]
        ) == .rejected("excluded_fingerprint"))
        #expect(HIDRemoteMonitor.reportRoutingDecision(
            reportingFingerprint: "remote-b",
            activeFingerprint: nil,
            targetFingerprint: "remote-a",
            excludedFingerprints: []
        ) == .rejected("target_fingerprint_mismatch"))
    }

    @Test func presetApplicationsHaveExpectedNamesAndBundleIdentifiers() {
        let localization = LocalizationStore(settings: AppSettings(defaults: .standard))
        let mappings = Dictionary(uniqueKeysWithValues: PresetApplication.allCases.map {
            ($0.displayName(using: localization), $0.bundleIdentifier)
        })
        #expect(mappings == [
            localization.text("app.name"): "com.hd838a.RemoteMic",
            "ChatGPT": "com.openai.codex",
            "Claude": "com.anthropic.claudefordesktop",
            "cmux": "com.cmuxterm.app",
            localization.text("application.wechat"): "com.tencent.xinWeChat",
            "Cursor": "com.todesktop.230313mzl4w4u92",
            "Xcode": "com.apple.dt.Xcode",
            "Slack": "com.tinyspeck.slackmacgap",
            localization.text("application.wecom"): "com.tencent.WeWorkMac",
            localization.text("application.netease_music"): "com.netease.163music",
            "Chrome": "com.google.Chrome",
            "Safari": "com.apple.Safari",
            "Zed": "dev.zed.Zed",
        ])
        #expect(Set(ButtonAction.allCases.compactMap(\.presetApplication)) == Set(PresetApplication.allCases))
    }

    @Test func onlySupportedApplicationsHaveAutomaticFocusStrategies() {
        #expect(PresetApplication.codex.focusStrategy == .accessibilityComposer)
        #expect(PresetApplication.claude.focusStrategy == .accessibilityComposer)
        #expect(PresetApplication.cmux.focusStrategy == .cmuxSurfaceAPI)
        #expect(PresetApplication.allCases.filter { $0.focusStrategy == nil } == [
            .remoteMic, .weChat, .cursor, .xcode, .slack, .weCom, .neteaseMusic, .chrome, .safari, .zed,
        ])
    }

    @Test func remoteMicApplicationActionIsAlwaysAvailable() {
        let localization = LocalizationStore(settings: AppSettings(defaults: .standard))
        #expect(PresetApplication.installedBundleIdentifiers.contains(
            PresetApplication.remoteMic.bundleIdentifier
        ))
        #expect(ButtonAction.pickerActions(
            installedBundleIdentifiers: PresetApplication.installedBundleIdentifiers,
            current: .escape,
            experimentalContinuousRecordingEnabled: false
        ).contains(.openRemoteMic))
        #expect(
            ButtonAction.openRemoteMic.displayName(using: localization) ==
                localization.text("action.open_remote_mic")
        )
    }

    @Test func pickerHidesUnavailableApplicationsAndPreservesCurrentMissingSelection() {
        let installed = Set([PresetApplication.codex.bundleIdentifier])
        let normalSelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .escape,
            experimentalContinuousRecordingEnabled: false
        )
        #expect(normalSelection.contains(.openCodex))
        #expect(!normalSelection.contains(.openClaude))

        let missingSelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .openClaude,
            experimentalContinuousRecordingEnabled: false
        )
        #expect(missingSelection.contains(.openClaude))
        #expect(!missingSelection.contains(.openXcode))
    }

    @Test func applicationActionsNeverRepeat() {
        let applicationActions = ButtonAction.allCases.filter { $0.presetApplication != nil }
        #expect(applicationActions.count == PresetApplication.allCases.count)
        #expect(applicationActions.allSatisfy { !$0.allowsRepeat })
        #expect(!ButtonAction.openCustomApplication.allowsRepeat)
    }

    @Test func weChatVoiceMessageIsAvailableForAnyButton() {
        let installed = Set<String>()
        let powerSelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .escape,
            experimentalContinuousRecordingEnabled: false,
            button: .power
        )
        let otherSelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .escape,
            experimentalContinuousRecordingEnabled: false,
            button: .up
        )

        #expect(powerSelection.contains(.wechatVoiceMessage))
        #expect(otherSelection.contains(.wechatVoiceMessage))
        #expect(ButtonAction.wechatVoiceMessage.isHoldAction)
        #expect(!ButtonAction.wechatVoiceMessage.allowsRepeat)
    }

    @Test func buttonActionsAreSeparatedIntoClearFlatCategories() {
        #expect(ButtonAction.escape.category == .basicKeys)
        #expect(ButtonAction.commandReturn.category == .basicKeys)
        #expect(ButtonAction.commandCopy.category == .basicKeys)
        #expect(ButtonAction.commandClose.category == .basicKeys)
        #expect(ButtonAction.commandUndo.category == .basicKeys)
        #expect(ButtonAction.commandDelete.category == .basicKeys)
        #expect(ButtonAction.volumeUp.category == .systemAndMedia)
        #expect(ButtonAction.previousCommandLeft.category == .systemAndMedia)
        #expect(ButtonAction.nextCommandRight.category == .systemAndMedia)
        #expect(ButtonAction.codexStopGeneration.category == .applicationSpecific)
        #expect(ButtonAction.codexPageUp.category == .applicationSpecific)
        #expect(ButtonAction.wechatVoiceMessage.category == .applicationSpecific)
        #expect(ButtonAction.customShortcut.category == .custom)
        #expect(ButtonAction.openCustomApplication.category == .custom)
        #expect(ButtonAction.openCodex.category == .applications)
        #expect(Set(ButtonAction.allCases.map(\.category)) == Set(ButtonActionCategory.allCases))
    }

    @Test func customShortcutsNeverRepeatWhileNavigationActionsStillCan() {
        #expect(!ButtonAction.customShortcut.allowsRepeat)
        #expect(!ButtonAction.commandReturn.allowsRepeat)
        #expect(!ButtonAction.shiftReturn.allowsRepeat)
        #expect(!ButtonAction.commandCopy.allowsRepeat)
        #expect(!ButtonAction.commandPaste.allowsRepeat)
        #expect(!ButtonAction.commandClose.allowsRepeat)
        #expect(!ButtonAction.commandQuit.allowsRepeat)
        #expect(!ButtonAction.commandCut.allowsRepeat)
        #expect(!ButtonAction.commandSelectAll.allowsRepeat)
        #expect(!ButtonAction.commandUndo.allowsRepeat)
        #expect(!ButtonAction.commandRedo.allowsRepeat)
        #expect(!ButtonAction.commandFind.allowsRepeat)
        #expect(!ButtonAction.commandSave.allowsRepeat)
        #expect(!ButtonAction.commandDelete.allowsRepeat)
        #expect(!ButtonAction.previousCommandLeft.allowsRepeat)
        #expect(!ButtonAction.nextCommandRight.allowsRepeat)
        #expect(ButtonAction.arrowUp.allowsRepeat)
        #expect(ButtonAction.volumeDown.allowsRepeat)
        #expect(ButtonAction.scrollUp.allowsRepeat)
        #expect(ButtonAction.scrollDown.allowsRepeat)
        #expect(ButtonAction.deleteBackward.allowsRepeat)
    }

    @Test func electronComposerFocusWaitsLongEnoughForTheManualAccessibilityTree() {
        // 真机上 Electron 收到 AXManualAccessibility 后约 1~2 秒才建好 web 内容树。
        #expect(KeyboardInjector.manualAccessibilityAttribute == "AXManualAccessibility")
        #expect(KeyboardInjector.enhancedUserInterfaceAttribute == "AXEnhancedUserInterface")
        #expect(KeyboardInjector.composerFocusMaximumAttempts == 12)
        #expect(KeyboardInjector.composerFocusRetryMilliseconds == 250)
        let retryWindow =
            (KeyboardInjector.composerFocusMaximumAttempts - 1) *
            KeyboardInjector.composerFocusRetryMilliseconds
        #expect(retryWindow >= 2_000)
    }

    @Test func manualAccessibilityFailuresAreNamedAndLoggedOnlyWhenTheyAddInformation() {
        #expect(KeyboardInjector.manualAccessibilityResultName(.success) == "success")
        #expect(
            KeyboardInjector.manualAccessibilityResultName(.attributeUnsupported)
                == "attribute_unsupported"
        )
        #expect(KeyboardInjector.manualAccessibilityResultName(.cannotComplete) == "cannot_complete")
        #expect(KeyboardInjector.manualAccessibilityResultName(.apiDisabled) == "api_disabled")
        #expect(KeyboardInjector.manualAccessibilityResultName(.actionUnsupported).hasPrefix("error_"))

        // Chromium 私有属性成功时不尝试降级；只有 attribute_unsupported 才会走
        // AXEnhancedUserInterface，日志必须说明是哪个属性回答的。
        #expect(KeyboardInjector.manualAccessibilityResultToken(
            primary: .success,
            fallback: nil
        ) == "success")
        #expect(KeyboardInjector.manualAccessibilityResultToken(
            primary: .attributeUnsupported,
            fallback: .success
        ) == "fallback_enhanced_success")
        #expect(KeyboardInjector.manualAccessibilityResultToken(
            primary: .attributeUnsupported,
            fallback: .cannotComplete
        ) == "fallback_enhanced_cannot_complete")
        #expect(KeyboardInjector.manualAccessibilityResultToken(
            primary: .attributeUnsupported,
            fallback: .attributeUnsupported
        ) == "fallback_enhanced_attribute_unsupported")
        #expect(KeyboardInjector.manualAccessibilityResultToken(
            primary: .cannotComplete,
            fallback: nil
        ) == "cannot_complete")

        #expect(KeyboardInjector.manualAccessibilityEffectiveResult(
            primary: .success,
            fallback: nil
        ) == .success)
        #expect(KeyboardInjector.manualAccessibilityEffectiveResult(
            primary: .attributeUnsupported,
            fallback: .success
        ) == .success)
        #expect(KeyboardInjector.manualAccessibilityEffectiveResult(
            primary: .attributeUnsupported,
            fallback: .attributeUnsupported
        ) == .attributeUnsupported)
        #expect(KeyboardInjector.manualAccessibilityEffectiveResult(
            primary: .cannotComplete,
            fallback: nil
        ) == .cannotComplete)

        // 首次尝试总是记录一行，之后只记录第一次真正建树成功。
        #expect(KeyboardInjector.shouldLogManualAccessibility(
            result: .attributeUnsupported,
            attempt: 0,
            alreadyLoggedSuccess: false
        ))
        #expect(!KeyboardInjector.shouldLogManualAccessibility(
            result: .attributeUnsupported,
            attempt: 4,
            alreadyLoggedSuccess: false
        ))
        #expect(KeyboardInjector.shouldLogManualAccessibility(
            result: .success,
            attempt: 4,
            alreadyLoggedSuccess: false
        ))
        #expect(!KeyboardInjector.shouldLogManualAccessibility(
            result: .success,
            attempt: 4,
            alreadyLoggedSuccess: true
        ))
    }

    @Test func hidReportsRouteOnlyToTheirActivePhysicalRemote() {
        #expect(HIDRemoteMonitor.acceptsReport(
            reportingFingerprint: "remote-a",
            activeFingerprint: "remote-a"
        ))
        #expect(!HIDRemoteMonitor.acceptsReport(
            reportingFingerprint: "remote-a",
            activeFingerprint: "remote-b"
        ))
        #expect(!HIDRemoteMonitor.acceptsReport(
            reportingFingerprint: nil,
            activeFingerprint: "remote-a"
        ))
    }

    @Test func partiallySuppressedHIDOnlyAcceptsSafeDeviceLocations() {
        #expect(HIDRemoteMonitor.isLocationAllowed(
            locationID: 202,
            allowedLocationIDs: Set([202])
        ))
        #expect(!HIDRemoteMonitor.isLocationAllowed(
            locationID: 101,
            allowedLocationIDs: Set([202])
        ))
        #expect(!HIDRemoteMonitor.isLocationAllowed(
            locationID: nil,
            allowedLocationIDs: Set([202])
        ))
        #expect(HIDRemoteMonitor.isLocationAllowed(
            locationID: nil,
            allowedLocationIDs: nil
        ))
    }

    @Test func rawHardwareRepeatStaysLatchedUntilAStableRelease() throws {
        let suiteName = "RemoteButtonsTests.rawHardwareRepeat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = HIDRemoteMonitor(settings: AppSettings(defaults: defaults))

        let otherApp = PresetApplication.codex.bundleIdentifier
        #expect(monitor.shouldAcceptRawPress(
            button: .up,
            action: .customShortcut,
            frontmostBundleIdentifier: otherApp
        ))
        #expect(!monitor.shouldAcceptRawPress(
            button: .up,
            action: .customShortcut,
            frontmostBundleIdentifier: otherApp
        ))
        monitor.finishNonRepeatablePress(.up)
        #expect(monitor.shouldAcceptRawPress(
            button: .up,
            action: .customShortcut,
            frontmostBundleIdentifier: otherApp
        ))
        #expect(monitor.shouldAcceptRawPress(
            button: .up,
            action: .arrowUp,
            frontmostBundleIdentifier: otherApp
        ))
        #expect(monitor.shouldAcceptRawPress(
            button: .up,
            action: .arrowUp,
            frontmostBundleIdentifier: otherApp
        ))
    }

    @Test func navigationRepeatStopsOnlyWhileRemoteMicIsFrontmost() throws {
        let remoteMic = PresetApplication.remoteMic.bundleIdentifier
        for action in [
            ButtonAction.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .deleteBackward,
        ] {
            #expect(!HIDRemoteMonitor.shouldRepeat(
                action: action,
                frontmostBundleIdentifier: remoteMic
            ))
            #expect(HIDRemoteMonitor.shouldRepeat(
                action: action,
                frontmostBundleIdentifier: PresetApplication.codex.bundleIdentifier
            ))
        }
        #expect(HIDRemoteMonitor.shouldRepeat(
            action: .volumeDown,
            frontmostBundleIdentifier: remoteMic
        ))

        let suiteName = "RemoteButtonsTests.frontmostRepeat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = HIDRemoteMonitor(settings: AppSettings(defaults: defaults))
        #expect(monitor.shouldAcceptRawPress(
            button: .left,
            action: .arrowLeft,
            frontmostBundleIdentifier: remoteMic
        ))
        #expect(!monitor.shouldAcceptRawPress(
            button: .left,
            action: .arrowLeft,
            frontmostBundleIdentifier: remoteMic
        ))
    }

    @Test func continuousRecordingIsInternalAndNeverRepeats() {
        #expect(ButtonAction.toggleLongRecording.isAppInternal)
        #expect(!ButtonAction.toggleLongRecording.allowsRepeat)
        #expect(!ButtonAction.escape.isAppInternal)
        #expect(!ButtonAction.toggleLongRecording.isEnabled(
            experimentalContinuousRecordingEnabled: false
        ))
        #expect(ButtonAction.toggleLongRecording.isEnabled(
            experimentalContinuousRecordingEnabled: true
        ))
    }

    @Test func pickerRequiresContinuousRecordingExperimentButPreservesLegacySelection() {
        let installed = Set<String>()
        let disabled = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .escape,
            experimentalContinuousRecordingEnabled: false
        )
        #expect(!disabled.contains(.toggleLongRecording))

        let enabled = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .escape,
            experimentalContinuousRecordingEnabled: true
        )
        #expect(enabled.contains(.toggleLongRecording))

        let legacySelection = ButtonAction.pickerActions(
            installedBundleIdentifiers: installed,
            current: .toggleLongRecording,
            experimentalContinuousRecordingEnabled: false
        )
        #expect(legacySelection.contains(.toggleLongRecording))
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

        let legacyConfigured = try JSONDecoder().decode(
            ConfiguredButtonAction.self,
            from: Data(#"{"action":"openCodex","shortcut":null}"#.utf8)
        )
        #expect(legacyConfigured.applicationProfileID == nil)
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

    @Test func shortcutPresetsAndStandardKeyboardExposeReservedAndUnpressableChoices() throws {
        let spotlight = KeyboardShortcutPreset.spotlight.shortcut
        #expect(spotlight.keyCode == 49)
        #expect(spotlight.modifierFlags == .command)

        let forceQuit = KeyboardShortcutPreset.forceQuit.shortcut
        #expect(forceQuit.keyCode == 53)
        #expect(forceQuit.modifierFlags == [.option, .command])

        let allKeys = StandardKeyboardKey.allKeys
        #expect(Set(allKeys.map(\.id)).count == allKeys.count)
        #expect(allKeys.contains { $0.keyCode == 122 && $0.keyLabel == "F1" })
        #expect(allKeys.contains { $0.keyCode == 90 && $0.keyLabel == "F20" })
        #expect(allKeys.contains { $0.keyCode == 117 && $0.keyLabel == "⌦" })
        #expect(allKeys.contains { $0.keyCode == 76 && $0.keyLabel == "Enter" })
        #expect(allKeys.contains { $0.keyCode == 123 && $0.keyLabel == "←" })

        let f20 = try #require(allKeys.first { $0.keyCode == 90 && $0.keyLabel == "F20" })
        let commandF20 = f20.shortcut(modifierFlags: [.command, .function])
        #expect(commandF20.modifierFlags == [.command, .function])
        #expect(commandF20.keyCode == 90)
    }

    @Test func standaloneLeftAndRightModifiersPreserveSideAndReleaseCleanly() throws {
        let leftOption = StandaloneKeyboardModifier.leftOption.shortcut
        let rightOption = StandaloneKeyboardModifier.rightOption.shortcut

        #expect(leftOption.keyCode == 58)
        #expect(rightOption.keyCode == 61)
        #expect(leftOption.modifierFlags == .option)
        #expect(rightOption.modifierFlags == .option)
        #expect(leftOption.standaloneModifier == .leftOption)
        #expect(rightOption.standaloneModifier == .rightOption)
        #expect(try JSONDecoder().decode(
            CustomKeyboardShortcut.self,
            from: JSONEncoder().encode(rightOption)
        ) == rightOption)

        var postedKeys: [(CGKeyCode, CGEventFlags)] = []
        var postedStates: [(CGKeyCode, Bool, CGEventFlags)] = []
        #expect(KeyboardInjector.send(
            .customShortcut,
            shortcut: rightOption,
            accessibilityTrusted: { true },
            keyPoster: { postedKeys.append(($0, $1)) },
            keyStatePoster: {
                postedStates.append(($0, $1, $2))
                return true
            }
        ))

        #expect(postedKeys.isEmpty)
        #expect(postedStates.count == 2)
        #expect(postedStates[0].0 == 61)
        #expect(postedStates[0].1)
        #expect(postedStates[0].2 == .maskAlternate)
        #expect(postedStates[1].0 == 61)
        #expect(!postedStates[1].1)
        #expect(postedStates[1].2.isEmpty)
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

    @Test func fixedCompoundShortcutsPostExpectedKeyCodesAndModifiers() {
        let expected: [(ButtonAction, CGKeyCode, CGEventFlags)] = [
            (.commandReturn, 36, .maskCommand),
            (.shiftReturn, 36, .maskShift),
            (.commandCopy, 8, .maskCommand),
            (.commandPaste, 9, .maskCommand),
            (.commandClose, 13, .maskCommand),
            (.commandQuit, 12, .maskCommand),
            (.commandCut, 7, .maskCommand),
            (.commandSelectAll, 0, .maskCommand),
            (.commandUndo, 6, .maskCommand),
            (.commandRedo, 6, [.maskCommand, .maskShift]),
            (.commandFind, 3, .maskCommand),
            (.commandSave, 1, .maskCommand),
            (.commandDelete, 51, .maskCommand),
            (.previousCommandLeft, 123, .maskCommand),
            (.nextCommandRight, 124, .maskCommand),
        ]

        for (action, keyCode, modifiers) in expected {
            var posted: (CGKeyCode, CGEventFlags)?
            #expect(KeyboardInjector.send(
                action,
                accessibilityTrusted: { true },
                keyPoster: { posted = ($0, $1) }
            ))
            #expect(posted?.0 == keyCode)
            #expect(posted?.1 == modifiers)
        }
    }

    @Test func scrollActionsPostExpectedWheelDeltas() {
        var deltas: [Int32] = []
        let poster: KeyboardInjector.ScrollEventPoster = { delta in
            deltas.append(delta)
            return true
        }

        #expect(KeyboardInjector.send(
            .scrollUp,
            accessibilityTrusted: { true },
            scrollEventPoster: poster
        ))
        #expect(KeyboardInjector.send(
            .scrollDown,
            accessibilityTrusted: { true },
            scrollEventPoster: poster
        ))
        #expect(deltas == [5, -5])
    }

    @Test func scrollDeltaHonorsSpeedAndDirection() {
        #expect(KeyboardInjector.scrollDelta(for: .scrollUp, speed: 7, inverted: false) == 7)
        #expect(KeyboardInjector.scrollDelta(for: .scrollDown, speed: 7, inverted: false) == -7)
        #expect(KeyboardInjector.scrollDelta(for: .scrollUp, speed: 7, inverted: true) == -7)
        #expect(KeyboardInjector.scrollDelta(for: .scrollDown, speed: 7, inverted: true) == 7)
        #expect(KeyboardInjector.scrollDelta(for: .scrollUp, speed: 99, inverted: false) == 10)
    }

    @Test func codexActionsPostStopAndScrollToLatestShortcuts() {
        var posted: [(CGKeyCode, CGEventFlags)] = []
        let poster: KeyboardInjector.KeyPoster = { code, flags in
            posted.append((code, flags))
        }

        #expect(KeyboardInjector.send(
            .codexStopGeneration,
            accessibilityTrusted: { true },
            keyPoster: poster
        ))
        #expect(KeyboardInjector.send(
            .codexScrollToLatest,
            accessibilityTrusted: { true },
            keyPoster: poster
        ))
        #expect(posted.count == 2)
        #expect(posted[0].0 == 53)
        #expect(posted[0].1 == [])
        #expect(posted[1].0 == 119)
        #expect(posted[1].1 == .maskCommand)
    }

    @Test func codexPageActionsPostIndependentLargeScrollDeltas() {
        var deltas: [Int32] = []
        var intervals: [Int32] = []
        let poster: KeyboardInjector.PageScrollEventPoster = { delta, interval in
            deltas.append(delta)
            intervals.append(interval)
            return true
        }

        #expect(KeyboardInjector.send(
            .codexPageUp,
            accessibilityTrusted: { true },
            pageScrollEventPoster: poster
        ))
        #expect(KeyboardInjector.send(
            .codexPageDown,
            accessibilityTrusted: { true },
            pageScrollEventPoster: poster,
            pageScrollLines: 14,
            pageScrollIntervalMilliseconds: 15
        ))
        #expect(deltas == [12, -14])
        #expect(intervals == [12, 15])
        #expect(KeyboardInjector.codexPageScrollDelta(for: .codexPageUp) == 12)
        #expect(KeyboardInjector.codexPageScrollDelta(for: .codexPageDown) == -12)
        #expect(KeyboardInjector.codexPageScrollDelta(for: .codexPageUp, lines: 50) == 50)
        #expect(KeyboardInjector.codexPageScrollDelta(for: .codexPageDown, lines: 99) == -50)
        #expect(!ButtonAction.codexPageUp.allowsRepeat)
        #expect(!ButtonAction.codexPageDown.allowsRepeat)
    }

    @Test func applicationSpecificActionsUseSelectedApplicationNameAndBundleScope() {
        let localization = LocalizationStore(settings: AppSettings(defaults: .standard))
        #expect(ButtonAction.codexPageUp.isAvailable(
            forApplicationBundleIdentifier: PresetApplication.codex.bundleIdentifier
        ))
        #expect(!ButtonAction.codexPageUp.isAvailable(
            forApplicationBundleIdentifier: "com.example.other"
        ))
        #expect(ButtonAction.codexPageUp.displayName(
            using: localization,
            applicationName: "ChatGPT"
        ).contains("ChatGPT"))
        #expect(ButtonAction.wechatVoiceMessage.isAvailable(
            forApplicationBundleIdentifier: PresetApplication.weChat.bundleIdentifier
        ))
        #expect(!ButtonAction.wechatVoiceMessage.isAvailable(
            forApplicationBundleIdentifier: PresetApplication.codex.bundleIdentifier
        ))
        #expect(ButtonAction.wechatVoiceMessage.displayName(
            using: localization,
            applicationName: "微信"
        ).contains("微信"))
    }

    @Test func phoneVoicePostsFunctionKeyDownAndUp() {
        var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
        let poster: KeyboardInjector.KeyStatePoster = { code, isDown, flags in
            posted.append((code, isDown, flags))
            return true
        }

        #expect(KeyboardInjector.setFunctionKeyPressed(
            true,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(KeyboardInjector.setFunctionKeyPressed(
            false,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(posted.count == 2)
        #expect(posted[0].0 == KeyboardInjector.functionKeyCode)
        #expect(posted[0].1)
        #expect(posted[0].2 == .maskSecondaryFn)
        #expect(posted[1].0 == KeyboardInjector.functionKeyCode)
        #expect(!posted[1].1)
        #expect(posted[1].2.isEmpty)
    }

    @Test func phoneVoiceFunctionKeyRequiresAccessibility() {
        var didPost = false
        #expect(!KeyboardInjector.setFunctionKeyPressed(
            true,
            accessibilityTrusted: { false },
            keyStatePoster: { _, _, _ in
                didPost = true
                return true
            }
        ))
        #expect(!didPost)
    }

    @Test func rightOptionVoiceKeyPostsRightOptionDownAndUp() {
        var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
        let poster: KeyboardInjector.KeyStatePoster = { code, isDown, flags in
            posted.append((code, isDown, flags))
            return true
        }

        #expect(KeyboardInjector.setRightOptionKeyPressed(
            true,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(KeyboardInjector.setRightOptionKeyPressed(
            false,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(posted.count == 2)
        #expect(posted[0].0 == KeyboardInjector.rightOptionKeyCode)
        #expect(posted[0].1)
        #expect(posted[0].2 == .maskAlternate)
        #expect(posted[1].0 == KeyboardInjector.rightOptionKeyCode)
        #expect(!posted[1].1)
        #expect(posted[1].2.isEmpty)
    }

    @Test func rightOptionVoiceKeyRequiresAccessibility() {
        var didPost = false
        #expect(!KeyboardInjector.setRightOptionKeyPressed(
            true,
            accessibilityTrusted: { false },
            keyStatePoster: { _, _, _ in
                didPost = true
                return true
            }
        ))
        #expect(!didPost)
    }

    @Test func unconfiguredCustomShortcutDoesNotReportPermissionFailure() {
        #expect(KeyboardInjector.send(
            .customShortcut,
            accessibilityTrusted: { false }
        ))
    }

    @Test func missingApplicationIsHandledWithoutPermissionFailure() {
        #expect(KeyboardInjector.send(.openCodex, applicationURL: { _ in nil }))
        #expect(KeyboardInjector.send(.openCustomApplication))
    }

    @Test func customApplicationLaunchUsesTheSelectedProfileAndFocusStrategy() {
        let profile = CustomApplicationProfile(
            displayName: "Example Agent",
            bundleIdentifier: "com.example.agent",
            applicationPath: "/Applications/Example Agent.app",
            focusStrategy: .recordedAccessibility,
            accessibilityTarget: AccessibilityFocusTarget(
                role: "AXTextArea",
                identifier: "composer",
                title: "",
                description: "Message input",
                help: "",
                placeholder: "Ask anything",
                context: "conversation composer",
                windowTitle: "Example Agent",
                normalizedFrame: nil
            )
        )
        let applicationURL = URL(fileURLWithPath: profile.applicationPath)
        var openedProfile: CustomApplicationProfile?
        var focusedProfile: CustomApplicationProfile?
        var focusedPID: pid_t?

        #expect(KeyboardInjector.send(
            .openCustomApplication,
            applicationProfile: profile,
            customApplicationURL: { _ in applicationURL },
            customApplicationOpener: { _, application, completion in
                openedProfile = application
                completion(4_242, nil)
            },
            customApplicationFocuser: { application, processIdentifier, _ in
                focusedProfile = application
                focusedPID = processIdentifier
            }
        ))
        #expect(openedProfile == profile)
        #expect(focusedProfile == profile)
        #expect(focusedPID == 4_242)
    }

    @Test func recordedAccessibilityMatchingPrefersRecordedSemanticsAndRejectsSensitiveFields() {
        let target = AccessibilityFocusTarget(
            role: "AXTextArea",
            identifier: "prompt-editor",
            title: "",
            description: "Message input",
            help: "",
            placeholder: "Ask anything",
            context: "conversation composer",
            windowTitle: "Agent",
            normalizedFrame: NormalizedAccessibilityFrame(
                x: 0.2,
                y: 0.7,
                width: 0.7,
                height: 0.15
            )
        )
        let exact = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "prompt-editor",
            title: "",
            description: "Message input",
            help: "",
            placeholder: "Ask anything",
            context: "conversation composer",
            frame: CGRect(x: 200, y: 560, width: 700, height: 120),
            enabled: true
        )
        let unrelated = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "notes",
            title: "Notes",
            description: "",
            help: "",
            placeholder: "Write notes",
            context: "sidebar notes",
            frame: CGRect(x: 20, y: 80, width: 240, height: 500),
            enabled: true
        )
        let password = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "prompt-editor",
            title: "Password",
            description: "Message input",
            help: "",
            placeholder: "Ask anything",
            context: "secret token",
            frame: exact.frame,
            enabled: true
        )
        let windowFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let exactScore = KeyboardInjector.recordedAccessibilityCandidateScore(
            exact,
            target: target,
            windowTitle: "Agent",
            windowFrame: windowFrame
        )
        let unrelatedScore = KeyboardInjector.recordedAccessibilityCandidateScore(
            unrelated,
            target: target,
            windowTitle: "Agent",
            windowFrame: windowFrame
        )
        #expect(exactScore != nil)
        #expect(exactScore ?? 0 > unrelatedScore ?? 0)
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(
            password,
            target: target,
            windowTitle: "Agent",
            windowFrame: windowFrame
        ) == nil)
    }

    @Test func applicationLaunchFailureIsHandledWithoutPermissionFailure() {
        struct LaunchFailure: Error {}
        var attemptedApplication: PresetApplication?
        var focusAttempted = false

        let handled = KeyboardInjector.send(
            .openCodex,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Codex.app") },
            applicationOpener: { _, application, completion in
                attemptedApplication = application
                completion(nil, LaunchFailure())
            },
            applicationFocuser: { _, _, _, _ in focusAttempted = true }
        )

        #expect(handled)
        #expect(attemptedApplication == .codex)
        #expect(!focusAttempted)
    }

    @Test func successfulCodexAndClaudeLaunchesPassURLApplicationAndPIDToFocuser() {
        let cases: [(ButtonAction, PresetApplication, pid_t)] = [
            (.openCodex, .codex, 4_242),
            (.openClaude, .claude, 4_243),
        ]

        for (action, expectedApplication, expectedProcessIdentifier) in cases {
            let applicationURL = URL(fileURLWithPath: "/Applications/\(expectedApplication.rawValue).app")
            var focusedApplication: PresetApplication?
            var focusedURL: URL?
            var focusedProcessIdentifier: pid_t?

            let handled = KeyboardInjector.send(
                action,
                applicationURL: { _ in applicationURL },
                applicationOpener: { _, _, completion in completion(expectedProcessIdentifier, nil) },
                applicationFocuser: { url, application, processIdentifier, _ in
                    focusedURL = url
                    focusedApplication = application
                    focusedProcessIdentifier = processIdentifier
                }
            )

            #expect(handled)
            #expect(focusedURL == applicationURL)
            #expect(focusedApplication == expectedApplication)
            #expect(focusedProcessIdentifier == expectedProcessIdentifier)
        }
    }

    @Test func applicationsWithoutFocusStrategyOnlyActivate() {
        var focusAttempted = false
        #expect(KeyboardInjector.send(
            .openSafari,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Safari.app") },
            applicationOpener: { _, _, completion in completion(123, nil) },
            applicationFocuser: { _, _, _, _ in focusAttempted = true }
        ))
        #expect(!focusAttempted)
    }

    @Test func newerApplicationFocusRequestInvalidatesOlderRequest() {
        let gate = ApplicationFocusRequestGate()
        let first = gate.begin()
        #expect(gate.isCurrent(first))

        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
    }

    @Test func composerCandidateRankingPrefersWideLowerComposerAndRejectsSensitiveFields() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let candidates = [
            KeyboardInjector.AccessibilityTextCandidate(
                role: "AXTextField",
                identifier: "global-search",
                title: "Search",
                description: "",
                help: "",
                placeholder: "Search conversations",
                context: "",
                frame: CGRect(x: 100, y: 60, width: 500, height: 36),
                enabled: true
            ),
            KeyboardInjector.AccessibilityTextCandidate(
                role: "AXTextField",
                identifier: "api-key",
                title: "",
                description: "",
                help: "",
                placeholder: "API Key",
                context: "Settings",
                frame: CGRect(x: 100, y: 500, width: 700, height: 36),
                enabled: true
            ),
            KeyboardInjector.AccessibilityTextCandidate(
                role: "AXTextArea",
                identifier: "prompt-editor",
                title: "",
                description: "Message input",
                help: "",
                placeholder: "Ask anything",
                context: "conversation composer",
                frame: CGRect(x: 100, y: 620, width: 800, height: 120),
                enabled: true
            ),
            KeyboardInjector.AccessibilityTextCandidate(
                role: "AXTextArea",
                identifier: "notes",
                title: "",
                description: "",
                help: "",
                placeholder: "",
                context: "",
                frame: CGRect(x: 100, y: 100, width: 800, height: 300),
                enabled: true
            ),
        ]

        #expect(KeyboardInjector.bestComposerCandidateIndex(candidates, windowFrame: windowFrame) == 2)
        #expect(KeyboardInjector.composerCandidateScore(candidates[0], windowFrame: windowFrame) == nil)
        #expect(KeyboardInjector.composerCandidateScore(candidates[1], windowFrame: windowFrame) == nil)

        let terminal = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "terminal-input",
            title: "Terminal",
            description: "Shell console",
            help: "",
            placeholder: "",
            context: "terminal panel",
            frame: CGRect(x: 50, y: 200, width: 900, height: 500),
            enabled: true
        )
        #expect(KeyboardInjector.composerCandidateScore(terminal, windowFrame: windowFrame) == nil)
    }

    @Test func codexComposerSemanticsAndTraversalPriorityReachTheVisibleEditor() {
        let codexComposer = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "",
            title: "Message ChatGPT",
            description: "",
            help: "",
            placeholder: "Message ChatGPT",
            context: "",
            frame: nil,
            enabled: true
        )
        #expect(KeyboardInjector.composerCandidateScore(codexComposer, windowFrame: nil) == 120)

        let windowFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let transcriptPriority = KeyboardInjector.accessibilityTraversalPriority(
            role: "AXGroup",
            frame: CGRect(x: 200, y: 80, width: 700, height: 520),
            windowFrame: windowFrame
        )
        let composerPriority = KeyboardInjector.accessibilityTraversalPriority(
            role: "AXTextArea",
            frame: CGRect(x: 200, y: 650, width: 700, height: 100),
            windowFrame: windowFrame
        )
        #expect(composerPriority > transcriptPriority)
        #expect(KeyboardInjector.maximumAccessibilityTraversalCount > 1_500)
        #expect(KeyboardInjector.accessibilityChildAttributes == [
            "AXChildrenInNavigationOrder", "AXVisibleChildren", "AXContents", "AXChildren",
        ])
    }

    @Test func cmuxTerminalRankingRequiresItsExplicitEditableAccessibilityElement() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let sidebar = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "sidebar-note",
            title: "Terminal notes",
            description: "",
            help: "",
            placeholder: "",
            context: "sidebar",
            frame: CGRect(x: 800, y: 100, width: 180, height: 500),
            enabled: true,
            selectedContext: true
        )
        let terminal = KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea",
            identifier: "",
            title: "",
            description: "",
            help: "Terminal content area",
            placeholder: "",
            context: "",
            frame: CGRect(x: 100, y: 100, width: 680, height: 600),
            enabled: true,
            selectedContext: true
        )

        #expect(KeyboardInjector.cmuxTerminalCandidateScore(sidebar, windowFrame: windowFrame) == nil)
        #expect(KeyboardInjector.bestCmuxTerminalCandidateIndex(
            [sidebar, terminal],
            windowFrame: windowFrame
        ) == 1)
    }

    @Test func cmuxFocusRequiresTheApplicationFocusedElementToMatchTheTerminal() {
        #expect(!KeyboardInjector.accessibilityFocusIsConfirmed(
            elementFocused: true,
            applicationFocusedElementMatches: false,
            requiresApplicationFocusedElement: true
        ))
        #expect(KeyboardInjector.accessibilityFocusIsConfirmed(
            elementFocused: false,
            applicationFocusedElementMatches: true,
            requiresApplicationFocusedElement: true
        ))
        #expect(KeyboardInjector.accessibilityFocusIsConfirmed(
            elementFocused: true,
            applicationFocusedElementMatches: false,
            requiresApplicationFocusedElement: false
        ))
    }

    @Test func cmuxFocusRecoveryUsesCmuxOwnedForceFocusShortcuts() {
        let terminalFrame = CGRect(x: 300, y: 100, width: 600, height: 600)
        let textBoxFrame = CGRect(x: 320, y: 620, width: 560, height: 60)
        let leftSidebarFrame = CGRect(x: 40, y: 100, width: 240, height: 600)
        let rightSidebarFrame = CGRect(x: 920, y: 100, width: 240, height: 600)

        #expect(KeyboardInjector.cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: "AXTextArea", focusedFrame: textBoxFrame, terminalFrame: terminalFrame
        ) == 0)
        #expect(KeyboardInjector.cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: "AXOutline", focusedFrame: rightSidebarFrame, terminalFrame: terminalFrame
        ) == 14)
        #expect(KeyboardInjector.cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: "AXTable", focusedFrame: leftSidebarFrame, terminalFrame: terminalFrame
        ) == nil)
        #expect(KeyboardInjector.cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: "AXWindow", focusedFrame: nil, terminalFrame: terminalFrame
        ) == nil)
    }

    @Test func liveCmuxFrontmostFocusUsesTheProductionOpenAction() async throws {
        guard ProcessInfo.processInfo.environment["REMOTEMIC_LIVE_CMUX_TEST"] == "1" else { return }
        let application = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: PresetApplication.cmux.bundleIdentifier).first
        )
        #expect(KeyboardInjector.send(.openCmux))
        try await Task.sleep(for: .seconds(2))
        #expect(KeyboardInjector.cmuxTerminalIsApplicationFocused(
            processIdentifier: application.processIdentifier
        ))
    }

    @Test func cmuxFocusUsesCurrentTerminalSurfaceThenFocusesIt() throws {
        let surfaceID = UUID().uuidString
        var commands: [[String]] = []
        var focusedSurfaceID: String?
        let result = KeyboardInjector.focusCmux(
            applicationURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            cliURL: URL(fileURLWithPath: "/Applications/cmux.app/Contents/bin/cmux"),
            runner: { _, arguments, _ in
                commands.append(arguments)
                if arguments[1] == "surface.current" {
                    return KeyboardInjector.CmuxCommandResult(
                        terminationStatus: 0,
                        standardOutput: Data(#"{"surface_id":"\#(surfaceID)","surface_type":"terminal","focused":true}"#.utf8),
                        timedOut: false
                    )
                }
                return KeyboardInjector.CmuxCommandResult(
                    terminationStatus: 0,
                    standardOutput: Data(#"{"surface_id":"\#(surfaceID)"}"#.utf8),
                    timedOut: false
                )
            },
            terminalFocuser: {
                focusedSurfaceID = $0
                return true
            }
        )

        #expect(result)
        #expect(focusedSurfaceID == surfaceID)
        #expect(commands.count == 2)
        #expect(commands[0] == ["rpc", "surface.current", "{}"])
        #expect(commands[1][0...1] == ["rpc", "surface.focus"])
        let focusParameters = try #require(
            JSONSerialization.jsonObject(with: Data(commands[1][2].utf8)) as? [String: String]
        )
        #expect(focusParameters == ["surface_id": surfaceID])
    }

    @Test func cmuxFocusStopsForNonTerminalInvalidOrCancelledCurrentSurface() {
        let surfaceID = UUID().uuidString
        var commandCount = 0
        let nonTerminal = KeyboardInjector.focusCmux(
            applicationURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            cliURL: URL(fileURLWithPath: "/tmp/cmux"),
            runner: { _, _, _ in
                commandCount += 1
                return KeyboardInjector.CmuxCommandResult(
                    terminationStatus: 0,
                    standardOutput: Data(#"{"surface_id":"\#(surfaceID)","surface_type":"browser"}"#.utf8),
                    timedOut: false
                )
            }
        )
        #expect(!nonTerminal)
        #expect(commandCount == 1)

        var active = true
        commandCount = 0
        let cancelled = KeyboardInjector.focusCmux(
            applicationURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            cliURL: URL(fileURLWithPath: "/tmp/cmux"),
            runner: { _, _, _ in
                commandCount += 1
                active = false
                return KeyboardInjector.CmuxCommandResult(
                    terminationStatus: 0,
                    standardOutput: Data(#"{"surface_id":"\#(surfaceID)","surface_type":"terminal"}"#.utf8),
                    timedOut: false
                )
            },
            canContinue: { active }
        )
        #expect(!cancelled)
        #expect(commandCount == 1)
    }

    @Test func cmuxFocusSafelyStopsOnTimeoutAndInvalidJSON() {
        var commandCount = 0
        let timedOut = KeyboardInjector.focusCmux(
            applicationURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            cliURL: URL(fileURLWithPath: "/tmp/cmux"),
            runner: { _, _, _ in
                commandCount += 1
                return KeyboardInjector.CmuxCommandResult(
                    terminationStatus: -1,
                    standardOutput: Data(),
                    timedOut: true
                )
            }
        )
        #expect(!timedOut)
        #expect(commandCount == 1)

        commandCount = 0
        let invalidJSON = KeyboardInjector.focusCmux(
            applicationURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            cliURL: URL(fileURLWithPath: "/tmp/cmux"),
            runner: { _, _, _ in
                commandCount += 1
                return KeyboardInjector.CmuxCommandResult(
                    terminationStatus: 0,
                    standardOutput: Data("not-json".utf8),
                    timedOut: false
                )
            }
        )
        #expect(!invalidJSON)
        #expect(commandCount == 1)
    }

    @Test func tvDefaultRemainsAppSwitcher() {
        #expect(AppSettings.defaultBindings[.tv] == .appSwitcher)
    }

    @Test func powerDefaultRemainsEscapeWhileExperimentIsUnavailable() {
        #expect(AppSettings.defaultBindings[.power] == .escape)
    }

    @Test func mapsActiveUsagesToButtonsForUIFeedback() {
        #expect(RemoteButton.buttons(for: [0x52, 0x65, 0xFFFF]) == Set<RemoteButton>([.up, .menu]))
    }

    @Test func HIDCallbacksDoNotDeferReportHandling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/HIDRemoteMonitor.swift"), encoding: .utf8)
        #expect(!source.contains("DispatchQueue.main.async"))
    }

    @Test func powerSuppressionIsArmedBeforeButtonCallbacksAndMonitoring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let monitor = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/HIDRemoteMonitor.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"), encoding: .utf8)
        let arm = try #require(monitor.range(of: "eventSuppressor.arm(button: button, edge: .down)"))
        let callback = try #require(monitor.range(of: "onButtonPressed?(profileID, deviceFingerprint, button)"))
        let applySettingsStart = try #require(model.range(of: "func applyHIDSettings()"))
        let applySettingsEnd = try #require(
            model.range(
                of: "func setExperimentalContinuousRecordingEnabled",
                range: applySettingsStart.upperBound..<model.endIndex
            )
        )
        let applySettings = model[applySettingsStart.lowerBound..<applySettingsEnd.lowerBound]
        let map = try #require(
            applySettings.range(of: "powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)")
        )
        let start = try #require(
            applySettings.range(of: "startHIDMonitors(powerKeySuppressed: powerKeySuppressed)")
        )
        #expect(arm.lowerBound < callback.lowerBound)
        #expect(map.lowerBound < start.lowerBound)
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
            accessibilityGranted: true,
            powerKeySuppressed: true
        ))
        #expect(!HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false,
            powerKeySuppressed: true
        ))
        #expect(!HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            powerKeySuppressed: false
        ))
        #expect(HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            powerKeySuppressed: true
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
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            voiceFnTapModeEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .accessibility)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            voiceFnTapModeEnabled: true,
            inputMonitoringGranted: false,
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

    @Test func legacyBindingsMigrateIntoFirstPhysicalRemoteProfile() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyIdentifier = UUID()
        defaults.set(legacyIdentifier.uuidString, forKey: "peripheralIdentifier")
        defaults.set(
            try JSONEncoder().encode([RemoteButton.menu.rawValue: ButtonAction.openCodex]),
            forKey: "buttonBindings"
        )

        let settings = AppSettings(defaults: defaults)
        let profile = try #require(settings.selectedRemoteProfile)
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(profile.bluetoothIdentifier == legacyIdentifier)
        #expect(settings.action(for: .menu) == .openCodex)
    }

    @Test func physicalRemoteProfilesPersistIndependentMappingsAndBindings() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let firstBluetoothID = UUID()
        let secondBluetoothID = UUID()
        let firstProfileID = settings.registerBluetoothRemote(identifier: firstBluetoothID)
        settings.updateRemoteProfile(firstProfileID, model: .rc001, customName: "办公")
        settings.bindHIDFingerprint("hid-one", to: firstProfileID)
        settings.selectRemoteProfile(firstProfileID)
        settings.setAction(.openCodex, for: .menu)

        let secondProfileID = settings.registerBluetoothRemote(identifier: secondBluetoothID)
        settings.updateRemoteProfile(secondProfileID, model: .rc003, customName: "剪辑")
        settings.bindHIDFingerprint("hid-two", to: secondProfileID)
        settings.selectRemoteProfile(secondProfileID)
        settings.setAction(.showDesktop, for: .menu)

        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: firstProfileID
        ).action == .openCodex)
        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: secondProfileID
        ).action == .showDesktop)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.remoteDeviceProfiles.count == 2)
        #expect(restored.profileID(forBluetoothIdentifier: firstBluetoothID) == firstProfileID)
        #expect(restored.profileID(forHIDFingerprint: "hid-two") == secondProfileID)
        #expect(restored.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: firstProfileID
        ).action == .openCodex)
        #expect(restored.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: secondProfileID
        ).action == .showDesktop)
    }

    @Test func applicationMappingProfilesOverrideOnlyTheirBundle() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.setAction(.showDesktop, for: .menu)
        let profileID = settings.addApplicationMappingProfile(
            displayName: "Codex",
            bundleIdentifier: "com.example.codex"
        )
        settings.setAction(
            .codexStopGeneration,
            for: .menu,
            trigger: .singleClick,
            applicationMappingProfileID: profileID
        )
        settings.setScrollSpeed(8, applicationMappingProfileID: profileID)
        settings.setScrollDirectionInverted(true, applicationMappingProfileID: profileID)
        settings.setPageScrollLines(24, applicationMappingProfileID: profileID)
        settings.setPageScrollIntervalMilliseconds(15, applicationMappingProfileID: profileID)

        let appScrollSettings = settings.scrollSettings(
            forApplicationBundleIdentifier: "com.example.codex"
        )
        #expect(appScrollSettings == ApplicationScrollSettings(
            scrollSpeed: 8,
            scrollDirectionInverted: true,
            pageScrollLines: 24,
            pageScrollIntervalMilliseconds: 15
        ))
        #expect(settings.scrollSettings(
            forApplicationBundleIdentifier: "com.example.other"
        ) == settings.globalScrollSettings)

        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: settings.selectedRemoteProfileID,
            applicationBundleIdentifier: "com.example.codex"
        ).action == .codexStopGeneration)
        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: settings.selectedRemoteProfileID,
            applicationBundleIdentifier: "com.example.other"
        ).action == .showDesktop)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.applicationMappingProfiles.count == 1)
        #expect(restored.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: restored.selectedRemoteProfileID,
            applicationBundleIdentifier: "com.example.codex"
        ).action == .codexStopGeneration)
        #expect(restored.scrollSettings(
            forApplicationBundleIdentifier: "com.example.codex"
        ) == ApplicationScrollSettings(
            scrollSpeed: 8,
            scrollDirectionInverted: true,
            pageScrollLines: 24,
            pageScrollIntervalMilliseconds: 15
        ))
    }

    @Test func additionalBluetoothRemoteCopiesCurrentMappingsBeforeIndependentEditing() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let firstProfileID = settings.registerBluetoothRemote(identifier: UUID())
        settings.selectRemoteProfile(firstProfileID)
        let shortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.command, .shift],
            keyLabel: "K"
        )
        settings.setAction(.customShortcut, for: .menu)
        settings.setShortcut(shortcut, for: .menu)
        settings.setAction(.showDesktop, for: .tv, trigger: .doubleClick)

        let secondProfileID = settings.registerBluetoothRemote(identifier: UUID())

        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: secondProfileID
        ).shortcut == shortcut)
        #expect(settings.configuredAction(
            for: .tv,
            trigger: .doubleClick,
            profileID: secondProfileID
        ).action == .showDesktop)

        settings.selectRemoteProfile(secondProfileID)
        settings.setAction(.openCodex, for: .menu)
        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: firstProfileID
        ).action == .customShortcut)
    }

    @Test func HIDRemotesAreAutomaticallyAssignedAndKeepIndependentProfiles() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.setAction(.openCodex, for: .menu)

        let firstProfileID = settings.registerHIDRemote(fingerprint: "hid-one")
        let secondProfileID = settings.registerHIDRemote(fingerprint: "hid-two")

        #expect(firstProfileID != secondProfileID)
        #expect(settings.profileID(forHIDFingerprint: "hid-one") == firstProfileID)
        #expect(settings.profileID(forHIDFingerprint: "hid-two") == secondProfileID)
        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: secondProfileID
        ).action == .openCodex)

        settings.selectRemoteProfile(secondProfileID)
        settings.setAction(.showDesktop, for: .menu)
        #expect(settings.configuredAction(
            for: .menu,
            trigger: .singleClick,
            profileID: firstProfileID
        ).action == .openCodex)
    }

    @Test func automaticHIDAssignmentDoesNotConsumeTheFirstButtonPress() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        #expect(source.contains("settings.registerHIDRemote(fingerprint: fingerprint)"))
        #expect(source.contains("return (resolvedProfileID, !self.macroFeature.isEditorActive)"))
        #expect(!source.contains("pendingHIDBindingProfileID"))
    }

    @Test func unavailableContinuousRecordingExperimentDoesNotReplacePowerShortcut() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let shortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.command],
            keyLabel: "K"
        )
        settings.setAction(.customShortcut, for: .power, trigger: .singleClick)
        settings.setShortcut(shortcut, for: .power, trigger: .singleClick)

        settings.setExperimentalContinuousRecordingEnabled(true)
        #expect(!settings.experimentalContinuousRecordingEnabled)
        #expect(settings.action(for: .power) == .customShortcut)
        #expect(settings.shortcut(for: .power) == shortcut)
        #expect(!settings.customMappingEnabled)
    }

    @Test func unavailableContinuousRecordingExperimentRestoresStalePowerBinding() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "experimentalContinuousRecordingEnabled")
        defaults.set(
            try JSONEncoder().encode([
                RemoteButton.power.rawValue: ButtonAction.toggleLongRecording,
            ]),
            forKey: "buttonBindings"
        )
        defaults.set(
            try JSONEncoder().encode(ConfiguredButtonAction(
                action: .showDesktop,
                shortcut: nil
            )),
            forKey: "continuousRecordingPowerBindingBackup"
        )
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.experimentalContinuousRecordingEnabled)
        #expect(restored.action(for: .power) == .showDesktop)

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            try JSONEncoder().encode([
                RemoteButton.power.rawValue: ButtonAction.toggleLongRecording,
            ]),
            forKey: "buttonBindings"
        )
        let migrated = AppSettings(defaults: defaults)
        #expect(!migrated.experimentalContinuousRecordingEnabled)
        #expect(migrated.action(for: .power) == .escape)
    }

    @Test func importedContinuousRecordingExperimentIsDisabledAndRestoresBackup() throws {
        let sourceSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuiteName))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuiteName) }
        let source = AppSettings(defaults: sourceDefaults)
        let shortcut = CustomKeyboardShortcut(
            keyCode: 8,
            modifierFlags: [.control, .option],
            keyLabel: "C"
        )
        source.setAction(.customShortcut, for: .power, trigger: .singleClick)
        source.setShortcut(shortcut, for: .power, trigger: .singleClick)
        var configuration = try #require(
            JSONSerialization.jsonObject(with: source.exportedConfigurationData()) as? [String: Any]
        )
        var bindings = try #require(configuration["buttonBindings"] as? [String: Any])
        bindings[RemoteButton.power.rawValue] = ButtonAction.toggleLongRecording.rawValue
        configuration["buttonBindings"] = bindings
        configuration["experimentalContinuousRecordingEnabled"] = true
        configuration["continuousRecordingPowerBindingBackup"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ConfiguredButtonAction(
                action: .customShortcut,
                shortcut: shortcut
            ))
        )
        let exported = try JSONSerialization.data(withJSONObject: configuration)

        let targetSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuiteName))
        defer { targetDefaults.removePersistentDomain(forName: targetSuiteName) }
        let target = AppSettings(defaults: targetDefaults)
        try target.importConfiguration(from: exported)
        #expect(!target.experimentalContinuousRecordingEnabled)
        #expect(target.action(for: .power) == .customShortcut)
        #expect(target.shortcut(for: .power) == shortcut)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "experimentalContinuousRecordingEnabled")
        legacyObject.removeValue(forKey: "continuousRecordingPowerBindingBackup")
        try target.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(!target.experimentalContinuousRecordingEnabled)
        #expect(target.action(for: .power) == .escape)
    }

    @Test func voiceFnTapModeExportsAndLegacyImportDisablesIt() throws {
        let sourceSuite = "RemoteMicTests.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let source = AppSettings(defaults: sourceDefaults)
        source.voiceFnTapModeEnabled = true
        let exported = try source.exportedConfigurationData()
        let object = try #require(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        #expect(object["voiceFnTapModeEnabled"] as? Bool == true)

        let targetSuite = "RemoteMicTests.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let target = AppSettings(defaults: targetDefaults)
        try target.importConfiguration(from: exported)
        #expect(target.voiceFnTapModeEnabled)

        var legacyObject = object
        legacyObject.removeValue(forKey: "voiceFnTapModeEnabled")
        target.voiceFnTapModeEnabled = true
        try target.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(!target.voiceFnTapModeEnabled)
    }

    @Test func rightOptionVoiceKeyModeAlwaysFallsBackToFnGlobe() throws {
        let sourceSuite = "RemoteMicTests.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let source = AppSettings(defaults: sourceDefaults)
        source.voiceKeyMode = .rightOptionHold
        #expect(source.voiceKeyMode == .fnGlobe)
        let exported = try source.exportedConfigurationData()
        let object = try #require(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        #expect(object["voiceKeyMode"] as? String == VoiceKeyMode.fnGlobe.rawValue)

        let targetSuite = "RemoteMicTests.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let target = AppSettings(defaults: targetDefaults)
        try target.importConfiguration(from: exported)
        #expect(target.voiceKeyMode == .fnGlobe)

        var legacyObject = object
        legacyObject.removeValue(forKey: "voiceKeyMode")
        try target.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(target.voiceKeyMode == .fnGlobe)
    }

    @Test func trustedPhoneIdentitiesPersistDeduplicateAndClear() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.trustPhoneIdentity("identity-a")
        settings.trustPhoneIdentity("identity-a")
        settings.trustPhoneIdentity("identity-b")

        let restored = AppSettings(defaults: defaults)
        #expect(restored.trustedPhoneIdentityFingerprints == Set(["identity-a", "identity-b"]))
        #expect(restored.isPhoneIdentityTrusted("identity-a"))
        #expect(!restored.isPhoneIdentityTrusted("identity-c"))

        restored.clearTrustedPhoneIdentities()
        #expect(AppSettings(defaults: defaults).trustedPhoneIdentityFingerprints.isEmpty)
    }

    @Test func updateAndLaunchPreferencesPersistAndImportCompatibly() throws {
        let sourceSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuiteName))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuiteName) }
        let sourceSettings = AppSettings(defaults: sourceDefaults)
        #expect(sourceSettings.openMainWindowAtLaunch)
        #expect(!sourceSettings.checksForPreReleaseUpdates)
        sourceSettings.openMainWindowAtLaunch = false
        sourceSettings.checksForPreReleaseUpdates = true
        #expect(!AppSettings(defaults: sourceDefaults).openMainWindowAtLaunch)
        #expect(AppSettings(defaults: sourceDefaults).checksForPreReleaseUpdates)

        let exportedData = try sourceSettings.exportedConfigurationData()
        let targetSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuiteName))
        defer { targetDefaults.removePersistentDomain(forName: targetSuiteName) }
        let targetSettings = AppSettings(defaults: targetDefaults)
        try targetSettings.importConfiguration(from: exportedData)
        #expect(!targetSettings.openMainWindowAtLaunch)
        #expect(targetSettings.checksForPreReleaseUpdates)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: exportedData) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "openMainWindowAtLaunch")
        legacyObject.removeValue(forKey: "checksForPreReleaseUpdates")
        targetSettings.openMainWindowAtLaunch = true
        targetSettings.checksForPreReleaseUpdates = false
        try targetSettings.importConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(targetSettings.openMainWindowAtLaunch)
        #expect(!targetSettings.checksForPreReleaseUpdates)
    }

    @Test func localUsageStatisticsSeparatesTodayWeekAndTotalAndPersists() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let monday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 10
        )))
        let sunday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 9,
            hour: 18
        )))
        let nextMonday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 10,
            hour: 9
        )))

        let settings = AppSettings(defaults: defaults)
        settings.recordButtonPress(at: monday, calendar: calendar)
        settings.recordButtonPress(at: monday, calendar: calendar)
        settings.recordVoiceDuration(60, at: monday, calendar: calendar)
        settings.recordButtonPress(at: sunday, calendar: calendar)
        settings.recordVoiceDuration(120, at: sunday, calendar: calendar)
        settings.recordButtonPress(at: nextMonday, calendar: calendar)
        settings.recordVoiceDuration(300, at: nextMonday, calendar: calendar)

        #expect(settings.usageStatistics(for: .today, at: sunday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 120))
        #expect(settings.usageStatistics(for: .thisWeek, at: sunday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 3, voiceDuration: 180))
        #expect(settings.usageStatistics(for: .today, at: nextMonday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 300))
        #expect(settings.usageStatistics(for: .thisWeek, at: nextMonday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 300))
        #expect(settings.usageStatistics(for: .total, at: nextMonday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 4, voiceDuration: 480))

        let dailyBuckets = settings.dailyUsageStatistics(
            endingAt: nextMonday,
            days: 8,
            calendar: calendar
        )
        #expect(dailyBuckets.count == 8)
        #expect(dailyBuckets.first?.statistics ==
            UsageStatistics(buttonPressCount: 2, voiceDuration: 60))
        #expect(dailyBuckets[6].statistics ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 120))
        #expect(dailyBuckets.last?.statistics ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 300))

        let weeklyBuckets = settings.weeklyUsageStatistics(
            endingAt: nextMonday,
            weeks: 2,
            calendar: calendar
        )
        #expect(weeklyBuckets.count == 2)
        #expect(weeklyBuckets[0].statistics ==
            UsageStatistics(buttonPressCount: 3, voiceDuration: 180))
        #expect(weeklyBuckets[1].statistics ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 300))

        let restored = AppSettings(defaults: defaults)
        #expect(restored.usageStatistics(for: .thisWeek, at: sunday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 3, voiceDuration: 180))
        #expect(restored.usageStatistics(for: .total, at: nextMonday, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 4, voiceDuration: 480))
    }

    @Test func legacyUsageTotalsRemainAvailableWithoutInventingDailyHistory() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(NSNumber(value: UInt64(42)), forKey: "usage.totalButtonPressCount")
        defaults.set(180.0, forKey: "usage.totalVoiceDuration")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.usageStatistics(for: .today) ==
            UsageStatistics(buttonPressCount: 0, voiceDuration: 0))
        #expect(settings.usageStatistics(for: .total) ==
            UsageStatistics(buttonPressCount: 42, voiceDuration: 180))
    }

    @Test func localVoiceSessionRankingKeepsTheLongestTenAndPersists() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        let settings = AppSettings(defaults: defaults)
        for duration in 1...12 {
            settings.recordVoiceDuration(
                TimeInterval(duration),
                at: baseDate.addingTimeInterval(TimeInterval(duration))
            )
        }
        settings.recordVoiceDuration(.nan, at: baseDate)
        settings.recordVoiceDuration(0, at: baseDate)

        #expect(settings.voiceSessionRanking.count == 10)
        #expect(settings.voiceSessionRanking.map(\.duration) == [
            12, 11, 10, 9, 8, 7, 6, 5, 4, 3,
        ])
        #expect(settings.voiceSessionRanking.first?.endedAt == baseDate.addingTimeInterval(12))

        let restored = AppSettings(defaults: defaults)
        #expect(restored.voiceSessionRanking == settings.voiceSessionRanking)
    }

    @Test func localUsageMetadataPersistsSourcesControlsHoursAndVoiceSessions() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let firstButton = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 5,
            hour: 9,
            minute: 15
        )))
        let voiceStartedAt = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 5,
            hour: 14
        )))
        let voiceEndedAt = try #require(
            calendar.date(byAdding: .second, value: 120, to: voiceStartedAt)
        )

        let settings = AppSettings(defaults: defaults)
        settings.recordButtonPress(
            control: .remoteButton(.ok),
            source: .bluetoothRemote,
            at: firstButton,
            calendar: calendar
        )
        settings.recordButtonPress(
            control: .remoteButton(.menu),
            source: .webRemote,
            at: voiceStartedAt,
            calendar: calendar
        )
        settings.recordButtonPress(
            control: .voice,
            source: .nearbyPhone,
            at: voiceStartedAt,
            calendar: calendar
        )
        settings.recordVoiceDuration(
            120,
            startedAt: voiceStartedAt,
            source: .nearbyPhone,
            at: voiceEndedAt,
            calendar: calendar
        )

        let metadata = settings.usageMetadata(
            for: .today,
            at: voiceEndedAt,
            calendar: calendar
        )
        #expect(metadata.firstActivityAt == firstButton)
        #expect(metadata.lastActivityAt == voiceEndedAt)
        #expect(metadata.buttonPressCountBySource[.bluetoothRemote] == 1)
        #expect(metadata.buttonPressCountBySource[.webRemote] == 1)
        #expect(metadata.buttonPressCountBySource[.nearbyPhone] == 1)
        #expect(metadata.buttonPressCountByControl["button.ok"] == 1)
        #expect(metadata.buttonPressCountByControl["button.menu"] == 1)
        #expect(metadata.buttonPressCountByControl["voice"] == 1)
        #expect(metadata.buttonPressCountByHour[9] == 1)
        #expect(metadata.buttonPressCountByHour[14] == 2)
        #expect(metadata.voiceSessionCount == 1)
        #expect(metadata.voiceSessionCountBySource[.nearbyPhone] == 1)
        #expect(metadata.voiceSessionCountByEndHour[14] == 1)
        #expect(metadata.voiceDurationBySource[.nearbyPhone] == 120)
        #expect(metadata.voiceDurationByEndHour[14] == 120)
        #expect(metadata.longestVoiceSessionDuration == 120)
        #expect(metadata.longestVoiceSessionDurationBySource[.nearbyPhone] == 120)
        #expect(metadata.timeZoneIdentifiers == [calendar.timeZone.identifier])
        #expect(metadata.calendarIdentifiers == [String(describing: calendar.identifier)])
        #expect(metadata.schemaVersions == [1])
        #expect(settings.voiceSessionRanking.first?.startedAt == voiceStartedAt)
        #expect(settings.voiceSessionRanking.first?.source == .nearbyPhone)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.usageMetadata(for: .total, calendar: calendar) == metadata)
        #expect(restored.voiceSessionRanking == settings.voiceSessionRanking)
    }

    @Test func legacyUsageJSONLoadsWithoutFabricatingNewMetadata() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recordID = UUID()
        let endedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "2026-08-05": [
                    "buttonPressCount": 3,
                    "voiceDuration": 45,
                ],
            ]),
            forKey: "usage.dailyStatistics"
        )
        defaults.set(
            try JSONSerialization.data(withJSONObject: [[
                "id": recordID.uuidString,
                "endedAt": endedAt.timeIntervalSinceReferenceDate,
                "duration": 45,
            ]]),
            forKey: "usage.voiceSessionRanking"
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 5,
            hour: 12
        )))
        let settings = AppSettings(defaults: defaults)

        #expect(settings.usageStatistics(for: .today, at: day, calendar: calendar) ==
            UsageStatistics(buttonPressCount: 3, voiceDuration: 45))
        #expect(settings.usageMetadata(for: .today, at: day, calendar: calendar) ==
            UsageStatisticsMetadata())
        #expect(settings.voiceSessionRanking.first?.id == recordID)
        #expect(settings.voiceSessionRanking.first?.startedAt == nil)
        #expect(settings.voiceSessionRanking.first?.source == nil)
    }

    @Test func weeklyUsageSeriesOnlyIncludesDatedHistory() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(NSNumber(value: UInt64(42)), forKey: "usage.totalButtonPressCount")
        defaults.set(180.0, forKey: "usage.totalVoiceDuration")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 5,
            hour: 12
        )))
        let olderDate = try #require(calendar.date(byAdding: .day, value: -56, to: today))

        let settings = AppSettings(defaults: defaults)
        settings.recordButtonPress(at: olderDate, calendar: calendar)
        settings.recordVoiceDuration(30, at: olderDate, calendar: calendar)
        settings.recordButtonPress(at: today, calendar: calendar)
        settings.recordButtonPress(at: today, calendar: calendar)
        settings.recordVoiceDuration(60, at: today, calendar: calendar)

        let series = settings.weeklyUsageStatisticsSeries(
            endingAt: today,
            recentWeeks: 7,
            calendar: calendar
        )
        let weeklyStatistics = series.weeklyBuckets.reduce(
            into: UsageStatistics(buttonPressCount: 0, voiceDuration: 0)
        ) { result, bucket in
            result = UsageStatistics(
                buttonPressCount: result.buttonPressCount + bucket.statistics.buttonPressCount,
                voiceDuration: result.voiceDuration + bucket.statistics.voiceDuration
            )
        }
        let totalStatistics = settings.usageStatistics(
            for: .total,
            at: today,
            calendar: calendar
        )

        #expect(series.weeklyBuckets.count == 7)
        #expect(series.earlierStatistics ==
            UsageStatistics(buttonPressCount: 1, voiceDuration: 30))
        #expect(weeklyStatistics ==
            UsageStatistics(buttonPressCount: 2, voiceDuration: 60))
        #expect(totalStatistics == UsageStatistics(buttonPressCount: 45, voiceDuration: 270))
        #expect(series.earlierStatistics.buttonPressCount + weeklyStatistics.buttonPressCount == 3)
        #expect(series.earlierStatistics.voiceDuration + weeklyStatistics.voiceDuration == 90)
    }

    @Test func weeklyVoiceLabelsApportionWholeSecondsToMatchTheDisplayedTotal() {
        let durations = [316.465, 0, 0, 0, 0, 0, 0, 868.257]
        let displayedSeconds = UsageStatisticsPresentation.apportionedWholeSeconds(
            durations,
            totalDuration: durations.reduce(0, +)
        )

        #expect(displayedSeconds == [317, 0, 0, 0, 0, 0, 0, 868])
        #expect(displayedSeconds.reduce(0, +) ==
            UsageStatisticsPresentation.wholeSeconds(durations.reduce(0, +)))
        #expect(UsageStatisticsPresentation.apportionedWholeSeconds(
            [0.6, 0.6],
            totalDuration: 1.2
        ).reduce(0, +) == 1)
        #expect(UsageStatisticsPresentation.wholeSeconds(.nan) == 0)
        #expect(UsageStatisticsPresentation.wholeSeconds(.infinity) == .max)
    }

    @Test func completedUpdateDetectionCoversBuildIncreaseAndExistingInstallMigration() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        #expect(!settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "39",
            sparkleHadLaunchedBefore: false
        ))
        #expect(!settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "39",
            sparkleHadLaunchedBefore: true
        ))
        #expect(settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "40",
            sparkleHadLaunchedBefore: true
        ))

        let migrationSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let migrationDefaults = try #require(UserDefaults(suiteName: migrationSuiteName))
        defer { migrationDefaults.removePersistentDomain(forName: migrationSuiteName) }
        #expect(AppSettings(defaults: migrationDefaults).recordLaunchAndDetectCompletedUpdate(
            currentBuild: "39",
            sparkleHadLaunchedBefore: true
        ))
    }

    @Test func completedUpdateRecoversOnlyPersistentlyEnabledHIDMappingAfterStartup() throws {
        #expect(BridgeAppModel.shouldRecoverHIDAfterCompletedUpdate(
            completedUpdate: true,
            customMappingEnabled: true
        ))
        #expect(!BridgeAppModel.shouldRecoverHIDAfterCompletedUpdate(
            completedUpdate: false,
            customMappingEnabled: true
        ))
        #expect(!BridgeAppModel.shouldRecoverHIDAfterCompletedUpdate(
            completedUpdate: true,
            customMappingEnabled: false
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let start = try #require(appSource.range(of: "model.startIfNeeded()"))
        let recovery = try #require(appSource.range(of: "model.recoverHIDAfterCompletedUpdate()"))
        #expect(start.lowerBound < recovery.lowerBound)

        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let recoveryStart = try #require(modelSource.range(of: "func recoverHIDAfterCompletedUpdate"))
        let recoveryEnd = try #require(modelSource.range(
            of: "func reconnect()",
            range: recoveryStart.upperBound..<modelSource.endIndex
        ))
        let recoverySource = modelSource[recoveryStart.lowerBound..<recoveryEnd.lowerBound]
        let stop = try #require(recoverySource.range(of: "stopHIDMonitors()"))
        let delayedRestart = try #require(recoverySource.range(of: "DispatchQueue.main.asyncAfter"))
        let apply = try #require(recoverySource.range(of: "self.applyHIDSettings()"))
        #expect(stop.lowerBound < apply.lowerBound)
        #expect(apply.lowerBound < delayedRestart.lowerBound)
    }

    @Test func HIDPermissionsRecoverWhenAuthorizationChangesAfterLaunch() throws {
        let denied = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: false
        )
        let granted = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        #expect(HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: true,
            previous: denied,
            current: granted
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: true,
            previous: granted,
            current: granted
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: false,
            customMappingEnabled: true,
            previous: denied,
            current: granted
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            previous: denied,
            current: granted
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: true,
            previous: nil,
            current: granted
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let activeCallback = try #require(appSource.range(of: "func applicationDidBecomeActive"))
        let callbackEnd = try #require(appSource.range(
            of: "func applicationShouldHandleReopen",
            range: activeCallback.upperBound..<appSource.endIndex
        ))
        let callbackSource = appSource[activeCallback.lowerBound..<callbackEnd.lowerBound]
        #expect(callbackSource.contains("model.refreshHIDAfterPermissionChange()"))
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

    @Test func customShortcutsSurviveSwitchingToOtherActionsAndBack() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = CustomKeyboardShortcut(
            keyCode: 36,
            modifierFlags: [.command],
            keyLabel: "Return"
        )
        let settings = AppSettings(defaults: defaults)
        settings.setAction(.customShortcut, for: .menu, trigger: .singleClick)
        settings.setShortcut(shortcut, for: .menu, trigger: .singleClick)
        settings.setAction(.openCodex, for: .menu, trigger: .singleClick)
        settings.setAction(.customShortcut, for: .menu, trigger: .singleClick)
        #expect(settings.configuredAction(for: .menu, trigger: .singleClick).shortcut == shortcut)

        settings.setAction(.customShortcut, for: .menu, trigger: .doubleClick)
        settings.setShortcut(shortcut, for: .menu, trigger: .doubleClick)
        settings.setAction(.openCmux, for: .menu, trigger: .doubleClick)
        settings.setAction(.disabled, for: .menu, trigger: .doubleClick)
        settings.setAction(.customShortcut, for: .menu, trigger: .doubleClick)
        #expect(settings.configuredAction(for: .menu, trigger: .doubleClick).shortcut == shortcut)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.configuredAction(for: .menu, trigger: .singleClick).shortcut == shortcut)
        #expect(restored.configuredAction(for: .menu, trigger: .doubleClick).shortcut == shortcut)

        restored.resetBindings()
        #expect(restored.shortcut(for: .menu) == nil)
        #expect(restored.configuredAction(for: .menu, trigger: .doubleClick).shortcut == nil)
    }

    @Test func inactiveShortcutAndCustomApplicationConfigurationsSurviveSwitchesRestartAndImport() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = CustomKeyboardShortcut(
            keyCode: 36,
            modifierFlags: [.command],
            keyLabel: "Return"
        )
        let focusShortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.command, .shift],
            keyLabel: "K"
        )
        let target = AccessibilityFocusTarget(
            role: "AXTextArea",
            identifier: "composer",
            title: "",
            description: "Message input",
            help: "",
            placeholder: "Ask anything",
            context: "conversation composer",
            windowTitle: "Example Agent",
            normalizedFrame: nil
        )
        let profile = CustomApplicationProfile(
            displayName: "Example Agent",
            bundleIdentifier: "com.example.agent",
            applicationPath: "/Applications/Example Agent.app",
            focusStrategy: .recordedAccessibility,
            focusShortcut: focusShortcut,
            accessibilityTarget: target
        )

        let settings = AppSettings(defaults: defaults)
        settings.addCustomApplicationProfile(profile)

        for trigger in [ButtonTrigger.singleClick, .doubleClick] {
            settings.setAction(.customShortcut, for: .menu, trigger: trigger)
            settings.setShortcut(shortcut, for: .menu, trigger: trigger)
            settings.setAction(.openCustomApplication, for: .menu, trigger: trigger)
            settings.setApplicationProfileID(profile.id, for: .menu, trigger: trigger)

            settings.setAction(.customShortcut, for: .menu, trigger: trigger)
            var configured = settings.configuredAction(for: .menu, trigger: trigger)
            #expect(configured.action == .customShortcut)
            #expect(configured.shortcut == shortcut)
            #expect(configured.applicationProfileID == profile.id)

            settings.setAction(.disabled, for: .menu, trigger: trigger)
            configured = settings.configuredAction(for: .menu, trigger: trigger)
            #expect(configured.action == .disabled)
            #expect(configured.shortcut == shortcut)
            #expect(configured.applicationProfileID == profile.id)

            settings.setAction(.openCustomApplication, for: .menu, trigger: trigger)
            configured = settings.configuredAction(for: .menu, trigger: trigger)
            #expect(configured.action == .openCustomApplication)
            #expect(configured.shortcut == shortcut)
            #expect(configured.applicationProfileID == profile.id)
            #expect(settings.customApplicationProfile(id: configured.applicationProfileID) == profile)

            settings.setAction(
                trigger == .singleClick ? .customShortcut : .openCustomApplication,
                for: .menu,
                trigger: trigger
            )
        }

        let restored = AppSettings(defaults: defaults)
        for trigger in [ButtonTrigger.singleClick, .doubleClick] {
            let configured = restored.configuredAction(for: .menu, trigger: trigger)
            #expect(configured.action == (trigger == .singleClick ? .customShortcut : .openCustomApplication))
            #expect(configured.shortcut == shortcut)
            #expect(configured.applicationProfileID == profile.id)
            #expect(restored.customApplicationProfile(id: configured.applicationProfileID)?.accessibilityTarget == target)
        }

        let importedSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let importedDefaults = try #require(UserDefaults(suiteName: importedSuiteName))
        defer { importedDefaults.removePersistentDomain(forName: importedSuiteName) }
        let imported = AppSettings(defaults: importedDefaults)
        try imported.importConfiguration(from: restored.exportedConfigurationData())

        for trigger in [ButtonTrigger.singleClick, .doubleClick] {
            let configured = imported.configuredAction(for: .menu, trigger: trigger)
            #expect(configured.action == (trigger == .singleClick ? .customShortcut : .openCustomApplication))
            #expect(configured.shortcut == shortcut)
            #expect(configured.applicationProfileID == profile.id)
            #expect(imported.customApplicationProfile(id: configured.applicationProfileID)?.accessibilityTarget == target)

            imported.setAction(
                configured.action == .customShortcut ? .openCustomApplication : .customShortcut,
                for: .menu,
                trigger: trigger
            )
            let switched = imported.configuredAction(for: .menu, trigger: trigger)
            #expect(switched.shortcut == shortcut)
            #expect(switched.applicationProfileID == profile.id)
        }

        imported.resetBindings()
        #expect(imported.shortcut(for: .menu) == nil)
        #expect(imported.applicationProfileID(for: .menu) == nil)
        #expect(imported.configuredAction(for: .menu, trigger: .doubleClick).shortcut == nil)
        #expect(imported.configuredAction(for: .menu, trigger: .doubleClick).applicationProfileID == nil)
        #expect(imported.customApplicationProfile(id: profile.id) == profile)
    }

    @Test func customApplicationProfilesPersistPerRemoteAndRoundTripConfiguration() throws {
        let suiteName = "RemoteMicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let target = AccessibilityFocusTarget(
            role: "AXTextArea",
            identifier: "composer",
            title: "",
            description: "Message input",
            help: "",
            placeholder: "Ask anything",
            context: "conversation composer",
            windowTitle: "Agent",
            normalizedFrame: nil
        )
        let profile = CustomApplicationProfile(
            displayName: "Example Agent",
            bundleIdentifier: "com.example.agent",
            applicationPath: "/Applications/Example Agent.app",
            focusStrategy: .recordedAccessibility,
            accessibilityTarget: target
        )

        let settings = AppSettings(defaults: defaults)
        settings.addCustomApplicationProfile(profile)
        settings.setAction(.openCustomApplication, for: .menu, trigger: .singleClick)
        settings.setApplicationProfileID(profile.id, for: .menu, trigger: .singleClick)
        settings.setAction(.openCustomApplication, for: .tv, trigger: .doubleClick)
        settings.setApplicationProfileID(profile.id, for: .tv, trigger: .doubleClick)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.customApplicationProfile(id: profile.id) == profile)
        #expect(restored.configuredAction(
            for: .menu,
            trigger: .singleClick
        ).applicationProfileID == profile.id)
        #expect(restored.configuredAction(
            for: .tv,
            trigger: .doubleClick
        ).applicationProfileID == profile.id)

        let importedSuiteName = "RemoteMicTests.\(UUID().uuidString)"
        let importedDefaults = try #require(UserDefaults(suiteName: importedSuiteName))
        defer { importedDefaults.removePersistentDomain(forName: importedSuiteName) }
        let imported = AppSettings(defaults: importedDefaults)
        try imported.importConfiguration(from: restored.exportedConfigurationData())
        #expect(imported.customApplicationProfile(id: profile.id) == profile)
        #expect(imported.configuredAction(
            for: .menu,
            trigger: .singleClick
        ).applicationProfileID == profile.id)

        restored.resetBindings()
        #expect(restored.configuredAction(
            for: .menu,
            trigger: .singleClick
        ).applicationProfileID == nil)
        #expect(restored.customApplicationProfile(id: profile.id) == profile)
    }

    @Test func preReleaseUpdateFeedAlwaysFallsBackToStableFeed() throws {
        let stableFeed = "https://example.com/releases/latest/download/appcast.xml"
        let preReleaseFeed = try #require(
            URL(string: "https://example.com/releases/download/v1.7.3/appcast.xml")
        )
        var selection = UpdateFeedSelection(stableFeedURLString: stableFeed)

        selection.usePreReleaseFeed(preReleaseFeed)
        #expect(
            selection.feedURLString(checksForPreReleaseUpdates: true)
                == preReleaseFeed.absoluteString
        )
        #expect(selection.feedURLString(checksForPreReleaseUpdates: false) == stableFeed)

        selection.useStableFeed()
        #expect(selection.feedURLString(checksForPreReleaseUpdates: true) == stableFeed)
        #expect(selection.feedURLString(checksForPreReleaseUpdates: false) == stableFeed)
    }

    @Test func intelUpdateSelectionUsesTheIntelAppcastNameForPreReleaseResolution() {
        let selection = UpdateFeedSelection(
            stableFeedURLString: "https://example.com/releases/latest/download/appcast-intel.xml"
        )

        #expect(selection.appcastAssetName == "appcast-intel.xml")
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
        // Real RC003 hardware emits keyCode 10 (ISO §) for the TV key.
        #expect(RemoteButton.tv.nativeEvent == .keyboard(keyCode: 10))
        #expect(RemoteButton.power.nativeEvent == .keyboard(keyCode: 90))
        #expect(RemoteButton.menu.nativeEvent == .keyboard(keyCode: KeyboardInjector.contextualMenuKeyCode))
        #expect(RemoteButton.volumeUp.nativeEvent == .systemKey(type: 0))
        #expect(RemoteButton.back.nativeEvent == nil)
    }

    @Test func nativeKeyAutoRepeatIsSuppressedUntilEveryRemoteReleases() throws {
        let suppressor = KeyboardEventSuppressor()
        let down = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 126,
            keyDown: true
        ))
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let up = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 126,
            keyDown: false
        ))

        suppressor.arm(button: .up, edge: .down)
        #expect(suppressor.handle(type: .keyDown, event: down))
        #expect(suppressor.handle(type: .keyDown, event: down))

        suppressor.arm(button: .up, edge: .down)
        suppressor.arm(button: .up, edge: .up)
        #expect(suppressor.handle(type: .keyDown, event: down))
        #expect(suppressor.handle(type: .keyUp, event: up))

        suppressor.arm(button: .up, edge: .up)
        #expect(suppressor.handle(type: .keyUp, event: up))
        #expect(!suppressor.handle(type: .keyDown, event: down))
    }

    @Test func missingRemoteKeyUpDoesNotSuppressNextPhysicalKeyPress() throws {
        let suppressor = KeyboardEventSuppressor()
        let remoteDown = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 123,
            keyDown: true
        ))
        let remoteRepeat = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 123,
            keyDown: true
        ))
        remoteRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let physicalDown = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 123,
            keyDown: true
        ))
        let physicalRepeat = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 123,
            keyDown: true
        ))
        physicalRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        suppressor.arm(button: .left, edge: .down)
        #expect(suppressor.handle(type: .keyDown, event: remoteDown))
        #expect(suppressor.handle(type: .keyDown, event: remoteRepeat))

        #expect(!suppressor.handle(type: .keyDown, event: physicalDown))
        #expect(!suppressor.handle(type: .keyDown, event: physicalRepeat))
    }

    @Test func remoteModelNumberIdentificationIsStrictAndCaseInsensitive() {
        #expect(XiaomiRemoteModel.identified(by: "RC001") == .rc001)
        #expect(XiaomiRemoteModel.identified(by: " rc003\n") == .rc003)
        #expect(XiaomiRemoteModel.identified(by: "RC002") == nil)
        #expect(XiaomiRemoteModel.identified(by: "2BED") == nil)
    }

    @Test func batteryLevelStatusDecodesUserFacingPowerStates() {
        #expect(RemotePowerState.decodeBatteryLevelStatus(Data([0x00, 0x61, 0x00])) == .onBattery)
        #expect(RemotePowerState.decodeBatteryLevelStatus(Data([0x00, 0x21, 0x00])) == .charging)
        #expect(RemotePowerState.decodeBatteryLevelStatus(Data([0x00, 0x63, 0x00])) == .externalPower)
        #expect(RemotePowerState.decodeBatteryLevelStatus(Data([0x00, 0x65, 0x00])) == .unknown)
        #expect(RemotePowerState.decodeBatteryLevelStatus(Data([0x00, 0x00, 0x00])) == .unknown)
        #expect(RemotePowerState.decodeBatteryLevelStatus(Data([0x00, 0x61])) == nil)
    }
}
