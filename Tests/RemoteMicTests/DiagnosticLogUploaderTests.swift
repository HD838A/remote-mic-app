import Foundation
import Testing
@testable import RemoteMic

@Suite("Diagnostic log uploader")
struct DiagnosticLogUploaderTests {
    @Test func configuredDSNUsesEnvironmentBeforeBundleAndAllowsEmptyConfiguration() {
        #expect(DiagnosticLogUploader.configuredDSN(
            environment: ["REMOTE_MIC_SENTRY_DSN": "https://env@example.ingest.sentry.io/1"],
            infoDictionary: ["SayAllSentryDSN": "https://bundle@example.ingest.sentry.io/2"]
        ) == "https://env@example.ingest.sentry.io/1")
        #expect(DiagnosticLogUploader.configuredDSN(
            environment: [:],
            infoDictionary: ["SayAllSentryDSN": "https://bundle@example.ingest.sentry.io/2"]
        ) == "https://bundle@example.ingest.sentry.io/2")
        #expect(DiagnosticLogUploader.configuredDSN(
            environment: [:],
            infoDictionary: [:]
        ) == nil)
    }

    @Test func missingDSNDoesNotInvokeSender() throws {
        let event = try #require(Self.environmentEvent())
        var senderCalled = false
        let uploader = DiagnosticLogUploader(
            eventProvider: { [event] },
            dsnProvider: { nil },
            sender: { _, _ in senderCalled = true }
        )

        #expect(uploader.uploadSynchronously() == .failure(.serviceNotConfigured))
        #expect(!senderCalled)
    }

    @Test func onlyApprovedEventsAreSent() throws {
        let approved = try #require(Self.environmentEvent())
        let rejected = try #require(PublicDiagnosticEvent(
            component: "audio",
            action: "configure",
            phase: "failed",
            result: "failed",
            reason: "device_unavailable"
        ))
        var received: [DiagnosticLogEntry] = []
        let uploader = DiagnosticLogUploader(
            eventProvider: { [approved, rejected] },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { entries, _ in received = entries }
        )

        #expect(uploader.uploadSynchronously() == .success(1))
        #expect(received.count == 1)
        #expect(received[0].message == approved.canonicalLine)
        #expect(!received[0].message.contains("device_unavailable"))
    }

    @Test func noEventsReturnsWithoutSending() {
        var senderCalled = false
        let uploader = DiagnosticLogUploader(
            eventProvider: { [] },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { _, _ in senderCalled = true }
        )

        #expect(uploader.uploadSynchronously() == .failure(.noLogs))
        #expect(!senderCalled)
    }

    @Test func invalidDSNIsRejectedBeforeEventRead() throws {
        let event = try #require(Self.environmentEvent())
        var eventRead = false
        let uploader = DiagnosticLogUploader(
            eventProvider: {
                eventRead = true
                return [event]
            },
            dsnProvider: { "not-a-dsn" },
            sender: { _, _ in }
        )

        #expect(uploader.uploadSynchronously() == .failure(.invalidServiceConfiguration))
        #expect(!eventRead)
    }

    @Test func DSNWithQueryOrPasswordIsRejected() throws {
        let event = try #require(Self.environmentEvent())
        for dsn in [
            "https://public:secret@example.ingest.sentry.io/1",
            "https://public@example.ingest.sentry.io/1?pii=true",
        ] {
            let uploader = DiagnosticLogUploader(
                eventProvider: { [event] },
                dsnProvider: { dsn },
                sender: { _, _ in }
            )
            #expect(uploader.uploadSynchronously() == .failure(.invalidServiceConfiguration))
        }
    }

    @Test func parserRejectsUnknownFieldsAndSensitiveValues() {
        let validPrefix = "PUBLIC_EVENT schema_version=1 operation_id=abc123 " +
            "component=environment action=snapshot phase=completed result=observed reason=app_launch"
        let rejectedLines = [
            validPrefix + " unexpected=value",
            validPrefix + " app_language=user@example.com",
            validPrefix + " voice_tool=token_value",
            validPrefix + " reason=order_123",
            validPrefix + " app_version=1.0\nsecret=value",
        ]

        for line in rejectedLines {
            #expect(PublicDiagnosticEvent.parse(line) == nil)
        }
    }

    @Test func approvedEventHasOnlyCanonicalSafeFields() throws {
        let event = try #require(Self.environmentEvent())
        let line = event.canonicalLine

        #expect(PublicDiagnosticEvent.parse(line) == event)
        #expect(!line.contains("@"))
        #expect(!line.contains("/"))
        #expect(!line.contains("\n"))
        #expect(!line.contains("bundle"))
        #expect(!line.contains("order"))
        #expect(!line.contains("payment"))
    }

    @Test func approvedVoiceEventCarriesUsefulSafeMetrics() throws {
        let event = try #require(PublicDiagnosticEvent(
            operationID: "voice_bluetooth_4",
            component: "voice",
            action: "session",
            phase: "completed",
            result: "passed",
            reason: "voice_stopped",
            elapsedMS: 3128,
            receivedSamples: 64_000,
            scheduledSamples: 64_000,
            playedSamples: 64_000,
            interruptedSamples: 0,
            pendingSamples: 0,
            failureCount: 0,
            source: "bluetooth",
            remoteModelFamily: "xiaomi",
            audioDeviceKind: "sayall_virtual",
            voiceTool: "doubao"
        ))

        #expect(event.isApprovedForUpload)
        #expect(PublicDiagnosticEvent.parse(event.canonicalLine) == event)
        #expect(event.canonicalLine.contains("received_samples=64000"))
        #expect(event.canonicalLine.contains("played_samples=64000"))
    }

    @Test func publicEventCatalogRejectsUnapprovedStableTokens() throws {
        let arbitraryReason = try #require(PublicDiagnosticEvent(
            operationID: "voice_bluetooth_4",
            component: "voice",
            action: "session",
            phase: "completed",
            result: "passed",
            reason: "private_reason_123",
            source: "bluetooth",
            remoteModelFamily: "xiaomi",
            audioDeviceKind: "sayall_virtual",
            voiceTool: "doubao"
        ))

        #expect(!arbitraryReason.isApprovedForUpload)
    }

    @Test func successfulSendAcknowledgesOnlyApprovedPublicEvents() throws {
        let approved = try #require(Self.environmentEvent())
        let rejected = try #require(PublicDiagnosticEvent(
            component: "audio",
            action: "configure",
            phase: "failed",
            result: "failed",
            reason: "device_unavailable"
        ))
        var acknowledged: [PublicDiagnosticEvent] = []
        let uploader = DiagnosticLogUploader(
            eventProvider: { [approved, rejected] },
            publicEventAcknowledger: { acknowledged = $0 },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { _, _ in }
        )

        #expect(uploader.uploadSynchronously() == .success(1))
        #expect(acknowledged == [approved])
    }

    @Test func failedSendDoesNotAcknowledgePublicEvents() throws {
        let approved = try #require(Self.environmentEvent())
        var acknowledged: [PublicDiagnosticEvent] = []
        let uploader = DiagnosticLogUploader(
            eventProvider: { [approved] },
            publicEventAcknowledger: { acknowledged = $0 },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { _, _ in throw DiagnosticLogUploadError.uploadFailed }
        )

        #expect(uploader.uploadSynchronously() == .failure(.uploadFailed))
        #expect(acknowledged.isEmpty)
    }

    @Test func privateBusinessRecordUsesSeparateStrictSchema() throws {
        let record = try #require(Self.privateRecord())
        let line = record.canonicalLine
        #expect(line.contains("category=PRIVATE_FLOW"))
        #expect(line.contains("state=ready"))
        #expect(PrivateDiagnosticUploadRecord.parse(line) == record)
        #expect(PublicDiagnosticEvent.parse(line) == nil)
        #expect(PrivateDiagnosticUploadRecord.parse(line + " unknown=value") != nil)
        #expect(PrivateDiagnosticUploadRecord.parse(line + " email=user") == nil)
        #expect(!line.contains("@"))
        #expect(!line.contains("https://"))
    }

    @Test func privateBusinessRecordRejectsReservedEnvelopeFields() {
        #expect(PrivateDiagnosticUploadRecord(
            recordID: "pe_abcdefghijklmnopqrstuv",
            occurredAt: Date(timeIntervalSince1970: 2_000_000_000),
            category: "PRIVATE_FLOW",
            fields: ["schema_version": "1", "phase": "completed"]
        ) == nil)
    }

    @Test func synchronousUploadIncludesApprovedPrivateRecords() throws {
        let record = try #require(Self.privateRecord())
        var received: [DiagnosticLogEntry] = []
        let uploader = DiagnosticLogUploader(
            eventProvider: { [] },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { entries, _ in received = entries }
        )

        #expect(uploader.uploadSynchronously(privateRecords: [record]) == .success(1))
        #expect(received.map(\.message) == [record.canonicalLine])
    }

    @Test func asynchronousUploadReadsAndAcknowledgesPrivateRecordsOnlyAfterSend() async throws {
        let record = try #require(Self.privateRecord())
        let provider = RecordingPrivateDiagnosticProvider(records: [record])
        let uploader = DiagnosticLogUploader(
            eventProvider: { [] },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { entries, _ in
                #expect(entries.map(\.message) == [record.canonicalLine])
            }
        )
        uploader.setPrivateEventProvider(provider)

        let result = await withCheckedContinuation { continuation in
            uploader.upload { continuation.resume(returning: $0) }
        }
        #expect(result == .success(1))
        #expect(await provider.pendingReadCount() == 1)
        #expect(await provider.uploadedRecordIDs() == [record.recordID])
    }

    @Test func missingDSNNeverReadsPrivateProvider() async throws {
        let provider = RecordingPrivateDiagnosticProvider(
            records: [try #require(Self.privateRecord())]
        )
        let uploader = DiagnosticLogUploader(
            eventProvider: { [] },
            dsnProvider: { nil },
            sender: { _, _ in Issue.record("Sender must not be called") }
        )
        uploader.setPrivateEventProvider(provider)

        let result = await withCheckedContinuation { continuation in
            uploader.upload { continuation.resume(returning: $0) }
        }
        #expect(result == .failure(.serviceNotConfigured))
        #expect(await provider.pendingReadCount() == 0)
        #expect(await provider.uploadedRecordIDs().isEmpty)
    }

    @Test func failedSendDoesNotAcknowledgePrivateRecords() async throws {
        let record = try #require(Self.privateRecord())
        let provider = RecordingPrivateDiagnosticProvider(records: [record])
        let uploader = DiagnosticLogUploader(
            eventProvider: { [] },
            dsnProvider: { "https://public@example.ingest.sentry.io/1" },
            sender: { _, _ in throw DiagnosticLogUploadError.uploadFailed }
        )
        uploader.setPrivateEventProvider(provider)

        let result = await withCheckedContinuation { continuation in
            uploader.upload { continuation.resume(returning: $0) }
        }
        #expect(result == .failure(.uploadFailed))
        #expect(await provider.pendingReadCount() == 1)
        #expect(await provider.uploadedRecordIDs().isEmpty)
    }

    private static func environmentEvent() -> PublicDiagnosticEvent? {
        PublicDiagnosticEvent(
            operationID: "abc123",
            component: "environment",
            action: "snapshot",
            phase: "completed",
            result: "observed",
            reason: "app_launch",
            audioDeviceKind: "sayall_virtual",
            voiceTool: "doubao",
            buildChannel: "public",
            capabilitySignature: String(repeating: "0", count: 64),
            appVersion: "1.0.0",
            appBuild: "100",
            osMajor: "15",
            cpuArchitecture: "arm64",
            appLanguage: "zh-Hans"
        )
    }

    private static func privateRecord() -> PrivateDiagnosticUploadRecord? {
        PrivateDiagnosticUploadRecord(
            recordID: "pe_abcdefghijklmnopqrstuv",
            occurredAt: Date(timeIntervalSince1970: 2_000_000_000),
            category: "PRIVATE_FLOW",
            fields: [
                "sequence": "7",
                "operation_id": "op_abcdefghijklmnopqrstuv",
                "client_flow_id": "cf_abcdefghijklmnopqrstuv",
                "support_trace_id": "st_abcdefghijklmnopqrstuv",
                "request_id": "rq_abcdefghijklmnopqrstuv",
                "component": "service",
                "action": "stage",
                "phase": "completed",
                "result": "observed",
                "reason_code": "none",
                "retryable": "false",
                "attempt": "2",
                "elapsed_ms": "842",
                "state": "ready",
            ]
        )
    }
}

private actor RecordingPrivateDiagnosticProvider: PrivateDiagnosticUploadProvider {
    private let records: [PrivateDiagnosticUploadRecord]
    private var readCount = 0
    private var uploadedIDs = Set<String>()

    init(records: [PrivateDiagnosticUploadRecord]) {
        self.records = records
    }

    func pendingPrivateDiagnosticRecords() -> [PrivateDiagnosticUploadRecord] {
        readCount += 1
        return records
    }

    func markPrivateDiagnosticRecordsUploaded(_ recordIDs: Set<String>) {
        uploadedIDs.formUnion(recordIDs)
    }

    func pendingReadCount() -> Int { readCount }
    func uploadedRecordIDs() -> Set<String> { uploadedIDs }
}
