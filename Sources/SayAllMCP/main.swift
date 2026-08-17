import Foundation
import SayAllMCPKit

private let clientIDEnvironmentKey = "SAYALL_MCP_CLIENT_ID"
private let accessTokenEnvironmentKey = "SAYALL_MCP_ACCESS_TOKEN"

@main
private struct SayAllMCPCommand {
    static func main() {
        do {
            try run()
        } catch {
            writeError("sayall-mcp: \(publicErrorMessage(error))\n")
            Foundation.exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage(exitCode: 2)
        }
        let paths = SayAllMCPPaths.defaults()
        let authorizationStore = SayAllMCPAuthorizationStore(paths: paths)
        switch command {
        case "serve":
            let clientId = ProcessInfo.processInfo.environment[clientIDEnvironmentKey] ?? ""
            let token = ProcessInfo.processInfo.environment[accessTokenEnvironmentKey] ?? ""
            let service = SayAllMCPService(paths: paths, clientId: clientId, token: token)
            try service.validateServerStart()
            try SayAllMCPStdioServer(service: service).run()
        case "enable":
            try authorizationStore.setEnabled(true)
            printJSON(["enabled": true])
        case "disable":
            try authorizationStore.setEnabled(false)
            printJSON(["enabled": false])
        case "status":
            printJSON([
                "enabled": try authorizationStore.isEnabled(),
                "authorizations": try publicAuthorizations(authorizationStore),
            ])
        case "list":
            printJSON(["authorizations": try publicAuthorizations(authorizationStore)])
        case "authorize":
            let name = try requiredOption("--name", arguments: arguments)
            let authorization = try authorizationStore.createAuthorization(displayName: name)
            try printIntegration(authorization, asJSON: true)
        case "setup":
            let name = optionalOption("--name", arguments: arguments) ?? "Local AI Client"
            let authorization = try authorizationStore.setupAuthorization(displayName: name)
            try printIntegration(authorization, asJSON: arguments.contains("--json"))
        case "revoke":
            let value = try requiredOption("--client-id", arguments: arguments)
            guard let clientId = UUID(uuidString: value) else {
                throw SayAllMCPAuthorizationError.authorizationNotFound
            }
            try authorizationStore.revokeAuthorization(clientId: clientId)
            printJSON(["revoked": true])
        case "help", "--help", "-h":
            printUsage(exitCode: 0)
        default:
            printUsage(exitCode: 2)
        }
    }

    private static func printIntegration(
        _ authorization: SayAllMCPCreatedAuthorization,
        asJSON: Bool
    ) throws {
        let config = try SayAllMCPIntegrationConfig(
            authorization: authorization,
            helperExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0])
        )
        let warning = "无线麦SayAll.app and this MCP server do not upload transcripts. "
            + "The authorized AI client may send returned text to its own provider."
        guard asJSON else {
            FileHandle.standardOutput.write(
                Data(
                    """
                    Created read-only authorization for: \(authorization.displayName)
                    Client ID: \(authorization.clientId.uuidString.lowercased())

                    Standard MCP JSON (Claude Desktop, Cursor, Windsurf, and compatible hosts):
                    \(config.standardJSON)

                    Codex TOML:
                    \(config.codexTOML)

                    Privacy notice: \(warning)

                    """.utf8
                )
            )
            return
        }
        printJSON([
            "authorization": [
                "clientId": authorization.clientId.uuidString.lowercased(),
                "displayName": authorization.displayName,
                "scope": authorization.scope,
                "token": authorization.token,
                "createdAt": isoString(authorization.createdAt),
            ],
            "mcpConfig": [
                "command": config.command,
                "args": config.arguments,
                "env": config.environment,
            ],
            "standardJson": config.standardJSON,
            "codexToml": config.codexTOML,
            "warning": warning,
        ])
    }

    private static func publicAuthorizations(
        _ store: SayAllMCPAuthorizationStore
    ) throws -> [[String: Any]] {
        try store.listAuthorizations().map { authorization in
            [
                "clientId": authorization.clientId.uuidString.lowercased(),
                "displayName": authorization.displayName,
                "scope": authorization.scope,
                "createdAt": isoString(authorization.createdAt),
                "revokedAt": authorization.revokedAt.map(isoString) ?? NSNull(),
            ]
        }
    }

    private static func requiredOption(_ name: String, arguments: [String]) throws -> String {
        guard let value = optionalOption(name, arguments: arguments) else {
            throw SayAllMCPCommandError.missingOption(name)
        }
        return value
    }

    private static func optionalOption(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    private static func printUsage(exitCode: Int32) -> Never {
        writeError(
            """
            Usage:
              SayAllMCP serve
              SayAllMCP status
              SayAllMCP list
              SayAllMCP enable
              SayAllMCP disable
              SayAllMCP authorize --name <client-name>
              SayAllMCP setup [--name <client-name>] [--json]
              SayAllMCP revoke --client-id <uuid>

            """
        )
        Foundation.exit(exitCode)
    }
}

