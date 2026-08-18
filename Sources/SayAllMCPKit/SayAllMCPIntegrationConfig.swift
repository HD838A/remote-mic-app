import Foundation

public struct SayAllMCPIntegrationConfig: Equatable, Sendable {
    public let authorization: SayAllMCPCreatedAuthorization
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let standardJSON: String
    public let codexTOML: String

    public init(
        authorization: SayAllMCPCreatedAuthorization,
        helperExecutableURL: URL
    ) throws {
        self.authorization = authorization
        command = helperExecutableURL.path
        arguments = ["serve"]
        environment = [
            "SAYALL_MCP_CLIENT_ID": authorization.clientId.uuidString.lowercased(),
            "SAYALL_MCP_ACCESS_TOKEN": authorization.token,
        ]
        let configuration: [String: Any] = [
            "mcpServers": [
                "sayall_history": [
                    "command": command,
                    "args": arguments,
                    "env": environment,
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let standardJSON = String(data: data, encoding: .utf8) else {
            throw SayAllMCPAuthorizationError.encodingFailed
        }
        self.standardJSON = standardJSON
        codexTOML = [
            "[mcp_servers.sayall_history]",
            "command = \(Self.tomlString(command))",
            "args = [\(arguments.map(Self.tomlString).joined(separator: ", "))]",
            "env = { SAYALL_MCP_CLIENT_ID = \(Self.tomlString(environment["SAYALL_MCP_CLIENT_ID"]!)), SAYALL_MCP_ACCESS_TOKEN = \(Self.tomlString(environment["SAYALL_MCP_ACCESS_TOKEN"]!)) }",
        ].joined(separator: "\n")
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0C: escaped += "\\f"
            case 0x0D: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }
}
