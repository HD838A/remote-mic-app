import Foundation

enum VoiceFunctionKeyTransition: Equatable {
    case press
    case release
}

struct VoiceFunctionKeyLatch {
    /// 语音键按下者。多个 owner 同时按住时按引用计数处理：
    /// 只有最后一个 owner 释放才会真正抬起语音键，因此各路硬件互不取消。
    enum Owner: Hashable {
        case bluetooth
        case appleRemote
        /// Chromecast 遥控器。与 Siri Remote 独立，两者同时收音时互不影响。
        case chromecast
        case mobile
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
