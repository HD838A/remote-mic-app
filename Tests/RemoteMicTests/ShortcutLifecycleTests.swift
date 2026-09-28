import AppKit
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Shortcut lifecycle")
struct ShortcutLifecycleTests {
    struct Edge: Equatable {
        let type: CGEventType
        let code: CGKeyCode
        let flags: CGEventFlags
        init(_ event: CGEvent) {
            type = event.type
            code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            flags = event.flags
        }
    }

    @Test(arguments: [NSEvent.ModifierFlags.control, [.control, .shift], .command])
    func switcherReceivesFinalModifierRelease(_ flags: NSEvent.ModifierFlags) {
        var events: [Edge] = []
        var controlReleased = false
        #expect(KeyboardInjector.send(
            .customShortcut,
            shortcut: CustomKeyboardShortcut(keyCode: 48, modifierFlags: flags, keyLabel: "Tab"),
            accessibilityTrusted: { true },
            keyPoster: { _, _ in Issue.record("Must not use flags-only injection") },
            shortcutEventPoster: { event in
                if event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker {
                    Issue.record("Missing synthetic marker")
                }
                events.append(Edge(event))
                if event.type == .flagsChanged && !event.flags.contains(.maskControl) {
                    controlReleased = true
                }
                return true
            },
            shortcutHardwareFlags: { [] }
        ))
        let codes: [CGKeyCode] = flags == .command ? [55, 48, 48, 55]
            : flags.contains(.shift) ? [59, 56, 48, 48, 56, 59] : [59, 48, 48, 59]
        #expect(events.map(\.code) == codes)
        #expect(events.filter { $0.type == .keyDown }.count == 1)
        #expect(events.filter { $0.type == .keyUp }.count == 1)
        #expect(events.first?.type == .flagsChanged)
        #expect(events.last?.type == .flagsChanged)
        #expect(events.last?.flags.isEmpty == true)
        if flags.contains(.control) { #expect(controlReleased) }
    }

    @Test func everyModifierUsesCumulativeFlagsAndReverseRelease() {
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 40,
            modifiers: [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn],
            hardwareFlags: { [] },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.map(\.code) == [59, 58, 56, 55, 63, 40, 40, 63, 55, 56, 58, 59])
        #expect(events[0].flags.contains(.maskControl))
        #expect(events[3].flags.contains([.maskControl, .maskAlternate, .maskShift, .maskCommand]))
        #expect(!events[8].flags.contains(.maskCommand))
        #expect(events[8].flags.contains([.maskControl, .maskAlternate, .maskShift]))
        #expect(events.last?.flags.isEmpty == true)
    }

    @Test(arguments: Array(0..<6))
    func failureCleansUpAndNextInvocationRecovers(_ failAt: Int) {
        var events: [Edge] = []
        var logs: [String] = []
        let result = ShortcutEventSequence.send(
            keyCode: 48, modifiers: [.maskControl, .maskShift], hardwareFlags: { [] },
            eventPoster: { event in
                events.append(Edge(event))
                return events.count - 1 != failAt
            }, logger: { logs.append($0) }
        )
        #expect(!result)
        #expect(events.last?.code == 59)
        #expect(events.last?.type == .flagsChanged)
        #expect(events.last?.flags.isEmpty == true)
        if events.contains(where: { $0.type == .keyDown }) {
            #expect(events.contains(where: { $0.type == .keyUp }))
        }
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(logs.last?.contains("result=failed") == true)
        #expect(logs.last?.contains("cleanup_failed=false") == true)
        events.removeAll()
        #expect(ShortcutEventSequence.send(
            keyCode: 48, modifiers: .maskControl, hardwareFlags: { [] },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.map(\.code) == [59, 48, 48, 59])
    }

    @Test func persistentReleaseFailureIsBoundedAndReported() {
        var count = 0
        var logs: [String] = []
        #expect(!ShortcutEventSequence.send(
            keyCode: 48, modifiers: .maskControl, hardwareFlags: { [] },
            eventPoster: { _ in count += 1; return count == 1 },
            logger: { logs.append($0) }
        ))
        #expect(count == 6)
        #expect(logs.last?.contains("cleanup_failed=true") == true)
        #expect(logs.last?.contains("user_visible_result=unknown") == true)
    }

    @Test func physicalModifierIsNotSynthesizedOrReleased() {
        var events: [Edge] = []
        let physical: CGEventFlags = [.maskControl, .maskAlphaShift]
        #expect(ShortcutEventSequence.send(
            keyCode: 48, modifiers: [.maskControl, .maskShift], hardwareFlags: { physical },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.map(\.code) == [56, 48, 48, 56])
        #expect(events.allSatisfy { $0.flags.contains(physical) })
        #expect(events.last?.flags == physical)
    }

    @Test func physicalPressDuringSequenceSurvivesSyntheticRelease() {
        var events: [Edge] = []
        var physical: CGEventFlags = []
        #expect(ShortcutEventSequence.send(
            keyCode: 48, modifiers: .maskControl, hardwareFlags: { physical },
            eventPoster: { event in
                events.append(Edge(event))
                if event.type == .keyDown { physical = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 1) }
                return true
            }
        ))
        #expect(events.last?.flags == physical)
    }

    @Test func permissionDenialDoesNotEmitEvents() {
        var count = 0
        #expect(!KeyboardInjector.send(
            .customShortcut,
            shortcut: CustomKeyboardShortcut(keyCode: 48, modifierFlags: .control, keyLabel: "Tab"),
            accessibilityTrusted: { false },
            shortcutEventPoster: { _ in count += 1; return true },
            shortcutHardwareFlags: { [] }
        ))
        #expect(count == 0)
    }

    @Test func successfulLogsAreCorrelatedAndDoNotContainShortcutContent() {
        var logs: [String] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 48, modifiers: .maskControl, hardwareFlags: { [] },
            eventPoster: { _ in true }, logger: { logs.append($0) }
        ))
        #expect(logs.count == 2)
        #expect(logs[0].split(separator: " ")[2] == logs[1].split(separator: " ")[2])
        #expect(logs[1].contains("result=submitted"))
        #expect(logs[1].contains("submitted_events=4"))
        #expect(logs[1].contains("user_visible_result=unknown"))
        #expect(!logs.joined().contains("key_code"))
    }
}
