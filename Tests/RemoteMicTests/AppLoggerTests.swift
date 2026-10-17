import CryptoKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("App logger")
struct AppLoggerTests {
    @Test func writesEncryptedRecordsWithStableSequenceAndMetadata() throws {
        let harness = try LoggerHarness()

        harness.logger.write("APP START")
        harness.logger.flush()

        let raw = try Data(contentsOf: harness.logURL)
        #expect(raw.range(of: Data("APP START".utf8)) == nil)
        let lines = try harness.decryptLines()
        #expect(lines.count == 1)
        #expect(lines[0].contains("pid=4242 ver=1.9_beta build=121_rc seq=0 APP START"))
    }

    @Test func normalizesControlsAndLineSeparatorsBeforeEncryption() throws {
        let harness = try LoggerHarness()

        harness.logger.write("first\nsecond\rthird\tfourth\u{0000}中文\u{2028}last")
        harness.logger.flush()

        let lines = try harness.decryptLines()
        #expect(lines[0].contains("first second third fourth 中文 last"))
        let message = lines[0].trimmingCharacters(in: .newlines)
        #expect(!message.contains("\n"))
        #expect(!message.contains("\r"))
        #expect(!message.contains("\t"))
    }

    @Test func writesDiagnosticSummaryAsOrderedEncryptedRecords() throws {
        let harness = try LoggerHarness()

        harness.logger.writeDiagnosticSummary(
            "SayAll first-use diagnostics\ndiagnostic_schema=3\nrecent_events:\n- event=1\nsecond\rthird",
            event: "ONBOARDING DIAGNOSTICS"
        )
        harness.logger.flush()

        let lines = try harness.decryptLines()
        #expect(lines.count == 8)
        #expect(lines[0].contains("seq=0 ONBOARDING DIAGNOSTICS BEGIN"))
        #expect(lines[1].contains("seq=1 ONBOARDING DIAGNOSTICS FIELD SayAll first-use diagnostics"))
        #expect(lines[5].contains("seq=5 ONBOARDING DIAGNOSTICS FIELD second"))
        #expect(lines[6].contains("seq=6 ONBOARDING DIAGNOSTICS FIELD third"))
        #expect(lines[7].contains("seq=7 ONBOARDING DIAGNOSTICS END"))
    }

