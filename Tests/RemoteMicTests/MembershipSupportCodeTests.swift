import Foundation
import Testing
@testable import RemoteMic

@Suite("Membership support code boundary")
struct MembershipSupportCodeTests {
    @Test func codesRemainAvailableInCopiedDiagnostics() {
        for code in [-1101, -1201] {
            let error = HostRemoteSessionError(
                failure: .invalidResponse, reasonCode: "internal_error",
                supportCode: code, requestID: "rq_abcdefghijklmnopqrstuv"
            )
            let snapshot = SettingsDiagnosticSnapshot(
                appVersion: "2.0.0", bluetoothGranted: false,
                inputMonitoringGranted: false, accessibilityGranted: false,
                runtimeLogAvailable: true, remoteSessionError: error
            )
            #expect(error.diagnosticFields.contains("support_code=\(code)"))
            #expect(snapshot.summary.contains("support_code=\(code)"))
            #expect(snapshot.summary.contains("request_id=rq_abcdefghijklmnopqrstuv"))
        }
    }

    @Test func legacyAndUnsafeDetailsUseFallbackWithoutPrivateText() {
        let legacy = HostRemoteSessionError(failure: .unavailable)
        #expect(legacy.diagnosticFields == "reason_code=internal_error support_code=-1900 request_id=none")
        let unsafe = HostRemoteSessionError(
            failure: .invalidResponse, reasonCode: "private message user@example.test",
            supportCode: 123, requestID: "user@example.test"
        )
        #expect(unsafe.diagnosticFields == legacy.diagnosticFields)
    }
}
