import Foundation

enum RemoteConnectionRecoveryStatus: String, Equatable {
    case waiting, recovering, ready, paused, cancelled
    case notFound = "not_found"

    var message: LocalizedMessage {
        LocalizedMessage("connection.history.status.\(rawValue)")
    }
}

/// The model retains one budget per device, independently of transport bridge replacement.
final class RemoteConnectionRecovery {
    static let automaticWindow: TimeInterval = 60
    static let manualWindow: TimeInterval = 30
    static let stableConnection: TimeInterval = 30
    static let manualCooldown: TimeInterval = 5
    static let discoveryWindow: TimeInterval = 20

    private(set) var status: RemoteConnectionRecoveryStatus = .waiting
    private(set) var deadline: TimeInterval?
    private(set) var attemptCount = 0
    private(set) var generation: UInt64 = 0
    private(set) var isManual = false
    private var automaticAttempts: [TimeInterval] = []
    private var readyAt: TimeInterval?
    private var lastManualCompletion: TimeInterval?
    private(set) var needsResume = false

    var isActive: Bool { status == .recovering }
    var presentationStatus: RemoteConnectionRecoveryStatus { needsResume ? .waiting : status }
    var manualAvailableAt: TimeInterval? { lastManualCompletion.map { $0 + Self.manualCooldown } }

    func begin(manual: Bool, at now: TimeInterval) -> Bool {
        guard !isActive, status != .ready else { return false }
        if manual {
            guard lastManualCompletion.map({ now - $0 >= Self.manualCooldown }) ?? true else {
                return false
            }
        } else {
            guard status == .waiting else { return false }
        }
        isManual = manual
        attemptCount = 0
        generation &+= 1
        deadline = now + (manual ? Self.manualWindow : Self.automaticWindow)
        status = .recovering
        return true
    }

    func claimAttempt(at now: TimeInterval) -> Bool {
        guard isActive else { return false }
        automaticAttempts.removeAll { now - $0 >= 600 }
        guard let deadline, now < deadline,
              attemptCount < (isManual ? 1 : 3),
              isManual || automaticAttempts.count < 6
        else {
            finish(at: now)
            return false
        }
        attemptCount += 1
        if !isManual { automaticAttempts.append(now) }
        return true
    }

    func retryDelay(at now: TimeInterval) -> TimeInterval? {
        guard isActive else { return nil }
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
    func disconnected(at now: TimeInterval) {
        guard status == .ready else { return }
        needsResume = false
        if let readyAt, now - readyAt >= Self.stableConnection {
            status = .waiting
            _ = begin(manual: false, at: now)
        } else {
            status = .recovering
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
        disconnected(at: now)
    }

    func finish(at now: TimeInterval, cancelled: Bool = false) {
        guard isActive else { return }
        if isManual { lastManualCompletion = now }
        status = cancelled ? .cancelled : isManual ? .notFound : .paused
    }
}
