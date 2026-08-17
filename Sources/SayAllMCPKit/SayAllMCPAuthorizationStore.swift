import CryptoKit
import Foundation
import Security

private let maximumClientNameLength = 100

public struct SayAllMCPAuthorizationRecord: Identifiable, Equatable, Sendable {
    public let clientId: UUID
    public let displayName: String
    public let scope: String
    public let tokenHash: String
    public let createdAt: Date
    public var revokedAt: Date?

    public var id: UUID { clientId }
}

public struct SayAllMCPCreatedAuthorization: Equatable, Sendable {
    public let clientId: UUID
    public let displayName: String
    public let scope: String
    public let token: String
    public let createdAt: Date
}

public struct SayAllMCPAccessDeniedError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public final class SayAllMCPAuthorizationStore: @unchecked Sendable {
    private let accessRoot: URL
    private let settingsFile: URL
    private let authorizationsFile: URL
    private let queue = DispatchQueue(label: "SayAllMCP.authorization")

    public init(accessRoot: URL) {
        self.accessRoot = accessRoot
        settingsFile = accessRoot.appendingPathComponent("settings.ndjson")
        authorizationsFile = accessRoot.appendingPathComponent("authorizations.ndjson")
    }

    public convenience init(paths: SayAllMCPPaths = .defaults()) {
        self.init(accessRoot: paths.accessRoot)
    }

    public func isEnabled() throws -> Bool {
        try queue.sync { try loadSettingEvents().last?.enabled ?? false }
    }

    public func setEnabled(_ enabled: Bool) throws {
        try queue.sync {
            try appendEvent(
                SettingEvent(
                    schemaVersion: 1,
                    type: "access_changed",
                    enabled: enabled,
                    changedAt: Date()
                ),
                to: settingsFile
            )
        }
    }

    public func createAuthorization(displayName: String) throws -> SayAllMCPCreatedAuthorization {
        try queue.sync {
            guard try loadSettingEvents().last?.enabled ?? false else {
                throw SayAllMCPAccessDeniedError(
                    code: "access_disabled",
                    message: "Local Agent access is disabled."
                )
            }
            let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty, normalizedName.count <= maximumClientNameLength else {
                throw SayAllMCPAuthorizationError.invalidClientName
            }

            let clientId = UUID()
            let token = try Self.randomToken()
            let createdAt = Date()
            try appendEvent(
                AuthorizationEvent(
                    schemaVersion: 1,
                    type: "authorization_created",
                    clientId: clientId,
                    displayName: normalizedName,
                    scope: "transcripts.read.all",
                    tokenHash: Self.hashToken(token),
                    createdAt: createdAt,
                    revokedAt: nil
                ),
                to: authorizationsFile
            )
            return SayAllMCPCreatedAuthorization(
                clientId: clientId,
                displayName: normalizedName,
                scope: "transcripts.read.all",
                token: token,
                createdAt: createdAt
            )
        }
    }

    public func setupAuthorization(displayName: String) throws -> SayAllMCPCreatedAuthorization {
        if try !isEnabled() {
            try setEnabled(true)
        }
        return try createAuthorization(displayName: displayName)
    }

    public func revokeAuthorization(clientId: UUID) throws {
        try queue.sync {
            guard let authorization = try resolvedAuthorizations().first(where: {
                $0.clientId == clientId
            }) else {
                throw SayAllMCPAuthorizationError.authorizationNotFound
            }
            guard authorization.revokedAt == nil else { return }
            try appendEvent(
                AuthorizationEvent(
                    schemaVersion: 1,
                    type: "authorization_revoked",
                    clientId: clientId,
                    displayName: nil,
                    scope: nil,
                    tokenHash: nil,
                    createdAt: nil,
                    revokedAt: Date()
                ),
                to: authorizationsFile
            )
        }
    }

    public func listAuthorizations() throws -> [SayAllMCPAuthorizationRecord] {
        try queue.sync { try resolvedAuthorizations() }
    }

