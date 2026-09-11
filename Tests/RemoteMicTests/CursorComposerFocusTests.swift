import AppKit
import Testing
@testable import RemoteMic

struct CursorComposerFocusTests {
    @Test(arguments: [true, false])
    func cursorNeverSendsToggleEvenWhenComposerIsMissing(focusConfirmed: Bool) {
        var posts = 0
        for _ in 0..<8 {
            #expect(KeyboardInjector.performCustomFocusShortcut(
                usesCursorComposer: true,
                focusComposer: { focusConfirmed },
                postShortcut: { posts += 1 }
            ) == focusConfirmed)
        }
        #expect(posts == 0)
    }

    @Test func otherConfiguredShortcutsStillPost() {
        var posts = 0
        var scans = 0
        #expect(KeyboardInjector.performCustomFocusShortcut(
            usesCursorComposer: false,
            focusComposer: { scans += 1; return false },
            postShortcut: { posts += 1 }
        ))
        #expect(posts == 1)
        #expect(scans == 0)
    }

    @Test(arguments: ["code editor", "monaco", "terminal", "Search", "editor content"])
    func rejectsOtherTextInputs(label: String) {
        #expect(!KeyboardInjector.isCursorComposerCandidate(
            candidate(label: label), windowFrame: window, hasChatControls: true
        ))
    }

    @Test func unlabeledComposerNeedsNearbyChatControls() {
        #expect(KeyboardInjector.isCursorComposerCandidate(
            candidate(), windowFrame: window, hasChatControls: true
        ))
        #expect(!KeyboardInjector.isCursorComposerCandidate(
            candidate(), windowFrame: window, hasChatControls: false
        ))
    }

    @Test func hiddenComposerIsNotSelected() {
        #expect(!KeyboardInjector.isCursorComposerCandidate(
            candidate(frame: .zero), windowFrame: window, hasChatControls: true
        ))
        #expect(!KeyboardInjector.isCursorComposerCandidate(
            candidate(frame: CGRect(x: 2000, y: 2000, width: 100, height: 50)),
            windowFrame: window, hasChatControls: true
        ))
    }

    private var window: CGRect { CGRect(x: 0, y: 0, width: 1000, height: 800) }

    private func candidate(
        label: String = "",
        frame: CGRect = CGRect(x: 200, y: 500, width: 300, height: 80)
    ) -> KeyboardInjector.AccessibilityTextCandidate {
        KeyboardInjector.AccessibilityTextCandidate(
            role: "AXTextArea", identifier: "", title: "", description: label,
            help: "", placeholder: "", context: "search-token.swift — Cursor",
            frame: frame, enabled: true
        )
    }

}
