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
}
