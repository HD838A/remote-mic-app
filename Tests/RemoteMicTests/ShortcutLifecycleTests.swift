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

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func tapDisableDropsStaleFunctionStateBeforeReenable(_ type: CGEventType) {
        let state = ShortcutHardwareModifierState()
        let suppressor = KeyboardEventSuppressor(hardwareModifierState: state)
        let held = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        held.type = .flagsChanged
        held.flags = .maskSecondaryFn
        #expect(!suppressor.handle(type: .flagsChanged, event: held))
        #expect(state.snapshot([]).functionState == "pressed")
        // 禁用窗口里没有事件回调，松开 Fn 的边沿会丢失；此处必须复位，
        // 否则过期的 pressed 会让之后每个快捷键都带上 Fn。
        let disabled = CGEvent(source: nil)!
        #expect(!suppressor.handle(type: type, event: disabled))
        #expect(state.snapshot([]).functionState == "unobserved")
        // 复位后只记录状态，不改变未观测 Fn 在快照里的历史行为。
        var logs: [String] = []
        let events = ShortcutEventSequence.send(
            keyCode: 37, modifiers: .maskCommand,
            hardwareFlags: { [] }, modifierState: state,
            eventPoster: { _ in true }, logger: { logs.append($0) }
        )
        #expect(events)
        #expect(logs.first?.contains("hardware_function_state=unobserved") == true)
    }

    @Test func navigationFunctionFilteringHasCorrelatedContentFreeDiagnostic() {
        var logs: [String] = []
        let state = ShortcutHardwareModifierState()
        #expect(ShortcutEventSequence.send(
            keyCode: 37, modifiers: .maskCommand,
            hardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) }, modifierState: state,
            eventPoster: { _ in true }, logger: { logs.append($0) }
        ))
        #expect(logs.filter { $0.contains("phase=requested") || $0.contains("phase=completed") }.count == 2)
        #expect(logs.filter { $0.contains("phase=event_submission") }.count == 4)
        #expect(logs[0].contains("hardware_function_filtered=true"))
        #expect(logs[0].contains("hardware_function_state=unobserved"))
        #expect(!logs.joined().contains("key_code"))
        #expect(logs.last?.contains("user_visible_result=unknown") == true)
    }

    // 主页键（Home，键码 115）在 Intel 机器上让系统快照只带 Fn、不带数字键盘位。
    // 该伪 Fn 曾进入已配置的 Command+Shift+H，目标 App 因多一个 Fn 而不匹配。
    @Test func unverifiedFunctionFlagNeverJoinsShortcutWithoutFunction() {
        var logs: [String] = []
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 4, modifiers: [.maskCommand, .maskShift],
            hardwareFlags: { CGEventFlags(rawValue: 0x0080_0000) },
            modifierState: ShortcutHardwareModifierState(),
            eventPoster: { events.append(Edge($0)); return true },
            logger: { logs.append($0) }
        ))
        #expect(events.map(\.code) == [56, 55, 4, 4, 55, 56])
        #expect(events.allSatisfy { !$0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags.isEmpty == true)
        let request = logs.first { $0.contains("phase=requested") }
        #expect(request?.contains("hardware_function_filtered=true") == true)
        #expect(request?.contains("hardware_function_state=unobserved") == true)
        #expect(request?.contains("physical_flags=0") == true)
        #expect(request?.contains("hardware_flags=8388608") == true)
    }

    @Test func explicitlyConfiguredFunctionKeepsUnverifiedFunctionFlag() {
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 4, modifiers: [.maskCommand, .maskSecondaryFn],
            hardwareFlags: { CGEventFlags(rawValue: 0x0080_0000) },
            modifierState: ShortcutHardwareModifierState(),
            eventPoster: { events.append(Edge($0)); return true }
        ))
        // 显式 Fn 已由硬件快照提供，不再重复按下 Fn 键，但事件必须保留 Fn。
        #expect(events.map(\.code) == [55, 4, 4, 55])
        #expect(events.allSatisfy { $0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags == .maskSecondaryFn)
    }

    // 真实按住的 Fn（收到键码 63 的 flagsChanged）保持既有行为，Apple 芯片与 Intel 一致。
    @Test func heldPhysicalFunctionStillJoinsShortcutWithoutFunction() {
        let state = ShortcutHardwareModifierState()
        let suppressor = KeyboardEventSuppressor(hardwareModifierState: state)
        let functionEvent = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        functionEvent.type = .flagsChanged
        functionEvent.flags = .maskSecondaryFn
        #expect(!suppressor.handle(type: .flagsChanged, event: functionEvent))
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 4, modifiers: [.maskCommand, .maskShift],
            hardwareFlags: { CGEventFlags(rawValue: 0x0080_0000) }, modifierState: state,
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.allSatisfy { $0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags == .maskSecondaryFn)
    }

    @Test func helpKeyIdentityFlagIsNotCarriedIntoShortcuts() {
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 4, modifiers: [.maskCommand, .maskShift],
            hardwareFlags: { .maskHelp },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        #expect(events.map(\.code) == [56, 55, 4, 4, 55, 56])
        // Help / Insert 用法会把 Help 位写进硬件快照，和 Fn 层键位写 Fn 位同理；
        // 没有任何快捷键能请求 Help，所以它不能进入合成事件。
        #expect(events.allSatisfy { !$0.flags.contains(.maskHelp) })
        #expect(events.last?.flags == [])
    }

    @Test func capsLockStateStillRidesAlongWithShortcuts() {
        var events: [Edge] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 4, modifiers: .maskCommand,
            hardwareFlags: { .maskAlphaShift },
            eventPoster: { events.append(Edge($0)); return true }
        ))
        // 大小写锁定是真实状态，不能让合成字母退化成小写。
        #expect(events.allSatisfy { $0.flags.contains(.maskAlphaShift) })
    }

    @Test(arguments: [
        (UInt16(114), "help"), (115, "home"), (116, "page_navigation"),
        (117, "forward_delete"), (119, "end"), (121, "page_navigation")
    ])
    func functionLayerKeysHaveStableDiagnosticKinds(_ sample: (UInt16, String)) {
        #expect(ShortcutEventSequence.diagnosticKind(sample.0, modifiers: []) == sample.1)
        // 带 Command 的快捷键仍归入既有分类，入口优先级不变。
        #expect(ShortcutEventSequence.diagnosticKind(sample.0, modifiers: .maskCommand) == "command_shortcut")
        #expect(ShortcutEventSequence.diagnosticKind(37, modifiers: []) == nil)
    }

    @Test func bareFunctionLayerShortcutGetsCorrelatedDiagnostics() {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(logger: { logs.append($0) })
        let result = ShortcutEventSequence.send(
            keyCode: 119, modifiers: [], hardwareFlags: { [] },
            modifierState: ShortcutHardwareModifierState(),
            eventPoster: { event in
                #expect(!suppressor.handle(type: event.type, event: event))
                return true
            },
            logger: { logs.append($0) }
        )
        #expect(result)
        let request = logs.first { $0.contains("phase=requested") }
        #expect(request?.contains("primary_kind=end") == true)
        #expect(logs.filter { $0.contains("phase=event_submission") }.count == 2)
        #expect(logs.filter { $0.contains("SHORTCUT OBSERVATION") }.count == 2)
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
                var expectedFlags = side == 0
                    ? selected.reduce(shortcut.cgEventFlags) { $0.union(CGEventFlags(rawValue: $1.1)) }
                    : shortcut.cgEventFlags
                if (123...126).contains(keyCode) {
                    expectedFlags.formUnion([.maskSecondaryFn, .maskNumericPad])
                }
                #expect(primary.map(\.code) == [keyCode, keyCode])
                #expect(primary.first?.type == .keyDown && primary.last?.type == .keyUp)
                for event in primary {
                    #expect(event.flags.contains(.maskNumericPad) == (123...126).contains(keyCode))
                    #expect(event.flags == expectedFlags)
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

    @Test func controlArrowDiagnosticsConnectConstructionToSessionObservation() throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(logger: { logs.append($0) })
        var primaryTimestamps: [UInt64] = []
        var filtered: [Bool] = []
        #expect(ShortcutEventSequence.send(
            keyCode: 126, modifiers: .maskControl,
            hardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) },
            modifierState: ShortcutHardwareModifierState(),
            eventPoster: { event in
                if event.type == .keyDown || event.type == .keyUp {
                    primaryTimestamps.append(event.timestamp)
                }
                // Replay the existing session callback; this is not a real system post.
                filtered.append(suppressor.handle(type: event.type, event: event))
                return true
            }, logger: { logs.append($0) }
        ))
        #expect(filtered == [false, false, false, false])
        let request = try #require(logs.first { $0.contains("phase=requested") })
        #expect(request.contains("primary_kind=arrow_up"))
        #expect(request.contains("requested_flags=262144"))
        #expect(request.contains("physical_flags=0"))
        let events = logs.filter { $0.contains("phase=event_submission") }
        try #require(events.count == 4)
        #expect(events[0].contains("event_kind=modifier_down"))
        #expect(events[1].contains("event_kind=key_down"))
        #expect(events[1].contains("event_flags=10747905"))
        #expect(events[1].contains("event_function=true"))
        #expect(events[1].contains("event_numeric_pad=true"))
        #expect(events[3].contains("event_kind=modifier_up"))
        #expect(events[3].contains("event_flags=0"))
        let observations = logs.filter { $0.contains("SHORTCUT OBSERVATION") }
        #expect(observations.count == 2)
        for timestamp in primaryTimestamps {
            #expect(events.contains { $0.contains("event_timestamp_ns=\(timestamp) ") })
            #expect(observations.contains { $0.contains("event_timestamp_ns=\(timestamp) ") })
        }
        #expect(observations.allSatisfy { $0.contains("result=passed_through") && $0.contains("user_visible_result=unknown") })
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(!logs.joined().contains("key_code"))
    }

    @Test(arguments: 0..<4)
    func controlArrowDiagnosticFailuresKeepOneTerminalAndRecovery(_ failAt: Int) {
        var logs: [String] = []
        var index = 0
        #expect(!ShortcutEventSequence.send(
            keyCode: 126, modifiers: .maskControl, hardwareFlags: { [] },
            eventPoster: { _ in defer { index += 1 }; return index != failAt },
            logger: { logs.append($0) }
        ))
        #expect(logs.contains { $0.contains("phase=event_submission") && $0.contains("result=failed") })
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(logs.last?.contains("result=failed") == true)
        logs.removeAll()
        #expect(ShortcutEventSequence.send(
            keyCode: 126, modifiers: .maskControl, hardwareFlags: { [] },
            eventPoster: { _ in true }, logger: { logs.append($0) }
        ))
        #expect(logs.last?.contains("result=submitted") == true)
    }

    @Test(arguments: [UInt16(4), 11, 37, 116, 121])
    func configuredShortcutDiagnosticsPreserveEventsAndOmitInputContent(_ code: UInt16) throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(logger: { logs.append($0) })
        let modifiers: CGEventFlags = code == 4 ? [.maskCommand, .maskShift]
            : code == 11 ? [.maskCommand, .maskAlternate] : code == 37 ? .maskCommand : []
        var keys: [UInt16] = []
        let result = ShortcutEventSequence.send(keyCode: code, modifiers: modifiers,
            hardwareFlags: { .maskSecondaryFn }, modifierState: ShortcutHardwareModifierState(),
            eventPoster: { event in
                if event.type == .keyDown || event.type == .keyUp {
                    keys.append(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
                    // 未观察到真实 Fn 边沿时，快照里的 Fn 是来源按键的伪影，不能进入事件。
                    #expect(!event.flags.contains(.maskSecondaryFn))
                }
                #expect(!suppressor.handle(type: event.type, event: event))
                return true
            }, logger: { logs.append($0) })
        #expect(result)
        #expect(keys == [code, code])
        let request = try #require(logs.first { $0.contains("phase=requested") })
        #expect(request.contains("primary_kind=command_shortcut") || request.contains("primary_kind=page_navigation"))
        #expect(request.contains("hardware_function_state=unobserved"))
        #expect(request.contains("physical_flags=0"))
        #expect(request.contains("hardware_function_filtered=true"))
        let observations = logs.filter { $0.contains("SHORTCUT OBSERVATION") }
        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0.contains("correlation=matched") && $0.contains("flags_match=true") }, "\(observations)")
        #expect(!logs.joined().contains("key_code"))
        #expect(!logs.joined().contains("letter_"))
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
    }

    @Test(arguments: [true, false])
    func systemMediaDiagnosticsCorrelateOnlyOurSubmittedEvents(_ accepted: Bool) throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(logger: { logs.append($0) })
        var events: [CGEvent] = []
        let result = KeyboardInjector.submitSystemKey(type: 16,
            eventPoster: { event in
                events.append(event)
                if accepted { #expect(!suppressor.handle(type: event.type, event: event)) }
                return accepted
            }, logger: { logs.append($0) })
        #expect(result == accepted)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.syntheticEventMarker })
        let observations = logs.filter { $0.contains("SHORTCUT OBSERVATION") }
        #expect(observations.count == (accepted ? 2 : 0))
        #expect(observations.allSatisfy { $0.contains("primary_kind=system_play_pause") && $0.contains("correlation=matched") })
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(logs.filter { $0.contains("SYSTEM MEDIA") }.allSatisfy {
            $0.contains("target=system_media_dispatch")
        })
        #expect(logs.filter { $0.contains("phase=completed") }.allSatisfy {
            $0.contains("user_visible_result=unknown")
        })
        if !accepted {
            logs.removeAll()
            for event in events { #expect(!suppressor.handle(type: event.type, event: event)) }
            #expect(logs.isEmpty)
        }
    }

    @Test(arguments: 0..<2)
    func mediaFailureStillAttemptsReleaseAndHasOneTerminal(_ failAt: Int) throws {
        var events: [CGEvent] = []
        var logs: [String] = []
        let result = KeyboardInjector.submitSystemKey(type: 16, eventPoster: { event in
            events.append(event)
            return events.count - 1 != failAt
        }, logger: { logs.append($0) })
        #expect(!result)
        try #require(events.count == 2)
        #expect(NSEvent(cgEvent: events[0])?.data1 == (16 << 16) | (0xA << 8))
        #expect(NSEvent(cgEvent: events[1])?.data1 == (16 << 16) | (0xB << 8))
        #expect(events.allSatisfy { $0.flags.isEmpty })
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(logs.last?.contains("result=failed reason=post_failed submitted_events=1") == true)
    }

    @Test func sessionObservationDoesNotLogPhysicalKeysOrOrdinarySyntheticContent() throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(logger: { logs.append($0) })
        for (code, marked, flags) in [
            (UInt16(126), false, CGEventFlags.maskControl),
            (UInt16(0), true, CGEventFlags.maskControl),
            (UInt16(126), true, CGEventFlags.maskShift),
        ] {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = flags
            if marked { event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker) }
            #expect(!suppressor.handle(type: .keyDown, event: event))
        }
        #expect(logs.isEmpty)
    }

    @Test func sessionObservationReportsChangedFlagsOnlyOnce() throws {
        let observation = ShortcutSessionObservation()
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 126, keyDown: true))
        event.timestamp = 1
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        event.flags = [.maskControl, .maskNumericPad]
        observation.register(event, operationID: "test", eventIndex: 2, primaryKind: "arrow_up")
        event.flags = .maskNumericPad
        var logs: [String] = []
        observation.observe(event, logger: { logs.append($0) })
        observation.observe(event, logger: { logs.append($0) })
        #expect(logs.count == 1)
        #expect(logs.first?.contains("operation_id=test") == true)
        #expect(logs.first?.contains("flags_match=false") == true)
        #expect(logs.first?.contains("expected_flags=2359296 event_flags=2097152") == true)
    }

    @Test func sessionObservationDoesNotPairMissingOrDuplicateTimestamps() throws {
        let observation = ShortcutSessionObservation()
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 126, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        event.flags = [.maskControl, .maskNumericPad]
        var logs: [String] = []
        event.timestamp = 0
        observation.register(event, operationID: "zero", eventIndex: 2, primaryKind: "arrow_up")
        observation.observe(event, logger: { logs.append($0) })
        event.timestamp = 1
        observation.register(event, operationID: "first", eventIndex: 2, primaryKind: "arrow_up")
        observation.register(event, operationID: "second", eventIndex: 2, primaryKind: "arrow_up")
        observation.observe(event, logger: { logs.append($0) })
        #expect(logs.count == 2)
        #expect(logs.allSatisfy { $0.contains("operation_id=unknown") && $0.contains("correlation=unavailable") })
        #expect(!logs.joined().contains("flags_match=true"))
    }

    @Test func sessionObservationBoundsMissingCallbacksAndExpiresWithoutFalseFailure() throws {
        var now: TimeInterval = 10
        let observation = ShortcutSessionObservation(uptime: { now })
        var events: [CGEvent] = []
        for index in 0..<65 {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 126, keyDown: true))
            event.timestamp = UInt64(index + 1)
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
            events.append(event)
            observation.register(event, operationID: "test", eventIndex: index, primaryKind: "arrow_up")
            now += 0.001
        }
        var logs: [String] = []
        observation.observe(events[0], logger: { logs.append($0) })
        #expect(logs.isEmpty)
        observation.observe(events[64], logger: { logs.append($0) })
        #expect(logs.count == 1)
        now = 13
        observation.observe(events[1], logger: { logs.append($0) })
        #expect(logs.count == 1)
        observation.register(events[0], operationID: "recovered", eventIndex: 0, primaryKind: "arrow_up")
        observation.observe(events[0], logger: { logs.append($0) })
        #expect(logs.last?.contains("operation_id=recovered") == true)
        #expect(!logs.joined().contains("result=failed"))
    }

}
