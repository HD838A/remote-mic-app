import Foundation

public struct SayAllMCPAuditEvent: Codable, Equatable, Sendable {
    public let clientId: String
    public let tool: String
    public let occurredAt: Date
    public let result: String
    public let returnedRecordCount: Int?
    public let startedAtOrAfter: String?
    public let endedAtBefore: String?
    public let bundleIdentifierCount: Int?
    public let reasonCode: String?

    public init(
        clientId: String,
        tool: String,
        occurredAt: Date = Date(),
        result: String,
        returnedRecordCount: Int? = nil,
        startedAtOrAfter: String? = nil,
        endedAtBefore: String? = nil,
        bundleIdentifierCount: Int? = nil,
        reasonCode: String? = nil
    ) {
        self.clientId = clientId
        self.tool = tool
        self.occurredAt = occurredAt
        self.result = result
        self.returnedRecordCount = returnedRecordCount
        self.startedAtOrAfter = startedAtOrAfter
        self.endedAtBefore = endedAtBefore
        self.bundleIdentifierCount = bundleIdentifierCount
        self.reasonCode = reasonCode
    }
}

public final class SayAllMCPAuditLog: @unchecked Sendable {
    private let auditDirectory: URL
    private let queue = DispatchQueue(label: "SayAllMCP.audit")

    public init(accessRoot: URL) {
        auditDirectory = accessRoot.appendingPathComponent("audit", isDirectory: true)
    }

    public convenience init(paths: SayAllMCPPaths = .defaults()) {
        self.init(accessRoot: paths.accessRoot)
    }

    public func append(_ event: SayAllMCPAuditEvent) throws {
        try queue.sync {
            let encoder = JSONEncoder()
            SayAllMCPISO8601.configureEncoder(encoder)
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(event)
            guard let line = String(data: data, encoding: .utf8) else {
                throw SayAllMCPAuthorizationError.encodingFailed
            }
            let dateKey = Self.dateFormatter.string(from: event.occurredAt)
            try SayAllMCPFileSecurity.appendPrivateLine(
                line,
                directory: auditDirectory,
                file: auditDirectory.appendingPathComponent("\(dateKey).ndjson")
            )
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
