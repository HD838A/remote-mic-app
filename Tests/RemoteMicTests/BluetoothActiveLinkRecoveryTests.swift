import Foundation
import Testing
@testable import RemoteMic

struct BluetoothActiveLinkRecoveryTests {
    @Test func establishedLinkGetsOneFastRetryButRepeatedLossesBackOff() {
        var policy = BluetoothActiveLinkRecovery()
        func delay(_ time: TimeInterval) -> TimeInterval? {
            policy.retryDelayIfAllowed(enabledForTarget: true, wasReady: true,
                shouldRun: true, systemSuspended: false, requestedDisconnect: false, uptime: time)
        }
        let first = delay(100)
        let repeated = delay(101)
        let beforeWindow = delay(129.9)
        let next = delay(130)
        #expect(first == 0.1)
        #expect(repeated == nil)
        #expect(beforeWindow == nil)
        #expect(next == 0.1)
    }

    @Test func sleepManualReconnectAndFailedInitializationNeverFastRetry() {
        for condition in 0..<5 {
            var policy = BluetoothActiveLinkRecovery()
            let delay = policy.retryDelayIfAllowed(
                enabledForTarget: condition != 0, wasReady: condition != 1,
                shouldRun: condition != 2, systemSuspended: condition == 3,
                requestedDisconnect: condition == 4, uptime: 100)
            #expect(delay == nil)
            #expect(policy.lastRetryUptime == nil)
        }
    }

    @Test func stopResetsCooldownWithoutPersistingIt() {
        var policy = BluetoothActiveLinkRecovery()
        _ = policy.retryDelayIfAllowed(enabledForTarget: true, wasReady: true,
            shouldRun: true, systemSuspended: false, requestedDisconnect: false, uptime: 100)
        policy.reset()
        #expect(policy.lastRetryUptime == nil)
    }
}
