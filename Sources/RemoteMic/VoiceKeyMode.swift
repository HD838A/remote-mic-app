import Foundation

/// The key emitted for a voice session.
///
/// Fn remains the compatibility default. Command variants are deliberately
/// limited to the two physical sides so a user can choose a rare, dedicated
/// trigger without turning the voice key into an arbitrary shortcut recorder.
enum VoiceKeyMode: String, Codable, CaseIterable, Identifiable {
    case function = "fn"
    case leftCommand = "left_command"
    case rightCommand = "right_command"

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .function: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
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
