import CryptoKit
import Foundation
import Security
import Testing
@testable import RemoteMic

private final class FeatureGateEarlyAccessClient: EarlyAccessClientProtocol {
    let response: EarlyAccessAPIResponse
    var refreshError: Error?

    init(response: EarlyAccessAPIResponse) {
        self.response = response
    }

    func redeem(
        code _: String,
        anonymousDeviceID _: String,
        appVersion _: String,
        appBuild _: String
    ) async throws -> EarlyAccessAPIResponse {
        response
    }

    func refresh(
        grantID _: String,
        refreshCredential _: String,
        anonymousDeviceID _: String,
        appVersion _: String,
        appBuild _: String
    ) async throws -> EarlyAccessAPIResponse {
        if let refreshError { throw refreshError }
        return response
    }

    func release(
        grantID _: String,
        refreshCredential _: String,
        anonymousDeviceID _: String,
        appVersion _: String,
        appBuild _: String
    ) async throws -> String? {
        "req_release"
    }
}

@Suite("Early Access AI feature gate", .serialized)
struct EarlyAccessFeatureGateTests {
    @Test func coversMissingOffOnAndRevokedStatesWithoutDeletingAIData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicFeatureGate-\(UUID().uuidString)", isDirectory: true)
        let keychainURL = directory.appendingPathComponent("test.keychain-db")
        let termsURL = directory.appendingPathComponent("programming-terms.json")
        let suiteName = "RemoteMicFeatureGate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "deepSeekPostDictationEnabled")
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            var keychain: SecKeychain?
            if SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain {
                SecKeychainDelete(keychain)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 10_000)
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
        let client = FeatureGateEarlyAccessClient(response: response)
        let earlyAccessStore = EarlyAccessCredentialStore(applicationKeychainURL: keychainURL)
        let earlyAccess = EarlyAccessController(
            store: earlyAccessStore,
            client: client,
            verifier: EarlyAccessTestSupport.verifier(publicKey: privateKey.publicKey),
            appVersion: "1.8.12",
            appBuild: "104",
            serviceConfigured: true,
            dateProvider: { now },
            uptimeProvider: { 500 }
        )
        let model = BridgeAppModel(
            settings: AppSettings(defaults: defaults),
            earlyAccess: earlyAccess,
            deepSeekCredentialStore: DeepSeekCredentialStore(applicationKeychainURL: keychainURL),
            programmingTermStore: ProgrammingTermStore(fileURL: termsURL)
        )

        #expect(!earlyAccess.hasEffectiveAccess)
        #expect(!model.settings.deepSeekPostDictationEnabled)
        model.setDeepSeekPostDictationEnabled(true)
        #expect(!model.settings.deepSeekPostDictationEnabled)

        model.redeemEarlyAccessCode("EA-TEST-CODE")
        await earlyAccess.waitForCurrentOperation()
        #expect(earlyAccess.hasEffectiveAccess)
        #expect(!model.settings.deepSeekPostDictationEnabled)

        model.setDeepSeekPostDictationEnabled(true)
        #expect(model.settings.deepSeekPostDictationEnabled)
        #expect(model.saveDeepSeekAPIKey("sk-test-feature-gate"))
        #expect(model.canRunPostDictation)

        client.refreshError = EarlyAccessClientError.server(
            code: "revoked",
            requestID: "req_revoked"
        )
        model.refreshEarlyAccessIfNeeded(force: true)
        await earlyAccess.waitForCurrentOperation()
        #expect(!earlyAccess.hasEffectiveAccess)
        #expect(!model.settings.deepSeekPostDictationEnabled)
        #expect(!model.canRunPostDictation)
        #expect(model.isDeepSeekAPIKeyConfigured)
        #expect((try? DeepSeekCredentialStore(
            applicationKeychainURL: keychainURL
        ).loadAPIKey()) != nil)
    }
}