    @discardableResult
    public func requireAuthorized(
        clientId: String,
        token: String
    ) throws -> SayAllMCPAuthorizationRecord {
        try queue.sync {
            guard try loadSettingEvents().last?.enabled ?? false else {
                throw SayAllMCPAccessDeniedError(
                    code: "access_disabled",
                    message: "Local Agent access is disabled."
                )
            }
            guard let parsedClientId = UUID(uuidString: clientId),
                  (32...256).contains(token.count)
            else {
                throw SayAllMCPAccessDeniedError(
                    code: "invalid_credentials",
                    message: "Client credentials are invalid."
                )
            }
            guard let authorization = try resolvedAuthorizations().first(where: {
                $0.clientId == parsedClientId
            }), authorization.revokedAt == nil else {
                throw SayAllMCPAccessDeniedError(
                    code: "authorization_unavailable",
                    message: "Authorization is unavailable."
                )
            }
            let providedHash = Data(Self.hashToken(token).utf8)
            let storedHash = Data(authorization.tokenHash.utf8)
            guard Self.constantTimeEqual(providedHash, storedHash) else {
                throw SayAllMCPAccessDeniedError(
                    code: "invalid_credentials",
                    message: "Client credentials are invalid."
                )
            }
            return authorization
        }
    }

    private func loadSettingEvents() throws -> [SettingEvent] {
        try decodeLines(from: settingsFile, as: SettingEvent.self).enumerated().map { index, event in
            guard event.schemaVersion == 1,
                  event.type == "access_changed"
            else { throw SayAllMCPStorageError.invalidEventLog(line: index + 1) }
            return event
        }
    }

    private func resolvedAuthorizations() throws -> [SayAllMCPAuthorizationRecord] {
        let events = try decodeLines(from: authorizationsFile, as: AuthorizationEvent.self)
        var records: [UUID: SayAllMCPAuthorizationRecord] = [:]
        for (index, event) in events.enumerated() {
            guard event.schemaVersion == 1 else {
                throw SayAllMCPStorageError.invalidEventLog(line: index + 1)
            }
            switch event.type {
            case "authorization_created":
                guard records[event.clientId] == nil,
                      let displayName = event.displayName,
                      !displayName.isEmpty,
                      displayName.count <= maximumClientNameLength,
                      event.scope == "transcripts.read.all",
                      let tokenHash = event.tokenHash,
                      tokenHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                      let createdAt = event.createdAt
                else { throw SayAllMCPStorageError.invalidEventLog(line: index + 1) }
                records[event.clientId] = SayAllMCPAuthorizationRecord(
                    clientId: event.clientId,
                    displayName: displayName,
                    scope: "transcripts.read.all",
                    tokenHash: tokenHash,
                    createdAt: createdAt,
                    revokedAt: nil
                )
            case "authorization_revoked":
                guard var record = records[event.clientId], let revokedAt = event.revokedAt else {
                    throw SayAllMCPStorageError.invalidEventLog(line: index + 1)
                }
                record.revokedAt = revokedAt
                records[event.clientId] = record
            default:
                throw SayAllMCPStorageError.invalidEventLog(line: index + 1)
            }
        }
        return records.values.sorted { $0.createdAt > $1.createdAt }
    }

    private func appendEvent<T: Encodable>(_ event: T, to file: URL) throws {
        let data = try Self.makeEventEncoder().encode(event)
        guard let line = String(data: data, encoding: .utf8) else {
            throw SayAllMCPAuthorizationError.encodingFailed
        }
        try SayAllMCPFileSecurity.appendPrivateLine(line, directory: accessRoot, file: file)
    }

    private func decodeLines<T: Decodable>(from file: URL, as type: T.Type) throws -> [T] {
        try SayAllMCPFileSecurity.readPrivateLines(from: file).enumerated().map { index, line in
            do {
                return try Self.makeEventDecoder().decode(T.self, from: Data(line.utf8))
            } catch {
                throw SayAllMCPStorageError.invalidEventLog(line: index + 1)
            }
        }
    }

    private static func makeEventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        SayAllMCPISO8601.configureEncoder(encoder)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeEventDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        SayAllMCPISO8601.configureDecoder(decoder)
        return decoder
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SayAllMCPAuthorizationError.randomGenerationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hashToken(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { result, pair in
            result | (pair.0 ^ pair.1)
        } == 0
    }
}

public enum SayAllMCPAuthorizationError: Error {
    case invalidClientName
    case authorizationNotFound
    case encodingFailed
    case randomGenerationFailed
}

private struct SettingEvent: Codable {
    let schemaVersion: Int
    let type: String
    let enabled: Bool
    let changedAt: Date
}

private struct AuthorizationEvent: Codable {
    let schemaVersion: Int
    let type: String
    let clientId: UUID
    let displayName: String?
    let scope: String?
    let tokenHash: String?
    let createdAt: Date?
    let revokedAt: Date?
}
