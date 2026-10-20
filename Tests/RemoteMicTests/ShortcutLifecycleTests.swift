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

    @Test func rightSideModifiersUseRequestedPhysicalKeys() {
        let cases: [(CGEventFlags, UInt64, CGKeyCode)] = [
            (.maskControl, 0x2000, 62),
            (.maskAlternate, 0x0040, 61),
            (.maskShift, 0x0004, 60),
            (.maskCommand, 0x0010, 54),
        ]
        for (genericFlag, sideBit, expectedKey) in cases {
            var events: [Edge] = []
            #expect(ShortcutEventSequence.send(
                keyCode: 43,
                modifiers: [genericFlag, CGEventFlags(rawValue: sideBit)],
                hardwareFlags: { [] },
                eventPoster: { events.append(Edge($0)); return true }
            ))

            #expect(events.map(\.code) == [expectedKey, 43, 43, expectedKey])
            #expect(events.first?.flags.contains(CGEventFlags(rawValue: sideBit)) == true)
            #expect(events.last?.flags.isEmpty == true)
        }
    }

    @Test func requestedRightSideIsSynthesizedWhileLeftSideIsPhysicallyHeld() {
        var events: [Edge] = []
        let physical: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        #expect(ShortcutEventSequence.send(
            keyCode: 43,
            modifiers: [.maskCommand, CGEventFlags(rawValue: 0x10)],
            hardwareFlags: { physical },
            eventPoster: { events.append(Edge($0)); return true }
        ))

        #expect(events.map(\.code) == [54, 43, 43, 54])
        #expect(events.first?.flags.contains(CGEventFlags(rawValue: 0x08)) == true)
        #expect(events.first?.flags.contains(CGEventFlags(rawValue: 0x10)) == true)
        #expect(events.last?.flags == physical)
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

    @Test func syntheticFeedbackDoesNotKeepModifiersPressed() {
        var events: [Edge] = []
        let physical: CGEventFlags = [.maskShift, CGEventFlags(rawValue: 0x02)]
        var systemSnapshot = physical.union(CGEventFlags(rawValue: 0x2000_0100))
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: [.maskCommand, .maskAlternate],
            hardwareFlags: { systemSnapshot },
            eventPoster: { event in
                events.append(Edge(event))
                // HID state can echo a posted event even with a private CGEventSource.
                systemSnapshot = event.flags
                return true
            }
        ))
        #expect(events.map(\.code) == [58, 55, 37, 37, 55, 58])
        #expect(events[4].flags.contains(.maskAlternate))
        #expect(!events[4].flags.contains(.maskCommand))
        #expect(events.last?.flags == physical)
        #expect(events.allSatisfy { $0.flags.contains(physical) })
        // A second shortcut must own and release Command again.
        events.removeAll()
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: .maskCommand, hardwareFlags: { systemSnapshot },
            eventPoster: { events.append(Edge($0)); systemSnapshot = $0.flags; return true }
        ))
        #expect(events.map(\.code) == [55, 37, 37, 55])
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
        #expect(logs[0].contains("side_specific=false"))
        #expect(logs[1].contains("result=submitted"))
        #expect(logs[1].contains("submitted_events=4"))
        #expect(logs[1].contains("user_visible_result=unknown"))
        #expect(!logs.joined().contains("key_code"))
    }
    @Test(arguments: [false, true])
    func remoteArrowSnapshotDoesNotAddFunctionToConfiguredShortcut(_ withOption: Bool) {
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: withOption ? 11 : 37,
            modifiers: withOption ? [.maskCommand, .maskAlternate] : .maskCommand,
            hardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.allSatisfy { !$0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags.isEmpty == true)
    }

    @Test func configuredFunctionKeyIsSynthesizedDespiteArrowSnapshot() {
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: [.maskCommand, .maskSecondaryFn],
            hardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.map(\.code) == [55, 63, 37, 37, 63, 55])
        #expect(events.last?.flags.isEmpty == true)
    }

    @Test func physicalFunctionEdgesPreserveHeldFunctionAndClearReleasedFunction() {
        let state = ShortcutHardwareModifierState()
        let suppressor = KeyboardEventSuppressor(hardwareModifierState: state)
        let functionEvent = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        functionEvent.type = .flagsChanged
        functionEvent.flags = .maskSecondaryFn
        #expect(!suppressor.handle(type: .flagsChanged, event: functionEvent))
        var events: [Edge] = []
        let arrowFlags = CGEventFlags(rawValue: 0x00A0_0100)
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: .maskCommand,
            hardwareFlags: { arrowFlags }, modifierState: state,
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.map(\.code) == [55, 37, 37, 55])
        #expect(events.allSatisfy { $0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags == .maskSecondaryFn)
        functionEvent.flags = []
        #expect(!suppressor.handle(type: .flagsChanged, event: functionEvent))
        events.removeAll()
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: .maskCommand,
            hardwareFlags: { arrowFlags }, modifierState: state,
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.allSatisfy { !$0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags.isEmpty == true)
    }

    @Test func synthesizedFunctionAndArrowEventsDoNotSetPhysicalFunctionState() {
        let state = ShortcutHardwareModifierState()
        let suppressor = KeyboardEventSuppressor(hardwareModifierState: state)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        event.type = .flagsChanged
        event.flags = .maskSecondaryFn
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        #expect(!suppressor.handle(type: .flagsChanged, event: event))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        event.setIntegerValueField(.keyboardEventKeycode, value: 125)
        #expect(!suppressor.handle(type: .flagsChanged, event: event))
        let snapshot = state.snapshot([.maskSecondaryFn, .maskNumericPad])
        #expect(snapshot.functionState == "unobserved")
        #expect(snapshot.removedFunctionFlag)
    }

    @Test func functionStateResetsWhenExistingListenerStops() {
        let state = ShortcutHardwareModifierState()
        let suppressor = KeyboardEventSuppressor(hardwareModifierState: state)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        event.type = .flagsChanged
        event.flags = .maskSecondaryFn
        #expect(!suppressor.handle(type: .flagsChanged, event: event))
        #expect(state.snapshot([]).functionState == "pressed")
        suppressor.stop()
        let snapshot = state.snapshot([.maskSecondaryFn, .maskNumericPad])
        #expect(snapshot.functionState == "unobserved")
        #expect(snapshot.removedFunctionFlag)
        // A held Fn seen before the first navigation event remains compatible.
        #expect(state.snapshot(.maskSecondaryFn).flags.contains(.maskSecondaryFn))
    }

    @Test func navigationFunctionFilteringHasCorrelatedContentFreeDiagnostic() {
        var logs: [String] = []
        let state = ShortcutHardwareModifierState()
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: .maskCommand,
            hardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) }, modifierState: state,
            eventPoster: { _ in true }, logger: { logs.append($0) }
        ))
        #expect(logs.count == 2)
        #expect(logs[0].contains("hardware_function_filtered=true"))
        #expect(logs[0].contains("hardware_function_state=unobserved"))
        #expect(!logs.joined().contains("key_code"))
        #expect(logs.last?.contains("user_visible_result=unknown") == true)
    }

    @Test(arguments: [UInt16(0), 11, 36, 37, 48, 49, 51, 53, 96, 123, 124, 125, 126])
    func recordedShortcutMatrixUsesCompleteSharedTransactions(_ keyCode: UInt16) throws {
        let families: [(String, UInt64, UInt64)] = [
            ("control", 0x1, 0x2000), ("option", 0x20, 0x40),
            ("shift", 0x2, 0x4), ("command", 0x8, 0x10), ("function", 0, 0)
        ]
        for mask in 0..<32 {
            let selected = families.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            for side in 0..<3 {
                let bits = selected.reduce(UInt64(0)) { $0 | (side == 1 ? $1.1 : side == 2 ? $1.2 : 0) }
                let shortcut = try #require(KeyboardInjector.recordedShortcut(
                    keyCode: keyCode, modifiers: selected.map(\.0), deviceModifierFlags: bits))
                var events: [Edge] = []
                #expect(KeyboardInjector.send(.customShortcut, shortcut: shortcut,
                    accessibilityTrusted: { true },
                    keyPoster: { _, _ in Issue.record("Shortcut bypassed shared transaction") },
                    shortcutEventPoster: { events.append(Edge($0)); return true },
                    shortcutHardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) }))
                let primary = events.filter { $0.type == .keyDown || $0.type == .keyUp }
                let expectedFlags = side == 0
                    ? selected.reduce(shortcut.cgEventFlags) { $0.union(CGEventFlags(rawValue: $1.1)) }
                    : shortcut.cgEventFlags
                #expect(primary.map(\.code) == [keyCode, keyCode])
                #expect(primary.first?.type == .keyDown && primary.last?.type == .keyUp)
                for event in primary {
                    #expect(event.flags.contains(.maskNumericPad) == (123...126).contains(keyCode))
                    #expect(event.flags.subtracting(.maskNumericPad) == expectedFlags)
                }
                #expect(events.filter { $0.type == .flagsChanged }.last?.flags.isEmpty ?? true)
            }
        }
    }

    @Test func recordedShortcutRejectsUnknownModifiersAndDeviceBits() {
        #expect(KeyboardInjector.recordedShortcut(keyCode: 37, modifiers: ["unknown"], deviceModifierFlags: 0) == nil)
        #expect(KeyboardInjector.recordedShortcut(keyCode: 37, modifiers: ["command"], deviceModifierFlags: 0x800000) == nil)
        #expect(KeyboardInjector.recordedShortcut(keyCode: 128, modifiers: [], deviceModifierFlags: 0) == nil)
    }

}
