import Darwin
import Foundation
@testable import SayAllMCPKit
import Testing

@Suite("SayAll MCP history")
struct SayAllMCPHistoryStoreTests {
    @Test func listsQueriesAndPaginatesExistingTranscriptFiles() throws {
        let root = try makeHistoryFixture()
        let store = SayAllMCPHistoryStore(transcriptRoot: root)

        let applications = try store.listApplications()
        #expect(applications.skippedFileCount == 0)
        #expect(applications.applications.count == 1)
        #expect(applications.applications[0].applicationName == "Codex")
        #expect(applications.applications[0].recordCount == 2)

        let firstPage = try store.query(
            SayAllMCPTranscriptQuery(order: .descending, limit: 1)
        )
        #expect(firstPage.records.map(\.text) == ["second"])
        #expect(firstPage.hasMore)
        let cursor = try #require(firstPage.nextCursor)

        let secondPage = try store.query(
            SayAllMCPTranscriptQuery(order: .descending, limit: 1, cursor: cursor)
        )
        #expect(secondPage.records.map(\.text) == ["first"])
        #expect(!secondPage.hasMore)
        #expect(secondPage.nextCursor == nil)
        let encodedSecondPage = try JSONEncoder().encode(secondPage)
        let secondPageObject = try #require(
            JSONSerialization.jsonObject(with: encodedSecondPage) as? [String: Any]
        )
        #expect(secondPageObject["nextCursor"] is NSNull)

