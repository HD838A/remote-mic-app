import CryptoKit
import Foundation

struct DiagnosticLogDocument: Equatable {
    let day: String
    let lines: [String]
}

enum AppLoggerError: Error {
    case invalidKey
    case invalidFileHeader
    case invalidRecord
    case invalidText
}

final class AppLogger {
    static let shared = AppLogger()

    static let maximumFileSize = 10 * 1024 * 1024
    static let retainedDayCount = 5

    let logDirectoryURL: URL

    var logURL: URL {
        logURL(for: dateProvider())
    }

    private static let fileHeader = Data("RMLG1\n".utf8)
    private static let filenamePrefix = "sayall.app-"
    private static let legacyFilenamePrefix = "runtime-"
    private static let filenameExtension = "rmlog"

    private let queue = DispatchQueue(label: "RemoteMic.logger")
    private let formatter = ISO8601DateFormatter()
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let keyDataProvider: () throws -> Data
    private let maximumFileSize: Int
    private let retainedDayCount: Int
    private let fileManager: FileManager

    private convenience init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RemoteMic", isDirectory: true)
        let keyStore = DiagnosticLogKeyStore()
        self.init(
            logDirectoryURL: base,
            keyDataProvider: { try keyStore.loadOrCreateKeyData() }
        )
    }

    init(
        logDirectoryURL: URL,
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init,
        keyDataProvider: @escaping () throws -> Data,
        maximumFileSize: Int = AppLogger.maximumFileSize,
        retainedDayCount: Int = AppLogger.retainedDayCount,
        fileManager: FileManager = .default
    ) {
        self.logDirectoryURL = logDirectoryURL
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.keyDataProvider = keyDataProvider
        self.maximumFileSize = maximumFileSize
        self.retainedDayCount = retainedDayCount
        self.fileManager = fileManager

        try? fileManager.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: logDirectoryURL.path
        )
        try? fileManager.removeItem(at: logDirectoryURL.appendingPathComponent("runtime.log"))
        migrateLegacyEncryptedLogs(referenceDate: dateProvider())
        removeExpiredLogs(referenceDate: dateProvider())
    }

    func write(_ message: String) {
        queue.async { [weak self] in
            self?.writeSynchronously(message, at: self?.dateProvider() ?? Date())
        }
    }

    func diagnosticDocuments(referenceDate: Date = Date()) throws -> [DiagnosticLogDocument] {
        try queue.sync {
            let key = try encryptionKey()
            return try [0, -1].compactMap { dayOffset in
                guard let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: referenceDate
                ) else { return nil }
                let day = dayIdentifier(for: date)
                let url = logURL(for: date)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return DiagnosticLogDocument(
                    day: day,
                    lines: try decryptedLines(from: url, day: day, key: key)
                )
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    func writeSynchronously(_ message: String, at date: Date) {
        do {
            removeExpiredLogs(referenceDate: max(date, dateProvider()))
            let day = dayIdentifier(for: date)
            let line = "\(formatter.string(from: date)) \(message)\n"
            let key = try encryptionKey()
            try appendEncryptedLine(line, day: day, key: key)
        } catch {
            return
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        let data = try keyDataProvider()
        guard data.count == 32 else { throw AppLoggerError.invalidKey }
        return SymmetricKey(data: data)
    }

    private func appendEncryptedLine(_ line: String, day: String, key: SymmetricKey) throws {
        let sealed = try AES.GCM.seal(
            Data(line.utf8),
            using: key,
            authenticating: Data(day.utf8)
        )
        guard let combined = sealed.combined,
              combined.count <= Int(UInt32.max)
        else { throw AppLoggerError.invalidRecord }

        var length = UInt32(combined.count).bigEndian
        var record = withUnsafeBytes(of: &length) { Data($0) }
        record.append(combined)

        let url = logURL(forDay: day)
        let existingSize = fileSize(at: url)
        let headerSize = existingSize == 0 ? Self.fileHeader.count : 0
        guard existingSize + headerSize + record.count <= maximumFileSize else { return }

        if existingSize == 0 {
            try Self.fileHeader.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: record)
    }

    private func decryptedLines(from url: URL, day: String, key: SymmetricKey) throws -> [String] {
        let data = try Data(contentsOf: url)
        guard data.starts(with: Self.fileHeader) else {
            throw AppLoggerError.invalidFileHeader
        }

        var lines: [String] = []
        var offset = Self.fileHeader.count
        while offset < data.count {
            guard offset + MemoryLayout<UInt32>.size <= data.count else {
                throw AppLoggerError.invalidRecord
            }
            let lengthBytes = data[offset..<(offset + MemoryLayout<UInt32>.size)]
            let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += MemoryLayout<UInt32>.size

            let recordLength = Int(length)
            guard recordLength > 0, offset + recordLength <= data.count else {
                throw AppLoggerError.invalidRecord
            }
            let combined = Data(data[offset..<(offset + recordLength)])
            offset += recordLength

            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: Data(day.utf8)
            )
            guard let line = String(data: plaintext, encoding: .utf8) else {
                throw AppLoggerError.invalidText
            }
            lines.append(line.trimmingCharacters(in: .newlines))
        }
        return lines
    }

    private func removeExpiredLogs(referenceDate: Date) {
        let retainedDays = Set((0..<retainedDayCount).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: referenceDate) else {
                return nil
            }
            return dayIdentifier(for: date)
        })
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in urls where url.pathExtension == Self.filenameExtension {
            let filename = url.deletingPathExtension().lastPathComponent
            let prefix = [Self.filenamePrefix, Self.legacyFilenamePrefix].first {
                filename.hasPrefix($0)
            }
            guard let prefix else { continue }
            let day = String(filename.dropFirst(prefix.count))
            if !retainedDays.contains(day) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func migrateLegacyEncryptedLogs(referenceDate: Date) {
        for offset in 0..<retainedDayCount {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: referenceDate) else {
                continue
            }
            let day = dayIdentifier(for: date)
            let legacyURL = logDirectoryURL.appendingPathComponent(
                "\(Self.legacyFilenamePrefix)\(day).\(Self.filenameExtension)"
            )
            let currentURL = logURL(forDay: day)
            guard fileManager.fileExists(atPath: legacyURL.path),
                  !fileManager.fileExists(atPath: currentURL.path)
            else { continue }
            try? fileManager.moveItem(at: legacyURL, to: currentURL)
        }
    }

    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    private func logURL(for date: Date) -> URL {
        logURL(forDay: dayIdentifier(for: date))
    }

    private func logURL(forDay day: String) -> URL {
        logDirectoryURL.appendingPathComponent(
            "\(Self.filenamePrefix)\(day).\(Self.filenameExtension)"
        )
    }

    private func dayIdentifier(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
