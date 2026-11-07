import Foundation

public final class SayAllMCPService: @unchecked Sendable {
    public let clientId: String
    private let token: String
    private let authorizationStore: SayAllMCPAuthorizationStore
    private let historyStore: SayAllMCPHistoryStore
    private let auditLog: SayAllMCPAuditLog

    public init(
        paths: SayAllMCPPaths = .defaults(),
        clientId: String,
        token: String
    ) {
        self.clientId = clientId
        self.token = token
        authorizationStore = SayAllMCPAuthorizationStore(paths: paths)
        historyStore = SayAllMCPHistoryStore(paths: paths)
        auditLog = SayAllMCPAuditLog(paths: paths)
    }

    public func validateServerStart() throws {
        do {
            let authorization = try authorizationStore.requireAuthorized(clientId: clientId, token: token)
            try auditLog.append(
                SayAllMCPAuditEvent(
                    clientId: authorization.clientId.uuidString.lowercased(),
                    tool: "server_start",
                    result: "allowed"
                )
            )
        } catch {
            try? auditLog.append(
                SayAllMCPAuditEvent(
                    clientId: "unknown",
                    tool: "server_start",
                    result: "denied",
                    reasonCode: Self.errorCode(error)
                )
            )
            throw error
        }
    }

    public func listApplications() throws -> SayAllMCPApplicationPage {
        let occurredAt = Date()
        var auditClientID = "unknown"
        do {
            let authorization = try authorizationStore.requireAuthorized(clientId: clientId, token: token)
            auditClientID = authorization.clientId.uuidString.lowercased()
            let result = try historyStore.listApplications()
            try auditLog.append(
                SayAllMCPAuditEvent(
                    clientId: auditClientID,
                    tool: "list_transcript_apps",
                    occurredAt: occurredAt,
                    result: "allowed",
                    returnedRecordCount: result.applications.reduce(0) { $0 + $1.recordCount }
                )
            )
            return result
        } catch {
            try? auditLog.append(
                SayAllMCPAuditEvent(
                    clientId: auditClientID,
                    tool: "list_transcript_apps",
                    occurredAt: occurredAt,
                    result: error is SayAllMCPAccessDeniedError ? "denied" : "error",
                    reasonCode: Self.errorCode(error)
                )
            )
            throw error
        }
    }

    public func query(_ query: SayAllMCPTranscriptQuery) throws -> SayAllMCPTranscriptPage {
        let occurredAt = Date()
        var auditClientID = "unknown"
        do {
            let authorization = try authorizationStore.requireAuthorized(clientId: clientId, token: token)
            auditClientID = authorization.clientId.uuidString.lowercased()
            let result = try historyStore.query(query)
            try auditLog.append(
                SayAllMCPAuditEvent(
                    clientId: auditClientID,
                    tool: "query_transcripts",
                    occurredAt: occurredAt,
                    result: "allowed",
                    returnedRecordCount: result.records.count,
                    bundleIdentifierCount: query.bundleIdentifiers?.count ?? 0
                )
            )
            return result
        } catch {
            try? auditLog.append(
                SayAllMCPAuditEvent(
                    clientId: auditClientID,
                    tool: "query_transcripts",
                    occurredAt: occurredAt,
                    result: error is SayAllMCPAccessDeniedError ? "denied" : "error",
                    bundleIdentifierCount: query.bundleIdentifiers?.count ?? 0,
                    reasonCode: Self.errorCode(error)
                )
            )
            throw error
        }
    }

    public static func errorCode(_ error: Error) -> String {
        if let accessError = error as? SayAllMCPAccessDeniedError {
            return accessError.code
        }
        return "request_failed"
    }
}
