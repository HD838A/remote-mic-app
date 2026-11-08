import Foundation
@testable import SayAllMCPKit
import Testing

@Suite("SayAll MCP audit")
struct SayAllMCPAuditLogTests {
    @Test func serviceAuditsOnlyAuthenticatedIdentityAndOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SayAllMCPPaths(
            transcriptRoot: root.appendingPathComponent("transcripts"),
            accessRoot: root.appendingPathComponent("access")
        )
        let store = SayAllMCPAuthorizationStore(paths: paths)
        try store.setEnabled(true)
        let authorization = try store.createAuthorization(displayName: "Audit regression")
        let untrusted = SayAllMCPService(paths: paths, clientId: "synthetic-client-canary", token: authorization.token)
        #expect(throws: SayAllMCPAccessDeniedError.self) {
            try untrusted.validateServerStart()
        }

        let service = SayAllMCPService(paths: paths, clientId: authorization.clientId.uuidString, token: authorization.token)
        try service.validateServerStart()
        #expect(throws: SayAllMCPHistoryError.self) {
            try service.query(.init(startedAtOrAfter: "synthetic-date-canary"))
        }
        _ = try service.query(.init(startedAtOrAfter: "2026-08-18T00:00:00.000Z"))

        let files = try FileManager.default.contentsOfDirectory(
            at: paths.accessRoot.appendingPathComponent("audit"),
            includingPropertiesForKeys: nil
        )
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let events = try contents.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        #expect(events.count == 4)
        #expect(events[0]?["clientId"] as? String == "unknown")
        #expect(events[0]?["reasonCode"] as? String == "invalid_credentials")
        #expect(events[1]?["clientId"] as? String == authorization.clientId.uuidString.lowercased())
        #expect(events[2]?["result"] as? String == "error")
        #expect(events[3]?["returnedRecordCount"] as? Int == 0)
        #expect(!contents.contains("synthetic-client-canary"))
        #expect(!contents.contains("synthetic-date-canary"))
        #expect(!contents.contains("startedAtOrAfter"))
        #expect(!contents.contains(authorization.token))
    }

    @Test func auditContainsMetadataButNeverTranscriptOrToken() throws {
        let accessRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayall-mcp-audit-\(UUID().uuidString)", isDirectory: true)
        let audit = SayAllMCPAuditLog(accessRoot: accessRoot)
        try audit.append(
            SayAllMCPAuditEvent(
                clientId: "11111111-2222-3333-4444-555555555555",
                tool: "query_transcripts",
                result: "allowed",
                returnedRecordCount: 2,
                startedAtOrAfter: "2026-08-18T00:00:00.000Z",
                bundleIdentifierCount: 1
            )
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: accessRoot.appendingPathComponent("audit", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let content = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(content.contains("query_transcripts"))
        #expect(content.contains("returnedRecordCount"))
        #expect(!content.contains("originalTranscript"))
        #expect(!content.contains("SAYALL_MCP_ACCESS_TOKEN"))
        #expect(!content.contains("secret test sentence"))
    }
}
