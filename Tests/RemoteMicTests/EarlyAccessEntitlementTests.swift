import CryptoKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Early Access entitlement")
struct EarlyAccessEntitlementTests {
    @Test func verifiesTrustedClaimsAndRejectsWrongSubject() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = EarlyAccessTestSupport.verifier(publicKey: privateKey.publicKey)
        let now = Date(timeIntervalSince1970: 10_000)
        let token = try EarlyAccessTestSupport.makeToken(
            privateKey: privateKey,
            issuedAt: 10_000,
            refreshAfter: 10_600,
            expiresAt: 13_600
        )

        let payload = try verifier.verify(
            token,
            feature: .deepSeekPostDictation,
            expectedGrantID: "gr_12345678901234567890",
            expectedSubject: String(repeating: "a", count: 64),
            appVersion: "1.8.12",
            now: now
        )
        #expect(payload.cohort == "internal")
        #expect(throws: EarlyAccessEntitlementError.invalidClaims) {
            try verifier.verify(
                token,
                feature: .deepSeekPostDictation,
                expectedGrantID: payload.grantID,
                expectedSubject: "wrong-subject",
                appVersion: "1.8.12",
                now: now
            )
        }
    }

    @Test func rejectsExpiredAndVersionBlockedTokens() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = EarlyAccessTestSupport.verifier(publicKey: privateKey.publicKey)
        let token = try EarlyAccessTestSupport.makeToken(
            privateKey: privateKey,
            issuedAt: 10_000,
            refreshAfter: 10_600,
            expiresAt: 13_600,
            minimumVersion: "2.0.0"
        )
        #expect(throws: EarlyAccessEntitlementError.versionBlocked) {
            try verifier.verify(
                token,
                feature: .deepSeekPostDictation,
                appVersion: "1.8.12",
                now: Date(timeIntervalSince1970: 10_001)
            )
        }
        #expect(throws: EarlyAccessEntitlementError.expired) {
            try verifier.verify(
                token,
                feature: .deepSeekPostDictation,
                appVersion: "2.0.0",
                now: Date(timeIntervalSince1970: 13_600)
            )
        }
    }
}