        #expect(throws: SayAllMCPHistoryError.cursorOrderMismatch) {
            try store.query(
                SayAllMCPTranscriptQuery(order: .ascending, limit: 1, cursor: cursor)
            )
        }
    }

    @Test func filtersByTimeAndBundleIdentifierWithoutReturningInternalFields() throws {
        let store = SayAllMCPHistoryStore(transcriptRoot: try makeHistoryFixture())
        let page = try store.query(
            SayAllMCPTranscriptQuery(
                startedAtOrAfter: "2001-01-01T00:00:10.000Z",
                bundleIdentifiers: ["com.openai.codex"],
                order: .ascending,
                limit: 50
            )
        )
        #expect(page.records.map(\.text) == ["second"])
        #expect(page.records[0].applicationName == "Codex")
        #expect(page.records[0].endedAt == "2001-01-01T00:00:20.000Z")

        let encoded = try JSONEncoder().encode(page)
        let output = String(decoding: encoded, as: UTF8.self)
        #expect(!output.contains("sessionID"))
        #expect(!output.contains("applicationKey"))
        #expect(!output.contains("captureMethodVersion"))
    }

    @Test func missingHistoryIsAnEmptyReadOnlyResult() throws {
        let store = SayAllMCPHistoryStore(
            transcriptRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString)")
        )
        #expect(try store.listApplications().applications.isEmpty)
        #expect(try store.query(SayAllMCPTranscriptQuery()).records.isEmpty)
    }

    @Test func transcriptRootRejectsSymbolicLinks() throws {
        let actualRoot = try makeHistoryFixture()
        let symbolicRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayall-mcp-history-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: symbolicRoot,
            withDestinationURL: actualRoot
        )
        let store = SayAllMCPHistoryStore(transcriptRoot: symbolicRoot)
        #expect(throws: SayAllMCPStorageError.invalidTranscriptRoot) {
            try store.listApplications()
        }
    }

    @Test(arguments: [SayAllMCPTranscriptOrder.ascending, .descending])
    func boundedSelectionPreservesTimestampTiesAcrossPages(order: SayAllMCPTranscriptOrder) throws {
        let root = try makeHistoryFixture(recordCount: 16)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SayAllMCPHistoryStore(transcriptRoot: root)
        let ascending = (1...16).map { "record-\($0)" }
        let expected = order == .ascending ? ascending : Array(ascending.reversed())
        var cursor: String?

        for offset in stride(from: 0, to: expected.count, by: 3) {
            let page = try store.query(.init(order: order, limit: 3, cursor: cursor))
            let end = min(offset + 3, expected.count)
            #expect(page.records.map(\.text) == Array(expected[offset..<end]))
            #expect(page.hasMore == (end < expected.count))
            if end < expected.count {
                let nextCursor = try #require(page.nextCursor)
                cursor = nextCursor
            } else {
                #expect(page.nextCursor == nil)
            }
        }
    }

    @Test func warmCacheRechecksChangedRemovedAndInvalidDayFiles() throws {
        let root = try makeHistoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SayAllMCPHistoryStore(transcriptRoot: root)
        let query = SayAllMCPTranscriptQuery(limit: 1)
        let file = root.appendingPathComponent("com.openai.codex-abc123/2001-01-01.json")
        let invalid = file.deletingLastPathComponent().appendingPathComponent("2001-01-02.json")
        let original = try String(contentsOf: file, encoding: .utf8)
        var originalStatus = stat()
        try #require(lstat(file.path, &originalStatus) == 0)
        #expect(try store.query(query).records.map(\.text) == ["second"])

        // An in-place edit with the same size and restored modification date must miss the cache.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(original.replacingOccurrences(of: "second", with: "update").utf8))
        try handle.close()
        let originalTimes = [originalStatus.st_atimespec, originalStatus.st_mtimespec]
        try #require(utimensat(AT_FDCWD, file.path, originalTimes, 0) == 0)
        try Data("invalid JSON".utf8).write(to: invalid)
        let updated = try store.query(query)
        #expect(updated.records.map(\.text) == ["update"])
        #expect(updated.skippedFileCount == 1)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: invalid)
        let linked = try store.query(query)
        #expect(linked.records.isEmpty)
        #expect(linked.skippedFileCount == 2)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: invalid)
        let empty = try store.listApplications()
        #expect(empty.applications.isEmpty)
        #expect(empty.skippedFileCount == 0)
    }

    private func makeHistoryFixture(recordCount: Int? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayall-mcp-history-\(UUID().uuidString)", isDirectory: true)
        let applicationKey = "com.openai.codex-abc123"
        let directory = root.appendingPathComponent(applicationKey, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let firstID = UUID()
        let secondID = UUID()
        let firstSession = UUID()
        let secondSession = UUID()
        let dayFile: [String: Any] = [
            "formatVersion": 1,
            "applicationKey": applicationKey,
            "applicationName": "Codex",
            "bundleIdentifier": "com.openai.codex",
            "localDateKey": "2001-01-01",
            "records": recordCount.map { count in
                (1...count).reversed().map { index in
                    record(
                        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
                        sessionID: UUID(),
                        startedAt: 5,
                        endedAt: 10,
                        applicationKey: applicationKey,
                        text: "record-\(index)"
                    )
                }
            } ?? [
                record(
                    id: firstID,
                    sessionID: firstSession,
                    startedAt: 5,
                    endedAt: 10,
                    applicationKey: applicationKey,
                    text: "first"
                ),
                record(
                    id: secondID,
                    sessionID: secondSession,
                    startedAt: 15,
                    endedAt: 20,
                    applicationKey: applicationKey,
                    text: "second"
                ),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: dayFile, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("2001-01-01.json"))
        return root
    }

    private func record(
        id: UUID,
        sessionID: UUID,
        startedAt: Double,
        endedAt: Double,
        applicationKey: String,
        text: String
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "id": id.uuidString.lowercased(),
            "sessionID": sessionID.uuidString.lowercased(),
            "startedAt": startedAt,
            "endedAt": endedAt,
            "localDateKey": "2001-01-01",
            "timeZoneIdentifier": "UTC",
            "applicationKey": applicationKey,
            "applicationName": "Codex",
            "bundleIdentifier": "com.openai.codex",
            "source": "bluetooth",
            "originalTranscript": text,
            "captureMethodVersion": 1,
        ]
    }
}
