import Foundation

enum VoiceFunctionKeyTransition: Equatable {
    case press
    case release
}

struct VoiceFunctionKeyLatch {
    enum Owner: Hashable {
        case bluetooth
        case mobile
        case appleRemote
    }

    private var owners: Set<Owner> = []

    var isHeld: Bool {
        !owners.isEmpty
    }

    mutating func transition(
        streaming: Bool,
        owner: Owner
    ) -> VoiceFunctionKeyTransition? {
        if streaming {
            guard owners.insert(owner).inserted else { return nil }
            return owners.count == 1 ? .press : nil
        }

        guard owners.remove(owner) != nil else { return nil }
        return owners.isEmpty ? .release : nil
    }

    mutating func rollback(
        _ transition: VoiceFunctionKeyTransition,
        owner: Owner
    ) {
        switch transition {
        case .press:
            owners.remove(owner)
        case .release:
            owners.insert(owner)
        }
    }

    mutating func reset() {
        owners.removeAll()
    }
}
