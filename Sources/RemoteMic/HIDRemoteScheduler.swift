import Foundation

protocol HIDRemoteScheduledTask: AnyObject {
    func cancel()
}

protocol HIDRemoteScheduling {
    @discardableResult
    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask
}

enum HIDRemoteTiming {
    static let doubleClickMilliseconds: UInt64 = 300
    static let longPressMilliseconds: UInt64 = 550
    static let repeatStartMilliseconds: UInt64 = 350
    /// 翻页每次都要扫一遍辅助功能树，按住重复时不能跟着 100ms 的节奏走。
    static let pageRepeatMinimumMilliseconds: UInt64 = 250
    static let stableReleaseMilliseconds: UInt64 = 600
    static let permissionPollMilliseconds: UInt64 = 1_000
    static let appSwitcherTimeoutMilliseconds: UInt64 = 15_000
    static let appSwitcherFrontmostPollMilliseconds: UInt64 = 500
    static let appSwitcherConfirmationProbeMilliseconds: UInt64 = 300
    static let appSwitcherMinimizedRestoreProbeMilliseconds: UInt64 = 500
    static let appSwitcherMinimizedRestoreRetryMilliseconds: UInt64 = 400
    static let appSwitcherModifierWatchdogMilliseconds: UInt64 = 1_000
    static let appSwitcherVisibilityProbeMilliseconds: [UInt64] = [0, 150, 500, 1_000]

    static func repeatIntervalMilliseconds(for button: RemoteButton) -> UInt64? {
        switch button {
        case .back: 50
        case .up, .down, .left, .right, .volumeUp, .volumeDown: 100
        default: nil
        }
    }
}

final class DispatchHIDRemoteScheduledTask: HIDRemoteScheduledTask {
    private let source: DispatchSourceTimer

    init(source: DispatchSourceTimer) {
        self.source = source
    }

    func cancel() {
        source.cancel()
    }
}

struct DispatchHIDRemoteScheduler: HIDRemoteScheduling {
    let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let deadline = DispatchTime.now() + .milliseconds(Int(clamping: afterMilliseconds))
        if let repeatingEveryMilliseconds {
            source.schedule(
                deadline: deadline,
                repeating: .milliseconds(Int(clamping: repeatingEveryMilliseconds))
            )
        } else {
            source.schedule(deadline: deadline)
        }
        source.setEventHandler(handler: action)
        source.resume()
        return DispatchHIDRemoteScheduledTask(source: source)
    }
}
