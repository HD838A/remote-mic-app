import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth wake recovery pending state")
struct BluetoothWakeRecoveryPendingTests {
    private func bridgeAppModelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
    }

    /// macOS delivers `systemDidWake` while the display can still be asleep, so
    /// the resume path is still suspended by `screenSleeping` and returns before
    /// Bluetooth recovery. The intent to recover therefore has to outlive the
    /// wake event itself.
    @Test func systemSleepArmsRecoveryUntilTheAppIsNoLongerSuspended() {
        #expect(BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .systemWillSleep,
            current: false
        ))
        #expect(BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .screenDidWake,
            current: true
        ))
    }

    /// A wake without an observed `systemWillSleep` still invalidates the
    /// CoreBluetooth connection cycle, so it arms recovery on its own.
    @Test func systemWakeArmsRecoveryEvenWithoutAnObservedSleep() {
        #expect(BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .systemDidWake,
            current: false
        ))
    }

    /// Display-only sleep/wake cycles happen constantly while the machine stays
    /// awake. They must not restart the Bluetooth connection cycle.
    @Test func displayOnlyWakeDoesNotArmRecovery() {
        #expect(!BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .screenDidWake,
            current: false
        ))
        #expect(!BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .screenDidSleep,
            current: false
        ))
        #expect(!BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .sessionDidBecomeActive,
            current: false
        ))
    }

    @Test func recoveryRunsOnlyWhileArmedAndStarted() {
        #expect(BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: true,
            started: true,
            readyBridgeCount: 0
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: false,
            started: true,
            readyBridgeCount: 0
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: true,
            started: false,
            readyBridgeCount: 0
        ))
    }

    /// A short sleep can end with CoreBluetooth reconnecting on its own before
    /// the resume path runs. Forcing a reconnect then tears down a healthy
    /// bridge — observed on real hardware as `recovery_begin ready_bridges=1`
    /// followed by an immediate scan/connect cycle. Nothing needs recovering
    /// when every bridge already came back.
    @Test func alreadyRecoveredBridgesAreNotForcedToReconnect() {
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: true,
            started: true,
            readyBridgeCount: 1
        ))
    }

    /// Regression guard for the observed failure: recovery must be driven by the
    /// armed flag on the resume path, and the flag must be cleared once it runs,
    /// so a later display wake does not reconnect again.
    @Test func resumePathDrivesRecoveryFromTheArmedFlag() throws {
        let source = try bridgeAppModelSource()
        #expect(source.contains("BluetoothWakeRecoveryPolicy.pendingRecovery"))
        #expect(source.contains("pendingRecovery: bluetoothWakeRecoveryPending"))
        #expect(source.contains("bluetoothWakeRecoveryPending = false"))
    }
}
