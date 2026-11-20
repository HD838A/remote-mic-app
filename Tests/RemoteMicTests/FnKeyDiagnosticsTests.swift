import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Fn key diagnostics")
struct FnKeyDiagnosticsTests {
    @Test func snapshotLineCarriesOnlyStableDiagnosticFields() {
        let line = FnKeyDiagnostics.snapshotLine(
            source: "launch",
            fnFlag: true,
            key63Down: true,
            secureInput: false,
            systemFnUsage: "do_nothing",
            voiceKeyMode: "fn",
            voiceFnTap: false,
            voiceTool: "typeless"
        )

        #expect(line == "VOICE KEY fn_snapshot source=launch result=observed " +
            "fn_flag=true key63_down=true secure_input=false system_fn_usage=do_nothing " +
            "voice_key_mode=fn voice_fn_tap=false voice_tool=typeless")
    }

    @Test func skippedSnapshotNamesThePermissionBoundary() {
        let line = FnKeyDiagnostics.skippedSnapshotLine(
            source: "launch",
            secureInput: true,
            systemFnUsage: "assigned",
            voiceKeyMode: "fn",
            voiceFnTap: true,
            voiceTool: "doubao"
        )

        #expect(line.contains("result=skipped"))
        #expect(line.contains("reason=accessibility_denied"))
        #expect(line.contains("secure_input=true"))
        #expect(line.contains("system_fn_usage=assigned"))
    }

    @Test func eventObservationMatchesOnlyFunctionKeyEdges() throws {
        let down = try #require(functionEvent(flags: .maskSecondaryFn))
        let up = try #require(functionEvent(flags: []))
        let letter = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 17,
            keyDown: true
        ))
        letter.type = .flagsChanged
        letter.flags = .maskSecondaryFn

        let downLine = try #require(FnKeyDiagnostics.eventObservation(
            source: "session_tap",
            tap: "session",
            type: .flagsChanged,
            event: down
        ))
        let upLine = try #require(FnKeyDiagnostics.eventObservation(
            source: "session_tap",
            tap: "session",
            type: .flagsChanged,
            event: up
        ))

        #expect(downLine.contains("synthetic=false"))
        #expect(downLine.contains("pressed=true"))
        #expect(upLine.contains("pressed=false"))
        #expect(FnKeyDiagnostics.eventObservation(
            source: "session_tap",
            tap: "session",
            type: .flagsChanged,
            event: letter
        ) == nil)
    }

    @Test func functionModifiedKeyDownIsClassifiedWithoutTheKeyCode() throws {
        let letter = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 17,
            keyDown: true
        ))
        letter.flags = .maskSecondaryFn
        let commandLetter = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 17,
            keyDown: true
        ))
        commandLetter.flags = [.maskSecondaryFn, .maskCommand]
        let arrow = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 126,
            keyDown: true
        ))
        arrow.flags = .maskSecondaryFn

        let letterLine = try #require(FnKeyDiagnostics.combinationObservation(
            source: "session_tap",
            tap: "session",
            type: .keyDown,
            event: letter
        ))
        let commandLine = try #require(FnKeyDiagnostics.combinationObservation(
            source: "session_tap",
            tap: "session",
            type: .keyDown,
            event: commandLetter
        ))

        #expect(letterLine.contains("primary_kind=unclassified"))
        #expect(!letterLine.contains("keycode"))
        #expect(commandLine.contains("primary_kind=command_shortcut"))
        #expect(FnKeyDiagnostics.combinationObservation(
            source: "session_tap",
            tap: "session",
            type: .keyDown,
            event: arrow
        ) == nil)
    }

    @Test func ordinaryKeyDownDoesNotProduceFunctionDiagnostics() throws {
        let letter = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 17,
            keyDown: true
        ))

        #expect(FnKeyDiagnostics.combinationObservation(
            source: "session_tap",
            tap: "session",
            type: .keyDown,
            event: letter
        ) == nil)
    }

    @Test func syntheticFunctionEdgeKeepsItsMarkerVisible() throws {
        let event = try #require(functionEvent(flags: .maskSecondaryFn, synthetic: true))
        let line = try #require(FnKeyDiagnostics.eventObservation(
            source: "hid_tap",
            tap: "hid_head",
            type: .flagsChanged,
            event: event
        ))

        #expect(line.contains("source=hid_tap"))
        #expect(line.contains("tap=hid_head"))
        #expect(line.contains("synthetic=true"))
        #expect(line.contains("pressed=true"))
    }

    private func functionEvent(
        flags: CGEventFlags,
        synthetic: Bool = false
    ) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)
        event?.type = .flagsChanged
        event?.flags = flags
        if synthetic {
            event?.setIntegerValueField(
                .eventSourceUserData,
                value: KeyboardInjector.syntheticEventMarker
            )
        }
        return event
    }
}
