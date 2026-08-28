import Foundation

struct TranscriptRecord: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

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
    let source: UsageEventSource
    let originalTranscript: String
    let captureMethodVersion: Int

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        applicationName: String,
        bundleIdentifier: String,
        source: UsageEventSource,
        originalTranscript: String,
        calendar: Calendar = .current
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        localDateKey = Self.localDateKey(for: endedAt, calendar: calendar)
        timeZoneIdentifier = calendar.timeZone.identifier
        applicationKey = TranscriptArchiveStore.applicationKey(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.source = source
        self.originalTranscript = originalTranscript
        captureMethodVersion = 1
    }

    private static func localDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private struct TranscriptDayFile: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let applicationKey: String
    let applicationName: String
    let bundleIdentifier: String
    let localDateKey: String
    var records: [TranscriptRecord]
}

enum TranscriptArchiveStoreError: Error {
    case unsupportedFormat
    case invalidRecord
}

final class TranscriptArchiveStore {
    typealias Logger = (String) -> Void

    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let trashItem: (URL) throws -> Void
    private let log: Logger
    private let queue = DispatchQueue(label: "RemoteMic.transcriptArchive")

    init(
        rootDirectoryURL: URL = TranscriptArchiveStore.defaultRootDirectoryURL(),
        fileManager: FileManager = .default,
        trashItem: ((URL) throws -> Void)? = nil,
        log: @escaping Logger = AppLogger.shared.write
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.fileManager = fileManager
        self.trashItem = trashItem ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
        self.log = log
    }

    func append(_ record: TranscriptRecord) throws {
        try queue.sync {
            guard record.schemaVersion == TranscriptRecord.currentSchemaVersion,
                  !record.originalTranscript.isEmpty,
                  Self.isSafePathComponent(record.applicationKey),
                  Self.isLocalDateKey(record.localDateKey)
            else { throw TranscriptArchiveStoreError.invalidRecord }

            let fileURL = dayFileURL(
                applicationKey: record.applicationKey,
                localDateKey: record.localDateKey
            )
            var dayFile = try loadDayFileIfPresent(at: fileURL) ?? TranscriptDayFile(
                formatVersion: TranscriptDayFile.currentFormatVersion,
                applicationKey: record.applicationKey,
                applicationName: record.applicationName,
                bundleIdentifier: record.bundleIdentifier,
                localDateKey: record.localDateKey,
                records: []
            )
            guard dayFile.formatVersion == TranscriptDayFile.currentFormatVersion,
                  dayFile.applicationKey == record.applicationKey,
                  dayFile.localDateKey == record.localDateKey
            else { throw TranscriptArchiveStoreError.unsupportedFormat }
            guard !dayFile.records.contains(where: { $0.id == record.id }) else { return }
            dayFile.records.append(record)
            dayFile.records.sort { $0.endedAt < $1.endedAt }
            try write(dayFile, to: fileURL)
        }
    }

