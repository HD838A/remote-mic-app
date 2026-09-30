import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

/// A device profile is what draws a card in the connection page, and nothing in the app can
/// delete one. So the question these tests pin is not "is a profile created" but "what does a
/// peripheral have to prove before one is created for it".
///
/// The reported symptom: two cards, the real remote plus a permanent "小米遥控器" with no model
/// and no battery. The runtime log showed the second one was a peripheral advertising the
/// generic name `MI RC` — on the app's name whitelist — that connected, answered reads, and
/// disconnected without ever completing the ATVV handshake.
@Suite("Remote device profile persistence")
struct RemoteProfilePersistenceTests {
    private struct Scope {
        let settings: AppSettings
        let defaults: UserDefaults
        let name: String

        func tearDown() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private static func scopedSettings(_ label: String) throws -> Scope {
        let name = "RemoteProfilePersistenceTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return Scope(settings: AppSettings(defaults: defaults), defaults: defaults, name: name)
    }

    /// A bridge whose `deviceIdentifier` is known without CoreBluetooth: with no peripheral
    /// attached it reports its target identifier, which is what the model keys profiles by.
    @MainActor
    private static func bridge(
        _ identifier: UUID,
        settings: AppSettings,
        delegate: BridgeAppModel
    ) -> XiaomiBluetoothBridge {
        XiaomiBluetoothBridge(settings: settings, delegate: delegate, targetIdentifier: identifier)
    }

    /// The regression test for the reported defect.
    ///
    /// The first profile slot has to be occupied first, because `registerBluetoothRemote` adopts
    /// an unbound slot rather than appending to it — with a virgin settings store the ghost would
    /// silently take over the migrated profile instead of adding a card, and the count would not
    /// move either way.
    ///
    /// Before the fix, the battery read alone persisted a second profile, and the model read gave
    /// it the `unknown` fallback name the user saw.
    @MainActor
    @Test func aPeripheralThatNeverCompletesTheHandshakeLeavesNoDeviceProfileBehind() throws {
        let scope = try Self.scopedSettings("ghost")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let realRemote = UUID()
        let strayAdvertiser = UUID()

        settings.registerBluetoothRemote(identifier: realRemote)
        #expect(settings.remoteDeviceProfiles.count == 1)

        // The stray peripheral gets as far as answering every read the app issues on connect,
        // then goes away. `MI RC` is on the name whitelist, so the discovery bridge does connect.
        let stray = Self.bridge(strayAdvertiser, settings: settings, delegate: model)
        model.bluetoothBridge(stray, didUpdateBatteryLevel: 73)
        model.bluetoothBridge(stray, didUpdatePowerState: .onBattery)
        model.bluetoothBridge(stray, didIdentifyRemoteModel: .rc001)
        model.bluetoothBridge(stray, didChange: .failed(LocalizedMessage("test.stray_gone")))

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.profileID(forBluetoothIdentifier: strayAdvertiser) == nil)
    }

    /// The positive control, without which the fix could be "never register anything".
    ///
    /// Same reads in the same order as the real remote produces on connect — the runtime log has
    /// battery and model both landing before `BLE READY` — followed by the handshake completing.
    /// The profile has to appear, and it has to carry the readings that arrived before it
    /// existed, or a first-ever remote would sit on "—" and the `unknown` fallback name until it
    /// happened to notify again.
    @MainActor
    @Test func aRemoteThatCompletesTheHandshakeKeepsTheReadingsThatArrivedFirst() throws {
        let scope = try Self.scopedSettings("ready")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let firstRemote = UUID()
        let secondRemote = UUID()

        settings.registerBluetoothRemote(identifier: firstRemote)
        #expect(settings.remoteDeviceProfiles.count == 1)

        let remote = Self.bridge(secondRemote, settings: settings, delegate: model)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: 73)
        model.bluetoothBridge(remote, didUpdatePowerState: .charging)
        model.bluetoothBridge(remote, didIdentifyRemoteModel: .rc003)

        // Nothing is persisted yet: the handshake is what earns a card.
        #expect(settings.remoteDeviceProfiles.count == 1)

        model.bluetoothBridge(remote, didChange: .ready("小米蓝牙语音遥控器"))

        let profileID = try #require(settings.profileID(forBluetoothIdentifier: secondRemote))
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(model.batteryLevel(for: profileID) == 73)
        #expect(model.powerState(for: profileID) == .charging)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == profileID })?.model == .rc003)
    }

    /// Buffering the readings creates a way for them to go stale, which this pins shut.
    ///
    /// A peripheral answers its reads, fails the handshake, and only succeeds much later — by
    /// which time the buffered battery level describes a battery that has since been used. The
    /// card must start empty and wait for the new connection's own reads rather than inherit the
    /// abandoned attempt's.
    @MainActor
    @Test func readingsFromAnAbandonedAttemptAreNotReplayedOntoALaterConnection() throws {
        let scope = try Self.scopedSettings("stale")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let firstRemote = UUID()
        let lateRemote = UUID()

        settings.registerBluetoothRemote(identifier: firstRemote)

        let remote = Self.bridge(lateRemote, settings: settings, delegate: model)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: 4)
        model.bluetoothBridge(remote, didUpdatePowerState: .onBattery)
        model.bluetoothBridge(remote, didIdentifyRemoteModel: .rc001)
        model.bluetoothBridge(remote, didChange: .failed(LocalizedMessage("test.init_failed")))

        model.bluetoothBridge(remote, didChange: .ready("小米蓝牙语音遥控器"))

        let profileID = try #require(settings.profileID(forBluetoothIdentifier: lateRemote))
        #expect(model.batteryLevel(for: profileID) == nil)
        #expect(model.powerState(for: profileID) == nil)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == profileID })?.model == .unknown)
    }

    /// A failed read reports `nil`, and that has to invalidate the buffered value rather than
    /// leave the last successful one to be replayed as if it were current.
    @MainActor
    @Test func aFailedReadInvalidatesTheBufferedValue() throws {
        let scope = try Self.scopedSettings("invalidate")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let firstRemote = UUID()
        let secondRemote = UUID()

        settings.registerBluetoothRemote(identifier: firstRemote)

        let remote = Self.bridge(secondRemote, settings: settings, delegate: model)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: 73)
        model.bluetoothBridge(remote, didUpdatePowerState: .charging)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: nil)
        model.bluetoothBridge(remote, didUpdatePowerState: nil)

        model.bluetoothBridge(remote, didChange: .ready("小米蓝牙语音遥控器"))

        let profileID = try #require(settings.profileID(forBluetoothIdentifier: secondRemote))
        #expect(model.batteryLevel(for: profileID) == nil)
        #expect(model.powerState(for: profileID) == nil)
    }
}
