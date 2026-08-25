import AppKit
import CoreGraphics

enum VoiceShortcutConflict: String, Equatable {
    case dangerousSystemAction = "dangerous_system_action"
    case knownSystemShortcut = "known_system_shortcut"
    case applicationCommand = "application_command"
    case unmodifiedKey = "unmodified_key"

    var localizationKey: String {
        "button_mapping.voice_shortcut.warning.\(rawValue)"
    }
}

enum VoiceShortcutConflictPolicy {
    static func warning(for shortcut: CustomKeyboardShortcut?) -> VoiceShortcutConflict? {
        guard let shortcut, shortcut.standaloneModifier == nil else { return nil }

        if matches(shortcut, keyCode: 12, modifiers: [.command]) ||
            matches(shortcut, keyCode: 12, modifiers: [.control, .command]) ||
            matches(shortcut, keyCode: 53, modifiers: [.option, .command])
        {
            return .dangerousSystemAction
        }

        let knownSystemShortcuts: [(UInt16, NSEvent.ModifierFlags)] = [
            (48, [.command]),
            (49, [.command]),
            (49, [.control]),
            (13, [.command]),
            (20, [.shift, .command]),
            (21, [.shift, .command]),
            (23, [.shift, .command]),
        ]
        if knownSystemShortcuts.contains(where: {
            matches(shortcut, keyCode: $0.0, modifiers: $0.1)
        }) {
            return .knownSystemShortcut
        }

        if shortcut.modifierFlags.contains(.command) {
            return .applicationCommand
        }
        if shortcut.modifierFlags.isEmpty {
            return .unmodifiedKey
        }
        return nil
    }

    private static func matches(
        _ shortcut: CustomKeyboardShortcut,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        shortcut.keyCode == keyCode && shortcut.modifierFlags == modifiers
    }
}

final class VoiceShortcutHoldController {
    typealias KeyStatePoster = (CGKeyCode, Bool, CGEventFlags) -> Bool

    private struct ModifierKey: Equatable {
        let keyCode: CGKeyCode
        let eventFlag: CGEventFlags
    }

    private struct HeldShortcut: Equatable {
        let shortcut: CustomKeyboardShortcut
        let modifierKeys: [ModifierKey]
        let standalone: Bool
    }

    private let keyStatePoster: KeyStatePoster
    private(set) var heldShortcut: CustomKeyboardShortcut?
    private var heldState: HeldShortcut?

    init(
        keyStatePoster: @escaping KeyStatePoster = {
            KeyboardInjector.postSyntheticKeyState(code: $0, isDown: $1, flags: $2)
        }
    ) {
        self.keyStatePoster = keyStatePoster
    }

    @discardableResult
    func press(_ shortcut: CustomKeyboardShortcut) -> Bool {
        if heldShortcut == shortcut { return true }
        if heldState != nil, !release() { return false }

        if shortcut.standaloneModifier != nil {
            guard keyStatePoster(
                CGKeyCode(shortcut.keyCode),
                true,
                shortcut.cgEventFlags
            ) else { return false }
            heldShortcut = shortcut
            heldState = HeldShortcut(shortcut: shortcut, modifierKeys: [], standalone: true)
            return true
        }

        let modifierKeys = Self.modifierKeys(for: shortcut.modifierFlags)
        var pressedModifiers: [ModifierKey] = []
        var activeFlags: CGEventFlags = []
        for modifier in modifierKeys {
            var nextFlags = activeFlags
            nextFlags.insert(modifier.eventFlag)
            guard keyStatePoster(modifier.keyCode, true, nextFlags) else {
                releaseModifiers(pressedModifiers, activeFlags: activeFlags)
                return false
            }
            pressedModifiers.append(modifier)
            activeFlags = nextFlags
        }

        guard keyStatePoster(CGKeyCode(shortcut.keyCode), true, shortcut.cgEventFlags) else {
            releaseModifiers(pressedModifiers, activeFlags: activeFlags)
            return false
        }
        heldShortcut = shortcut
        heldState = HeldShortcut(
            shortcut: shortcut,
            modifierKeys: modifierKeys,
            standalone: false
        )
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard let heldState else { return true }
        self.heldState = nil
        heldShortcut = nil

        if heldState.standalone {
            return keyStatePoster(CGKeyCode(heldState.shortcut.keyCode), false, [])
        }

        var success = keyStatePoster(
            CGKeyCode(heldState.shortcut.keyCode),
            false,
            heldState.shortcut.cgEventFlags
        )
        var activeFlags = heldState.shortcut.cgEventFlags
        for modifier in heldState.modifierKeys.reversed() {
            activeFlags.remove(modifier.eventFlag)
            if !keyStatePoster(modifier.keyCode, false, activeFlags) {
                success = false
            }
        }
        return success
    }

    private func releaseModifiers(
        _ modifiers: [ModifierKey],
        activeFlags: CGEventFlags
    ) {
        var remainingFlags = activeFlags
        for modifier in modifiers.reversed() {
            remainingFlags.remove(modifier.eventFlag)
            _ = keyStatePoster(modifier.keyCode, false, remainingFlags)
        }
    }

    private static func modifierKeys(
        for flags: NSEvent.ModifierFlags
    ) -> [ModifierKey] {
        var result: [ModifierKey] = []
        if flags.contains(.control) {
            result.append(ModifierKey(keyCode: 59, eventFlag: .maskControl))
        }
        if flags.contains(.option) {
            result.append(ModifierKey(keyCode: 58, eventFlag: .maskAlternate))
        }
        if flags.contains(.shift) {
            result.append(ModifierKey(keyCode: 56, eventFlag: .maskShift))
        }
        if flags.contains(.command) {
            result.append(ModifierKey(keyCode: 55, eventFlag: .maskCommand))
        }
        if flags.contains(.function) {
            result.append(ModifierKey(keyCode: 63, eventFlag: .maskSecondaryFn))
        }
        return result
    }
}
