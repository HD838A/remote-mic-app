import CoreGraphics
import Foundation
import IOKit.hidsystem

/// The key emitted for a voice session.
///
/// Fn remains the compatibility default. Command and Option variants are
/// deliberately limited to dedicated physical sides so a user can choose a
/// rare, dedicated trigger without turning the voice key into an arbitrary
/// shortcut recorder. Right Option is included because it is the least used
/// modifier and several voice input tools accept it as a hold trigger.
enum VoiceKeyMode: String, Codable, CaseIterable, Identifiable {
    case function = "fn"
    case leftCommand = "left_command"
    case rightCommand = "right_command"
    case rightOption = "right_option"

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .function: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
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
        case .rightOption: self = .rightOption
        case .leftOption, .leftControl, .rightControl, .leftShift, .rightShift:
            return nil
        }
    }
}
