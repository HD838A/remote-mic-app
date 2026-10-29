import Foundation
import CoreGraphics

/// Device timing and button behavior. Missing button entries mean one-shot execution.
struct RemoteButtonInteractionSettings: Codable, Equatable {
    var doubleClickMilliseconds: Int = 300
    var longPressMilliseconds: Int = 550
    var modes: [String: String] = [:]
    var migratedRepeatButtons: [String]? = nil

    var isValid: Bool {
        (150...500).contains(doubleClickMilliseconds) && doubleClickMilliseconds % 50 == 0 &&
        (300...1000).contains(longPressMilliseconds) && longPressMilliseconds % 50 == 0
    }

    var isWellFormed: Bool {
        isValid && modes.allSatisfy { RemoteButton(rawValue: $0.key) != nil && RemoteButtonHoldMode(rawValue: $0.value) != nil } &&
            (migratedRepeatButtons ?? []).allSatisfy { RemoteButton(rawValue: $0) != nil }
    }

    func mode(for button: RemoteButton) -> RemoteButtonHoldMode? {
        guard let value = modes[button.rawValue] else {
            return .once
        }
        return RemoteButtonHoldMode(rawValue: value)
    }
}

enum RemoteButtonHoldMode: String, CaseIterable, Codable, Identifiable {
    case once, repeatLong, repeatSingle, holdSingle
    var id: String { rawValue }
    var localizationKey: String { "button_mapping.hold_mode.\(rawValue.lowercased())" }
}

extension ConfiguredButtonAction {
    /// Only ordinary keyboard keys have a balanced down/up lifecycle in this release.
    var heldKeyboardKey: (code: CGKeyCode, flags: CGEventFlags)? {
        switch action {
        case .arrowUp: return (126, .maskNumericPad)
        case .arrowDown: return (125, .maskNumericPad)
        case .arrowLeft: return (123, .maskNumericPad)
        case .arrowRight: return (124, .maskNumericPad)
        case .deleteBackward: return (51, [])
        case .returnKey: return (36, [])
        case .escape: return (53, [])
        case .customShortcut:
            guard let shortcut, shortcut.standaloneModifier == nil,
                  shortcut.modifierFlags.isEmpty else { return nil }
            return (CGKeyCode(shortcut.keyCode), [123, 124, 125, 126].contains(Int(shortcut.keyCode)) ? .maskNumericPad : [])
        default: return nil
        }
    }

    var allowsHoldRepeat: Bool {
        action != .disabled && action != .appSwitcher && allowsSingleClickRepeat
    }
}

struct RemoteButtonInteractionSnapshot {
    var settings: RemoteButtonInteractionSettings
    var mode: RemoteButtonHoldMode?
    var single: ConfiguredButtonAction
    var double: ConfiguredButtonAction
    var long: ConfiguredButtonAction
    var hasOpaqueBinding = false
    var repeatInterval: UInt64 = 100
    var repeatAllowed = true
    var opaqueDouble = false
    var opaqueLong = false
    var recognizesDouble: Bool { opaqueDouble || double.action != .disabled }
    var recognizesLong: Bool { opaqueLong || long.action != .disabled }

    func hasSameBinding(as other: Self) -> Bool {
        mode == other.mode && single == other.single && double == other.double && long == other.long &&
            hasOpaqueBinding == other.hasOpaqueBinding && opaqueDouble == other.opaqueDouble && opaqueLong == other.opaqueLong
    }

    var unavailableReason: String? {
        guard settings.isValid, let mode else { return "button_mapping.hold_invalid" }
        switch mode {
        case .once: return nil
        case .repeatLong:
            return !hasOpaqueBinding && long.allowsHoldRepeat ? nil : "button_mapping.hold_repeat_long_unavailable"
        case .repeatSingle:
            return !hasOpaqueBinding && single.allowsHoldRepeat && !recognizesLong
                ? nil : "button_mapping.hold_repeat_single_unavailable"
        case .holdSingle:
            return !hasOpaqueBinding && single.heldKeyboardKey != nil &&
                !recognizesDouble && !recognizesLong
                ? nil : "button_mapping.hold_key_unavailable"
        }
    }
}

