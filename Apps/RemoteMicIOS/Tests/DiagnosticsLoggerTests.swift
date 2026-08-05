import Foundation
import Network
import XCTest
@testable import RemoteMicIOS

final class DiagnosticsLoggerTests: XCTestCase {
    func testShareFileContainsOrderedSanitizedEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = DiagnosticsLogger(
            directoryURL: directory,
            now: { date }
        )

        logger.record("browser_state", fields: ["state": "ready\nforged_event"])
        logger.record("browser_results", fields: ["count": "0"])

        let url = try XCTUnwrap(logger.makeShareFile())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("browser_state state=ready forged_event"))
        XCTAssertTrue(text.contains("browser_results count=0"))
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "browser_state")?.lowerBound),
            try XCTUnwrap(text.range(of: "browser_results")?.lowerBound)
        )
    }

    func testLoggerRotatesWithinConfiguredFileLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticsLogger(
            directoryURL: directory,
            maxFileBytes: 96,
            maxArchivedFiles: 2
        )

        for index in 0..<12 {
            logger.record("event", fields: ["index": String(index), "value": String(repeating: "x", count: 40)])
        }
        _ = logger.makeShareFile()

        let logFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "log" }
        XCTAssertLessThanOrEqual(logFiles.count, 3)
        XCTAssertTrue(logFiles.contains { $0.lastPathComponent == "current.log" })
    }

    func testNetworkErrorsAreReducedToNonSensitiveCodes() {
        XCTAssertEqual(
            DiagnosticsLogger.networkErrorCode(.posix(.ECONNREFUSED)),
            "posix.\(POSIXErrorCode.ECONNREFUSED.rawValue)"
        )
    }
}
