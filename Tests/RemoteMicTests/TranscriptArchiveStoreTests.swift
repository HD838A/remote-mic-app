import Foundation
import Testing
@testable import RemoteMic

@Suite("Local transcript archive")
struct TranscriptArchiveStoreTests {
    @Test func mixedHistoryHasUniqueDescendingDaysAndInterleavedEntries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10)))
        func record(day: Int, hour: Int) -> TranscriptRecord {
            let end = today.addingTimeInterval(Double(day * 86_400 + hour * 3_600))
            return TranscriptRecord(sessionID: UUID(), startedAt: end, endedAt: end,
                applicationName: "Notes", bundleIdentifier: "com.apple.Notes",
                source: .bluetoothRemote, originalTranscript: "fixture", calendar: calendar)
        }
        func asset(day: Int, hour: Int, sessionID: UUID = UUID()) -> RecordingAssetManifest {
            let reference = record(day: day, hour: hour)
            return RecordingAssetManifest(schemaVersion: 1, id: UUID(), sessionID: sessionID,
                startedAt: reference.startedAt, endedAt: reference.endedAt,
                localDateKey: reference.localDateKey, timeZoneIdentifier: reference.timeZoneIdentifier,
                source: .bluetoothRemote, applicationKey: reference.applicationKey,
                applicationName: reference.applicationName, bundleIdentifier: reference.bundleIdentifier,
                relativeMediaPath: "fixture.m4a", durationMilliseconds: 1_000,
                byteCount: 0, sha256: "", format: "m4a")
        }
        let text = record(day: 0, hour: 12)
        let olderText = record(day: -2, hour: 12)
        let oldText = record(day: -8, hour: 12)
        let newestAudio = asset(day: 0, hour: 13)
        let earlierAudio = asset(day: 0, hour: 11)
        let yesterdayAudio = asset(day: -1, hour: 12)
        let oldAudio = asset(day: -8, hour: 13)
        let linkedAudio = asset(day: 0, hour: 12, sessionID: text.sessionID)
        let records = [olderText, oldText, text]
        let assets = [earlierAudio, linkedAudio, oldAudio, yesterdayAudio, newestAudio]
        let now = today.addingTimeInterval(14 * 3_600)
        let groups = TranscriptHistoryPresentationPolicy.dayGroups(
            records: records, assets: assets, applicationKey: nil, now: now)
        #expect(groups.map(\.id) == ["2026-10-10", "2026-10-09", "2026-10-08"])
        #expect(groups[0].entries.map(\.id) == [newestAudio.sessionID, text.sessionID, earlierAudio.sessionID])
        #expect(groups.flatMap(\.entries).count == 5)
        let appGroups = TranscriptHistoryPresentationPolicy.dayGroups(
            records: records, assets: assets, applicationKey: text.applicationKey, now: now)
        #expect(appGroups.last?.id == "2026-10-02")
        #expect(appGroups.last?.entries.map(\.id) == [oldAudio.sessionID, oldText.sessionID])
        #expect(TranscriptHistoryPresentationPolicy.dayGroups(
            records: records, assets: assets, applicationKey: "missing", now: now).isEmpty)
    }

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