    @Test func typedEventsAreBufferedInMemoryWithoutReadingTheFile() throws {
        let harness = try LoggerHarness()
        let event = try #require(PublicDiagnosticEvent(
            component: "environment",
            action: "snapshot",
            phase: "completed",
            result: "observed",
            reason: "app_launch",
            appVersion: "1.0.0"
        ))

        harness.logger.record(event)
        harness.logger.flush()

        #expect(harness.logger.publicDiagnosticEvents() == [event])
        #expect(try harness.decryptLines()[0].contains(event.canonicalLine))
    }

    @Test func uploadedTypedEventsAreRemovedExactlyOnce() throws {
        let harness = try LoggerHarness()
        let first = try #require(PublicDiagnosticEvent(
            operationID: "first",
            component: "environment",
            action: "snapshot",
            phase: "completed",
            result: "observed",
            reason: "app_launch",
            audioDeviceKind: "sayall_virtual",
            voiceTool: "doubao",
            buildChannel: "public",
            capabilitySignature: String(repeating: "0", count: 64),
            appVersion: "1.0",
            appBuild: "1",
            osMajor: "15",
            cpuArchitecture: "arm64",
            appLanguage: "zh-Hans"
        ))
        let second = try #require(PublicDiagnosticEvent(
            operationID: "second",
            component: "environment",
            action: "snapshot",
            phase: "completed",
            result: "observed",
            reason: "app_launch",
            audioDeviceKind: "sayall_virtual",
            voiceTool: "doubao",
            buildChannel: "public",
            capabilitySignature: String(repeating: "1", count: 64),
            appVersion: "1.0",
            appBuild: "1",
            osMajor: "15",
            cpuArchitecture: "arm64",
            appLanguage: "zh-Hans"
        ))

        harness.logger.record(first)
        harness.logger.record(second)
        harness.logger.flush()
        harness.logger.markPublicDiagnosticEventsUploaded([first])

        #expect(harness.logger.publicDiagnosticEvents() == [second])
    }

    @Test func missingPublicKeyUsesPlaintextLogWithoutCreatingEncryptedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SayAllAppLoggerMissingKey-\(UUID().uuidString)")
        let logURL = root.appendingPathComponent("runtime.rmlog")
        let plaintextLogURL = root.appendingPathComponent("runtime.log")
        var failures: [String] = []
        let logger = AppLogger(
            logURL: logURL,
            metadata: AppLogger.Metadata(processID: 1, version: "1", build: "1"),
            reportFailure: { failures.append($0) },
            publicKeyDataProvider: { nil }
        )

        logger.write("secret")
        logger.flush()

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(FileManager.default.fileExists(atPath: plaintextLogURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: plaintextLogURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        let plaintext = try String(contentsOf: plaintextLogURL, encoding: .utf8)
        #expect(plaintext.contains("LOGGING mode=plaintext reason=encryption_public_key_missing"))
        #expect(plaintext.contains("secret"))
        #expect(failures.contains { $0.contains("encryption_public_key_missing") })
    }

    @Test func enforcesTheEncryptedFileSizeLimit() throws {
        let harness = try LoggerHarness(maximumFileSize: 256)

        for index in 0 ..< 20 {
            harness.logger.write(String(repeating: "x", count: 100) + "-\(index)")
        }
        harness.logger.flush()

        let size = try FileManager.default.attributesOfItem(atPath: harness.logURL.path)[.size] as? NSNumber
        #expect(size?.uint64Value ?? 0 <= 256)
        #expect(!harness.failures.isEmpty)
    }

    @Test func rejectedOversizedRecordDoesNotCreateSequenceGap() throws {
        let harness = try LoggerHarness(maximumFileSize: 400)

        harness.logger.write(String(repeating: "x", count: 2_000))
        harness.logger.write("small_record_after_rejection")
        harness.logger.flush()

        let lines = try harness.decryptLines()
        #expect(lines.count == 2)
        #expect(lines[0].contains("seq=0 small_record_after_rejection"))
        #expect(lines[1].contains("LOG GAP phase=recovered lost_record_count=1"))
        #expect(harness.failures.contains("encrypted_log_record_too_large"))
    }

    @Test func rotatesWithoutLosingRecordsAndEverySegmentDecrypts() throws {
        let harness = try LoggerHarness(maximumFileSize: 1024)
        for index in 0..<40 { harness.logger.write("FLOW step=\(index)") }
        harness.logger.flush()
        let urls = try harness.segmentURLs()
        #expect(urls.count > 1)
        for url in urls { #expect(try Data(contentsOf: url).count <= 1024) }
        let lines = try harness.decryptAllLines()
        #expect(lines.count == 40)
        for index in 0..<40 { #expect(lines.filter { $0.hasSuffix("FLOW step=\(index)\n") }.count == 1) }
        #expect(harness.failures.isEmpty)
    }

    @Test func repeatedStateKeepsExactCountAndTypedBoundaryOrder() throws {
        let harness = try LoggerHarness()
        for _ in 0..<81 { harness.logger.write("HID FILTER ready=true") }
        harness.logger.writeSynchronously("FLOW phase=failed", at: Date())
        harness.logger.flush()
        let lines = try harness.decryptAllLines()
        #expect(lines.count == 3)
        #expect(lines[0].contains("HID FILTER ready=true"))
        #expect(lines[1].contains("LOG REPEAT repeat_count=80"))
        #expect(lines[2].contains("FLOW phase=failed"))
    }

    @Test func retentionMovesOnlyVerifiedInactiveLogsAndReportsBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("sayall.app-2026-01-01-session-ABCDEF01.rmlog")
        let unrelated = root.appendingPathComponent("unrelated.rmlog")
        let active = root.appendingPathComponent("sayall.app-2026-01-02-session-ABCDEF02.rmlog")
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let live = AppLogger(logURL: active, publicKeyDataProvider: { key })
        live.write("ALIVE"); live.flush()
        try Data(repeating: 1, count: 1500).write(to: stale)
        try Data(repeating: 2, count: 1500).write(to: unrelated)
        let retired = root.appendingPathComponent("recoverable", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let newLog = root.appendingPathComponent("sayall.app-2026-01-03-session-ABCDEF03.rmlog")
        let logger = AppLogger(logURL: newLog, maximumFileSize: 1024,
            retirementHandler: { url in try FileManager.default.moveItem(at: url,
                to: retired.appendingPathComponent(url.lastPathComponent)) },
            maximumDirectorySize: 1800, publicKeyDataProvider: { key })
        logger.write("NEW"); logger.flush()
        #expect(FileManager.default.fileExists(atPath: retired.appendingPathComponent(stale.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        live.write("STILL_ALIVE"); live.flush()
        #expect(try Data(contentsOf: active).count > 118)
    }

    @Test func failedWriteRecoversInNewDecryptableSegmentAndReportsGap() throws {
        let harness = try LoggerHarness()
        let saved = harness.logURL.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: harness.logURL, to: saved)
        try FileManager.default.createDirectory(at: harness.logURL, withIntermediateDirectories: false)
        harness.logger.write("FLOW phase=failed_write")
        harness.logger.flush()
        harness.logger.write("FLOW phase=recovered")
        harness.logger.flush()
        let newSegment = harness.logURL.deletingPathExtension().appendingPathExtension("part-1.rmlog")
        let lines = try harness.decryptLines(at: newSegment)
        #expect(lines.contains { $0.contains("seq=0 FLOW phase=recovered") })
        #expect(lines.contains { $0.contains("LOG GAP phase=recovered lost_record_count=1") })
        #expect(harness.failures.contains { $0.contains("encrypted_log_write_failed") })
    }

    @Test func smallFilesAreAlsoBoundedByFileCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let retired = root.appendingPathComponent("recoverable", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        for index in 0..<6 {
            let name = String(format: "sayall.app-2026-10-15-session-%08X.rmlog", index)
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let logger = AppLogger(logURL: root.appendingPathComponent("sayall.app-2026-10-15-session-ABCDEF99.rmlog"),
            archiveCount: 1, retirementHandler: { url in
                try FileManager.default.moveItem(at: url, to: retired.appendingPathComponent(url.lastPathComponent))
            }, publicKeyDataProvider: { key })
        logger.write("START"); logger.flush()
        let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "rmlog" }
        #expect(remaining.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil).count == 5)
    }

    @Test func errorFieldsUseStableDomainAndNumericCode() {
        let error = NSError(domain: "com.example failure\n", code: -17)

        #expect(AppLogger.errorFields(error) ==
            "error_domain=com.example_failure_ error_code=-17")
        #expect(AppLogger.optionalErrorFields(nil) ==
            "error_domain=none error_code=0")
        #expect(AppLogger.errorFields(domain: "os status", code: -50) ==
            "error_domain=os_status error_code=-50")
    }

    @Test func sharedLoggerIsDisabledForXCTestProcesses() {
        #expect(!AppLogger.shouldEnableSharedLogging(
            arguments: ["/tmp/RemoteMicPackageTests.xctest/Contents/MacOS/RemoteMicPackageTests"],
            environment: [:]
        ))
        #expect(!AppLogger.shouldEnableSharedLogging(
            arguments: ["/tmp/RemoteMicPackageTests"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test-configuration"]
        ))
    }
}

