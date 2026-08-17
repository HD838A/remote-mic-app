import Foundation

private let maximumDayFileBytes: Int64 = 32 * 1024 * 1024
private let maximumTranscriptCharacters = 8_000
private let maximumApplicationKeyCharacters = 200

public struct SayAllMCPTranscriptRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: String
    public let endedAt: String
    public let localDateKey: String
    public let timeZoneIdentifier: String
    public let applicationName: String
    public let bundleIdentifier: String
    public let source: String
    public let text: String
}

public struct SayAllMCPApplicationSummary: Codable, Equatable, Sendable {
    public let applicationName: String
    public let bundleIdentifier: String
    public let recordCount: Int
    public let earliestEndedAt: String
    public let latestEndedAt: String
}

public struct SayAllMCPApplicationPage: Codable, Equatable, Sendable {
    public let applications: [SayAllMCPApplicationSummary]
    public let skippedFileCount: Int
}

public struct SayAllMCPTranscriptQuery: Equatable, Sendable {
    public var startedAtOrAfter: String?
    public var endedAtBefore: String?
    public var bundleIdentifiers: [String]?
    public var order: SayAllMCPTranscriptOrder?
    public var limit: Int?
    public var cursor: String?

    public init(
        startedAtOrAfter: String? = nil,
        endedAtBefore: String? = nil,
        bundleIdentifiers: [String]? = nil,
        order: SayAllMCPTranscriptOrder? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.startedAtOrAfter = startedAtOrAfter
        self.endedAtBefore = endedAtBefore
        self.bundleIdentifiers = bundleIdentifiers
        self.order = order
        self.limit = limit
        self.cursor = cursor
    }
}

public enum SayAllMCPTranscriptOrder: String, Codable, Sendable {
    case ascending
    case descending
}

public struct SayAllMCPTranscriptPage: Codable, Equatable, Sendable {
    public let records: [SayAllMCPTranscriptRecord]
    public let nextCursor: String?
    public let hasMore: Bool
    public let skippedFileCount: Int
}

public enum SayAllMCPHistoryError: Error, Equatable {
    case invalidLimit
    case invalidDateRange
    case invalidDate(String)
    case invalidBundleIdentifiers
    case invalidCursor
    case cursorOrderMismatch
}

public final class SayAllMCPHistoryStore: @unchecked Sendable {
    private let transcriptRoot: URL

    public init(transcriptRoot: URL) {
        self.transcriptRoot = transcriptRoot
    }

    public convenience init(paths: SayAllMCPPaths = .defaults()) {
        self.init(transcriptRoot: paths.transcriptRoot)
    }

    public func listApplications() throws -> SayAllMCPApplicationPage {
        let loaded = try loadAllRecords()
        var groups: [String: ApplicationAccumulator] = [:]
        for record in loaded.records {
            let key = record.bundleIdentifier.isEmpty ? record.applicationKey : record.bundleIdentifier
            if var group = groups[key] {
                group.count += 1
                group.earliest = min(group.earliest, record.endedAt)
                group.latest = max(group.latest, record.endedAt)
                groups[key] = group
            } else {
                groups[key] = ApplicationAccumulator(
                    applicationName: record.applicationName,
                    bundleIdentifier: record.bundleIdentifier,
                    count: 1,
                    earliest: record.endedAt,
                    latest: record.endedAt
                )
            }
        }
        let applications = groups.values.map { group in
            SayAllMCPApplicationSummary(
                applicationName: group.applicationName,
                bundleIdentifier: group.bundleIdentifier,
                recordCount: group.count,
                earliestEndedAt: Self.isoString(group.earliest),
                latestEndedAt: Self.isoString(group.latest)
            )
        }.sorted {
            if $0.latestEndedAt == $1.latestEndedAt {
                return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
            }
            return $0.latestEndedAt > $1.latestEndedAt
        }
        return SayAllMCPApplicationPage(
            applications: applications,
            skippedFileCount: loaded.skippedFileCount
        )
    }

