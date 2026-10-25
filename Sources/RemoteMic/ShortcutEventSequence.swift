import CoreGraphics
import Foundation

/// HID flags and keyState both treat a navigation key's extended-key Fn bit as
/// a held Fn. Only a real Fn flagsChanged edge can disambiguate that snapshot.
final class ShortcutHardwareModifierState {
    private let lock = NSLock()
    private var functionKeyPressed: Bool?

    func observe(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == 63,
              event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker
        else { return }
        lock.lock()
        functionKeyPressed = event.flags.contains(.maskSecondaryFn)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        functionKeyPressed = nil
        lock.unlock()
    }

    func snapshot(_ raw: CGEventFlags) -> (
        flags: CGEventFlags, functionState: String, removedFunctionFlag: Bool
    ) {
        lock.lock()
        let pressed = functionKeyPressed
        lock.unlock()
        var flags = raw
        if pressed == true {
            flags.insert(.maskSecondaryFn)
        } else if pressed == false || raw.contains(.maskNumericPad) {
            flags.remove(.maskSecondaryFn)
        }
        let state = pressed.map { $0 ? "pressed" : "released" } ?? "unobserved"
        return (flags, state, raw.contains(.maskSecondaryFn) && !flags.contains(.maskSecondaryFn))
    }
}

/// Observe our Control-arrow events without changing fields or installing another tap.
/// Missing/expired correlation is unknown, not a delivery failure.
final class ShortcutSessionObservation {
    static let shared = ShortcutSessionObservation()

    private struct EventKey: Hashable {
        let timestamp: CGEventTimestamp
        let type: UInt32
        let code: Int64

        init(_ event: CGEvent) {
            timestamp = event.timestamp
            type = event.type.rawValue
            code = event.getIntegerValueField(.keyboardEventKeycode)
        }
    }

    private struct Pending {
        let operationID: String
        let eventIndex: Int
        let primaryKind: String
        let flags: UInt64
        let expiresAt: TimeInterval
        let ambiguous: Bool
    }

    private let lock = NSLock()
    private let uptime: () -> TimeInterval
    private var pending: [EventKey: Pending] = [:]

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func register(_ event: CGEvent, operationID: String, eventIndex: Int, primaryKind: String) {
        // Constructed events can have no timestamp. Never pair unrelated events at zero.
        guard event.timestamp != 0 else { return }
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        pending = pending.filter { $0.value.expiresAt > now }
        if pending.count >= 64, let oldest = pending.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            pending.removeValue(forKey: oldest.key)
        }
        let key = EventKey(event)
        let ambiguous = pending[key] != nil
        pending[key] = Pending(operationID: operationID, eventIndex: eventIndex,
            primaryKind: primaryKind, flags: ShortcutEventSequence.diagnosticFlags(event.flags),
            expiresAt: now + 2, ambiguous: ambiguous)
    }

    func discard(operationID: String, eventIndex: Int) {
        lock.lock()
        pending = pending.filter { $0.value.operationID != operationID || $0.value.eventIndex != eventIndex }
        lock.unlock()
    }

    func observe(_ event: CGEvent, logger: (String) -> Void) {
        guard event.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.syntheticEventMarker else { return }
        let now = uptime()
        lock.lock()
        let match = pending.removeValue(forKey: EventKey(event))
        lock.unlock()
        let actualFlags = ShortcutEventSequence.diagnosticFlags(event.flags)
        let eventKind = event.type == .keyDown ? "key_down" : "key_up"
        guard let match, match.expiresAt > now, !match.ambiguous else {
            guard event.type == .keyDown || event.type == .keyUp,
                  event.flags.contains(.maskControl),
                  let code = CGKeyCode(exactly: event.getIntegerValueField(.keyboardEventKeycode)),
                  let kind = ShortcutEventSequence.navigationKind(code)
            else { return }
            logger("SHORTCUT OBSERVATION operation_id=unknown phase=observed correlation=unavailable " +
                "event_index=unknown event_timestamp_ns=\(event.timestamp) event_kind=\(eventKind) " +
                "primary_kind=\(kind) source=session_event_tap event_flags=\(actualFlags) " +
                "expected_flags=unknown flags_match=unknown " +
                "result=passed_through user_visible_result=unknown")
            return
        }
        logger("SHORTCUT OBSERVATION operation_id=\(match.operationID) phase=observed " +
            "correlation=matched event_index=\(match.eventIndex) event_timestamp_ns=\(event.timestamp) event_kind=\(eventKind) " +
            "primary_kind=\(match.primaryKind) source=session_event_tap " +
            "expected_flags=\(match.flags) event_flags=\(actualFlags) " +
            "flags_match=\(match.flags == actualFlags) result=passed_through user_visible_result=unknown")
    }
}