    func loadAll() throws -> [TranscriptRecord] {
        try queue.sync {
            guard fileManager.fileExists(atPath: rootDirectoryURL.path) else { return [] }
            var records: [TranscriptRecord] = []
            for applicationDirectory in try directoryContents(at: rootDirectoryURL) {
                let applicationKey = applicationDirectory.lastPathComponent
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: applicationDirectory.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue,
                    Self.isSafePathComponent(applicationKey)
                else { continue }
                for fileURL in try directoryContents(at: applicationDirectory)
                    where fileURL.pathExtension == "json"
                {
                    let localDateKey = fileURL.deletingPathExtension().lastPathComponent
                    guard Self.isLocalDateKey(localDateKey) else {
                        log(
                            "TRANSCRIPT ARCHIVE read_skipped reason=invalid_date " +
                                "application_key=\(applicationKey)"
                        )
                        continue
                    }
                    let dayFile: TranscriptDayFile
                    do {
                        dayFile = try loadDayFile(at: fileURL)
                    } catch {
                        log(
                            "TRANSCRIPT ARCHIVE read_failed reason=decode " +
                                "application_key=\(applicationKey) date=\(localDateKey) " +
                                AppLogger.errorFields(error)
                        )
                        continue
                    }
                    guard dayFile.formatVersion == TranscriptDayFile.currentFormatVersion else {
                        log(
                            "TRANSCRIPT ARCHIVE read_skipped reason=unsupported_format " +
                                "application_key=\(applicationKey) date=\(localDateKey)"
                        )
                        continue
                    }
                    guard dayFile.applicationKey == applicationKey else {
                        log(
                            "TRANSCRIPT ARCHIVE read_skipped reason=application_key_mismatch " +
                                "application_key=\(applicationKey) date=\(localDateKey)"
                        )
                        continue
                    }
                    guard dayFile.localDateKey == localDateKey else {
                        log(
                            "TRANSCRIPT ARCHIVE read_skipped reason=date_mismatch " +
                                "application_key=\(applicationKey) date=\(localDateKey)"
                        )
                        continue
                    }
                    let validRecords = dayFile.records.filter {
                        $0.schemaVersion == TranscriptRecord.currentSchemaVersion &&
                            $0.applicationKey == applicationKey &&
                            $0.localDateKey == localDateKey
                    }
                    if validRecords.count != dayFile.records.count {
                        log(
                            "TRANSCRIPT ARCHIVE records_skipped reason=invalid_record " +
                                "application_key=\(applicationKey) date=\(localDateKey) " +
                                "count=\(dayFile.records.count - validRecords.count)"
                        )
                    }
                    records.append(contentsOf: validRecords)
                }
            }
            return records.sorted { $0.endedAt > $1.endedAt }
        }
    }

    func deleteRecord(id: UUID) throws {
        try queue.sync {
            for fileURL in try allDayFileURLs() {
                guard var dayFile = try? loadDayFile(at: fileURL) else { continue }
                let previousCount = dayFile.records.count
                dayFile.records.removeAll { $0.id == id }
                guard dayFile.records.count != previousCount else { continue }
                try trashItem(fileURL)
                if dayFile.records.isEmpty {
                    return
                } else {
                    try write(dayFile, to: fileURL)
                }
                return
            }
        }
    }

    func deleteApplication(applicationKey: String) throws {
        try queue.sync {
            guard Self.isSafePathComponent(applicationKey) else {
                throw TranscriptArchiveStoreError.invalidRecord
            }
            let directoryURL = applicationDirectoryURL(applicationKey: applicationKey)
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            try trashItem(directoryURL)
        }
    }

    func deleteAll() throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: rootDirectoryURL.path) else { return }
            try trashItem(rootDirectoryURL)
        }
    }

    static func applicationKey(bundleIdentifier: String, applicationName: String) -> String {
        let identity = bundleIdentifier.isEmpty ? applicationName : bundleIdentifier
        let sanitized = identity.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar) {
                return Character(String(scalar))
            }
            return "_"
        }
        let visiblePrefix = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let prefix = visiblePrefix.isEmpty ? "unknown" : String(visiblePrefix.prefix(80))
        return "\(prefix)-\(String(stableHash(identity), radix: 16))"
    }

    private func allDayFileURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: rootDirectoryURL.path) else { return [] }
        return try directoryContents(at: rootDirectoryURL).flatMap { applicationDirectory in
            (try? directoryContents(at: applicationDirectory))?.filter {
                $0.pathExtension == "json"
            } ?? []
        }
    }

    private func directoryContents(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private func loadDayFileIfPresent(at url: URL) throws -> TranscriptDayFile? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try loadDayFile(at: url)
    }

    private func loadDayFile(at url: URL) throws -> TranscriptDayFile {
        let dayFile = try JSONDecoder().decode(
            TranscriptDayFile.self,
            from: Data(contentsOf: url)
        )
        guard dayFile.formatVersion == TranscriptDayFile.currentFormatVersion else {
            throw TranscriptArchiveStoreError.unsupportedFormat
        }
        return dayFile
    }

    private func write(_ dayFile: TranscriptDayFile, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectoryURL.path
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(dayFile).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func applicationDirectoryURL(applicationKey: String) -> URL {
        rootDirectoryURL.appendingPathComponent(applicationKey, isDirectory: true)
    }

    private func dayFileURL(applicationKey: String, localDateKey: String) -> URL {
        applicationDirectoryURL(applicationKey: applicationKey)
            .appendingPathComponent(localDateKey)
            .appendingPathExtension("json")
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isLocalDateKey(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func defaultRootDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteMic", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}
