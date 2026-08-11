import Foundation
import Security
import Testing
@testable import RemoteMic

@Suite("DeepSeek credential store")
struct DeepSeekCredentialStoreTests {
    @Test func maskedPreviewShowsOnlyTheFirstAndLastFourCharacters() {
        #expect(
            DeepSeekCredentialStore.maskedPreview(for: "demo1234567890tail")
                == "demo••••tail"
        )
        #expect(DeepSeekCredentialStore.maskedPreview(for: "short") == "•••••")
    }

    @Test func savesLoadsAndDeletesUsingAnApplicationSpecificKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicCredentialTests-\(UUID().uuidString)")
        let keychainURL = directory.appendingPathComponent("RemoteMic.keychain-db")
        let store = DeepSeekCredentialStore(applicationKeychainURL: keychainURL)
        defer {
            var keychain: SecKeychain?
            if SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess,
               let keychain {
                SecKeychainDelete(keychain)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        try store.saveAPIKey("demo1234567890tail")
        #expect(try store.loadAPIKey() == "demo1234567890tail")
        try store.deleteAPIKey()
        #expect(try store.loadAPIKey() == nil)
    }
}