/// One synchronous shortcut transaction. Capture hardware flags before posting:
/// HID state can echo our injected flags even when the source is private.
enum ShortcutEventSequence {
    private struct ModifierFamily {
        let flag: CGEventFlags
        let leftKey: CGKeyCode
        let leftDeviceBit: CGEventFlags
        let rightKey: CGKeyCode?
        let rightDeviceBit: CGEventFlags
    }

    private struct SelectedModifier {
        let flag: CGEventFlags
        let key: CGKeyCode
        let deviceBit: CGEventFlags
        let sideSpecific: Bool
    }

    static let hardwareModifierState = ShortcutHardwareModifierState()
    private static let lock = NSLock()
    // Existing saved combinations have no modifier side. Use left keys without
    // changing their persisted representation; standalone modifiers keep their path.
    private static let modifierFamilies: [ModifierFamily] = [
        ModifierFamily(
            flag: .maskControl,
            leftKey: 59,
            leftDeviceBit: CGEventFlags(rawValue: 0x0001),
            rightKey: 62,
            rightDeviceBit: CGEventFlags(rawValue: 0x2000)
        ),
        ModifierFamily(
            flag: .maskAlternate,
            leftKey: 58,
            leftDeviceBit: CGEventFlags(rawValue: 0x0020),
            rightKey: 61,
            rightDeviceBit: CGEventFlags(rawValue: 0x0040)
        ),
        ModifierFamily(
            flag: .maskShift,
            leftKey: 56,
            leftDeviceBit: CGEventFlags(rawValue: 0x0002),
            rightKey: 60,
            rightDeviceBit: CGEventFlags(rawValue: 0x0004)
        ),
        ModifierFamily(
            flag: .maskCommand,
            leftKey: 55,
            leftDeviceBit: CGEventFlags(rawValue: 0x0008),
            rightKey: 54,
            rightDeviceBit: CGEventFlags(rawValue: 0x0010)
        ),
        ModifierFamily(
            flag: .maskSecondaryFn,
            leftKey: 63,
            leftDeviceBit: [],
            rightKey: nil,
            rightDeviceBit: []
        )
    ]

    // Event-state flags also contain attributes that are not held modifiers.
    private static let hardwareModifierMask = modifierFamilies.reduce(
        CGEventFlags([.maskAlphaShift, .maskHelp])
    ) { $0.union($1.flag).union($1.leftDeviceBit).union($1.rightDeviceBit) }

    static func diagnosticFlags(_ flags: CGEventFlags) -> UInt64 {
        flags.intersection(hardwareModifierMask.union(.maskNumericPad)).rawValue
    }

    static func navigationKind(_ keyCode: CGKeyCode) -> String? {
        switch keyCode {
        case 123: return "arrow_left"
        case 124: return "arrow_right"
        case 125: return "arrow_down"
        case 126: return "arrow_up"
        default: return nil
        }
    }

    private static func selectedModifiers(for requested: CGEventFlags) -> [SelectedModifier] {
        modifierFamilies.compactMap { family in
            guard requested.contains(family.flag) else { return nil }
            if let rightKey = family.rightKey,
               requested.contains(family.rightDeviceBit) {
                return SelectedModifier(
                    flag: family.flag,
                    key: rightKey,
                    deviceBit: family.rightDeviceBit,
                    sideSpecific: true
                )
            }
            let leftIsSpecific = !family.leftDeviceBit.isEmpty &&
                requested.contains(family.leftDeviceBit)
            return SelectedModifier(
                flag: family.flag,
                key: family.leftKey,
                deviceBit: family.leftDeviceBit,
                sideSpecific: leftIsSpecific
            )
        }
    }

    static func post(_ event: CGEvent) -> Bool {
        event.post(tap: .cghidEventTap)
        // CGEventPost has no acknowledgement from the receiving application.
        return true
    }

