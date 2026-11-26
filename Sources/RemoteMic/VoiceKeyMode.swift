import CoreGraphics
import Foundation
import IOKit.hidsystem

/// The key emitted for a voice session.
///
/// Fn remains the compatibility default. Command and Option variants are
/// deliberately limited to dedicated physical sides so a user can choose a
/// rare, dedicated trigger without turning the voice key into an arbitrary
/// shortcut recorder. Both Option sides are available for tools that accept a
/// dedicated modifier as a hold trigger. Two fixed right-side modifier chords
/// cover tools whose hold-to-talk shortcut must combine several modifiers;
/// they are still a closed list, not a recorder.
enum VoiceKeyMode: String, Codable, CaseIterable, Identifiable {
    case function = "fn"
    case leftCommand = "left_command"
    case rightCommand = "right_command"
    case leftOption = "left_option"
    case rightOption = "right_option"
    case rightCommandOption = "right_command_option"
    case rightCommandOptionShift = "right_command_option_shift"

    /// One physical modifier inside a voice key mode.
    struct ModifierKey: Equatable {
        let keyCode: UInt16
        /// Generic modifier flag plus the side-specific device flag.
        let flags: CGEventFlags
    }

    private static let fnKey = ModifierKey(keyCode: 63, flags: .maskSecondaryFn)
    private static let leftCommandKey = ModifierKey(
        keyCode: 55,
        flags: [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))]
    )
    private static let rightCommandKey = ModifierKey(
        keyCode: 54,
        flags: [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))]
    )
    private static let leftOptionKey = ModifierKey(
        keyCode: 58,
        flags: [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))]
    )
    private static let rightOptionKey = ModifierKey(
        keyCode: 61,
        flags: [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))]
    )
    private static let rightShiftKey = ModifierKey(
        keyCode: 60,
        flags: [.maskShift, CGEventFlags(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))]
    )

    var id: String { rawValue }

    /// Keys in press order. Release uses the reverse order.
    var keys: [ModifierKey] {
        switch self {
        case .function: return [Self.fnKey]
        case .leftCommand: return [Self.leftCommandKey]
        case .rightCommand: return [Self.rightCommandKey]
        case .leftOption: return [Self.leftOptionKey]
        case .rightOption: return [Self.rightOptionKey]
        case .rightCommandOption: return [Self.rightCommandKey, Self.rightOptionKey]
        case .rightCommandOptionShift:
            return [Self.rightCommandKey, Self.rightOptionKey, Self.rightShiftKey]
        }
    }

    /// Single-key modes keep their historical key code; chords report the first key.
    var keyCode: UInt16 { keys[0].keyCode }

    /// Flags present while the whole mode is held.
    var eventFlags: CGEventFlags {
        keys.reduce(into: CGEventFlags()) { $0.formUnion($1.flags) }
    }

    var isChord: Bool { keys.count > 1 }

    static var singleKeyModes: [VoiceKeyMode] { allCases.filter { !$0.isChord } }
    static var chordModes: [VoiceKeyMode] { allCases.filter(\.isChord) }

    var requiresAccessibility: Bool {
        self != .function
    }

    var usesHardwareMapping: Bool {
        self == .function
    }

    var localizationKey: String {
        "connection.voice_key.mode.\(rawValue)"
    }
}

extension VoiceKeyMode {
    init?(standaloneModifier: StandaloneKeyboardModifier) {
        switch standaloneModifier {
        case .function: self = .function
        case .leftCommand: self = .leftCommand
        case .rightCommand: self = .rightCommand
        case .leftOption: self = .leftOption
        case .rightOption: self = .rightOption
        case .leftControl, .rightControl, .leftShift, .rightShift:
            return nil
        }
    }
}
