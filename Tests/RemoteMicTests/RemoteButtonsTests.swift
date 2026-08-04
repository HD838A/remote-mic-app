import AppKit
import CryptoKit
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
            localization.text("app.name"): "com.hd838a.RemoteMic",
            "Codex": "com.openai.codex",
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
        let callback = try #require(monitor.range(of: "onButtonPressed?(button)"))
        let map = try #require(model.range(of: "let powerKeySuppressed = applyVoiceFunctionMapping()"))
        let start = try #require(model.range(of: "hidMonitor.start(powerKeySuppressed: powerKeySuppressed)"))
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

    @Test func phoneIdentityProofMustMatchTheCurrentSessionKey() throws {
        let identity = P256.Signing.PrivateKey()
        let firstSessionKey = Data(repeating: 0x11, count: 32)
        let secondSessionKey = Data(repeating: 0x22, count: 32)
        let signature = try identity.signature(
            for: PhoneRemoteIdentityVerifier.proof(for: firstSessionKey)
        )

        let verified = PhoneRemoteIdentityVerifier.verify(
            identityPublicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
            identitySignature: signature.rawRepresentation.base64EncodedString(),
            sessionPublicKey: firstSessionKey
        )
        guard case .verified = verified else {
            Issue.record("Expected a valid identity proof")
            return
        }
        #expect(PhoneRemoteIdentityVerifier.verify(
            identityPublicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
            identitySignature: signature.rawRepresentation.base64EncodedString(),
            sessionPublicKey: secondSessionKey
        ) == .invalid)
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
        #expect(RemoteButton.power.nativeEvent == .keyboard(keyCode: 90))
        #expect(RemoteButton.menu.nativeEvent == .keyboard(keyCode: KeyboardInjector.contextualMenuKeyCode))
        #expect(RemoteButton.volumeUp.nativeEvent == .systemKey(type: 0))
        #expect(RemoteButton.back.nativeEvent == nil)
    }
}
