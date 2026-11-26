import Foundation

enum RemoteConnectionRecoveryStatus: String, Equatable {
    case waiting, recovering, ready, paused, cancelled
    case notFound = "not_found"

    var message: LocalizedMessage {
        LocalizedMessage("connection.history.status.\(rawValue)")
    }
}

/// Why a bounded recovery episode started.
///
/// Only `.automatic` is a connection-failure retry and spends the rolling
/// failure budget. `.systemWake`, `.voiceKey` and `.devicePresence` are
/// lifecycle/user intent or a real device observation: they may start one
/// bounded episode even after an automatic failure budget is exhausted, but
/// they never create a background retry loop.
enum RemoteConnectionRecoveryTrigger: String, Equatable {
    case automatic
    case systemWake = "system_wake"
    case voiceKey = "voice_key"
    /// The system reconnected this remote's HID link, so the device is reachable.
    case devicePresence = "device_presence"
    case manual

    var countsAgainstFailureBudget: Bool { self == .automatic }
}

enum RemoteConnectionRecoveryAdmission: Equatable {
    case started
    case alreadyActive
    case ready
    case paused
    case cooldown
    case notWaiting

    var logName: String {
        switch self {
        case .started: return "started"
        case .alreadyActive: return "already_active"
        case .ready: return "ready"
        case .paused: return "budget_paused"
        case .cooldown: return "cooldown"
        case .notWaiting: return "not_waiting"
        }
    }
}

/// The model retains one budget per device, independently of transport bridge replacement.
final class RemoteConnectionRecovery {
    static let automaticWindow: TimeInterval = 60
    static let manualWindow: TimeInterval = 30
    static let stableConnection: TimeInterval = 30
    static let manualCooldown: TimeInterval = 5
    /// HID links can flap; one presence-driven handshake per 30 s at most.
    static let presenceCooldown: TimeInterval = 30
    static let discoveryWindow: TimeInterval = 20

    private(set) var status: RemoteConnectionRecoveryStatus = .waiting
    private(set) var deadline: TimeInterval?
    private(set) var attemptCount = 0
    private(set) var generation: UInt64 = 0
    private(set) var isManual = false
    private(set) var activeTrigger: RemoteConnectionRecoveryTrigger?
    private(set) var lastTerminalTrigger: RemoteConnectionRecoveryTrigger?
    private var automaticAttempts: [TimeInterval] = []
    private var lastVoiceKeyAttemptAt: TimeInterval?
    private var lastPresenceAttemptAt: TimeInterval?
    private var readyAt: TimeInterval?
    private var lastManualCompletion: TimeInterval?
    private(set) var needsResume = false

    var isActive: Bool { status == .recovering }
    /// Automatic attempts still remembered by the rolling failure window (diagnostics only).
    var automaticAttemptHistoryCount: Int { automaticAttempts.count }
    var presentationStatus: RemoteConnectionRecoveryStatus { needsResume ? .waiting : status }
    var manualAvailableAt: TimeInterval? { lastManualCompletion.map { $0 + Self.manualCooldown } }

    func begin(
        trigger: RemoteConnectionRecoveryTrigger,
        at now: TimeInterval
    ) -> RemoteConnectionRecoveryAdmission {
        guard !isActive else { return .alreadyActive }
        guard status != .ready else { return .ready }
        switch trigger {
        case .automatic:
            // Background recovery only starts from an idle budget. Once the
            // rolling failure budget is exhausted it stays paused until an
            // explicit user/system intent or a new device observation.
            guard status == .waiting else {
                return status == .paused ? .paused : .notWaiting
            }
        case .manual:
            guard lastManualCompletion.map({ now - $0 >= Self.manualCooldown }) ?? true else {
                return .cooldown
            }
        case .voiceKey:
            guard lastVoiceKeyAttemptAt.map({ now - $0 >= Self.manualCooldown }) ?? true else {
                return .cooldown
            }
            lastVoiceKeyAttemptAt = now
        case .devicePresence:
            // A user cancellation stays final; presence only lifts the
            // automatic pause or an earlier "not found" result.
            guard status != .cancelled else { return .notWaiting }
            guard lastPresenceAttemptAt.map({ now - $0 >= Self.presenceCooldown }) ?? true else {
                return .cooldown
            }
            lastPresenceAttemptAt = now
        case .systemWake:
            // Eligibility is decided by the bridge from "was Ready before
            // suspension" and "this wake already attempted". The failure
            // budget itself must not block a real system wake.
            break
        }
        activeTrigger = trigger
        lastTerminalTrigger = nil
        isManual = trigger == .manual
        attemptCount = 0
        generation &+= 1
        deadline = now + (trigger.countsAgainstFailureBudget ? Self.automaticWindow : Self.manualWindow)
        status = .recovering
        return .started
    }

