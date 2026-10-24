import Foundation

struct RuntimePermissionSnapshot: Equatable {
    let inputMonitoringGranted: Bool
    let accessibilityTrusted: Bool

    var hidInputAvailable: Bool {
        inputMonitoringGranted && accessibilityTrusted
    }
}

/// Synchronous system queries run off the main thread; delivery returns to main.
final class RuntimePermissionReader {
    static let shared = RuntimePermissionReader()
    private let queue = DispatchQueue(label: "RemoteMic.runtimePermissions", qos: .utility)
    private let inputMonitoring: () -> Bool
    private let accessibility: () -> Bool

    init(
        inputMonitoring: @escaping () -> Bool = { HIDRemoteMonitor.isInputMonitoringGranted },
        accessibility: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted }
    ) {
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    func query(needsAccessibility: Bool, completion: @escaping (RuntimePermissionSnapshot) -> Void) {
        queue.async {
            let snapshot = RuntimePermissionSnapshot(
                inputMonitoringGranted: self.inputMonitoring(),
                accessibilityTrusted: needsAccessibility ? self.accessibility() : false
            )
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
}

/// One timer and one in-flight query serve all runtime permission consumers.
final class RuntimePermissionPoll {
    final class Subscription {
        private let lock = NSLock()
        private var owner: RuntimePermissionPoll?
        private var token: UUID?

        fileprivate init(owner: RuntimePermissionPoll, token: UUID) {
            self.owner = owner
            self.token = token
        }

        func cancel() {
            lock.lock()
            let cancellation = owner.flatMap { owner in token.map { (owner, $0) } }
            owner = nil
            token = nil
            lock.unlock()
            if let (owner, token) = cancellation { owner.unsubscribe(token) }
        }

        deinit { cancel() }
    }

    static let shared = RuntimePermissionPoll()
    private enum TaskState {
        case idle
        case starting
        case running(HIDRemoteScheduledTask)
    }
    private struct Subscriber {
        let needsAccessibility: Bool
        let handler: (Bool) -> Void
        var lastValue: Bool?
    }

    private let scheduler: HIDRemoteScheduling
    private let permissionQuery: (Bool, @escaping (RuntimePermissionSnapshot) -> Void) -> Void
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private var taskState: TaskState = .idle
    private var generation: UInt64 = 0
    // Kept across stop/start: a slow old query must not permit overlapping queries.
    private var queryInFlight = false

    init(
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionQuery: @escaping (Bool, @escaping (RuntimePermissionSnapshot) -> Void) -> Void = {
            RuntimePermissionReader.shared.query(needsAccessibility: $0, completion: $1)
        },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.scheduler = scheduler
        self.permissionQuery = permissionQuery
        self.logger = logger
    }

    convenience init(
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionEvaluator: @escaping () -> Bool,
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.init(scheduler: scheduler, permissionQuery: { _, completion in
            let granted = permissionEvaluator()
            completion(RuntimePermissionSnapshot(inputMonitoringGranted: granted, accessibilityTrusted: granted))
        }, logger: logger)
    }

    @discardableResult
    func subscribe(_ handler: @escaping (Bool) -> Void) -> Subscription {
        subscribe(needsAccessibility: true, handler)
    }

    @discardableResult
    func subscribeInputMonitoring(_ handler: @escaping (Bool) -> Void) -> Subscription {
        subscribe(needsAccessibility: false, handler)
    }

    private func subscribe(needsAccessibility: Bool, _ handler: @escaping (Bool) -> Void) -> Subscription {
        let token = UUID()
        lock.lock()
        subscribers[token] = Subscriber(needsAccessibility: needsAccessibility, handler: handler)
        let subscriberCount = subscribers.count
        let shouldStart: Bool
        if case .idle = taskState {
            generation &+= 1
            taskState = .starting
            shouldStart = true
        } else {
            shouldStart = false
        }
        let currentGeneration = generation
        lock.unlock()
        if shouldStart { startPolling(generation: currentGeneration) }
        logger("RUNTIME PERMISSION POLL phase=subscribed result=active " +
               "subscriber_count=\(subscriberCount) timer_started=\(shouldStart)")
        return Subscription(owner: self, token: token)
    }

    private func unsubscribe(_ token: UUID) {
        lock.lock()
        guard subscribers.removeValue(forKey: token) != nil else { lock.unlock(); return }
        let subscriberCount = subscribers.count
        var taskToCancel: HIDRemoteScheduledTask?
        if subscribers.isEmpty {
            if case .running(let task) = taskState { taskToCancel = task }
            taskState = .idle
        }
        lock.unlock()
        taskToCancel?.cancel()
        logger("RUNTIME PERMISSION POLL phase=unsubscribed " +
               "result=\(subscriberCount == 0 ? "stopped" : "active") " +
               "subscriber_count=\(subscriberCount) timer_stopped=\(taskToCancel != nil)")
    }

    private func startPolling(generation: UInt64) {
        let task = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.permissionPollMilliseconds
        ) { [weak self] in self?.poll(generation: generation) }
        lock.lock()
        let shouldCancel = subscribers.isEmpty || self.generation != generation
        if !shouldCancel { taskState = .running(task) }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    private func poll(generation: UInt64) {
        lock.lock()
        guard self.generation == generation, !subscribers.isEmpty, !queryInFlight else {
            lock.unlock()
            return
        }
        queryInFlight = true
        let tokens = Set(subscribers.keys)
        let needsAccessibility = subscribers.values.contains { $0.needsAccessibility }
        lock.unlock()
        permissionQuery(needsAccessibility) { [weak self] snapshot in
            self?.deliver(snapshot, tokens: tokens, generation: generation)
        }
    }

    private func deliver(_ snapshot: RuntimePermissionSnapshot, tokens: Set<UUID>, generation: UInt64) {
        lock.lock()
        queryInFlight = false
        let isCurrent = self.generation == generation
        lock.unlock()
        guard isCurrent else {
            logger("RUNTIME PERMISSION POLL phase=ignored reason=stale_generation generation=\(generation)")
            return
        }
        for token in tokens {
            lock.lock()
            guard self.generation == generation, var subscriber = subscribers[token] else {
                lock.unlock()
                continue
            }
            let value = subscriber.needsAccessibility ? snapshot.hidInputAvailable : snapshot.inputMonitoringGranted
            guard subscriber.lastValue != value else { lock.unlock(); continue }
            subscriber.lastValue = value
            subscribers[token] = subscriber
            lock.unlock()
            subscriber.handler(value)
        }
    }
}

typealias HIDPermissionPoll = RuntimePermissionPoll
