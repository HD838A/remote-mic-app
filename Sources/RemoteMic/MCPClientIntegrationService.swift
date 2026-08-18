import AppKit
import Foundation
import SayAllMCPKit

enum MCPClientKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case cursor
    case openCode = "opencode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .openCode: return "OpenCode"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .codex: return "com.openai.codex"
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .openCode: return "ai.opencode.desktop"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claudeCode: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .openCode: return "curlybraces.square"
        }
    }
}

enum MCPClientIntegrationError: Error, Equatable {
    case clientUnavailable
    case configurationConflict
    case invalidConfiguration
    case unsafeConfigurationPath
    case clientCommandUnavailable
    case commandFailed
    case writeFailed
}

struct MCPClientIntegrationService: @unchecked Sendable {
    typealias ApplicationURLProvider = (String) -> URL?
    typealias ExecutableURLProvider = (String) -> URL?
    typealias CommandRunner = (URL, [String]) throws -> Int32

    private let homeDirectory: URL
    private let fileManager: FileManager
    private let applicationURLProvider: ApplicationURLProvider
    private let executableURLProvider: ExecutableURLProvider
    private let commandRunner: CommandRunner

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        applicationURLProvider: @escaping ApplicationURLProvider = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        executableURLProvider: @escaping ExecutableURLProvider = { name in
            let candidates = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/\(name)").path,
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".volta/bin/\(name)").path,
            ]
            return candidates
                .map(URL.init(fileURLWithPath:))
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        },
        commandRunner: @escaping CommandRunner = { executable, arguments in
            let process = Process()
            let finished = DispatchSemaphore(value: 0)
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 15) == .success else {
                process.terminate()
                return -1
            }
            return process.terminationStatus
        }
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.applicationURLProvider = applicationURLProvider
        self.executableURLProvider = executableURLProvider
        self.commandRunner = commandRunner
    }

    func isAvailable(_ client: MCPClientKind) -> Bool {
        if client == .claudeCode {
            return executableURLProvider("claude") != nil
        }
        if client == .codex, executableURLProvider("codex") != nil {
            return true
        }
        guard let bundleIdentifier = client.bundleIdentifier else { return false }
        return applicationURLProvider(bundleIdentifier) != nil
    }

    func applicationIcon(_ client: MCPClientKind) -> NSImage? {
        guard let bundleIdentifier = client.bundleIdentifier,
              let applicationURL = applicationURLProvider(bundleIdentifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    func install(
        _ client: MCPClientKind,
        configuration: SayAllMCPIntegrationConfig
    ) throws {
        switch client {
        case .codex:
            try installCodex(configuration)
        case .claudeCode:
            try installClaudeCode(configuration)
        case .cursor:
            try installCursor(configuration)
        case .openCode:
            try installOpenCode(configuration)
        }
    }

    func preflight(_ client: MCPClientKind) throws {
        guard isAvailable(client) else {
            throw MCPClientIntegrationError.clientUnavailable
        }
        switch client {
        case .codex:
            let existing = try readTextIfPresent(codexConfigurationURL) ?? ""
            guard managedCodexRange(in: existing) == nil,
                  !existing.contains("[mcp_servers.sayall_history]")
            else {
                throw MCPClientIntegrationError.configurationConflict
            }
        case .claudeCode:
            guard let executable = executableURLProvider("claude") else {
                throw MCPClientIntegrationError.clientUnavailable
            }
            guard try commandRunner(executable, ["--version"]) == 0 else {
                throw MCPClientIntegrationError.clientCommandUnavailable
            }
        case .cursor:
            try validateJSONEntryAvailable(
                file: cursorConfigurationURL,
                rootKey: "mcpServers"
            )
        case .openCode:
            try validateJSONEntryAvailable(
                file: openCodeConfigurationURL,
                rootKey: "mcp"
            )
        }
    }

    func remove(_ client: MCPClientKind) throws {
        switch client {
        case .codex:
            try removeCodex()
        case .claudeCode:
            try removeClaudeCode()
        case .cursor:
            try removeJSONEntry(
                file: cursorConfigurationURL,
                rootKey: "mcpServers"
            )
        case .openCode:
            try removeJSONEntry(
                file: openCodeConfigurationURL,
                rootKey: "mcp"
            )
        }
    }

    private var codexConfigurationURL: URL {
        homeDirectory.appendingPathComponent(".codex/config.toml")
    }

    private var cursorConfigurationURL: URL {
        homeDirectory.appendingPathComponent(".cursor/mcp.json")
    }

    private var openCodeConfigurationURL: URL {
        homeDirectory.appendingPathComponent(".config/opencode/opencode.json")
    }

    private var codexBeginMarker: String {
        "# BEGIN SAYALL MANAGED MCP sayall_history"
    }

    private var codexEndMarker: String {
        "# END SAYALL MANAGED MCP sayall_history"
    }

    private func installCodex(_ configuration: SayAllMCPIntegrationConfig) throws {
        let file = codexConfigurationURL
        let existing = try readTextIfPresent(file) ?? ""
        let block = [codexBeginMarker, configuration.codexTOML, codexEndMarker]
            .joined(separator: "\n")
        let updated: String

        if let managedRange = managedCodexRange(in: existing) {
            updated = existing.replacingCharacters(in: managedRange, with: block)
        } else {
            guard !existing.contains("[mcp_servers.sayall_history]") else {
                throw MCPClientIntegrationError.configurationConflict
            }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            updated = existing + separator + (existing.isEmpty ? "" : "\n") + block + "\n"
        }
        try writePrivate(Data(updated.utf8), to: file)
    }

    private func removeCodex() throws {
        let file = codexConfigurationURL
        guard let existing = try readTextIfPresent(file),
              let managedRange = managedCodexRange(in: existing)
        else { return }
        var updated = existing.replacingCharacters(in: managedRange, with: "")
        while updated.contains("\n\n\n") {
            updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        try writePrivate(Data(updated.utf8), to: file)
    }

    private func managedCodexRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: codexBeginMarker),
              let end = text.range(of: codexEndMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        var upperBound = end.upperBound
        if upperBound < text.endIndex, text[upperBound] == "\n" {
            upperBound = text.index(after: upperBound)
        }
        return start.lowerBound..<upperBound
    }

    private func installClaudeCode(_ configuration: SayAllMCPIntegrationConfig) throws {
        guard let executable = executableURLProvider("claude") else {
            throw MCPClientIntegrationError.clientUnavailable
        }
        let server: [String: Any] = [
            "type": "stdio",
            "command": configuration.command,
            "args": configuration.arguments,
            "env": configuration.environment,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: server,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPClientIntegrationError.invalidConfiguration
        }
        let status = try commandRunner(
            executable,
            ["mcp", "add-json", "--scope", "user", "sayall_history", json]
        )
        guard status == 0 else { throw MCPClientIntegrationError.commandFailed }
    }

    private func removeClaudeCode() throws {
        guard let executable = executableURLProvider("claude") else {
            throw MCPClientIntegrationError.clientUnavailable
        }
        let status = try commandRunner(
            executable,
            ["mcp", "remove", "--scope", "user", "sayall_history"]
        )
        guard status == 0 else { throw MCPClientIntegrationError.commandFailed }
    }

    private func installCursor(_ configuration: SayAllMCPIntegrationConfig) throws {
        let server: [String: Any] = [
            "type": "stdio",
            "command": configuration.command,
            "args": configuration.arguments,
            "env": configuration.environment,
        ]
        try mergeJSONEntry(
            server,
            file: cursorConfigurationURL,
            rootKey: "mcpServers"
        )
    }

    private func installOpenCode(_ configuration: SayAllMCPIntegrationConfig) throws {
        let server: [String: Any] = [
            "type": "local",
            "command": [configuration.command] + configuration.arguments,
            "environment": configuration.environment,
            "enabled": true,
        ]
        try mergeJSONEntry(
            server,
            file: openCodeConfigurationURL,
            rootKey: "mcp"
        )
    }

    private func mergeJSONEntry(
        _ server: [String: Any],
        file: URL,
        rootKey: String
    ) throws {
        var root = try readJSONObject(file)
        var servers = root[rootKey] as? [String: Any] ?? [:]
        if root[rootKey] != nil, root[rootKey] as? [String: Any] == nil {
            throw MCPClientIntegrationError.invalidConfiguration
        }
        guard servers["sayall_history"] == nil else {
            throw MCPClientIntegrationError.configurationConflict
        }
        servers["sayall_history"] = server
        root[rootKey] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try writePrivate(data, to: file)
    }

    private func validateJSONEntryAvailable(file: URL, rootKey: String) throws {
        let root = try readJSONObject(file)
        guard root[rootKey] == nil || root[rootKey] is [String: Any] else {
            throw MCPClientIntegrationError.invalidConfiguration
        }
        let servers = root[rootKey] as? [String: Any] ?? [:]
        guard servers["sayall_history"] == nil else {
            throw MCPClientIntegrationError.configurationConflict
        }
    }

    private func removeJSONEntry(file: URL, rootKey: String) throws {
        guard fileManager.fileExists(atPath: file.path) else { return }
        var root = try readJSONObject(file)
        guard var servers = root[rootKey] as? [String: Any],
              servers.removeValue(forKey: "sayall_history") != nil
        else { return }
        root[rootKey] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try writePrivate(data, to: file)
    }

    private func readJSONObject(_ file: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: file.path) else { return [:] }
        try rejectSymbolicLink(file)
        do {
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw MCPClientIntegrationError.invalidConfiguration }
            return object
        } catch let error as MCPClientIntegrationError {
            throw error
        } catch {
            throw MCPClientIntegrationError.invalidConfiguration
        }
    }

    private func readTextIfPresent(_ file: URL) throws -> String? {
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        try rejectSymbolicLink(file)
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw MCPClientIntegrationError.invalidConfiguration
        }
        return text
    }

    private func writePrivate(_ data: Data, to file: URL) throws {
        do {
            let directory = file.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: file.path) {
                try rejectSymbolicLink(file)
                let backup = file.deletingLastPathComponent().appendingPathComponent(
                    ".\(file.lastPathComponent).sayall-backup-\(UUID().uuidString)"
                )
                try fileManager.copyItem(at: file, to: backup)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            try data.write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch let error as MCPClientIntegrationError {
            throw error
        } catch {
            throw MCPClientIntegrationError.writeFailed
        }
    }

    private func rejectSymbolicLink(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw MCPClientIntegrationError.unsafeConfigurationPath
        }
    }
}
