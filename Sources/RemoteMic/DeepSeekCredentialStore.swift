import Foundation
import Security

enum DeepSeekCredentialStoreError: Error {
    case invalidValue
    case unexpectedStatus(OSStatus)
}

struct DeepSeekCredentialStore {
    static let service = "com.hd838a.RemoteMic.deepseek"
    static let account = "deepseek-api-key"

    private let applicationKeychainURL: URL

    init(applicationKeychainURL: URL? = nil) {
        self.applicationKeychainURL = applicationKeychainURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remote Mic", isDirectory: true)
            .appendingPathComponent("RemoteMic.keychain-db")
    }

    static func maskedPreview(for apiKey: String) -> String {
        guard apiKey.count > 8 else {
            return String(repeating: "•", count: apiKey.count)
        }
        return "\(apiKey.prefix(4))••••\(apiKey.suffix(4))"
    }

    func loadAPIKey() throws -> String? {
        do {
            if let apiKey = try loadAPIKey(using: dataProtectionQuery) {
                return apiKey
            }
        } catch DeepSeekCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            // The application-specific Keychain below does not require a shared access group.
        }
        return try loadAPIKey(using: applicationKeychainSearchQuery())
    }

    private func loadAPIKey(using baseQuery: [String: Any]) throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw DeepSeekCredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { throw DeepSeekCredentialStoreError.invalidValue }
        return value
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw DeepSeekCredentialStoreError.invalidValue
        }
        do {
            try saveAPIKeyData(data, updateQuery: dataProtectionQuery)
        } catch DeepSeekCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            try saveAPIKeyData(
                data,
                updateQuery: applicationKeychainSearchQuery(),
                addQuery: applicationKeychainAddQuery()
            )
        }
    }

    private func saveAPIKeyData(
        _ data: Data,
        updateQuery: [String: Any],
        addQuery: [String: Any]? = nil
    ) throws {
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw DeepSeekCredentialStoreError.unexpectedStatus(updateStatus)
        }

        var item = addQuery ?? updateQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DeepSeekCredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    func deleteAPIKey() throws {
        do {
            try deleteAPIKey(using: dataProtectionQuery)
        } catch DeepSeekCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            // Continue with the application-specific Keychain below.
        }
        try deleteAPIKey(using: applicationKeychainSearchQuery())
    }

    private func deleteAPIKey(using baseQuery: [String: Any]) throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekCredentialStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
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
            throw DeepSeekCredentialStoreError.unexpectedStatus(trustedStatus)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Remote Mic DeepSeek API" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw DeepSeekCredentialStoreError.unexpectedStatus(accessStatus)
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
            let openStatus = applicationKeychainURL.path.withCString {
                SecKeychainOpen($0, &keychain)
            }
            guard openStatus == errSecSuccess else {
                throw DeepSeekCredentialStoreError.unexpectedStatus(openStatus)
            }
        } else {
            let createStatus = applicationKeychainURL.path.withCString { path in
                "".withCString { password in
                    SecKeychainCreate(path, 0, password, false, nil, &keychain)
                }
            }
            guard createStatus == errSecSuccess else {
                throw DeepSeekCredentialStoreError.unexpectedStatus(createStatus)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: applicationKeychainURL.path
            )
        }

        guard let keychain else { throw DeepSeekCredentialStoreError.invalidValue }
        let unlockStatus = "".withCString {
            SecKeychainUnlock(keychain, 0, $0, true)
        }
        guard unlockStatus == errSecSuccess else {
            throw DeepSeekCredentialStoreError.unexpectedStatus(unlockStatus)
        }
        return keychain
    }
}
