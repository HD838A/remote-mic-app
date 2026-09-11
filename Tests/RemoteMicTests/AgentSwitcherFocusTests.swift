import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Agent switcher focus handoff")
struct AgentSwitcherFocusTests {
    @Test func selectedApplicationUsesMatchingCustomShortcutProfile() {
        let profile = customProfile(
            bundleIdentifier: PresetApplication.cursor.bundleIdentifier,
            focusStrategy: .keyboardShortcut,
            focusShortcut: CustomKeyboardShortcut(
                keyCode: 37,
                modifierFlags: .command,
                keyLabel: "L"
            )
        )
        var focusedProfile: CustomApplicationProfile?
        var focusedPID: pid_t?
        var presetFocused = false

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(PresetApplication.cursor),
            profiles: [customProfile(bundleIdentifier: "other.bundle", focusStrategy: .none), profile],
            switcherOperationID: 41,
            frontmostApplication: { (PresetApplication.cursor.bundleIdentifier, 4242) },
            applicationFocuser: { _, _, _, _ in presetFocused = true },
            customApplicationFocuser: { profile, processIdentifier, _ in
                focusedProfile = profile
                focusedPID = processIdentifier
            }
        )

        #expect(focusedProfile == profile)
        #expect(focusedPID == 4242)
        #expect(!presetFocused)
    }

    @Test func customProfilePrecedenceRespectsExplicitNone() {
        let profile = customProfile(
            bundleIdentifier: PresetApplication.codex.bundleIdentifier,
            focusStrategy: .none
        )
        var customFocused = false
        var presetFocused = false
        var logs: [String] = []

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(PresetApplication.codex),
            profiles: [profile],
            switcherOperationID: 42,
            frontmostApplication: { (PresetApplication.codex.bundleIdentifier, 4242) },
            applicationFocuser: { _, _, _, _ in presetFocused = true },
            customApplicationFocuser: { _, _, _ in customFocused = true },
            logger: { logs.append($0) }
        )

        #expect(!customFocused)
        #expect(!presetFocused)
        #expect(logs.contains { $0.contains("reason=focus_disabled") })
    }

    @Test func customShortcutProfileWithoutShortcutSkipsInsteadOfFallingBack() {
        let profile = customProfile(
            bundleIdentifier: PresetApplication.codex.bundleIdentifier,
            focusStrategy: .keyboardShortcut
        )
        var customFocused = false
        var presetFocused = false
        var logs: [String] = []

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(PresetApplication.codex),
            profiles: [profile],
            switcherOperationID: 43,
            frontmostApplication: { (PresetApplication.codex.bundleIdentifier, 4242) },
            applicationFocuser: { _, _, _, _ in presetFocused = true },
            customApplicationFocuser: { _, _, _ in customFocused = true },
            logger: { logs.append($0) }
        )

        #expect(!customFocused)
        #expect(!presetFocused)
        #expect(logs.contains { $0.contains("method=custom_shortcut reason=shortcut_missing") })
    }

    @Test func recordedAccessibilityProfileWithoutTargetSkipsInsteadOfRetrying() {
        let profile = customProfile(
            bundleIdentifier: PresetApplication.codex.bundleIdentifier,
            focusStrategy: .recordedAccessibility
        )
        var customFocused = false
        var presetFocused = false
        var logs: [String] = []

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(PresetApplication.codex),
            profiles: [profile],
            switcherOperationID: 44,
            frontmostApplication: { (PresetApplication.codex.bundleIdentifier, 4242) },
            applicationFocuser: { _, _, _, _ in presetFocused = true },
            customApplicationFocuser: { _, _, _ in customFocused = true },
            logger: { logs.append($0) }
        )

        #expect(!customFocused)
        #expect(!presetFocused)
        #expect(logs.contains { $0.contains("method=custom_accessibility reason=target_missing") })
    }

    @Test(arguments: [PresetApplication.codex, .claude, .cmux])
    func presetFocusRunsWhenNoCustomProfileMatches(preset: PresetApplication) {
        var focusedApplication: PresetApplication?
        var focusedPID: pid_t?

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(preset),
            profiles: [customProfile(bundleIdentifier: "other.bundle", focusStrategy: .none)],
            switcherOperationID: 45,
            frontmostApplication: { (preset.bundleIdentifier, 4242) },
            applicationFocuser: { _, application, processIdentifier, _ in
                focusedApplication = application
                focusedPID = processIdentifier
            },
            customApplicationFocuser: { _, _, _ in }
        )

        #expect(focusedApplication == preset)
        #expect(focusedPID == 4242)
    }

    @Test func applicationsWithoutFocusStrategyOnlyActivate() {
        var customFocused = false
        var presetFocused = false
        var logs: [String] = []

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(PresetApplication.cursor),
            profiles: [],
            switcherOperationID: 46,
            frontmostApplication: { (PresetApplication.cursor.bundleIdentifier, 4242) },
            applicationFocuser: { _, _, _, _ in presetFocused = true },
            customApplicationFocuser: { _, _, _ in customFocused = true },
            logger: { logs.append($0) }
        )

        #expect(!customFocused)
        #expect(!presetFocused)
        #expect(logs.contains { $0.contains("method=preset reason=strategy_missing") })
    }

    @Test func frontmostMismatchDoesNotSendFocus() {
        var customFocused = false
        var presetFocused = false
        var logs: [String] = []

        KeyboardInjector.focusActivatedAgent(
            switcherApplication(PresetApplication.codex),
            profiles: [],
            switcherOperationID: 47,
            frontmostApplication: { ("other.bundle", 4242) },
            applicationFocuser: { _, _, _, _ in presetFocused = true },
            customApplicationFocuser: { _, _, _ in customFocused = true },
            logger: { logs.append($0) }
        )

        #expect(!customFocused)
        #expect(!presetFocused)
        #expect(logs.count == 1)
        #expect(logs[0].contains("switcher_operation_id=47"))
        #expect(logs[0].contains("operation_id="))
        #expect(logs[0].contains("method=agent_switcher reason=frontmost_changed"))
    }

    @Test func handoffLogsDoNotExposeCustomBundlePathOrDisplayName() {
        let profile = customProfile(
            displayName: "Private Agent",
            bundleIdentifier: "com.example.private-agent",
            applicationPath: "/Users/example/Private Agent.app",
            focusStrategy: .none
        )
        var logs: [String] = []

        KeyboardInjector.focusActivatedAgent(
            AgentSwitcherApplication(
                id: profile.bundleIdentifier,
                name: profile.displayName,
                url: URL(fileURLWithPath: profile.applicationPath)
            ),
            profiles: [profile],
            switcherOperationID: 48,
            frontmostApplication: { (profile.bundleIdentifier, 4242) },
            logger: { logs.append($0) }
        )

        #expect(!logs.isEmpty)
        #expect(!logs.contains { $0.contains(profile.bundleIdentifier) })
        #expect(!logs.contains { $0.contains(profile.applicationPath) })
        #expect(!logs.contains { $0.contains(profile.displayName) })
    }

    private func switcherApplication(_ preset: PresetApplication) -> AgentSwitcherApplication {
        AgentSwitcherApplication(
            id: preset.bundleIdentifier,
            name: preset.rawValue,
            url: URL(fileURLWithPath: "/Applications/\(preset.rawValue).app")
        )
    }

    private func customProfile(
        displayName: String = "Agent",
        bundleIdentifier: String,
        applicationPath: String = "/Applications/Agent.app",
        focusStrategy: CustomApplicationFocusStrategy,
        focusShortcut: CustomKeyboardShortcut? = nil
    ) -> CustomApplicationProfile {
        CustomApplicationProfile(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationPath,
            focusStrategy: focusStrategy,
            focusShortcut: focusShortcut
        )
    }
}
