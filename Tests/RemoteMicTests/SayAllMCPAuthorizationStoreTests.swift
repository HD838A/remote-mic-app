import Foundation
@testable import SayAllMCPKit
import Testing

@Suite("SayAll MCP authorization")
struct SayAllMCPAuthorizationStoreTests {
    @Test func accessDefaultsOffAndStoresOnlyTokenHash() throws {
        let root = temporaryDirectory("authorization-default")
        let store = SayAllMCPAuthorizationStore(accessRoot: root)

        #expect(try !store.isEnabled())
        #expect(throws: SayAllMCPAccessDeniedError.self) {
            try store.createAuthorization(displayName: "Codex")
        }

        try store.setEnabled(true)
        let created = try store.createAuthorization(displayName: "Codex")
        let restored = try #require(store.listAuthorizations().first)
        #expect(restored.clientId == created.clientId)
        #expect(restored.displayName == "Codex")
        #expect(restored.tokenHash.count == 64)
        #expect(restored.tokenHash != created.token)
        #expect(
            try store.requireAuthorized(
                clientId: created.clientId.uuidString,
                token: created.token
            ).clientId == created.clientId
        )

        let eventFile = root.appendingPathComponent("authorizations.ndjson")
        let rawEvents = try String(contentsOf: eventFile, encoding: .utf8)
        #expect(!rawEvents.contains(created.token))
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: eventFile.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test func revocationAndGlobalDisableApplyToExistingCredentials() throws {
        let store = SayAllMCPAuthorizationStore(
            accessRoot: temporaryDirectory("authorization-revoke")
        )
        try store.setEnabled(true)
        let first = try store.createAuthorization(displayName: "Codex")
        let second = try store.createAuthorization(displayName: "Claude Desktop")

        try store.revokeAuthorization(clientId: first.clientId)
        #expect(throws: SayAllMCPAccessDeniedError.self) {
            try store.requireAuthorized(clientId: first.clientId.uuidString, token: first.token)
        }
        #expect(
            try store.requireAuthorized(
                clientId: second.clientId.uuidString,
                token: second.token
            ).clientId == second.clientId
        )

        try store.setEnabled(false)
        #expect(throws: SayAllMCPAccessDeniedError.self) {
            try store.requireAuthorized(clientId: second.clientId.uuidString, token: second.token)
        }
        #expect(try store.listAuthorizations().count == 2)
    }

    @Test func readsFractionalISOEventsProducedByTheNodeRepository() throws {
        let root = temporaryDirectory("authorization-node-compatibility")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let clientId = UUID()
        let tokenHash = String(repeating: "a", count: 64)
        let content = """
        {"schemaVersion":1,"type":"access_changed","enabled":true,"changedAt":"2026-08-18T01:02:03.456Z"}
        """
        try Data((content + "\n").utf8).write(to: root.appendingPathComponent("settings.ndjson"))
        let authorization = """
        {"schemaVersion":1,"type":"authorization_created","clientId":"\(clientId.uuidString.lowercased())","displayName":"Codex","scope":"transcripts.read.all","tokenHash":"\(tokenHash)","createdAt":"2026-08-18T01:02:03.456Z"}
        """
        try Data((authorization + "\n").utf8).write(
            to: root.appendingPathComponent("authorizations.ndjson")
        )

        let store = SayAllMCPAuthorizationStore(accessRoot: root)
        #expect(try store.isEnabled())
        #expect(try store.listAuthorizations().first?.clientId == clientId)
    }

    @Test func privateEventFilesRejectSymbolicLinks() throws {
        let root = temporaryDirectory("authorization-symbolic-link")
        let target = temporaryDirectory("authorization-symbolic-link-target")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let targetFile = target.appendingPathComponent("events.ndjson")
        _ = FileManager.default.createFile(atPath: targetFile.path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("settings.ndjson"),
            withDestinationURL: targetFile
        )

        let store = SayAllMCPAuthorizationStore(accessRoot: root)
        #expect(throws: POSIXError.self) {
            try store.setEnabled(true)
        }
        #expect(try Data(contentsOf: targetFile).isEmpty)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sayall-mcp-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
