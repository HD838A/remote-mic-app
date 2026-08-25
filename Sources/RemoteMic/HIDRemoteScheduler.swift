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
    static let stableReleaseMilliseconds: UInt64 = 600
    static let permissionPollMilliseconds: UInt64 = 1_000
    static let appSwitcherTimeoutMilliseconds: UInt64 = 15_000
    static let appSwitcherFrontmostPollMilliseconds: UInt64 = 500
    static let appSwitcherConfirmationProbeMilliseconds: UInt64 = 300

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
