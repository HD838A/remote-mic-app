import Foundation
import Testing
@testable import RemoteMic

@Suite("Diagnostic log encryption key")
struct DiagnosticLogKeyStoreTests {
    @Test func createsAndReusesAMacOSKeychainKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMic-KeyStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogKeyStore(
            service: "com.hd838a.RemoteMic.tests.\(UUID().uuidString)",
            account: "diagnostic-key",
            applicationKeychainURL: directory.appendingPathComponent("test.keychain-db")
        )
        defer { try? store.deleteKeyData() }

        let first = try store.loadOrCreateKeyData()
        let second = try store.loadOrCreateKeyData()

        #expect(first.count == 32)
        #expect(second == first)
    }
}
