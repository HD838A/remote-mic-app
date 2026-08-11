import CryptoKit
import Foundation
import Security
import Testing
@testable import RemoteMic

private final class MockEarlyAccessClient: EarlyAccessClientProtocol {
    var redeemResult: Result<EarlyAccessAPIResponse, Error>
    var refreshResult: Result<EarlyAccessAPIResponse, Error>
    var releaseResult: Result<String?, Error> = .success("req_release")
    private(set) var redeemCount = 0
    private(set) var refreshCount = 0
    private(set) var releaseCount = 0

    init(response: EarlyAccessAPIResponse) {
        redeemResult = .success(response)
        refreshResult = .success(response)
    }

    func redeem(
        code _: String,
        anonymousDeviceID _: String,
        appVersion _: String,
        appBuild _: String
    ) async throws -> EarlyAccessAPIResponse {
        redeemCount += 1
        return try redeemResult.get()
    }

    func refresh(
        grantID _: String,
        refreshCredential _: String,
        anonymousDeviceID _: String,
        appVersion _: String,
        appBuild _: String
    ) async throws -> EarlyAccessAPIResponse {
        refreshCount += 1
        return try refreshResult.get()
    }

    func release(
        grantID _: String,
        refreshCredential _: String,
        anonymousDeviceID _: String,
        appVersion _: String,
        appBuild _: String
    ) async throws -> String? {
        releaseCount += 1
        return try releaseResult.get()
    }
}

@Suite("Early Access controller", .serialized)
struct EarlyAccessControllerTests {
    @Test func doesNotCreateIdentityOrRequestBeforeManualRedeem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        #expect(fixture.controller.state == .notEnrolled)
        #expect(fixture.client.redeemCount == 0)
        #expect(fixture.client.refreshCount == 0)
        #expect(try fixture.store.loadDeviceID() == nil)

        fixture.controller.redeem(code: "EA-TEST-CODE")
        await fixture.controller.waitForCurrentOperation()
        #expect(fixture.client.redeemCount == 1)
        #expect(try fixture.store.loadDeviceID() != nil)
        #expect(fixture.controller.hasEffectiveAccess)
        #expect(fixture.controller.state == .authorized)
    }

    @Test func keepsValidCachedAccessWhenRefreshNetworkFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.redeem(code: "EA-TEST-CODE")
        await fixture.controller.waitForCurrentOperation()

        fixture.now = fixture.now.addingTimeInterval(120)
        fixture.uptime += 120
        fixture.syncClockValues()
        fixture.client.refreshResult = .failure(EarlyAccessClientError.requestFailed)
        fixture.controller.refreshIfNeeded(force: true)
        await fixture.controller.waitForCurrentOperation()

        #expect(fixture.client.refreshCount == 1)
        #expect(fixture.controller.state == .offlineValid)
        #expect(fixture.controller.hasEffectiveAccess)
    }

    @Test func explicitRevocationDisablesAndRemovesGrantButKeepsAnonymousIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.redeem(code: "EA-TEST-CODE")
        await fixture.controller.waitForCurrentOperation()
        let deviceID = try fixture.store.loadDeviceID()

        fixture.client.refreshResult = .failure(
            EarlyAccessClientError.server(code: "revoked", requestID: "req_revoked")
        )
        fixture.controller.refreshIfNeeded(force: true)
        await fixture.controller.waitForCurrentOperation()

        #expect(fixture.controller.state == .revoked)
        #expect(!fixture.controller.hasEffectiveAccess)
        #expect(try fixture.store.loadGrantBundle() == nil)
        #expect(try fixture.store.loadDeviceID() == deviceID)
    }

    @Test func localExitInvalidatesAccessAndPreventsLateRefreshState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.redeem(code: "EA-TEST-CODE")
        await fixture.controller.waitForCurrentOperation()

        fixture.controller.clearLocalEnrollment()
        #expect(fixture.controller.state == .notEnrolled)
        #expect(!fixture.controller.hasEffectiveAccess)
        #expect(try fixture.store.loadGrantBundle() == nil)
        #expect(try fixture.store.loadDeviceID() == nil)
    }

    private final class Fixture {
        let directory: URL
        let keychainURL: URL
        let store: EarlyAccessCredentialStore
        let client: MockEarlyAccessClient
        let controller: EarlyAccessController
        var now = Date(timeIntervalSince1970: 10_000)
        var uptime: TimeInterval = 500

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteMicEarlyAccessController-\(UUID().uuidString)", isDirectory: true)
            keychainURL = directory.appendingPathComponent("test.keychain-db")
            store = EarlyAccessCredentialStore(applicationKeychainURL: keychainURL)
            let privateKey = Curve25519.Signing.PrivateKey()
            let token = try EarlyAccessTestSupport.makeToken(
                privateKey: privateKey,
                issuedAt: 10_000,
                refreshAfter: 10_600,
                expiresAt: 13_600
            )
            let response = EarlyAccessAPIResponse(
                grantID: "gr_12345678901234567890",
                refreshCredential: String(repeating: "r", count: 43),
                entitlement: token,
                refreshAfter: 10_600,
                expiresAt: 13_600,
                requestID: "req_redeem",
                serverTime: now
            )
            client = MockEarlyAccessClient(response: response)
            let nowBox = MutableValue(now)
            let uptimeBox = MutableValue(uptime)
            controller = EarlyAccessController(
                store: store,
                client: client,
                verifier: EarlyAccessTestSupport.verifier(publicKey: privateKey.publicKey),
                appVersion: "1.8.12",
                appBuild: "104",
                serviceConfigured: true,
                dateProvider: { nowBox.value },
                uptimeProvider: { uptimeBox.value }
            )
            self.nowBox = nowBox
            self.uptimeBox = uptimeBox
        }

        private let nowBox: MutableValue<Date>
        private let uptimeBox: MutableValue<TimeInterval>

        func cleanup() {
            controller.stop()
            var keychain: SecKeychain?
            if SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain {
                SecKeychainDelete(keychain)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        func syncClockValues() {
            nowBox.value = now
            uptimeBox.value = uptime
        }
    }
}

private final class MutableValue<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
