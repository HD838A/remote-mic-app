import CryptoKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Public diagnostic retention")
struct PublicDiagnosticEventStoreTests {
    private func event(_ id: String = "startup") throws -> PublicDiagnosticEvent {
        try #require(PublicDiagnosticEvent(
            operationID: id, component: "settings", action: "load", phase: "failed",
            result: "defaults_applied", reason: "remote_profiles_data_corrupted", source: "app"
        ))
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SayAllDiagnosticRetention-\(UUID().uuidString)")
            .appendingPathComponent("public-events.json")
    }

    @Test func approvedEventsSurviveRestartWithRestrictedPermissions() throws {
        let url = storeURL()
        let expected = try event()
        try PublicDiagnosticEventStore(fileURL: url).append(expected)
        #expect(PublicDiagnosticEventStore(fileURL: url).pending() == [expected])
        for (target, mode) in [(url, 0o600), (url.deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
    }

    @Test func rejectionCapacityExpiryAndAcknowledgementKeepOnlyPendingApprovedEvents() throws {
        let url = storeURL()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = PublicDiagnosticEventStore(fileURL: url, capacity: 2, ttl: 60, now: { now })
        let first = try event("first"), second = try event("second"), third = try event("third")
        try store.append(first)
        try store.append(second)
        try store.append(third)
        let rejected = try #require(PublicDiagnosticEvent(
            component: "settings", action: "load", phase: "failed", result: "defaults_applied",
            reason: "user_supplied_text", source: "app"
        ))
        try store.append(rejected)
        #expect(store.pending() == [second, third])
        try store.acknowledge([first, second])
        #expect(PublicDiagnosticEventStore(fileURL: url, now: { now }).pending() == [third])
        #expect(PublicDiagnosticEventStore(fileURL: url, ttl: 60,
            now: { now.addingTimeInterval(61) }).pending().isEmpty)
    }

    @Test func editedStoreCannotTurnUnapprovedTextIntoAnUpload() throws {
        let url = storeURL()
        try PublicDiagnosticEventStore(fileURL: url).append(event())
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        records[0]["line"] = "PUBLIC_EVENT schema_version=1 operation_id=edited component=settings action=load phase=failed result=defaults_applied reason=private_details source=app"
        try JSONSerialization.data(withJSONObject: records).write(to: url)
        #expect(PublicDiagnosticEventStore(fileURL: url).pending().isEmpty)
    }

    @Test func restartedLoggerRetainsFailedSendAndAcknowledgesSuccessfulSend() throws {
        let url = storeURL()
        let expected = try event()
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        func logger(_ name: String) -> AppLogger {
            AppLogger(logURL: url.deletingLastPathComponent().appendingPathComponent(name),
                publicKeyDataProvider: { key },
                publicEventStore: PublicDiagnosticEventStore(fileURL: url))
        }
        let first = logger("first.rmlog")
        first.record(expected)
        first.flush()
        let restarted = logger("second.rmlog")
        #expect(restarted.publicDiagnosticEvents() == [expected])
        let failed = DiagnosticLogUploader(eventProvider: restarted.publicDiagnosticEvents,
            publicEventAcknowledger: restarted.markPublicDiagnosticEventsUploaded,
            configurationStateProvider: { .configured },
            sender: { _ in throw DiagnosticLogUploadError.uploadFailed })
        #expect(failed.uploadSynchronously() == .failure(.uploadFailed))
        #expect(PublicDiagnosticEventStore(fileURL: url).pending() == [expected])
        var sent: [DiagnosticLogEntry] = []
        let success = DiagnosticLogUploader(eventProvider: restarted.publicDiagnosticEvents,
            publicEventAcknowledger: restarted.markPublicDiagnosticEventsUploaded,
            configurationStateProvider: { .configured }, sender: { sent = $0 })
        #expect(success.uploadSynchronously() == .success(1))
        #expect(sent.map(\.message) == [expected.canonicalLine])
        #expect(logger("third.rmlog").publicDiagnosticEvents().isEmpty)
        #expect(success.uploadSynchronously() == .failure(.noLogs))
    }

    @Test func expiredEventsAreNotResurrectedByTheLoggerMemoryBuffer() throws {
        final class Clock { var date = Date(timeIntervalSince1970: 2_000_000_000) }
        let clock = Clock(), url = storeURL()
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let logger = AppLogger(logURL: url.deletingLastPathComponent().appendingPathComponent("session.rmlog"),
            publicKeyDataProvider: { key }, publicEventStore: PublicDiagnosticEventStore(
                fileURL: url, ttl: 60, now: { clock.date }))
        logger.record(try event())
        logger.flush()
        clock.date = clock.date.addingTimeInterval(61)
        #expect(logger.publicDiagnosticEvents().isEmpty)
    }

    @Test func settingsReasonsDiscardDecoderTextAndStorageKeys() throws {
        let context = DecodingError.Context(codingPath: [], debugDescription: "user@example.test /private/user-data")
        let errors: [(Error, String)] = [
            (DecodingError.dataCorrupted(context), "data_corrupted"),
            (DecodingError.typeMismatch(String.self, context), "type_mismatch"),
            (DecodingError.valueNotFound(String.self, context), "value_missing"),
            (NSError(domain: "private.text", code: 1), "unknown")
        ]
        for (error, reason) in errors {
            #expect(AppSettings.diagnosticDecodeReason(error) == reason)
            let event = try #require(PublicDiagnosticEvent(component: "settings", action: "load",
                phase: "failed", result: "defaults_applied", reason: "remote_profiles_\(reason)", source: "app"))
            #expect(event.isApprovedForUpload)
        }
        #expect(AppSettings.diagnosticSettingCategory("remoteDeviceProfiles") == "remote_profiles")
        #expect(AppSettings.diagnosticSettingCategory("user@example.test") == "other")
    }
}
