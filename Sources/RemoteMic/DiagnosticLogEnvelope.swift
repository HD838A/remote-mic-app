import CryptoKit
import Foundation

/// The public-key envelope used for local diagnostic files.
///
/// The app only performs sealing. The matching private key is intentionally
/// absent from the app and is used by an internal support tool.
struct DiagnosticLogEnvelope {
    static let magic = Data("RMLG2\n".utf8)
    static let sessionIDLength = 16
    static let ephemeralPublicKeyLength = 32
    static let fileKeyLength = 32

    struct Session {
        let sessionID: Data
        let fileKey: SymmetricKey
        let header: Data
    }

    enum Error: Swift.Error {
        case invalidPublicKey
        case invalidSessionID
        case invalidRecord
    }

    static func makeSession(publicKeyData: Data, sessionID: Data = sessionID()) throws -> Session {
        guard sessionID.count == sessionIDLength else { throw Error.invalidSessionID }
        let recipient: Curve25519.KeyAgreement.PublicKey
        do {
            recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw Error.invalidPublicKey
        }

        let fileKey = SymmetricKey(size: .bits256)
        let fileKeyData = Data(fileKey.withUnsafeBytes { Data($0) })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: sessionID,
            sharedInfo: Data("SayAll diagnostic log v2".utf8),
            outputByteCount: fileKeyLength
        )
        guard let wrappedKey = try AES.GCM.seal(
            fileKeyData,
            using: wrappingKey,
            authenticating: sessionID
        ).combined else {
            throw Error.invalidRecord
        }

        var header = magic
        header.append(sessionID)
        header.append(ephemeral.publicKey.rawRepresentation)
        var wrappedLength = UInt32(wrappedKey.count).bigEndian
        header.append(withUnsafeBytes(of: &wrappedLength) { Data($0) })
        header.append(wrappedKey)

        return Session(sessionID: sessionID, fileKey: fileKey, header: header)
    }

    static func associatedData(sessionID: Data, sequence: UInt64) -> Data {
        var data = sessionID
        var bigEndianSequence = sequence.bigEndian
        data.append(withUnsafeBytes(of: &bigEndianSequence) { Data($0) })
        return data
    }

    static func sessionID() -> Data {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}

enum DiagnosticLogPublicKeyConfiguration {
    static let environmentVariable = "SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64"
    static let infoPlistKey = "SayAllDiagnosticPublicKey"

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Data? {
        let value = environment[environmentVariable] ??
            (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
