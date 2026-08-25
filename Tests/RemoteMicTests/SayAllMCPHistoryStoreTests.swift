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

    @Test func audioOnlyFallbackDoesNotInvalidateTextHistory() throws {
        let root = try makeHistoryFixture(includeAudioOnlyFallback: true)
        let store = SayAllMCPHistoryStore(transcriptRoot: root)

        let applications = try store.listApplications()
        let page = try store.query(SayAllMCPTranscriptQuery())

        #expect(applications.skippedFileCount == 0)
        #expect(applications.applications.first?.recordCount == 2)
        #expect(page.records.map(\.text).sorted() == ["first", "second"])
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

    private func makeHistoryFixture(includeAudioOnlyFallback: Bool = false) throws -> URL {
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
        var records = [
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
        ]
        if includeAudioOnlyFallback {
            var fallback = record(
                id: UUID(),
                sessionID: UUID(),
                startedAt: 25,
                endedAt: 30,
                applicationKey: applicationKey,
                text: ""
            )
            fallback["transcriptStatus"] = "unavailable"
            records.append(fallback)
        }
        let dayFile: [String: Any] = [
            "formatVersion": 1,
            "applicationKey": applicationKey,
            "applicationName": "Codex",
            "bundleIdentifier": "com.openai.codex",
            "localDateKey": "2001-01-01",
            "records": records,
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