private final class LoggerHarness {
    let logURL: URL
    let logger: AppLogger
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let failureBox = FailureBox()
    var failures: [String] { failureBox.values }

    init(
        metadata: AppLogger.Metadata = AppLogger.Metadata(
            processID: 4242,
            version: "1.9 beta",
            build: "121 rc"
        ),
        maximumFileSize: UInt64 = 10 * 1_024 * 1_024
    ) throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("SayAllAppLoggerTests-\(UUID().uuidString)", isDirectory: true)
        logURL = rootURL.appendingPathComponent("runtime.rmlog")
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        logger = AppLogger(
            logURL: logURL,
            metadata: metadata,
            maximumFileSize: maximumFileSize,
            now: { Date(timeIntervalSinceReferenceDate: 0) },
            reportFailure: { [failureBox] message in failureBox.values.append(message) },
            publicKeyDataProvider: { publicKey }
        )
    }

    func segmentURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: logURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "rmlog" }.sorted { $0.path < $1.path }
    }

    func decryptAllLines() throws -> [String] {
        try segmentURLs().flatMap { try decryptLines(at: $0) }
    }

    func decryptLines(at url: URL? = nil) throws -> [String] {
        let data = try Data(contentsOf: url ?? logURL)
        var offset = DiagnosticLogEnvelope.magic.count
        #expect(data.starts(with: DiagnosticLogEnvelope.magic))

        let sessionID = Data(data[offset ..< offset + DiagnosticLogEnvelope.sessionIDLength])
        offset += DiagnosticLogEnvelope.sessionIDLength
        let ephemeralPublicKeyData = Data(
            data[offset ..< offset + DiagnosticLogEnvelope.ephemeralPublicKeyLength]
        )
        offset += DiagnosticLogEnvelope.ephemeralPublicKeyLength
        let wrappedLength = try readUInt32(data, offset: &offset)
        let wrappedKey = Data(data[offset ..< offset + Int(wrappedLength)])
        offset += Int(wrappedLength)

        let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ephemeralPublicKeyData
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: sessionID,
            sharedInfo: Data("SayAll diagnostic log v2".utf8),
            outputByteCount: DiagnosticLogEnvelope.fileKeyLength
        )
        let wrappedBox = try AES.GCM.SealedBox(combined: wrappedKey)
        let fileKeyData = try AES.GCM.open(
            wrappedBox,
            using: wrappingKey,
            authenticating: sessionID
        )
        let fileKey = SymmetricKey(data: fileKeyData)

        var lines: [String] = []
        var sequence: UInt64 = 0
        while offset < data.count {
            let length = try readUInt32(data, offset: &offset)
            let combined = Data(data[offset ..< offset + Int(length)])
            offset += Int(length)
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                box,
                using: fileKey,
                authenticating: DiagnosticLogEnvelope.associatedData(
                    sessionID: sessionID,
                    sequence: sequence
                )
            )
            lines.append(try #require(String(data: plaintext, encoding: .utf8)))
            sequence += 1
        }
        return lines
    }

    private func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DiagnosticLogEnvelope.Error.invalidRecord }
        let value = data[offset ..< offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }
}

private final class FailureBox {
    var values: [String] = []
}
