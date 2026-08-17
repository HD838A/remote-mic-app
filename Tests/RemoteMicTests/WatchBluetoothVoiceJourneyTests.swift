import Foundation
import Testing
@testable import SayAllMacRemoteCore
@testable import RemoteMic

@Suite("Apple Watch BLE voice journey")
struct WatchBluetoothVoiceJourneyTests {
    @Test func firstVoiceAttemptWaitsForMacPreparationBeforeVoiceReady() throws {
        let server = WatchBluetoothRemoteServer()
        var macVoicePrepared = false
        server.onVoiceStartResult = { completion in
            macVoicePrepared = true
            completion(.started)
        }
        server._testConfigureSession(approved: true, voiceActive: false)

        server._testHandleMessage(WatchBluetoothMessage(type: "voiceStart"))

        #expect(macVoicePrepared)
        #expect(server._testSessionState().voiceActive)
        #expect(server._testPendingNotifications().map(\.type) == ["voiceReady"])

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        #expect(bridgeSource.contains(
            "completion(self?.startPhoneVoice(source: .nearbyWatch) ?? .unavailable)"
        ))
    }
}
