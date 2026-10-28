import Foundation

/// A single fast retry for an established link; repeated losses must still back off.
/// Uses monotonic time and does not reset on READY, preventing reconnect storms.
struct BluetoothActiveLinkRecovery {
    static let retryDelay: TimeInterval = 0.1
    static let minimumInterval: TimeInterval = 30
    private(set) var lastRetryUptime: TimeInterval?

    mutating func retryDelayIfAllowed(
        enabledForTarget: Bool,
        wasReady: Bool,
        shouldRun: Bool,
        systemSuspended: Bool,
        requestedDisconnect: Bool,
        uptime: TimeInterval
    ) -> TimeInterval? {
        guard enabledForTarget, wasReady, shouldRun, !systemSuspended,
              !requestedDisconnect else { return nil }
        if let lastRetryUptime, uptime - lastRetryUptime < Self.minimumInterval { return nil }
        lastRetryUptime = uptime
        return Self.retryDelay
    }

    mutating func reset() { lastRetryUptime = nil }
}
