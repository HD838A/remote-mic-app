import Foundation
import Security
import Testing
@testable import RemoteMic

@Suite("Early Access credential store")
struct EarlyAccessCredentialStoreTests {
    @Test func createsStableAnonymousIdentityAndAtomicallyStoresGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicEarlyAccessTests-\(UUID().uuidString)", isDirectory: true)
        let keychainURL = directory.appendingPathComponent("test.keychain-db")
        let store = EarlyAccessCredentialStore(applicationKeychainURL: keychainURL)
        defer {
            var keychain: SecKeychain?
            if SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain {
                SecKeychainDelete(keychain)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(try store.loadDeviceID() == nil)
        let firstID = try store.createDeviceIDIfNeeded()
        #expect(firstID.count >= 32)
        #expect(try store.createDeviceIDIfNeeded() == firstID)

        let bundle = EarlyAccessGrantBundle(
            grantID: "gr_12345678901234567890",
            refreshCredential: String(repeating: "r", count: 43),
            entitlement: "header.payload.signature",
            subject: String(repeating: "a", count: 64),
            serverTime: Date(timeIntervalSince1970: 10_000),
            processUptime: 500
        )
        try store.saveGrantBundle(bundle)
        #expect(try store.loadGrantBundle() == bundle)
        try store.deleteGrantBundle()
        #expect(try store.loadGrantBundle() == nil)
        #expect(try store.loadDeviceID() == firstID)
        try store.deleteAll()
        #expect(try store.loadDeviceID() == nil)
    }
}
