import Foundation
import Testing
@testable import RemoteMic

@Suite("Phone remote server")
struct PhoneRemoteServerTests {
    @Test func authenticatedReconnectSafelyReplacesStaleSession() {
        #expect(PhoneRemoteServer.shouldReplaceExistingClient(
            existingIsApproved: false,
            newIsApproved: false
        ))
        #expect(!PhoneRemoteServer.shouldReplaceExistingClient(
            existingIsApproved: true,
            newIsApproved: false
        ))
        #expect(PhoneRemoteServer.shouldReplaceExistingClient(
            existingIsApproved: true,
            newIsApproved: true
        ))
    }

    @Test func buttonEventCapabilityAndPhaseRoundTrip() throws {
        let original = PhoneRemoteWireMessage(
            type: "buttonEvent",
            command: RemoteButton.power.rawValue,
            capabilities: [PhoneRemoteWireMessage.buttonEventsCapability],
            buttonPhase: RemoteButtonPhase.press.rawValue
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneRemoteWireMessage.self, from: data)

        #expect(decoded.type == "buttonEvent")
        #expect(decoded.command == RemoteButton.power.rawValue)
        #expect(decoded.capabilities == [PhoneRemoteWireMessage.buttonEventsCapability])
        #expect(decoded.buttonPhase == RemoteButtonPhase.press.rawValue)
    }
}
