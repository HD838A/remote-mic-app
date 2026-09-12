import Foundation
import Testing
@testable import RemoteMic

@Suite("Local transcript archive")
struct TranscriptArchiveStoreTests {
    @Test func malformedDayFileIsSkippedAndLoggedWithoutTranscriptBody() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteMicTranscriptReadFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        let applicationDirectory = root.appendingPathComponent("com.example.editor", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationDirectory, withIntermediateDirectories: true)
        try Data("private transcript body".utf8)
            .write(to: applicationDirectory.appendingPathComponent("2026-08-29.json"))
        var logs: [String] = []
        let store = TranscriptArchiveStore(rootDirectoryURL: root, log: { logs.append($0) })

        #expect(try store.loadAll().isEmpty)
        #expect(logs.contains {
            $0.contains("TRANSCRIPT ARCHIVE read_failed") &&
                $0.contains("reason=decode") &&
                $0.contains("application_key=com.example.editor") &&
                $0.contains("date=2026-08-29")
        })
        #expect(logs.allSatisfy { !$0.contains("private transcript body") })
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    @Test func allApplicationsWindowKeepsRecentWeekWhileAppViewKeepsOlderEntries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = TranscriptRecord(
            sessionID: UUID(),
            startedAt: now.addingTimeInterval(-60),
            endedAt: now.addingTimeInterval(-60),
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            source: .bluetoothRemote,
            originalTranscript: "recent"
        )
        let old = TranscriptRecord(
            sessionID: UUID(),
            startedAt: now.addingTimeInterval(-(8 * 24 * 60 * 60)),
            endedAt: now.addingTimeInterval(-(8 * 24 * 60 * 60)),
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            source: .bluetoothRemote,
            originalTranscript: "old"
        )

        #expect(
            TranscriptHistoryPresentationPolicy.visibleRecords(
                [old, recent],
                applicationKey: nil,
                now: now
            ).map(\.id) == [recent.id]
        )
        #expect(
            TranscriptHistoryPresentationPolicy.visibleRecords(
                [old, recent],
                applicationKey: old.applicationKey,
                now: now
            ).map(\.id) == [recent.id, old.id]
        )
    }

    @Test func recordsAreStoredByApplicationAndLocalDate() throws {
        let harness = try ArchiveHarness()
        let first = harness.record(
            id: UUID(),
            sessionID: UUID(),
            endedAt: Date(timeIntervalSince1970: 1_767_268_800),
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: "first"
        )
        let second = harness.record(
            id: UUID(),
            sessionID: UUID(),
            endedAt: Date(timeIntervalSince1970: 1_767_355_200),
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: "second"
        )
        let third = harness.record(
            id: UUID(),
            sessionID: UUID(),
            endedAt: Date(timeIntervalSince1970: 1_767_355_260),
            applicationName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            text: "third"
        )

        try harness.store.append(first)
        try harness.store.append(second)
        try harness.store.append(third)

        #expect(try harness.store.loadAll().map(\.id) == [third.id, second.id, first.id])
        #expect(harness.fileExists(for: first))
        #expect(harness.fileExists(for: second))
        #expect(harness.fileExists(for: third))
        #expect(harness.dayFileURL(for: first) != harness.dayFileURL(for: second))
        #expect(
            harness.dayFileURL(for: second).deletingLastPathComponent() !=
                harness.dayFileURL(for: third).deletingLastPathComponent()
        )
        #expect(try harness.permissions(at: harness.dayFileURL(for: first)) == 0o600)
        #expect(try harness.permissions(
            at: harness.dayFileURL(for: first).deletingLastPathComponent()
        ) == 0o700)
    }

    @Test func deletingOneRecordArchivesTheOriginalFileBeforeRewriting() throws {
        let harness = try ArchiveHarness()
        let first = harness.record(id: UUID(), sessionID: UUID(), text: "first")
        let second = harness.record(id: UUID(), sessionID: UUID(), text: "second")
        try harness.store.append(first)
        try harness.store.append(second)

        try harness.store.deleteRecord(id: first.id)

        #expect(try harness.store.loadAll().map(\.id) == [second.id])
        #expect(harness.trashedItems.count == 1)
        #expect(harness.trashedItems.first?.lastPathComponent.hasSuffix(".json") == true)
    }

    @Test func deletingAnApplicationOrEverythingMovesDirectoriesToTrash() throws {
        let harness = try ArchiveHarness()
        let notes = harness.record(
            id: UUID(),
            sessionID: UUID(),
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            text: "notes"
        )
        let messages = harness.record(
            id: UUID(),
            sessionID: UUID(),
            applicationName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            text: "messages"
        )
        try harness.store.append(notes)
        try harness.store.append(messages)

        try harness.store.deleteApplication(applicationKey: notes.applicationKey)
        #expect(try harness.store.loadAll().map(\.id) == [messages.id])
        #expect(harness.trashedItems.count == 1)

        try harness.store.deleteAll()
        #expect(try harness.store.loadAll().isEmpty)
        #expect(harness.trashedItems.count == 2)
    }

    @Test func historySwitchDefaultsOffAndPersistsWithoutTranscriptTextInDefaults() throws {
        let suiteName = "RemoteMicTests.TranscriptHistory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.localTranscriptHistoryEnabled)
        settings.localTranscriptHistoryEnabled = true

        let restored = AppSettings(defaults: defaults)
        #expect(restored.localTranscriptHistoryEnabled)
        #expect(defaults.dictionaryRepresentation().values.allSatisfy {
            !String(describing: $0).contains("private transcript body")
        })
    }

    @Test func applicationDeletionRejectsPathsOutsideTheArchiveRoot() throws {
        let harness = try ArchiveHarness()
        let outsideURL = harness.rootURL.deletingLastPathComponent()
            .appendingPathComponent("outside-sentinel")
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )

        do {
            try harness.store.deleteApplication(applicationKey: "../outside-sentinel")
            Issue.record("Unsafe application key should be rejected")
        } catch TranscriptArchiveStoreError.invalidRecord {
            #expect(FileManager.default.fileExists(atPath: outsideURL.path))
            #expect(harness.trashedItems.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func disablingAfterUseKeepsExistingHistory() throws {
        let harness = try ArchiveHarness()
        let record = harness.record(
            id: UUID(),
            sessionID: UUID(),
            text: "kept after disabling"
        )
        try harness.store.append(record)
        let suiteName = "RemoteMicTests.TranscriptHistoryAfterUse.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.localTranscriptHistoryEnabled = true
        settings.localTranscriptHistoryEnabled = false

        #expect(!AppSettings(defaults: defaults).localTranscriptHistoryEnabled)
        #expect(try harness.store.loadAll().map(\.id) == [record.id])
    }
}

