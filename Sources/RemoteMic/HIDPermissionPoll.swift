import Foundation

/// Shares one process-wide permission timer across all HID remote monitors.
final class HIDPermissionPoll {
    final class Subscription {
        private let lock = NSLock()
        private var owner: HIDPermissionPoll?
        private var token: UUID?

        fileprivate init(owner: HIDPermissionPoll, token: UUID) {
            self.owner = owner
            self.token = token
        }

        func cancel() {
            let cancellation: (HIDPermissionPoll, UUID)?
            lock.lock()
            if let owner, let token {
                cancellation = (owner, token)
                self.owner = nil
                self.token = nil
            } else {
                cancellation = nil
            }
            lock.unlock()
            if let cancellation {
                cancellation.0.unsubscribe(cancellation.1)
            }
        }

        deinit {
            cancel()
        }
    }

    static let shared = HIDPermissionPoll()

    private enum TaskState {
        case idle
        case starting
        case running(HIDRemoteScheduledTask)
    }

    private let scheduler: HIDRemoteScheduling
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var subscribers: [UUID: () -> Void] = [:]
    private var taskState: TaskState = .idle

    init(
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.scheduler = scheduler
        self.logger = logger
    }

    @discardableResult
    func subscribe(_ handler: @escaping () -> Void) -> Subscription {
        let token = UUID()
        let shouldStart: Bool
        let subscriberCount: Int
        lock.lock()
        subscribers[token] = handler
        subscriberCount = subscribers.count
        if case .idle = taskState {
            taskState = .starting
            shouldStart = true
        } else {
            shouldStart = false
        }
        lock.unlock()

        if shouldStart {
            startPolling()
        }
        logger(
            "HID PERMISSION POLL phase=subscribed result=active " +
                "subscriber_count=\(subscriberCount) timer_started=\(shouldStart)"
        )
        return Subscription(owner: self, token: token)
    }

    private func unsubscribe(_ token: UUID) {
        let taskToCancel: HIDRemoteScheduledTask?
        let subscriberCount: Int
        lock.lock()
        guard subscribers.removeValue(forKey: token) != nil else {
            lock.unlock()
            return
        }
        subscriberCount = subscribers.count
        if subscribers.isEmpty, case .running(let task) = taskState {
            taskState = .idle
            taskToCancel = task
        } else {
            taskToCancel = nil
        }
        lock.unlock()

        taskToCancel?.cancel()
        logger(
            "HID PERMISSION POLL phase=unsubscribed " +
                "result=\(subscriberCount == 0 ? "stopped" : "active") " +
                "subscriber_count=\(subscriberCount) timer_stopped=\(taskToCancel != nil)"
        )
    }

    private func startPolling() {
        let task = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.permissionPollMilliseconds
        ) { [weak self] in
            self?.notifySubscribers()
        }

        let shouldCancel: Bool
        lock.lock()
        if subscribers.isEmpty {
            taskState = .idle
            shouldCancel = true
        } else {
            taskState = .running(task)
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    private func notifySubscribers() {
        let handlers: [() -> Void]
        lock.lock()
        handlers = Array(subscribers.values)
        lock.unlock()
        handlers.forEach { $0() }
    }
}
