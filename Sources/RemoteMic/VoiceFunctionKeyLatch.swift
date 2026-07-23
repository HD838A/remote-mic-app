import Foundation

enum VoiceFunctionKeyTransition: Equatable {
    case press
    case release
}

struct VoiceFunctionKeyLatch {
    private(set) var isHeld = false

    mutating func transition(streaming: Bool) -> VoiceFunctionKeyTransition? {
        if streaming {
            guard !isHeld else { return nil }
            isHeld = true
            return .press
        }

        guard isHeld else { return nil }
        isHeld = false
        return .release
    }

    mutating func rollback(_ transition: VoiceFunctionKeyTransition) {
        switch transition {
        case .press:
            isHeld = false
        case .release:
            isHeld = true
        }
    }
}
