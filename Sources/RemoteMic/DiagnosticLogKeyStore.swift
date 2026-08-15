import Foundation
import Security

enum DiagnosticLogKeyStoreError: Error {
    case keychain(OSStatus)
    case random(OSStatus)
    case invalidKey
}

struct DiagnosticLogKeyStore {
    private let service: String
    private let account: String
    private let applicationKeychainURL: URL

    init(
        service: String = "com.hd838a.RemoteMic.diagnostic-logs",
        account: String = "aes-gcm-key-v1",
        applicationKeychainURL: URL? = nil
    ) {
        self.service = service
        self.account = account
        self.applicationKeychainURL = applicationKeychainURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remote Mic", isDirectory: true)
            .appendingPathComponent("DiagnosticLogs.keychain-db")
    }

    func loadOrCreateKeyData() throws -> Data {
        do {
            if let key = try loadKey(using: dataProtectionQuery) {
                return key
            }
            let key = try randomKeyData()
            try addKey(key, using: dataProtectionQuery)
            return key
        } catch DiagnosticLogKeyStoreError.keychain(errSecMissingEntitlement) {
            return try loadOrCreateApplicationKeychainKey()
        } catch DiagnosticLogKeyStoreError.keychain(errSecAuthFailed) {
            return try loadOrCreateApplicationKeychainKey()
        }
    }

    func deleteKeyData() throws {
        do {
            try deleteKey(using: dataProtectionQuery)
        } catch DiagnosticLogKeyStoreError.keychain(errSecMissingEntitlement) {
            // Continue with the application-specific Keychain below.
        } catch DiagnosticLogKeyStoreError.keychain(errSecAuthFailed) {
            // Continue with the application-specific Keychain below.
        }
        try deleteKey(using: applicationKeychainSearchQuery())
        if FileManager.default.fileExists(atPath: applicationKeychainURL.path) {
            var keychain: SecKeychain?
            if SecKeychainOpen(applicationKeychainURL.path, &keychain) == errSecSuccess,
               let keychain {
                SecKeychainDelete(keychain)
            }
        }
    }

    private func loadOrCreateApplicationKeychainKey() throws -> Data {
        let searchQuery = try applicationKeychainSearchQuery()
        if let key = try loadKey(using: searchQuery) {
            return key
        }
        let key = try randomKeyData()
        try addKey(key, using: applicationKeychainAddQuery())
        return key
    }

    private func loadKey(using baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw DiagnosticLogKeyStoreError.keychain(status)
        }
        guard let key = item as? Data, key.count == 32 else {
            throw DiagnosticLogKeyStoreError.invalidKey
        }
        return key
    }

    private func addKey(_ key: Data, using baseQuery: [String: Any]) throws {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrLabel as String] = "Remote Mic Diagnostic Log Encryption Key"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DiagnosticLogKeyStoreError.keychain(status)
        }
    }

    private func deleteKey(using query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DiagnosticLogKeyStoreError.keychain(status)
        }
    }

    private func randomKeyData() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DiagnosticLogKeyStoreError.random(status)
        }
        return Data(bytes)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private var dataProtectionQuery: [String: Any] {
        var query = baseQuery
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private func applicationKeychainSearchQuery() throws -> [String: Any] {
        var query = baseQuery
        query[kSecMatchSearchList as String] = [try applicationKeychain()]
        return query
    }

    private func applicationKeychainAddQuery() throws -> [String: Any] {
        var query = baseQuery
        query[kSecUseKeychain as String] = try applicationKeychain()
        query[kSecAttrAccess as String] = try applicationKeychainAccess()
        return query
    }

    private func applicationKeychainAccess() throws -> SecAccess {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw DiagnosticLogKeyStoreError.keychain(trustedStatus)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Remote Mic Diagnostic Logs" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw DiagnosticLogKeyStoreError.keychain(accessStatus)
        }
        return access
    }

    private func applicationKeychain() throws -> SecKeychain {
        let directory = applicationKeychainURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var keychain: SecKeychain?
        if FileManager.default.fileExists(atPath: applicationKeychainURL.path) {
            let status = applicationKeychainURL.path.withCString {
                SecKeychainOpen($0, &keychain)
            }
            guard status == errSecSuccess else {
                throw DiagnosticLogKeyStoreError.keychain(status)
            }
        } else {
            let status = applicationKeychainURL.path.withCString { path in
                "".withCString { password in
                    SecKeychainCreate(path, 0, password, false, nil, &keychain)
                }
            }
            guard status == errSecSuccess else {
                throw DiagnosticLogKeyStoreError.keychain(status)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: applicationKeychainURL.path
            )
        }

        guard let keychain else { throw DiagnosticLogKeyStoreError.invalidKey }
        let unlockStatus = "".withCString {
            SecKeychainUnlock(keychain, 0, $0, true)
        }
        guard unlockStatus == errSecSuccess else {
            throw DiagnosticLogKeyStoreError.keychain(unlockStatus)
        }
        return keychain
    }
}
