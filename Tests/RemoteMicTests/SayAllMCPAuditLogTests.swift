import Foundation
@testable import SayAllMCPKit
import Testing

@Suite("SayAll MCP audit")
struct SayAllMCPAuditLogTests {
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
