import CoreGraphics
import Foundation
import IOKit.hidsystem

/// The key emitted for a voice session.
///
/// Fn remains the compatibility default. Command and Option variants are
/// deliberately limited to dedicated physical sides so a user can choose a
/// rare, dedicated trigger without turning the voice key into an arbitrary
/// shortcut recorder. Both Option sides are available for tools that accept a
/// dedicated modifier as a hold trigger.
enum VoiceKeyMode: String, Codable, CaseIterable, Identifiable {
    case function = "fn"
    case leftCommand = "left_command"
    case rightCommand = "right_command"
    case leftOption = "left_option"
    case rightOption = "right_option"

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .function: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .function:
            return .maskSecondaryFn
        case .leftCommand:
            return [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))]
        case .rightCommand:
            return [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))]
        case .leftOption:
            return [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))]
        case .rightOption:
            return [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))]
        }
    }

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
