import Foundation

/// Keeps the user's connection intent separate from idle discovery resources.
final class NearbyRemoteLifecycle {
    private let lock = NSLock()
    private var running = false
    private var currentGeneration: UInt64 = 0
    private var needsWakeRestart = false
    private var wakeRestartsThisSleep = 0
    private let maxWakeRestartsPerSleep = 1
    private var systemSleeping = false
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

    var isSystemSleeping: Bool {
        lock.withLock { systemSleeping }
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
            lock.withLock {
                systemSleeping = true
                wakeRestartsThisSleep = 0
            }
        case .systemDidWake:
            lock.withLock { systemSleeping = false }
        default:
            break
        }
    }

    /// Called on the main thread. Callback ingress can read the generation from any queue.
    func update(enabled: Bool, hasActiveVoice: Bool, reason: String) {
        enum Transition {
            case none
            case start(generation: UInt64, systemSleeping: Bool)
            case stop(generation: UInt64, systemSleeping: Bool)
            case restart(stopGeneration: UInt64, attempt: Int)
        }

        let transition: Transition = lock.withLock {
            if systemSleeping {
                // Keep the service only while voice audio still needs to drain.
                // An idle connection is closed cleanly before sleep so the
                // client sees the disconnect instead of a silently dead socket.
                if enabled && running && hasActiveVoice {
                    needsWakeRestart = true
                    return .none
                }
                guard running else {
                    needsWakeRestart = false
                    return .none
                }
                running = false
                needsWakeRestart = false
                currentGeneration &+= 1
                return .stop(generation: currentGeneration, systemSleeping: true)
            }

            if needsWakeRestart {
                needsWakeRestart = false
                guard enabled else {
                    guard running else { return .none }
                    running = false
                    currentGeneration &+= 1
                    return .stop(generation: currentGeneration, systemSleeping: false)
                }
                // At most one automatic restart per sleep cycle. If the client
                // still does not reconnect, stay stopped instead of looping.
                guard wakeRestartsThisSleep < maxWakeRestartsPerSleep else {
                    guard running else { return .none }
                    running = false
                    currentGeneration &+= 1
                    return .stop(generation: currentGeneration, systemSleeping: false)
                }
                // A voice drain kept the listener alive across sleep. Its client
                // socket is likely dead; restart once so the phone/Watch
                // reconnects without leaving a false connected state.
                wakeRestartsThisSleep += 1
                let attempt = wakeRestartsThisSleep
                running = false
                currentGeneration &+= 1
                return .restart(stopGeneration: currentGeneration, attempt: attempt)
            }

            let shouldRun = enabled
            guard shouldRun != running else { return .none }
            running = shouldRun
            currentGeneration &+= 1
            return shouldRun
                ? .start(generation: currentGeneration, systemSleeping: false)
                : .stop(generation: currentGeneration, systemSleeping: false)
        }

        switch transition {
        case .none:
            return
        case let .start(generation, systemSleeping):
            log(
                "NEARBY REMOTE lifecycle generation=\(generation) phase=submitted " +
                    "result=start_requested reason=\(reason) " +
                    "system_sleeping=\(systemSleeping)"
            )
            start()
        case let .stop(generation, systemSleeping):
            log(
                "NEARBY REMOTE lifecycle generation=\(generation) phase=submitted " +
                    "result=stop_requested reason=\(reason) " +
                    "system_sleeping=\(systemSleeping)"
            )
            stop()
        case let .restart(stopGeneration, attempt):
            let attemptLimit = "\(attempt)/\(maxWakeRestartsPerSleep)"
            log(
                "NEARBY REMOTE lifecycle generation=\(stopGeneration) phase=submitted " +
                    "result=stop_requested reason=\(reason)_restart " +
                    "wake_restart_attempt=\(attemptLimit) system_sleeping=false"
            )
            stop()
            // Advance again after stop so late callbacks from the stopped server
            // cannot be accepted by the fresh listener.
            let startGeneration: UInt64 = lock.withLock {
                currentGeneration &+= 1
                running = true
                return currentGeneration
            }
            log(
                "NEARBY REMOTE lifecycle generation=\(startGeneration) phase=submitted " +
                    "result=start_requested reason=\(reason)_restart " +
                    "wake_restart_attempt=\(attemptLimit) system_sleeping=false"
            )
            start()
        }
    }
}
