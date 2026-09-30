import CoreGraphics
import Foundation

/// One synchronous shortcut transaction. A private source keeps our injected flags
/// out of the HID hardware snapshot used to preserve keys the user is holding.
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
        logger(
            "\(prefix) phase=requested modifier_count=\(selectedModifiers.count) " +
                "side_specific=\(selectedModifiers.contains { $0.sideSpecific })"
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
        let physicalAtStart = hardwareFlags()
        let owned = selectedModifiers.filter { modifier in
            if modifier.sideSpecific {
                return !physicalAtStart.contains(modifier.deviceBit)
            }
            return !physicalAtStart.contains(modifier.flag)
        }
        var synthetic: CGEventFlags = []
        var attemptedModifiers: [SelectedModifier] = []

        func emit(_ code: CGKeyCode, down: Bool, modifier: Bool) -> Bool {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { return false }
            if modifier { event.type = .flagsChanged }
            // Read again on release: do not clear a physical key pressed mid-sequence.
            event.flags = synthetic.union(hardwareFlags())
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
            let accepted = eventPoster(event)
            if accepted { submitted += 1 }
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