private final class SayAllMCPStdioServer {
    private let service: SayAllMCPService
    private var negotiatedProtocolVersion = "2025-11-25"

    init(service: SayAllMCPService) {
        self.service = service
    }

    func run() throws {
        writeError("无线麦SayAll.app history MCP server is running on stdio.\n")
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            do {
                let data = Data(line.utf8)
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SayAllMCPProtocolError.invalidRequest
                }
                try handle(request)
            } catch {
                writeResponse([
                    "jsonrpc": "2.0",
                    "id": NSNull(),
                    "error": ["code": -32700, "message": "Parse error"],
                ])
            }
        }
    }

    private func handle(_ request: [String: Any]) throws {
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String
        else { throw SayAllMCPProtocolError.invalidRequest }
        let identifier = request["id"]
        if identifier == nil {
            return
        }
        let parameters = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let requestedVersion = parameters["protocolVersion"] as? String,
               Self.supportedProtocolVersions.contains(requestedVersion) {
                negotiatedProtocolVersion = requestedVersion
            }
            respond(
                identifier: identifier!,
                result: [
                    "protocolVersion": negotiatedProtocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": [
                        "name": "sayall-remote-mic-history",
                        "version": "0.1.0",
                    ],
                ]
            )
        case "ping":
            respond(identifier: identifier!, result: [:])
        case "tools/list":
            respond(identifier: identifier!, result: ["tools": Self.tools])
        case "tools/call":
            respond(identifier: identifier!, result: callTool(parameters))
        default:
            respondError(identifier: identifier!, code: -32601, message: "Method not found")
        }
    }

    private func callTool(_ parameters: [String: Any]) -> [String: Any] {
        guard let name = parameters["name"] as? String else {
            return toolFailure(code: "invalid_request", message: "Tool name is required.")
        }
        let arguments = parameters["arguments"] as? [String: Any] ?? [:]
        do {
            switch name {
            case "list_transcript_apps":
                let result = try service.listApplications()
                return try toolSuccess(result)
            case "query_transcripts":
                let query = try Self.parseQuery(arguments)
                return try toolSuccess(service.query(query))
            default:
                return toolFailure(code: "unknown_tool", message: "Tool is unavailable.")
            }
        } catch {
            let code = SayAllMCPService.errorCode(error)
            let message = (error as? SayAllMCPAccessDeniedError)?.message
                ?? "The local history request failed."
            return toolFailure(code: code, message: message)
        }
    }

    private func toolSuccess<T: Encodable>(_ value: T) throws -> [String: Any] {
        let object = try jsonObject(value)
        let textData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return [
            "content": [["type": "text", "text": String(decoding: textData, as: UTF8.self)]],
            "structuredContent": object,
        ]
    }

    private func toolFailure(code: String, message: String) -> [String: Any] {
        let payload = ["code": code, "message": message]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [
            "isError": true,
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
        ]
    }

    private func respond(identifier: Any, result: Any) {
        writeResponse(["jsonrpc": "2.0", "id": identifier, "result": result])
    }

    private func respondError(identifier: Any, code: Int, message: String) {
        writeResponse([
            "jsonrpc": "2.0",
            "id": identifier,
            "error": ["code": code, "message": message],
        ])
    }

    private func writeResponse(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: response,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func parseQuery(_ arguments: [String: Any]) throws -> SayAllMCPTranscriptQuery {
        let allowedKeys: Set<String> = [
            "startedAtOrAfter", "endedAtBefore", "bundleIdentifiers",
            "order", "limit", "cursor",
        ]
        guard Set(arguments.keys).isSubset(of: allowedKeys) else {
            throw SayAllMCPProtocolError.invalidArguments
        }
        let bundleIdentifiers: [String]?
        if let raw = arguments["bundleIdentifiers"] {
            guard let values = raw as? [String] else {
                throw SayAllMCPProtocolError.invalidArguments
            }
            bundleIdentifiers = values
        } else {
            bundleIdentifiers = nil
        }
        let order: SayAllMCPTranscriptOrder?
        if let rawOrder = arguments["order"] as? String {
            guard let parsed = SayAllMCPTranscriptOrder(rawValue: rawOrder) else {
                throw SayAllMCPProtocolError.invalidArguments
            }
            order = parsed
        } else {
            order = nil
        }
        let limit: Int?
        if let rawLimit = arguments["limit"] {
            guard let number = rawLimit as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue)
            else { throw SayAllMCPProtocolError.invalidArguments }
            limit = number.intValue
        } else {
            limit = nil
        }
        return SayAllMCPTranscriptQuery(
            startedAtOrAfter: arguments["startedAtOrAfter"] as? String,
            endedAtBefore: arguments["endedAtBefore"] as? String,
            bundleIdentifiers: bundleIdentifiers,
            order: order,
            limit: limit,
            cursor: arguments["cursor"] as? String
        )
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "list_transcript_apps",
            "title": "List 无线麦SayAll.app transcript applications",
            "description": "List applications represented in the user's local 无线麦SayAll.app voice transcript history. Does not return transcript text.",
            "inputSchema": ["type": "object", "additionalProperties": false],
            "outputSchema": [
                "type": "object",
                "required": ["applications", "skippedFileCount"],
                "properties": [
                    "applications": ["type": "array", "items": applicationSchema],
                    "skippedFileCount": ["type": "integer", "minimum": 0],
                ],
            ],
            "annotations": readOnlyAnnotations,
        ],
        [
            "name": "query_transcripts",
            "title": "Query 无线麦SayAll.app transcripts",
            "description": "Read authorized local 无线麦SayAll.app transcript records with optional time and application filters. Results are paginated.",
            "inputSchema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "startedAtOrAfter": ["type": "string", "format": "date-time"],
                    "endedAtBefore": ["type": "string", "format": "date-time"],
                    "bundleIdentifiers": [
                        "type": "array",
                        "maxItems": 100,
                        "items": ["type": "string", "minLength": 1, "maxLength": 500],
                    ],
                    "order": ["type": "string", "enum": ["ascending", "descending"]],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500],
                    "cursor": ["type": "string", "maxLength": 2048],
                ],
            ],
            "outputSchema": [
                "type": "object",
                "required": ["records", "nextCursor", "hasMore", "skippedFileCount"],
                "properties": [
                    "records": ["type": "array", "items": transcriptSchema],
                    "nextCursor": ["type": ["string", "null"]],
                    "hasMore": ["type": "boolean"],
                    "skippedFileCount": ["type": "integer", "minimum": 0],
                ],
            ],
            "annotations": readOnlyAnnotations,
        ],
    ]

    private static let supportedProtocolVersions: Set<String> = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
        "2024-10-07",
    ]

    private static let readOnlyAnnotations: [String: Any] = [
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
    ]

    private static let applicationSchema: [String: Any] = [
        "type": "object",
        "required": [
            "applicationName", "bundleIdentifier", "recordCount",
            "earliestEndedAt", "latestEndedAt",
        ],
        "properties": [
            "applicationName": ["type": "string"],
            "bundleIdentifier": ["type": "string"],
            "recordCount": ["type": "integer", "minimum": 0],
            "earliestEndedAt": ["type": "string", "format": "date-time"],
            "latestEndedAt": ["type": "string", "format": "date-time"],
        ],
    ]

    private static let transcriptSchema: [String: Any] = [
        "type": "object",
        "required": [
            "id", "startedAt", "endedAt", "localDateKey", "timeZoneIdentifier",
            "applicationName", "bundleIdentifier", "source", "text",
        ],
        "properties": [
            "id": ["type": "string", "format": "uuid"],
            "startedAt": ["type": "string", "format": "date-time"],
            "endedAt": ["type": "string", "format": "date-time"],
            "localDateKey": ["type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$"],
            "timeZoneIdentifier": ["type": "string"],
            "applicationName": ["type": "string"],
            "bundleIdentifier": ["type": "string"],
            "source": ["type": "string"],
            "text": ["type": "string"],
        ],
    ]
}

private enum SayAllMCPCommandError: Error {
    case missingOption(String)
}

private enum SayAllMCPProtocolError: Error {
    case invalidRequest
    case invalidArguments
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try JSONSerialization.jsonObject(with: encoder.encode(value))
}

private func printJSON(_ value: Any) {
    let data = try! JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

private func publicErrorMessage(_ error: Error) -> String {
    if let accessError = error as? SayAllMCPAccessDeniedError { return accessError.message }
    switch error {
    case SayAllMCPAuthorizationError.invalidClientName:
        return "Client name must contain 1-100 characters."
    case SayAllMCPAuthorizationError.authorizationNotFound:
        return "Authorization was not found."
    case let SayAllMCPCommandError.missingOption(name):
        return "Missing required option \(name)."
    default:
        return "The local MCP request failed."
    }
}

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
