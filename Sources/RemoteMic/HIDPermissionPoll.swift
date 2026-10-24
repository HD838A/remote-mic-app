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
    private let permissionQuery: (@escaping (Bool) -> Void) -> Void
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var subscribers: [UUID: (Bool) -> Void] = [:]
    private var taskState: TaskState = .idle
    private var isQueryPending = false

    init(
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionQuery: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            // 输入监控与辅助功能都是同步 IPC 到 tccd，不能在主线程上跑。
            PermissionStatusProbe.shared.fetch { snapshot in
                completion(snapshot.inputMonitoring && snapshot.accessibility)
            }
        },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.scheduler = scheduler
        self.permissionQuery = permissionQuery
        self.logger = logger
    }

    @discardableResult
    func subscribe(_ handler: @escaping (Bool) -> Void) -> Subscription {
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
        // 查询未返回时跳过 tick，避免慢 TCC IPC 无限积累 completion。
        lock.lock()
        guard !isQueryPending, !subscribers.isEmpty else {
            lock.unlock()
            return
        }
        isQueryPending = true
        let tokens = Array(subscribers.keys)
        lock.unlock()

        permissionQuery { [weak self] permissionsGranted in
            guard let self else { return }
            self.lock.lock()
            self.isQueryPending = false
            // 只交付给查询发出时仍存活的订阅，不把旧结果交给后来启动的监听。
            let handlers = tokens.compactMap { self.subscribers[$0] }
            self.lock.unlock()
            handlers.forEach { $0(permissionsGranted) }
        }
    }
}
