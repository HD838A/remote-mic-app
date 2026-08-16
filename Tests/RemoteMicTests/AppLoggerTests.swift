import Foundation
import Testing
@testable import RemoteMic

@Suite("Encrypted app logger")
struct AppLoggerTests {
    private let key = Data(repeating: 0x4A, count: 32)

    @Test func writesEncryptedDailyFilesAndDecryptsOnlyTodayAndYesterday() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 15,
            hour: 12
        )))
        let logger = AppLogger(
            logDirectoryURL: directory,
            calendar: calendar,
            dateProvider: { today },
            keyDataProvider: { key }
        )

        logger.writeSynchronously("TODAY secret diagnostic", at: today)
        logger.writeSynchronously(
            "YESTERDAY diagnostic",
            at: try #require(calendar.date(byAdding: .day, value: -1, to: today))
        )
        logger.writeSynchronously(
            "OLDER diagnostic",
            at: try #require(calendar.date(byAdding: .day, value: -2, to: today))
        )

        let rawToday = try Data(contentsOf: directory.appendingPathComponent(
            "sayall.app-2026-08-15.rmlog"
        ))
        #expect(!String(decoding: rawToday, as: UTF8.self).contains("TODAY secret diagnostic"))
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        let filePermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("sayall.app-2026-08-15.rmlog").path
            )[.posixPermissions] as? NSNumber
        )
        #expect(directoryPermissions.intValue & 0o777 == 0o700)
        #expect(filePermissions.intValue & 0o777 == 0o600)

        let documents = try logger.diagnosticDocuments(referenceDate: today)
        #expect(documents.map(\.day) == ["2026-08-15", "2026-08-14"])
        #expect(documents[0].lines.count == 1)
        #expect(documents[0].lines[0].contains("TODAY secret diagnostic"))
        #expect(documents[1].lines[0].contains("YESTERDAY diagnostic"))
        #expect(!documents.flatMap(\.lines).contains { $0.contains("OLDER diagnostic") })
    }

    @Test func retainsAtMostFiveCalendarDays() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 15,
            hour: 12
        )))
        let logger = AppLogger(
            logDirectoryURL: directory,
            calendar: calendar,
            dateProvider: { today },
            keyDataProvider: { key }
        )

        for offset in (-6)...0 {
            let date = try #require(calendar.date(byAdding: .day, value: offset, to: today))
            logger.writeSynchronously("day offset \(offset)", at: date)
        }
        logger.writeSynchronously("trigger cleanup", at: today)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "rmlog" }
        #expect(files.count == 5)
        #expect(files.contains { $0.lastPathComponent == "sayall.app-2026-08-11.rmlog" })
        #expect(!files.contains { $0.lastPathComponent == "sayall.app-2026-08-10.rmlog" })
    }

    @Test func neverGrowsDailyFilePastConfiguredLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 15,
            hour: 12
        )))
        let logger = AppLogger(
            logDirectoryURL: directory,
            calendar: calendar,
            dateProvider: { today },
            keyDataProvider: { key },
            maximumFileSize: 512
        )

        for index in 0..<100 {
            logger.writeSynchronously("entry \(index) \(String(repeating: "x", count: 80))", at: today)
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("sayall.app-2026-08-15.rmlog").path
        )
        let size = try #require(attributes[.size] as? NSNumber)
        #expect(size.intValue <= 512)
        #expect(try logger.diagnosticDocuments(referenceDate: today)[0].lines.count < 100)
    }

    @Test func removesLegacyPlaintextLogOnInitialization() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("runtime.log")
        try Data("legacy plaintext".utf8).write(to: legacy)

        _ = AppLogger(
            logDirectoryURL: directory,
            keyDataProvider: { key }
        )

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func migratesRecentRuntimeEncryptedFileToSayAllPrefix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 15,
            hour: 12
        )))
        let source = AppLogger(
            logDirectoryURL: directory,
            calendar: calendar,
            dateProvider: { today },
            keyDataProvider: { key }
        )
        source.writeSynchronously("legacy encrypted entry", at: today)
        let currentURL = directory.appendingPathComponent("sayall.app-2026-08-15.rmlog")
        let legacyURL = directory.appendingPathComponent("runtime-2026-08-15.rmlog")
        try FileManager.default.moveItem(at: currentURL, to: legacyURL)

        let migrated = AppLogger(
            logDirectoryURL: directory,
            calendar: calendar,
            dateProvider: { today },
            keyDataProvider: { key }
        )

        #expect(FileManager.default.fileExists(atPath: currentURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try migrated.diagnosticDocuments(referenceDate: today)[0].lines[0]
            .contains("legacy encrypted entry"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMic-AppLoggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