    static func send(
        keyCode: CGKeyCode,
        modifiers requested: CGEventFlags,
        hardwareFlags: () -> CGEventFlags,
        modifierState: ShortcutHardwareModifierState = hardwareModifierState,
        eventPoster: (CGEvent) -> Bool,
        logger: (String) -> Void = { AppLogger.shared.write($0) }
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let operationID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        let prefix = "SHORTCUT SEQUENCE operation_id=\(operationID)"
        var result = true
        var reason = "none"
        var submitted = 0
        var cleanupFailed = false
        let selectedModifiers = selectedModifiers(for: requested)
        let hardwareSnapshot = modifierState.snapshot(hardwareFlags())
        let physicalAtStart = hardwareSnapshot.flags.intersection(hardwareModifierMask)
        let diagnosticKind = requested.contains(.maskControl) ? navigationKind(keyCode) : nil
        let diagnosticContext = diagnosticKind.map {
            " primary_kind=\($0) requested_flags=\(diagnosticFlags(requested)) " +
                "physical_flags=\(diagnosticFlags(physicalAtStart)) source_state=private post_tap=hid"
        } ?? ""
        logger(
            "\(prefix) phase=requested modifier_count=\(selectedModifiers.count) " +
                "side_specific=\(selectedModifiers.contains { $0.sideSpecific }) " +
                "hardware_function_state=\(hardwareSnapshot.functionState) " +
                "hardware_function_filtered=\(hardwareSnapshot.removedFunctionFlag)\(diagnosticContext)"
        )
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            logger("\(prefix) phase=completed result=\(result ? "submitted" : "failed") " +
                "reason=\(reason) submitted_events=\(submitted) cleanup_failed=\(cleanupFailed) " +
                "elapsed_ms=\(elapsed) user_visible_result=unknown")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            result = false
            reason = "source_unavailable"
            return false
        }
        let owned = selectedModifiers.filter { modifier in
            if modifier.sideSpecific {
                return !physicalAtStart.contains(modifier.deviceBit)
            }
            return !physicalAtStart.contains(modifier.flag)
        }
        var synthetic: CGEventFlags = []
        var attemptedModifiers: [SelectedModifier] = []
        var eventIndex = 0

        func emit(_ code: CGKeyCode, down: Bool, modifier: Bool) -> Bool {
            eventIndex += 1
            let eventKind = modifier ? (down ? "modifier_down" : "modifier_up") : (down ? "key_down" : "key_up")
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else {
                if diagnosticKind != nil {
                    logger("\(prefix) phase=event_submission event_index=\(eventIndex) " +
                        "event_kind=\(eventKind) result=construction_failed")
                }
                return false
            }
            let generatedFunction = event.flags.contains(.maskSecondaryFn)
            let generatedNumericPad = event.flags.contains(.maskNumericPad)
            if modifier { event.type = .flagsChanged }
            // Keep one physical snapshot for this synchronous transaction. Reading
            // HID state after posting can retain our own modifiers and prevent release.
            event.flags = synthetic.union(physicalAtStart)
            if !modifier, (123...126).contains(code) {
                event.flags.insert(.maskNumericPad)
            }
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
            let timestamp = event.timestamp
            let flags = event.flags
            if let diagnosticKind, !modifier {
                ShortcutSessionObservation.shared.register(event, operationID: operationID,
                    eventIndex: eventIndex, primaryKind: diagnosticKind)
            }
            let accepted = eventPoster(event)
            if accepted { submitted += 1 }
            if diagnosticKind != nil {
                if !accepted { ShortcutSessionObservation.shared.discard(operationID: operationID, eventIndex: eventIndex) }
                logger("\(prefix) phase=event_submission event_index=\(eventIndex) " +
                    "event_timestamp_ns=\(timestamp) event_kind=\(eventKind) " +
                    "generated_function=\(generatedFunction) generated_numeric_pad=\(generatedNumericPad) " +
                    "event_flags=\(diagnosticFlags(flags)) " +
                    "event_function=\(flags.contains(.maskSecondaryFn)) " +
                    "event_numeric_pad=\(flags.contains(.maskNumericPad)) " +
                    "result=\(accepted ? "submitted" : "failed")")
            }
            return accepted
        }

        for modifier in owned {
            synthetic.formUnion(modifier.flag)
            synthetic.formUnion(modifier.deviceBit)
            // Include attempted presses in cleanup even when submission fails.
            attemptedModifiers.append(modifier)
            if !emit(modifier.key, down: true, modifier: true) {
                result = false
                reason = "modifier_down_failed"
                break
            }
        }
        if result {
            if !emit(keyCode, down: true, modifier: false) {
                result = false
                reason = "key_down_failed"
            }
            // Always attempt key-up, including after a failed key-down.
            if !emit(keyCode, down: false, modifier: false) {
                result = false
                reason = "key_up_failed"
                if !emit(keyCode, down: false, modifier: false) { cleanupFailed = true }
            }
        }
        for modifier in attemptedModifiers.reversed() {
            synthetic.subtract(modifier.flag)
            synthetic.subtract(modifier.deviceBit)
            if !emit(modifier.key, down: false, modifier: true) {
                result = false
                reason = "modifier_up_failed"
                if !emit(modifier.key, down: false, modifier: true) { cleanupFailed = true }
            }
        }
        return result
    }
}
