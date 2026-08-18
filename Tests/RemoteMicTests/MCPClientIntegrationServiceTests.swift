import Foundation
@testable import RemoteMic
@testable import SayAllMCPKit
import Testing

@Suite("MCP client quick connections")
struct MCPClientIntegrationServiceTests {
    @Test func codexAddsAndUpdatesOnlyItsManagedBlock() throws {
        let home = temporaryDirectory("codex-managed")
        let file = home.appendingPathComponent(".codex/config.toml")
        try createParent(of: file)
        try Data("model = \"gpt-5\"\n".utf8).write(to: file)
        let service = makeService(home: home)

        try service.install(.codex, configuration: configuration(token: "first-token"))
        var text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("model = \"gpt-5\""))
        #expect(text.contains("BEGIN SAYALL MANAGED MCP"))
        #expect(text.contains("first-token"))

        try service.install(.codex, configuration: configuration(token: "second-token"))
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("first-token"))
        #expect(text.contains("second-token"))
        #expect(text.components(separatedBy: "BEGIN SAYALL MANAGED MCP").count == 2)
        #expect(try backupCount(nextTo: file) == 2)
        #expect(try permissions(of: file) == 0o600)

        try service.remove(.codex)
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("model = \"gpt-5\""))
        #expect(!text.contains("sayall_history"))
    }

    @Test func codexRefusesToOverwriteAnUnmanagedServer() throws {
        let home = temporaryDirectory("codex-conflict")
        let file = home.appendingPathComponent(".codex/config.toml")
        try createParent(of: file)
        try Data("[mcp_servers.sayall_history]\ncommand = \"custom\"\n".utf8).write(to: file)
        let service = makeService(home: home)

        #expect(throws: MCPClientIntegrationError.configurationConflict) {
            try service.install(.codex, configuration: configuration())
        }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("custom"))
        #expect(try backupCount(nextTo: file) == 0)
    }

    @Test func cursorMergesAndRemovesOnlySayAllServer() throws {
        let home = temporaryDirectory("cursor-merge")
        let file = home.appendingPathComponent(".cursor/mcp.json")
        try createParent(of: file)
        try Data(#"{"mcpServers":{"existing":{"command":"keep"}},"theme":"dark"}"#.utf8)
            .write(to: file)
        let service = makeService(home: home)

        try service.install(.cursor, configuration: configuration())
        var root = try json(at: file)
        var servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["existing"] != nil)
        #expect(servers["sayall_history"] != nil)
        #expect(root["theme"] as? String == "dark")

        try service.remove(.cursor)
        root = try json(at: file)
        servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["existing"] != nil)
        #expect(servers["sayall_history"] == nil)
    }

    @Test func cursorRejectsJSONCWithoutChangingIt() throws {
        let home = temporaryDirectory("cursor-jsonc")
        let file = home.appendingPathComponent(".cursor/mcp.json")
        try createParent(of: file)
        let original = "{\n  // keep this comment\n  \"mcpServers\": {}\n}\n"
        try Data(original.utf8).write(to: file)

        #expect(throws: MCPClientIntegrationError.invalidConfiguration) {
            try makeService(home: home).install(.cursor, configuration: configuration())
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func cursorRefusesToOverwriteAnExistingSameNameServer() throws {
        let home = temporaryDirectory("cursor-conflict")
        let file = home.appendingPathComponent(".cursor/mcp.json")
        try createParent(of: file)
        let original = #"{"mcpServers":{"sayall_history":{"command":"custom"}}}"#
        try Data(original.utf8).write(to: file)

        #expect(throws: MCPClientIntegrationError.configurationConflict) {
            try makeService(home: home).install(.cursor, configuration: configuration())
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func openCodeUsesTheDocumentedLocalServerShape() throws {
        let home = temporaryDirectory("opencode-merge")
        let file = home.appendingPathComponent(".config/opencode/opencode.json")
        let service = makeService(home: home)

        try service.install(.openCode, configuration: configuration())
        let root = try json(at: file)
        let servers = try #require(root["mcp"] as? [String: Any])
        let server = try #require(servers["sayall_history"] as? [String: Any])
        #expect(server["type"] as? String == "local")
        #expect(server["enabled"] as? Bool == true)
        #expect((server["command"] as? [String])?.last == "serve")
        #expect(server["environment"] as? [String: String] != nil)
    }

    @Test func claudeCodeUsesOfficialUserScopedCLIArguments() throws {
        let home = temporaryDirectory("claude-cli")
        let executable = home.appendingPathComponent("claude")
        var receivedArguments: [String] = []
        let service = MCPClientIntegrationService(
            homeDirectory: home,
            applicationURLProvider: { _ in nil },
            executableURLProvider: { $0 == "claude" ? executable : nil },
            commandRunner: { _, arguments in
                receivedArguments = arguments
                return 0
            }
        )

        try service.install(.claudeCode, configuration: configuration())
        #expect(receivedArguments.prefix(5) == [
            "mcp", "add-json", "--scope", "user", "sayall_history",
        ])
        #expect(receivedArguments.last?.contains("SAYALL_MCP_ACCESS_TOKEN") == true)

        try service.remove(.claudeCode)
        #expect(receivedArguments == [
            "mcp", "remove", "--scope", "user", "sayall_history",
        ])
    }

    @MainActor
    @Test func failedPreflightDoesNotCreateAnAuthorization() async throws {
        let home = temporaryDirectory("rollback")
        let accessRoot = home.appendingPathComponent("access")
        let helper = home.appendingPathComponent("SayAllMCP")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let store = SayAllMCPAuthorizationStore(accessRoot: accessRoot)
        let service = MCPClientIntegrationService(
            homeDirectory: home,
            applicationURLProvider: { _ in nil },
            executableURLProvider: { _ in home.appendingPathComponent("claude") },
            commandRunner: { _, _ in 1 }
        )
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: service,
            helperExecutableURL: { helper }
        )
        model.setEnabled(true)

        model.connect(.claudeCode)
        try await waitForIntegration(model)

        #expect(model.error == .clientCommandUnavailable)
        #expect(model.activeAuthorization(for: .claudeCode) == nil)
        #expect(try store.listAuthorizations().isEmpty)
    }

    @MainActor
    @Test func invalidCursorConfigurationFailsBeforeAuthorizationCreation() async throws {
        let home = temporaryDirectory("cursor-preflight")
        let accessRoot = home.appendingPathComponent("access")
        let helper = home.appendingPathComponent("SayAllMCP")
        let cursorConfiguration = home.appendingPathComponent(".cursor/mcp.json")
        try createParent(of: cursorConfiguration)
        try Data("{\"mcpServers\": {}}}".utf8).write(to: cursorConfiguration)
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let store = SayAllMCPAuthorizationStore(accessRoot: accessRoot)
        let service = MCPClientIntegrationService(
            homeDirectory: home,
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Cursor.app") },
            executableURLProvider: { _ in nil },
            commandRunner: { _, _ in 0 }
        )
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: service,
            helperExecutableURL: { helper }
        )
        model.setEnabled(true)

        model.connect(.cursor)
        try await waitForIntegration(model)

        #expect(model.error == .invalidClientConfiguration)
        #expect(model.failedClient == .cursor)
        #expect(try store.listAuthorizations().isEmpty)
    }

    @MainActor
    @Test func failedInstallationDiscardsItsTemporaryAuthorization() async throws {
        let home = temporaryDirectory("installation-discard")
        let accessRoot = home.appendingPathComponent("access")
        let helper = home.appendingPathComponent("SayAllMCP")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let store = SayAllMCPAuthorizationStore(accessRoot: accessRoot)
        let service = MCPClientIntegrationService(
            homeDirectory: home,
            applicationURLProvider: { _ in nil },
            executableURLProvider: { _ in home.appendingPathComponent("claude") },
            commandRunner: { _, arguments in arguments == ["--version"] ? 0 : 1 }
        )
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: service,
            helperExecutableURL: { helper }
        )
        model.setEnabled(true)

        model.connect(.claudeCode)
        try await waitForIntegration(model)

        #expect(model.error == .clientInstallationRejected)
        #expect(model.failedClient == .claudeCode)
        #expect(try store.listAuthorizations().isEmpty)
    }

    @MainActor
    @Test func healthyClientConnectsOnceAndRejectsDuplicateCalls() async throws {
        let home = temporaryDirectory("healthy-client")
        let accessRoot = home.appendingPathComponent("access")
        let helper = home.appendingPathComponent("SayAllMCP")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let store = SayAllMCPAuthorizationStore(accessRoot: accessRoot)
        let service = makeService(home: home)
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: service,
            helperExecutableURL: { helper }
        )
        model.setEnabled(true)

        model.connect(.cursor)
        model.connect(.cursor)
        try await waitForIntegration(model)
        model.connect(.cursor)

        #expect(model.error == nil)
        #expect(model.activeAuthorization(for: .cursor) != nil)
        #expect(!model.needsReconnect(.cursor))
        #expect(try store.listAuthorizations().count == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".cursor/mcp.json").path
            )
        )
    }

    @MainActor
    @Test func noncanonicalAppPathWorksAndMovingItRequiresReconnect() async throws {
        let home = temporaryDirectory("moved-app")
        let accessRoot = home.appendingPathComponent("access")
        let originalHelper = home
            .appendingPathComponent("Preview Builds/SayAll Preview.app")
            .appendingPathComponent("Contents/Helpers/SayAllMCP")
        try createParent(of: originalHelper)
        _ = FileManager.default.createFile(atPath: originalHelper.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: originalHelper.path
        )
        let store = SayAllMCPAuthorizationStore(accessRoot: accessRoot)
        let initialModel = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: makeService(home: home),
            helperExecutableURL: { originalHelper }
        )
        initialModel.setEnabled(true)
        initialModel.connect(.cursor)
        try await waitForIntegration(initialModel)

        #expect(initialModel.activeAuthorization(for: .cursor) != nil)
        #expect(!initialModel.needsReconnect(.cursor))

        let movedHelper = URL(
            fileURLWithPath: "/Applications/SayAll.app/Contents/Helpers/SayAllMCP"
        )
        let relaunchedModel = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: makeService(home: home),
            helperExecutableURL: { movedHelper }
        )
        relaunchedModel.refresh()

        #expect(relaunchedModel.needsReconnect(.cursor))
    }

    @MainActor
    @Test func legacyRemoteMicPathAndUnfingerprintedRecordsRequireReconnect() throws {
        let home = temporaryDirectory("legacy-path")
        let store = SayAllMCPAuthorizationStore(
            accessRoot: home.appendingPathComponent("access")
        )
        try store.setEnabled(true)
        _ = try store.createAuthorization(
            displayName: "Codex",
            integrationIdentifier: MCPClientKind.codex.rawValue,
            helperExecutablePath: "/Applications/Remote Mic.app/Contents/Helpers/SayAllMCP"
        )
        _ = try store.createAuthorization(displayName: "Legacy Manual Client")
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: makeService(home: home),
            helperExecutableURL: {
                URL(fileURLWithPath: "/Applications/SayAll.app/Contents/Helpers/SayAllMCP")
            }
        )

        model.refresh()

        #expect(model.needsReconnect(.codex))
        #expect(model.authorizations.allSatisfy(model.needsReconnect))
    }

    @MainActor
    @Test func revokedAttemptsAreNotShownAsAuthorizedClients() throws {
        let home = temporaryDirectory("hidden-revoked")
        let store = SayAllMCPAuthorizationStore(
            accessRoot: home.appendingPathComponent("access")
        )
        try store.setEnabled(true)
        let failedAttempt = try store.createAuthorization(
            displayName: "Claude Code",
            integrationIdentifier: "claude-code"
        )
        try store.revokeAuthorization(clientId: failedAttempt.clientId)
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: makeService(home: home),
            helperExecutableURL: { home.appendingPathComponent("SayAllMCP") }
        )

        model.refresh()

        #expect(model.authorizations.isEmpty)
        #expect(try store.listAuthorizations().count == 1)
    }

    @MainActor
    @Test func removalFailureStillRevokesAccess() async throws {
        let home = temporaryDirectory("remove-rollback")
        let accessRoot = home.appendingPathComponent("access")
        let helper = home.appendingPathComponent("SayAllMCP")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let store = SayAllMCPAuthorizationStore(accessRoot: accessRoot)
        let service = MCPClientIntegrationService(
            homeDirectory: home,
            applicationURLProvider: { _ in nil },
            executableURLProvider: { _ in home.appendingPathComponent("claude") },
            commandRunner: { _, arguments in arguments.contains("remove") ? 1 : 0 }
        )
        let model = TranscriptAgentAccessModel(
            authorizationStore: store,
            integrationService: service,
            helperExecutableURL: { helper }
        )
        model.setEnabled(true)
        model.connect(.claudeCode)
        try await waitForIntegration(model)

        model.removeConnection(.claudeCode)
        try await waitForIntegration(model)

        #expect(model.error == .configurationRemovalFailed)
        #expect(model.activeAuthorization(for: .claudeCode) == nil)
        #expect(try store.listAuthorizations().first?.revokedAt != nil)
    }

    private func configuration(token: String = "test-token") -> SayAllMCPIntegrationConfig {
        try! SayAllMCPIntegrationConfig(
            authorization: SayAllMCPCreatedAuthorization(
                clientId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                displayName: "Test",
                integrationIdentifier: nil,
                scope: "transcripts.read.all",
                token: token,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            helperExecutableURL: URL(
                fileURLWithPath: "/Applications/SayAll.app/Contents/Helpers/SayAllMCP"
            )
        )
    }

    private func makeService(home: URL) -> MCPClientIntegrationService {
        MCPClientIntegrationService(
            homeDirectory: home,
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Test.app") },
            executableURLProvider: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            commandRunner: { _, _ in 0 }
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sayall-client-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func createParent(of file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func json(at file: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
    }

    private func backupCount(nextTo file: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            atPath: file.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(".\(file.lastPathComponent).sayall-backup-") }.count
    }

    private func permissions(of file: URL) throws -> Int {
        let number = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber
        )
        return number.intValue & 0o777
    }

    @MainActor
    private func waitForIntegration(_ model: TranscriptAgentAccessModel) async throws {
        for _ in 0..<200 where model.integrationInProgress != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.integrationInProgress == nil)
    }
}
