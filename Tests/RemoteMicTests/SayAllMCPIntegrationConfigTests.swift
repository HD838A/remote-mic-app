import Foundation
@testable import SayAllMCPKit
import Testing

@Suite("SayAll MCP integration configuration")
struct SayAllMCPIntegrationConfigTests {
    @Test func generatesStandardJSONAndCodexTOMLForTheBundledHelper() throws {
        let authorization = SayAllMCPCreatedAuthorization(
            clientId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Codex",
            scope: "transcripts.read.all",
            token: "test-token-that-is-long-enough-for-the-helper",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let helper = URL(fileURLWithPath: "/Applications/Remote Mic.app/Contents/Helpers/SayAllMCP")
        let configuration = try SayAllMCPIntegrationConfig(
            authorization: authorization,
            helperExecutableURL: helper
        )

        #expect(configuration.command == helper.path)
        #expect(configuration.arguments == ["serve"])
        #expect(configuration.standardJSON.contains("sayall_history"))
        #expect(configuration.standardJSON.contains("SAYALL_MCP_CLIENT_ID"))
        #expect(configuration.standardJSON.contains(authorization.token))
        #expect(configuration.codexTOML.contains("[mcp_servers.sayall_history]"))
        #expect(configuration.codexTOML.contains("SAYALL_MCP_ACCESS_TOKEN"))
    }

    @Test func bundledHelperOnlyExposesTheServeEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SayAllMCP/main.swift"),
            encoding: .utf8
        )

        #expect(source.contains("arguments == [\"serve\"]"))
        #expect(!source.contains("case \"setup\""))
        #expect(!source.contains("case \"enable\""))
        #expect(!source.contains("case \"authorize\""))
        #expect(source.contains("\"version\": \"1.0.0\""))
    }
}