    @discardableResult
    func begin(manual: Bool, at now: TimeInterval) -> Bool {
        begin(trigger: manual ? .manual : .automatic, at: now) == .started
    }

    func claimAttempt(at now: TimeInterval) -> Bool {
        guard isActive, let trigger = activeTrigger else { return false }
        guard let deadline, now < deadline else {
            finish(at: now)
            return false
        }
        switch trigger {
        case .automatic:
            automaticAttempts.removeAll { now - $0 >= 600 }
            guard attemptCount < 3, automaticAttempts.count < 6 else {
                finish(at: now)
                return false
            }
            attemptCount += 1
            automaticAttempts.append(now)
            return true
        case .manual, .systemWake, .voiceKey, .devicePresence:
            // Assisted episodes are one shot. If the one attempt fails, the
            // device stays paused until the next explicit trigger.
            guard attemptCount < 1 else {
                finish(at: now)
                return false
            }
            attemptCount += 1
            return true
        }
    }

    func retryDelay(at now: TimeInterval) -> TimeInterval? {
        guard isActive else { return nil }
        guard activeTrigger == .automatic else {
            finish(at: now)
            return nil
        }
        let delay: TimeInterval = attemptCount == 1 ? 3 : 10
        guard !isManual, attemptCount < 3, automaticAttempts.count < 6,
              let deadline, now + delay < deadline
        else {
            finish(at: now)
            return nil
        }
        return delay
    }

    @discardableResult
    func connected(at now: TimeInterval) -> Bool {
        guard isActive, let deadline, now < deadline else {
            finish(at: now)
            return false
        }
        if isManual { lastManualCompletion = now }
        readyAt = now
        needsResume = false
        status = .ready
        return true
    }

    /// Brief Ready must continue the original episode, rather than mint a fresh budget.
    func disconnected(
        at now: TimeInterval,
        trigger: RemoteConnectionRecoveryTrigger = .automatic
    ) {
        guard status == .ready else { return }
        needsResume = false
        if let readyAt, now - readyAt >= Self.stableConnection {
            status = .waiting
            _ = begin(trigger: trigger, at: now)
        } else {
            status = .recovering
            // A brief Ready keeps the existing episode. Assisted episodes still
            // only get their one attempt; automatic flaps stay charged to the
            // rolling failure budget.
            if trigger != .automatic {
                activeTrigger = trigger
            }
        }
        readyAt = nil
    }

    func interrupted(suspended: Bool, at now: TimeInterval) {
        guard status == .ready else { return }
        if suspended { needsResume = true }
        else { disconnected(at: now) }
    }

    func resume(at now: TimeInterval) {
        guard needsResume else { return }
        needsResume = false
        clearFailureHistoryIfStable(at: now)
        disconnected(at: now)
    }

    /// Resume after a real system sleep. The wake is a lifecycle event, not a
    /// failed handshake, so it starts an assisted one-shot episode even if the
    /// previous automatic failure budget was exhausted.
    func resume(trigger: RemoteConnectionRecoveryTrigger, at now: TimeInterval) {
        guard needsResume else { return }
        needsResume = false
        clearFailureHistoryIfStable(at: now)
        readyAt = nil
        status = .waiting
        _ = begin(trigger: trigger, at: now)
    }

    /// A stable link that only dropped because the Mac slept is not a device
    /// flap. `systemUptime` stops during sleep, so earlier wake reconnects would
    /// otherwise pile up inside one rolling window across hours of wall time.
    private func clearFailureHistoryIfStable(at now: TimeInterval) {
        guard let readyAt, now - readyAt >= Self.stableConnection else { return }
        automaticAttempts.removeAll()
    }

    /// A wake can arrive while the bridge is still marked Ready. Start a fresh
    /// assisted episode instead of applying the brief-Ready flap rule, which
    /// would otherwise leave no deadline or attempt for the wake.
    func forceAssistedEpisode(
        trigger: RemoteConnectionRecoveryTrigger,
        at now: TimeInterval
    ) {
        guard trigger != .automatic else { return }
        readyAt = nil
        needsResume = false
        status = .waiting
        _ = begin(trigger: trigger, at: now)
    }

    func finish(at now: TimeInterval, cancelled: Bool = false) {
        guard isActive else { return }
        if isManual { lastManualCompletion = now }
        lastTerminalTrigger = activeTrigger
        status = cancelled ? .cancelled : isManual ? .notFound : .paused
        activeTrigger = nil
    }
}
