import CryptoKit
import Foundation
@testable import RemoteMic

enum EarlyAccessTestSupport {
    static func makeToken(
        privateKey: Curve25519.Signing.PrivateKey,
        keyID: String = "test-key",
        issuer: String = "test-issuer",
        grantID: String = "gr_12345678901234567890",
        subject: String = String(repeating: "a", count: 64),
        issuedAt: Int64,
        refreshAfter: Int64,
        expiresAt: Int64,
        minimumVersion: String? = "1.0.0",
        maximumVersion: String? = nil
    ) throws -> String {
        let header: [String: Any] = [
            "alg": "EdDSA",
            "kid": keyID,
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "app": EarlyAccessEntitlementVerifier.applicationKey,
            "cohort": "internal",
            "expires_at": expiresAt,
            "feature": EarlyAccessFeature.deepSeekPostDictation.rawValue,
            "grant_id": grantID,
            "issued_at": issuedAt,
            "issuer": issuer,
            "key_id": keyID,
            "maximum_app_version": maximumVersion ?? NSNull(),
            "minimum_app_version": minimumVersion ?? NSNull(),
            "nonce": "test-nonce",
            "not_before": issuedAt,
            "policy_revision": 1,
            "refresh_after": refreshAfter,
            "schema_version": 1,
            "subject": subject,
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encodedHeader = base64URL(headerData)
        let encodedPayload = base64URL(payloadData)
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = try privateKey.signature(for: signingInput)
        return "\(encodedHeader).\(encodedPayload).\(base64URL(signature))"
    }

    static func verifier(
        publicKey: Curve25519.Signing.PublicKey,
        keyID: String = "test-key",
        issuer: String = "test-issuer"
    ) -> EarlyAccessEntitlementVerifier {
        EarlyAccessEntitlementVerifier(
            issuer: issuer,
            trustedKeyID: keyID,
            trustedPublicKey: base64URL(publicKey.rawRepresentation)
        )
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
