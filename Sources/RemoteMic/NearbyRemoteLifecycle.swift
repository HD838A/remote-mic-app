import Foundation

/// Keeps the user's connection intent separate from idle discovery resources.
final class NearbyRemoteLifecycle {
    private let lock = NSLock()
    private var running = false
    private var currentGeneration: UInt64 = 0
    private(set) var isSystemSleeping = false
    private let start: () -> Void
    private let stop: () -> Void
    private let log: (String) -> Void

    init(
        start: @escaping () -> Void,
        stop: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        self.start = start
        self.stop = stop
        self.log = log
    }

    var generation: UInt64 {
        lock.withLock { currentGeneration }
    }

    func acceptsEvents(generation: UInt64) -> Bool {
        lock.withLock { running && currentGeneration == generation }
    }

    func deliver(onIgnored: @escaping () -> Void = {}, _ action: @escaping () -> Void) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                onIgnored()
                return
            }
            guard self.acceptsEvents(generation: generation) else {
                self.log(
                    "NEARBY REMOTE callback generation=\(generation) phase=ignored " +
                        "result=ignored reason=stale_generation"
                )
                onIgnored()
                return
            }
            action()
        }
    }

    func handleSystemEvent(_ event: SystemAudioLifecycleEvent) {
        switch event {
        case .systemWillSleep:
            isSystemSleeping = true
        case .systemDidWake:
            isSystemSleeping = false
        default:
            break
        }
    }

    /// Called on the main thread. Callback ingress can read the generation from any queue.
    func update(enabled: Bool, keepAlive: Bool, reason: String) {
        let transition: (running: Bool, generation: UInt64)? = lock.withLock {
            // An established session, including pending audio drain, keeps its existing lifecycle.
            let shouldRun = enabled && (!isSystemSleeping || (running && keepAlive))
            guard shouldRun != running else { return nil }
            running = shouldRun
            currentGeneration &+= 1
            return (running, currentGeneration)
        }
        guard let transition else { return }
        let result = transition.running ? "start_requested" : "stop_requested"
        log(
            "NEARBY REMOTE lifecycle generation=\(transition.generation) phase=submitted " +
                "result=\(result) reason=\(reason) system_sleeping=\(isSystemSleeping)"
        )
        if transition.running {
            start()
        } else {
            stop()
        }
    }
}
