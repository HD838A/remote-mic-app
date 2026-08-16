import Foundation
import Testing
@testable import RemoteMic

@Suite("User initiated diagnostic upload")
struct DiagnosticLogUploaderTests {
    private let key = Data(repeating: 0x5B, count: 32)
    private let dsn = "https://public@example.ingest.sentry.io/123"

    @Test func sendsOnlyTodayAndYesterdayAfterSanitizingSensitiveValues() throws {
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
        logger.writeSynchronously(
            "listener name=Andy's MacBook email=owner@example.com id=123E4567-E89B-12D3-A456-426614174000",
            at: today
        )
        logger.writeSynchronously(
            "yesterday 192.168.1.8",
            at: try #require(calendar.date(byAdding: .day, value: -1, to: today))
        )
        logger.writeSynchronously(
            "older must not upload",
            at: try #require(calendar.date(byAdding: .day, value: -2, to: today))
        )

        var sentEntries: [DiagnosticLogEntry] = []
        let uploader = DiagnosticLogUploader(
            logger: logger,
            sanitizer: DiagnosticLogSanitizer(
                additionalSensitiveValues: ["Andy's MacBook"]
            ),
            dsnProvider: { dsn },
            sender: { entries, receivedDSN in
                #expect(receivedDSN == dsn)
                sentEntries = entries
            },
            dateProvider: { today }
        )

        #expect(uploader.uploadSynchronously() == .success(2))
        #expect(Set(sentEntries.map(\.day)) == ["2026-08-15", "2026-08-14"])
        let body = sentEntries.map(\.message).joined(separator: "\n")
        #expect(body.contains("<redacted>"))
        #expect(body.contains("<redacted-email>"))
        #expect(body.contains("<redacted-uuid>"))
        #expect(body.contains("<redacted-ip>"))
        #expect(!body.contains("Andy's MacBook"))
        #expect(!body.contains("older must not upload"))
    }

    @Test func doesNotInvokeSenderWithoutConfiguredService() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(
            logDirectoryURL: directory,
            keyDataProvider: { key }
        )
        logger.writeSynchronously("local only", at: Date())
        var sendCount = 0
        let uploader = DiagnosticLogUploader(
            logger: logger,
            dsnProvider: { nil },
            sender: { _, _ in sendCount += 1 }
        )

        #expect(uploader.uploadSynchronously() == .failure(.serviceNotConfigured))
        #expect(sendCount == 0)
    }

    @Test func usesOfficialSentrySDKWithAutomaticTelemetryDisabled() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/RemoteMic/DiagnosticLogUploader.swift"))

        #expect(source.contains("import Sentry"))
        #expect(source.contains("SentrySDK.start"))
        #expect(source.contains("SentrySDK.logger"))
        #expect(source.contains("options.enableCrashHandler = false"))
        #expect(source.contains("options.enableAutoSessionTracking = false"))
        #expect(source.contains("options.enableAutoPerformanceTracing = false"))
        #expect(source.contains("options.cacheDirectoryPath = cacheDirectory.path"))
        #expect(source.contains("hasPendingSentryEnvelopes"))
        #expect(!source.contains("URLRequest("))
        #expect(!source.contains("SentryLogEnvelope"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMic-DiagnosticUploadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
