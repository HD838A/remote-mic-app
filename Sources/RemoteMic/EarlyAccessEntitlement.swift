import CryptoKit
import Foundation

enum EarlyAccessFeature: String, Codable, CaseIterable {
    case deepSeekPostDictation = "deepseek_post_dictation"
}

struct EarlyAccessEntitlementPayload: Codable, Equatable {
    let schemaVersion: Int
    let issuer: String
    let keyID: String
    let grantID: String
    let subject: String
    let app: String
    let feature: String
    let cohort: String
    let issuedAt: Int64
    let notBefore: Int64
    let refreshAfter: Int64
    let expiresAt: Int64
    let minimumAppVersion: String?
    let maximumAppVersion: String?
    let policyRevision: Int
    let nonce: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case issuer
        case keyID = "key_id"
        case grantID = "grant_id"
        case subject
        case app
        case feature
        case cohort
        case issuedAt = "issued_at"
        case notBefore = "not_before"
        case refreshAfter = "refresh_after"
        case expiresAt = "expires_at"
        case minimumAppVersion = "minimum_app_version"
        case maximumAppVersion = "maximum_app_version"
        case policyRevision = "policy_revision"
        case nonce
    }
}

enum EarlyAccessEntitlementError: Error, Equatable {
    case malformed
    case unknownKey
    case invalidSignature
    case invalidClaims
    case notYetValid
    case expired
    case versionBlocked
}

struct EarlyAccessEntitlementVerifier {
    static let applicationKey = "remote-mic-macos"
    static let productionIssuer = "getsayall-early-access"
    static let productionKeyID = "ea-2026-08-10-3e594827"
    static let productionPublicKey = "4nCgMycm2yKIkct5flYyoLSF7_ZmSG-qr7RoLo6IuGg"
    static let maximumCompactTokenBytes = 16 * 1_024

    private let applicationKey: String
    private let issuer: String
    private let trustedKeyID: String
    private let trustedPublicKey: String

    init(
        applicationKey: String = Self.applicationKey,
        issuer: String = Self.productionIssuer,
        trustedKeyID: String = Self.productionKeyID,
        trustedPublicKey: String = Self.productionPublicKey
    ) {
        self.applicationKey = applicationKey
        self.issuer = issuer
        self.trustedKeyID = trustedKeyID
        self.trustedPublicKey = trustedPublicKey
    }

    func verify(
        _ compactToken: String,
        feature: EarlyAccessFeature,
        expectedGrantID: String? = nil,
        expectedSubject: String? = nil,
        appVersion: String,
        now: Date
    ) throws -> EarlyAccessEntitlementPayload {
        guard compactToken.utf8.count <= Self.maximumCompactTokenBytes else {
            throw EarlyAccessEntitlementError.malformed
        }
        let parts = compactToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Self.decodeBase64URL(String(parts[0])),
              let payloadData = Self.decodeBase64URL(String(parts[1])),
              let signature = Self.decodeBase64URL(String(parts[2])),
              signature.count == 64
        else { throw EarlyAccessEntitlementError.malformed }

        let headerKeys = try Self.objectKeys(in: headerData)
        guard headerKeys == ["alg", "kid", "typ"] else {
            throw EarlyAccessEntitlementError.malformed
        }
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        guard header.alg == "EdDSA", header.typ == "JWT" else {
            throw EarlyAccessEntitlementError.malformed
        }
        guard header.kid == trustedKeyID,
              let publicKeyData = Self.decodeBase64URL(trustedPublicKey)
        else { throw EarlyAccessEntitlementError.unknownKey }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw EarlyAccessEntitlementError.unknownKey
        }
        let signedData = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signedData) else {
            throw EarlyAccessEntitlementError.invalidSignature
        }

        let payloadKeys = try Self.objectKeys(in: payloadData)
        guard payloadKeys == Set([
            "app", "cohort", "expires_at", "feature", "grant_id", "issued_at",
            "issuer", "key_id", "maximum_app_version", "minimum_app_version", "nonce",
            "not_before", "policy_revision", "refresh_after", "schema_version", "subject",
        ]) else { throw EarlyAccessEntitlementError.malformed }

        let payload = try JSONDecoder().decode(EarlyAccessEntitlementPayload.self, from: payloadData)
        guard payload.schemaVersion == 1,
              payload.issuer == issuer,
              payload.keyID == header.kid,
              payload.app == applicationKey,
              payload.feature == feature.rawValue,
              !payload.grantID.isEmpty,
              !payload.subject.isEmpty,
              !payload.cohort.isEmpty,
              !payload.nonce.isEmpty,
              payload.policyRevision >= 1,
              payload.issuedAt <= payload.notBefore,
              payload.notBefore < payload.refreshAfter,
              payload.refreshAfter < payload.expiresAt,
              payload.expiresAt - payload.issuedAt <= 7 * 24 * 60 * 60,
              expectedGrantID == nil || payload.grantID == expectedGrantID,
              expectedSubject == nil || payload.subject == expectedSubject
        else { throw EarlyAccessEntitlementError.invalidClaims }

        let currentTimestamp = Int64(now.timeIntervalSince1970.rounded(.down))
        guard currentTimestamp >= payload.notBefore else {
            throw EarlyAccessEntitlementError.notYetValid
        }
        guard currentTimestamp < payload.expiresAt else {
            throw EarlyAccessEntitlementError.expired
        }
        guard Self.version(appVersion, isAtLeast: payload.minimumAppVersion),
              Self.version(appVersion, isAtMost: payload.maximumAppVersion)
        else { throw EarlyAccessEntitlementError.versionBlocked }
        return payload
    }

    static func version(_ version: String, isAtLeast minimum: String?) -> Bool {
        guard let minimum else { return parsedVersion(version) != nil }
        guard let current = parsedVersion(version), let bound = parsedVersion(minimum) else { return false }
        return compare(current, bound) >= 0
    }

    static func version(_ version: String, isAtMost maximum: String?) -> Bool {
        guard let maximum else { return parsedVersion(version) != nil }
        guard let current = parsedVersion(version), let bound = parsedVersion(maximum) else { return false }
        return compare(current, bound) <= 0
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func objectKeys(in data: Data) throws -> Set<String> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EarlyAccessEntitlementError.malformed
        }
        return Set(object.keys)
    }

    private static func parsedVersion(_ value: String) -> [Int]? {
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return parts.compactMap { Int($0) }
    }

    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue { return leftValue < rightValue ? -1 : 1 }
        }
        return 0
    }

    private struct Header: Decodable {
        let alg: String
        let kid: String
        let typ: String
    }
}
