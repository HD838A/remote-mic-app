import Foundation

enum RemoteCommand: Equatable {
    case chooseDevice
    case power
    case up
    case down
    case left
    case right
    case confirm
    case back
    case home
    case menu
    case television
    case volumeUp
    case volumeDown
    case voiceStart
    case voiceStop

    var hapticStrength: HapticFeedback.Strength {
        switch self {
        case .confirm, .power, .voiceStart:
            return .emphasized
        case .voiceStop:
            return .release
        default:
            return .standard
        }
    }
}