private final class ArchiveHarness {
    let rootURL: URL
    let trashURL: URL
    lazy var store = TranscriptArchiveStore(
        rootDirectoryURL: rootURL,
        fileManager: fileManager,
        trashItem: { [unowned self] sourceURL in
            try fileManager.createDirectory(
                at: trashURL,
                withIntermediateDirectories: true
            )
            let destinationURL = trashURL.appendingPathComponent(
                "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
            )
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            trashedItems.append(destinationURL)
        }
    )
    private(set) var trashedItems: [URL] = []
    private let fileManager = FileManager.default
    private var calendar: Calendar

    init() throws {
        let identifier = UUID().uuidString
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("RemoteMicTranscriptArchiveTests-\(identifier)")
            .appendingPathComponent("archive")
        trashURL = fileManager.temporaryDirectory
            .appendingPathComponent("RemoteMicTranscriptArchiveTests-\(identifier)")
            .appendingPathComponent("trash")
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    }

    func record(
        id: UUID,
        sessionID: UUID,
        endedAt: Date = Date(timeIntervalSince1970: 1_767_268_800),
        applicationName: String = "Notes",
        bundleIdentifier: String = "com.apple.Notes",
        text: String
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            sessionID: sessionID,
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            source: .bluetoothRemote,
            originalTranscript: text,
            calendar: calendar
        )
    }

    func dayFileURL(for record: TranscriptRecord) -> URL {
        rootURL
            .appendingPathComponent(record.applicationKey)
            .appendingPathComponent(record.localDateKey)
            .appendingPathExtension("json")
    }

    func fileExists(for record: TranscriptRecord) -> Bool {
        fileManager.fileExists(atPath: dayFileURL(for: record).path)
    }

    func permissions(at url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }
}
