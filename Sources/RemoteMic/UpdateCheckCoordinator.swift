import Foundation

/// Coalesces checks before feed resolution and keeps manual requests independent of the information cache.
struct UpdateCheckCoordinator {
    enum Purpose { case information, userInitiated }
    enum Decision { case start, cached, coalesced }

    private var activePurpose: Purpose?
    private var activeGeneration: Int?
    private var generation = 0
    private var pendingUserCheck = false
    private var successfulCheckAt: Date?
    private static let informationLifetime: TimeInterval = 6 * 60 * 60

    mutating func request(
        _ purpose: Purpose,
        sessionInProgress: Bool,
        now: Date = Date()
    ) -> Decision {
        if activePurpose != nil || sessionInProgress {
            if purpose == .userInitiated, activePurpose != .userInitiated {
                pendingUserCheck = true
            }
            return .coalesced
        }
        if purpose == .information, let successfulCheckAt {
            let age = now.timeIntervalSince(successfulCheckAt)
            if age >= 0, age < Self.informationLifetime { return .cached }
        }
        activePurpose = purpose
        activeGeneration = generation
        return .start
    }

    /// A channel change invalidates the cache. An old Sparkle callback cannot make it fresh again.
    mutating func invalidate(cancelPreparation: Bool) {
        generation += 1
        successfulCheckAt = nil
        if cancelPreparation {
            activePurpose = nil
            activeGeneration = nil
            pendingUserCheck = false
        }
    }

    /// Returns true when a manual request arrived during an information/background check.
    mutating func finish(success: Bool, now: Date = Date()) -> Bool {
        if success, activeGeneration == generation { successfulCheckAt = now }
        if !success { successfulCheckAt = nil }
        activePurpose = nil
        activeGeneration = nil
        let shouldCheckForUser = pendingUserCheck
        pendingUserCheck = false
        return shouldCheckForUser
    }
}
