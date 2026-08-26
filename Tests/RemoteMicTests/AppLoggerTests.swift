import Foundation
import Testing
@testable import RemoteMic

@Suite("App logger")
struct AppLoggerTests {
    @Test func writesStableProcessAndBuildMetadataAfterTheUTCTimestamp() throws {
        let harness = try LoggerHarness(
            metadata: AppLogger.Metadata(
                processID: 4_242,
                version: "1.9 beta",
                build: "121 rc"
            )
        )

        harness.logger.write("APP START")
        harness.logger.flush()

        #expect(try harness.currentLog() ==
            "2001-01-01T00:00:00.000Z pid=4242 ver=1.9_beta build=121_rc APP START\n"
        )
    }

    @Test func normalizesControlsAndLineSeparatorsIntoOneValidUTF8Line() throws {
        let harness = try LoggerHarness()

        harness.logger.write("first\nsecond\rthird\tfourth\u{0000}中文\u{2028}last")
        harness.logger.flush()

        let data = try Data(contentsOf: harness.logURL)
        let output = try #require(String(data: data, encoding: .utf8))
        let message = try #require(output.split(separator: " ", maxSplits: 4).last)
        #expect(message == "first second third fourth 中文 last\n")
        #expect(output.filter { $0 == "\n" }.count == 1)
    }

    @Test func errorFieldsUseStableDomainAndNumericCode() {
        let error = NSError(domain: "com.example failure\n", code: -17)

        #expect(AppLogger.errorFields(error) ==
            "error_domain=com.example_failure_ error_code=-17"
        )
        #expect(AppLogger.optionalErrorFields(nil) ==
            "error_domain=none error_code=0"
        )
        #expect(AppLogger.errorFields(domain: "os status", code: -50) ==
            "error_domain=os_status error_code=-50"
        )
        #expect(AppLogger.errorFields(
            domain: "io_return",
            code: -536_870_203,
            fieldPrefix: "seize error"
        ) == "seize_error_domain=io_return seize_error_code=-536870203")
    }

    @Test func sharedLoggerIsDisabledForXCTestAndSwiftTestingProcesses() {
        #expect(!AppLogger.shouldEnableSharedLogging(
            arguments: ["/tmp/RemoteMicPackageTests.xctest/Contents/MacOS/RemoteMicPackageTests"],
            environment: [:]
        ))
        #expect(!AppLogger.shouldEnableSharedLogging(
            arguments: ["/tmp/RemoteMicPackageTests"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test-configuration"]
        ))
        #expect(AppLogger.shouldEnableSharedLogging(
            arguments: ["/Applications/SayAll.app/Contents/MacOS/RemoteMic"],
            environment: [:]
        ))
        #expect(!AppLogger.shared.isEnabled)
    }

    @Test func concurrentLoggerInstancesAppendWholeUTF8Lines() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SayAllAppLoggerConcurrent-\(UUID().uuidString)")
            .appendingPathComponent("runtime.log")
        let firstLogger = AppLogger(
            logURL: logURL,
            metadata: AppLogger.Metadata(processID: 101, version: "1.9.0", build: "121")
        )
        let secondLogger = AppLogger(
            logURL: logURL,
            metadata: AppLogger.Metadata(processID: 202, version: "1.9.1", build: "122")
        )

        for index in 0 ..< 1_000 {
            let logger = index.isMultiple(of: 2) ? firstLogger : secondLogger
            logger.write("event=\(index)-中文")
        }
        firstLogger.flush()
        secondLogger.flush()

        let data = try Data(contentsOf: logURL)
        let output = try #require(String(data: data, encoding: .utf8))
        let lines = output.split(separator: "\n")
        let events = lines.compactMap { line -> Substring? in
            guard let range = line.range(of: " event=") else { return nil }
            return line[range.upperBound...]
        }
        #expect(lines.count == 1_000)
        #expect(events.count == 1_000)
        #expect(Set(events).count == 1_000)
    }

    @Test func fifthOversizedWriteKeepsCurrentThreeArchivesAndRecoverableRetiredFile() throws {
        let harness = try LoggerHarness(maximumFileSize: 1)

        for index in 1 ... 5 {
            harness.logger.write("message-\(index)")
        }
        harness.logger.flush()

        #expect(try harness.currentLog().contains("message-5"))
        #expect(try harness.archive(1).contains("message-4"))
        #expect(try harness.archive(2).contains("message-3"))
        #expect(try harness.archive(3).contains("message-2"))
        #expect(harness.retiredURLs.count == 1)
        #expect(try String(contentsOf: harness.retiredURLs[0], encoding: .utf8)
            .contains("message-1"))
    }

    @Test func failedRetirementPreservesArchivesAndContinuesAppendingCurrentLog() throws {
        let harness = try LoggerHarness(
            maximumFileSize: 1,
            retirementHandler: { _ in throw RetirementFailure.expected }
        )

        for index in 1 ... 5 {
            harness.logger.write("message-\(index)")
        }
        harness.logger.flush()

        let current = try harness.currentLog()
        #expect(current.contains("message-4"))
        #expect(current.contains("message-5"))
        #expect(try harness.archive(3).contains("message-1"))
        #expect(harness.failures.contains {
            $0.contains("archive_retirement_failed")
        })
    }
}

private enum RetirementFailure: Error {
    case expected
}

private final class LoggerHarness {
    let logURL: URL
    let logger: AppLogger
    var retiredURLs: [URL] { retiredURLsProvider() }
    var failures: [String] { failuresProvider() }

    private let retiredURLsProvider: () -> [URL]
    private let failuresProvider: () -> [String]

    init(
        metadata: AppLogger.Metadata = AppLogger.Metadata(
            processID: 99,
            version: "1.9.0",
            build: "121"
        ),
        maximumFileSize: UInt64 = 10 * 1_024 * 1_024,
        retirementHandler: AppLogger.RetirementHandler? = nil
    ) throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("SayAllAppLoggerTests-\(UUID().uuidString)", isDirectory: true)
        let retiredDirectoryURL = rootURL.appendingPathComponent(
            "retired",
            isDirectory: true
        )
        logURL = rootURL.appendingPathComponent("runtime.log")

        var capturedRetiredURLs: [URL] = []
        var capturedFailures: [String] = []
        retiredURLsProvider = { capturedRetiredURLs }
        failuresProvider = { capturedFailures }
        logger = AppLogger(
            logURL: logURL,
            metadata: metadata,
            maximumFileSize: maximumFileSize,
            retirementHandler: retirementHandler ?? { sourceURL in
                try fileManager.createDirectory(
                    at: retiredDirectoryURL,
                    withIntermediateDirectories: true
                )
                let destinationURL = retiredDirectoryURL.appendingPathComponent(
                    "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
                )
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                capturedRetiredURLs.append(destinationURL)
            },
            now: { Date(timeIntervalSinceReferenceDate: 0) },
            reportFailure: { capturedFailures.append($0) }
        )
    }

    func currentLog() throws -> String {
        return try String(contentsOf: logURL, encoding: .utf8)
    }

    func archive(_ index: Int) throws -> String {
        return try String(
            contentsOf: URL(fileURLWithPath: "\(logURL.path).\(index)"),
            encoding: .utf8
        )
    }
}