    public func query(_ query: SayAllMCPTranscriptQuery) throws -> SayAllMCPTranscriptPage {
        let order = query.order ?? .descending
        let limit = query.limit ?? 100
        guard (1...500).contains(limit) else { throw SayAllMCPHistoryError.invalidLimit }

        let startedAt = try Self.parseOptionalDate(query.startedAtOrAfter, field: "startedAtOrAfter")
        let endedAt = try Self.parseOptionalDate(query.endedAtBefore, field: "endedAtBefore")
        if let startedAt, let endedAt, startedAt >= endedAt {
            throw SayAllMCPHistoryError.invalidDateRange
        }
        let bundleIdentifiers = try Self.normalizedBundleIdentifiers(query.bundleIdentifiers)
        let cursor = try query.cursor.map { try Self.decodeCursor($0, order: order) }
        let loaded = try loadAllRecords()
        var records = loaded.records.filter { record in
            if let startedAt, record.startedAt < startedAt { return false }
            if let endedAt, record.endedAt >= endedAt { return false }
            if let bundleIdentifiers, !bundleIdentifiers.contains(record.bundleIdentifier) {
                return false
            }
            if let cursor {
                let comparison = Self.compare(record, endedAt: cursor.endedAt, id: cursor.id)
                return order == .ascending ? comparison > 0 : comparison < 0
            }
            return true
        }
        records.sort {
            let comparison = Self.compare($0, $1)
            return order == .ascending ? comparison < 0 : comparison > 0
        }
        let selected = Array(records.prefix(limit))
        let hasMore = records.count > selected.count
        return SayAllMCPTranscriptPage(
            records: selected.map(Self.publicRecord),
            nextCursor: hasMore ? selected.last.map { Self.encodeCursor($0, order: order) } : nil,
            hasMore: hasMore,
            skippedFileCount: loaded.skippedFileCount
        )
    }

    private func loadAllRecords() throws -> LoadedHistory {
        guard FileManager.default.fileExists(atPath: transcriptRoot.path) else {
            return LoadedHistory(records: [], skippedFileCount: 0)
        }
        let rootStatus = try SayAllMCPFileSecurity.fileStatus(at: transcriptRoot)
        guard rootStatus.isDirectory, !rootStatus.isSymbolicLink else {
            throw SayAllMCPStorageError.invalidTranscriptRoot
        }

        let applications = try FileManager.default.contentsOfDirectory(
            at: transcriptRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [StoredTranscriptRecord] = []
        var skippedFileCount = 0
        for applicationDirectory in applications {
            let applicationKey = applicationDirectory.lastPathComponent
            guard Self.isSafeApplicationKey(applicationKey),
                  let status = try? SayAllMCPFileSecurity.fileStatus(at: applicationDirectory),
                  status.isDirectory,
                  !status.isSymbolicLink
            else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: applicationDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                skippedFileCount += 1
                continue
            }
            for file in files where file.pathExtension == "json" {
                let localDateKey = file.deletingPathExtension().lastPathComponent
                guard Self.isLocalDateKey(localDateKey) else { continue }
                do {
                    let status = try SayAllMCPFileSecurity.fileStatus(at: file)
                    guard status.isRegularFile,
                          !status.isSymbolicLink,
                          status.size <= maximumDayFileBytes
                    else {
                        skippedFileCount += 1
                        continue
                    }
                    let dayFile = try JSONDecoder().decode(
                        StoredTranscriptDayFile.self,
                        from: Data(contentsOf: file, options: [.mappedIfSafe])
                    )
                    guard dayFile.formatVersion == 1,
                          dayFile.applicationKey == applicationKey,
                          dayFile.localDateKey == localDateKey,
                          dayFile.applicationKey.count <= maximumApplicationKeyCharacters,
                          dayFile.applicationName.count <= 500,
                          dayFile.bundleIdentifier.count <= 500,
                          dayFile.records.allSatisfy({ Self.isValid($0, dayFile: dayFile) })
                    else {
                        skippedFileCount += 1
                        continue
                    }
                    records.append(contentsOf: dayFile.records)
                } catch {
                    skippedFileCount += 1
                }
            }
        }
        return LoadedHistory(records: records, skippedFileCount: skippedFileCount)
    }

