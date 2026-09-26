import Foundation

struct PrivateDiagnosticUploadRecord: Equatable, Sendable {
    static let schemaVersion = 1

    let recordID: String
    let occurredAt: Date
    let category: String
    let fields: [String: String]

    init?(
        recordID: String,
        occurredAt: Date,
        category: String,
        fields: [String: String]
    ) {
        let occurredAtMS = Int64(occurredAt.timeIntervalSince1970 * 1_000)
        guard occurredAtMS >= 0,
              Self.matches(recordID, pattern: #"^[a-z]{2}_[A-Za-z0-9_-]{20,64}$"#),
              Self.matches(category, pattern: #"^[A-Z][A-Z0-9_]{0,63}$"#),
              !fields.isEmpty,
              fields.count <= 32,
              fields.keys.allSatisfy({ !Self.reservedFieldNames.contains($0) }),
              fields.allSatisfy({ Self.isValid(field: $0.key, value: $0.value) })
        else { return nil }
        self.recordID = recordID
        self.occurredAt = Date(timeIntervalSince1970: Double(occurredAtMS) / 1_000)
        self.category = category
        self.fields = fields
    }

    var canonicalLine: String {
        let prefix = [
            "PRIVATE_EVENT",
            "schema_version=\(Self.schemaVersion)",
            "record_id=\(recordID)",
            "occurred_at_ms=\(Int64(occurredAt.timeIntervalSince1970 * 1_000))",
            "category=\(category)",
        ]
        let payload = fields.keys.sorted().compactMap { key in
            fields[key].map { "\(key)=\($0)" }
        }
        return (prefix + payload).joined(separator: " ")
    }

    static func parse(_ line: String) -> PrivateDiagnosticUploadRecord? {
        guard line.count <= 4_096,
              !line.contains("\n"),
              !line.contains("\r") else { return nil }
        let segments = line.split(separator: " ", omittingEmptySubsequences: true)
        guard segments.first == "PRIVATE_EVENT" else { return nil }
        var values: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0])
            guard values[key] == nil else { return nil }
            values[key] = String(pair[1])
        }
        guard values.removeValue(forKey: "schema_version") == String(schemaVersion),
              let recordID = values.removeValue(forKey: "record_id"),
              let occurredValue = values.removeValue(forKey: "occurred_at_ms"),
              let occurredMS = Int64(occurredValue),
              occurredMS >= 0,
              let category = values.removeValue(forKey: "category"),
              let record = PrivateDiagnosticUploadRecord(
                  recordID: recordID,
                  occurredAt: Date(timeIntervalSince1970: Double(occurredMS) / 1_000),
                  category: category,
                  fields: values
              ),
              record.canonicalLine == line
        else { return nil }
        return record
    }

    private static func isValid(field: String, value: String) -> Bool {
        guard matches(field, pattern: #"^[a-z][a-z0-9_]{0,63}$"#),
              !forbiddenFieldNames.contains(field) else { return false }
        if field.hasSuffix("operation_id") {
            return value == "none" || matches(value, pattern: #"^op_[A-Za-z0-9_-]{20,64}$"#)
        }
        if field.hasSuffix("client_flow_id") {
            return value == "none" || matches(value, pattern: #"^cf_[A-Za-z0-9_-]{20,64}$"#)
        }
        if field.hasSuffix("support_trace_id") {
            return value == "none" || matches(value, pattern: #"^st_[A-Za-z0-9_-]{20,64}$"#)
        }
        if field.hasSuffix("request_id") {
            return value == "none" || matches(value, pattern: #"^rq_[A-Za-z0-9_-]{20,64}$"#)
        }
        if field == "sequence" || field == "attempt" || field.hasSuffix("_count") || field.hasSuffix("_ms") {
            guard let integer = UInt64(value) else { return false }
            return integer <= 10_000_000_000
        }
        return matches(value, pattern: #"^[A-Za-z0-9_.-]{1,64}$"#)
    }

    private static let forbiddenFieldNames: Set<String> = [
        "email", "token", "cookie", "password", "secret", "url", "path", "bundle_id",
        "package", "hostname", "ip", "device_name", "user_id", "account_id", "order_id",
        "product_id", "provider_id", "price", "currency", "expires_at", "message", "error",
    ]

    private static let reservedFieldNames: Set<String> = [
        "schema_version", "record_id", "occurred_at_ms", "category",
    ]

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

protocol PrivateDiagnosticUploadProvider: AnyObject, Sendable {
    func pendingPrivateDiagnosticRecords() async -> [PrivateDiagnosticUploadRecord]
    func markPrivateDiagnosticRecordsUploaded(_ recordIDs: Set<String>) async
}
