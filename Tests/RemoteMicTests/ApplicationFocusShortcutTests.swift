import AppKit
import Testing
@testable import RemoteMic

@Suite("Application focus shortcuts")
@MainActor
struct ApplicationFocusShortcutTests {
    @Test func applicationEditorOffersStandardKeyboardWhenCaptureIsUnavailable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"))
        let start = try #require(source.range(of: "private func inlineApplicationShortcutEditor("))
        let end = try #require(source.range(of: "private func shortcutCaptureFeedbackView", range: start.upperBound..<source.endIndex))
        let editor = source[start.lowerBound..<end.lowerBound]
        #expect(editor.contains("KeyboardShortcutPicker("))
        #expect(editor.contains("shortcut: profile.focusShortcut"))
    }

    @Test(arguments: [UInt16(37), 40, 49])
    func commandCombinationsCaptureIntoApplicationProfile(keyCode: UInt16) throws {
        let suite = "ApplicationFocusShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let cursor = CustomApplicationProfile(
            displayName: "Cursor", bundleIdentifier: "test.cursor", applicationPath: "/Applications/Cursor.app",
            focusStrategy: .keyboardShortcut
        )
        let codex = CustomApplicationProfile(
            displayName: "Codex", bundleIdentifier: "test.codex", applicationPath: "/Applications/Codex.app"
        )
        settings.addCustomApplicationProfile(cursor)
        settings.addCustomApplicationProfile(codex)
        let monitor = ShortcutCaptureMonitor(onCapture: { shortcut in
            settings.setApplicationFocusShortcut(shortcut, profileID: cursor.id)
        }, dispatchCallback: { $0() })
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.flags = .maskCommand
        #expect(monitor.handle(type: .keyDown, event: event))
        let restored = AppSettings(defaults: defaults)
        #expect(restored.customApplicationProfile(id: cursor.id)?.focusShortcut?.keyCode == keyCode)
        #expect(restored.customApplicationProfile(id: cursor.id)?.focusShortcut?.modifierFlags == .command)
        #expect(restored.customApplicationProfile(id: codex.id) == codex)
    }

    @Test func standardKeyboardSelectionPersistsAndReachesSelectedApplicationOnly() throws {
        let suite = "ApplicationFocusShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let cursor = CustomApplicationProfile(
            displayName: "Cursor", bundleIdentifier: "test.cursor", applicationPath: "/Applications/Cursor.app",
            focusStrategy: .keyboardShortcut
        )
        let codex = CustomApplicationProfile(
            displayName: "Codex", bundleIdentifier: "test.codex", applicationPath: "/Applications/Codex.app"
        )
        settings.addCustomApplicationProfile(cursor)
        settings.addCustomApplicationProfile(codex)
        let l = try #require(StandardKeyboardKey.mainRows.flatMap { $0 }.first { $0.id == "l" })
        settings.setApplicationFocusShortcut(l.shortcut(modifierFlags: .command), profileID: cursor.id)
        settings.setApplicationProfileID(cursor.id, for: .ok, trigger: .singleClick)
        let restored = AppSettings(defaults: defaults)
        let selected = try #require(restored.customApplicationProfile(
            id: restored.configuredAction(for: .ok, trigger: .singleClick).applicationProfileID
        ))
        var focused: CustomApplicationProfile?
        #expect(KeyboardInjector.send(
            .openCustomApplication,
            applicationProfile: selected,
            customApplicationURL: { URL(fileURLWithPath: $0.applicationPath) },
            customApplicationOpener: { _, _, completion in completion(123, nil) },
            customApplicationFocuser: { profile, _, _ in focused = profile }
        ))
        #expect(focused?.id == cursor.id)
        #expect(focused?.focusShortcut?.keyCode == 37)
        #expect(focused?.focusShortcut?.cgEventFlags == .maskCommand)
        #expect(restored.customApplicationProfile(id: codex.id) == codex)
        settings.setApplicationFocusShortcut(nil, profileID: cursor.id)
        #expect(AppSettings(defaults: defaults).customApplicationProfile(id: cursor.id)?.focusShortcut == nil)
        #expect(settings.customApplicationProfile(id: cursor.id)?.focusStrategy == .keyboardShortcut)
        #expect(settings.customApplicationProfile(id: codex.id) == codex)
    }
}