    private static func isValid(
        _ record: StoredTranscriptRecord,
        dayFile: StoredTranscriptDayFile
    ) -> Bool {
        record.schemaVersion == 1 &&
            record.applicationKey == dayFile.applicationKey &&
            record.localDateKey == dayFile.localDateKey &&
            record.applicationKey.count <= maximumApplicationKeyCharacters &&
            !record.originalTranscript.isEmpty &&
            record.originalTranscript.count <= maximumTranscriptCharacters &&
            record.applicationName.count <= 500 &&
            record.bundleIdentifier.count <= 500 &&
            !record.timeZoneIdentifier.isEmpty &&
            record.timeZoneIdentifier.count <= 200 &&
            !record.source.isEmpty &&
            record.source.count <= 100 &&
            record.captureMethodVersion > 0 &&
            record.startedAt.timeIntervalSince1970.isFinite &&
            record.endedAt.timeIntervalSince1970.isFinite
    }

    private static func publicRecord(_ record: StoredTranscriptRecord) -> SayAllMCPTranscriptRecord {
        SayAllMCPTranscriptRecord(
            id: record.id,
            startedAt: isoString(record.startedAt),
            endedAt: isoString(record.endedAt),
            localDateKey: record.localDateKey,
            timeZoneIdentifier: record.timeZoneIdentifier,
            applicationName: record.applicationName,
            bundleIdentifier: record.bundleIdentifier,
            source: record.source,
            text: record.originalTranscript
        )
    }

    private static func compare(_ left: StoredTranscriptRecord, _ right: StoredTranscriptRecord) -> Int {
        compare(left, endedAt: right.endedAt, id: right.id)
    }

    private static func compare(_ record: StoredTranscriptRecord, endedAt: Date, id: UUID) -> Int {
        if record.endedAt != endedAt { return record.endedAt < endedAt ? -1 : 1 }
        return record.id.uuidString.compare(id.uuidString).rawValue
    }

    private static func parseOptionalDate(_ value: String?, field: String) throws -> Date? {
        guard let value else { return nil }
        guard let date = isoFormatterWithFractions.date(from: value) ?? isoFormatter.date(from: value) else {
            throw SayAllMCPHistoryError.invalidDate(field)
        }
        return date
    }

    private static func normalizedBundleIdentifiers(_ values: [String]?) throws -> Set<String>? {
        guard let values, !values.isEmpty else { return nil }
        guard values.count <= 100 else { throw SayAllMCPHistoryError.invalidBundleIdentifiers }
        let normalized = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty && $0.count <= 500 }) else {
            throw SayAllMCPHistoryError.invalidBundleIdentifiers
        }
        return Set(normalized)
    }

    private static func encodeCursor(
        _ record: StoredTranscriptRecord,
        order: SayAllMCPTranscriptOrder
    ) -> String {
        let payload = CursorPayload(v: 1, endedAt: record.endedAt, id: record.id, order: order)
        let data = try! JSONEncoder().encode(payload)
        return base64URL(data)
    }

    private static func decodeCursor(
        _ value: String,
        order: SayAllMCPTranscriptOrder
    ) throws -> CursorPayload {
        guard value.count <= 2_048,
              let data = dataFromBase64URL(value),
              let payload = try? JSONDecoder().decode(CursorPayload.self, from: data),
              payload.v == 1
        else { throw SayAllMCPHistoryError.invalidCursor }
        guard payload.order == order else { throw SayAllMCPHistoryError.cursorOrderMismatch }
        return payload
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func isSafeApplicationKey(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: ".-_")
                ).contains($0)
            }
    }

    private static func isLocalDateKey(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isoString(_ date: Date) -> String {
        isoFormatterWithFractions.string(from: date)
    }

    private static let isoFormatterWithFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct StoredTranscriptDayFile: Decodable {
    let formatVersion: Int
    let applicationKey: String
    let applicationName: String
    let bundleIdentifier: String
    let localDateKey: String
    let records: [StoredTranscriptRecord]
}

private struct StoredTranscriptRecord: Decodable {
    let schemaVersion: Int
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let localDateKey: String
    let timeZoneIdentifier: String
    let applicationKey: String
    let applicationName: String
    let bundleIdentifier: String
    let source: String
    let originalTranscript: String
    let captureMethodVersion: Int
}

private struct LoadedHistory {
    let records: [StoredTranscriptRecord]
    let skippedFileCount: Int
}

private struct ApplicationAccumulator {
    let applicationName: String
    let bundleIdentifier: String
    var count: Int
    var earliest: Date
    var latest: Date
}

private struct CursorPayload: Codable {
    let v: Int
    let endedAt: Date
    let id: UUID
    let order: SayAllMCPTranscriptOrder
}
