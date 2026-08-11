import Foundation
import Security

struct EarlyAccessGrantBundle: Codable, Equatable {
    let schemaVersion: Int
    let grantID: String
    let refreshCredential: String
    let entitlement: String
    let subject: String
    let serverTime: Date
    let processUptime: TimeInterval
    let blockedReason: String?

    init(
        grantID: String,
        refreshCredential: String,
        entitlement: String,
        subject: String,
        serverTime: Date,
        processUptime: TimeInterval,
        blockedReason: String? = nil
    ) {
        schemaVersion = 1
        self.grantID = grantID
        self.refreshCredential = refreshCredential
        self.entitlement = entitlement
        self.subject = subject
        self.serverTime = serverTime
        self.processUptime = processUptime
        self.blockedReason = blockedReason
    }
}

enum EarlyAccessCredentialStoreError: Error, Equatable {
    case invalidValue
    case unexpectedStatus(OSStatus)
}

struct EarlyAccessCredentialStore {
    static let service = "com.hd838a.RemoteMic.early-access"
    static let deviceAccount = "anonymous-device-id"
    static let grantAccount = "grant-bundle"

    private let applicationKeychainURL: URL

    init(applicationKeychainURL: URL? = nil) {
        self.applicationKeychainURL = applicationKeychainURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remote Mic", isDirectory: true)
            .appendingPathComponent("RemoteMic.keychain-db")
    }

    func loadDeviceID() throws -> String? {
        try loadString(account: Self.deviceAccount)
    }

    func createDeviceIDIfNeeded() throws -> String {
        if let existing = try loadDeviceID() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EarlyAccessCredentialStoreError.invalidValue
        }
        let identifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try save(Data(identifier.utf8), account: Self.deviceAccount)
        return identifier
    }

    func loadGrantBundle() throws -> EarlyAccessGrantBundle? {
        guard let data = try load(account: Self.grantAccount) else { return nil }
        guard let bundle = try? JSONDecoder().decode(EarlyAccessGrantBundle.self, from: data),
              bundle.schemaVersion == 1,
              !bundle.grantID.isEmpty,
              bundle.refreshCredential.count >= 32,
              !bundle.entitlement.isEmpty,
              !bundle.subject.isEmpty,
              bundle.processUptime >= 0
        else { throw EarlyAccessCredentialStoreError.invalidValue }
        return bundle
    }

    func saveGrantBundle(_ bundle: EarlyAccessGrantBundle) throws {
        guard bundle.schemaVersion == 1,
              !bundle.grantID.isEmpty,
              bundle.refreshCredential.count >= 32,
              !bundle.entitlement.isEmpty,
              !bundle.subject.isEmpty,
              bundle.processUptime >= 0,
              let data = try? JSONEncoder().encode(bundle)
        else { throw EarlyAccessCredentialStoreError.invalidValue }
        try save(data, account: Self.grantAccount)
    }

    func deleteGrantBundle() throws {
        try delete(account: Self.grantAccount)
    }

    func deleteAll() throws {
        try delete(account: Self.grantAccount)
        try delete(account: Self.deviceAccount)
    }

    private func loadString(account: String) throws -> String? {
        guard let data = try load(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw EarlyAccessCredentialStoreError.invalidValue
        }
        return value
    }

    private func load(account: String) throws -> Data? {
        do {
            if let data = try load(using: dataProtectionQuery(account: account)) {
                return data
            }
        } catch EarlyAccessCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            // The application-specific Keychain below does not require a shared access group.
        }
        return try load(using: applicationKeychainSearchQuery(account: account))
    }

    private func load(using baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(status)
        }
        return data
    }

    private func save(_ data: Data, account: String) throws {
        guard !data.isEmpty else { throw EarlyAccessCredentialStoreError.invalidValue }
        do {
            try save(data, updateQuery: dataProtectionQuery(account: account))
        } catch EarlyAccessCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            try save(
                data,
                updateQuery: applicationKeychainSearchQuery(account: account),
                addQuery: applicationKeychainAddQuery(account: account)
            )
        }
    }

    private func save(
        _ data: Data,
        updateQuery: [String: Any],
        addQuery: [String: Any]? = nil
    ) throws {
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(updateStatus)
        }

        var item = addQuery ?? updateQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    private func delete(account: String) throws {
        do {
            try delete(using: dataProtectionQuery(account: account))
        } catch EarlyAccessCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            // Continue with the application-specific Keychain below.
        }
        try delete(using: applicationKeychainSearchQuery(account: account))
    }

    private func delete(using query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func dataProtectionQuery(account: String) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private func applicationKeychainSearchQuery(account: String) throws -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecMatchSearchList as String] = [try applicationKeychain()]
        return query
    }

    private func applicationKeychainAddQuery(account: String) throws -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecUseKeychain as String] = try applicationKeychain()
        query[kSecAttrAccess as String] = try applicationKeychainAccess()
        return query
    }

    private func applicationKeychainAccess() throws -> SecAccess {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(trustedStatus)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Remote Mic Early Access" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(accessStatus)
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
            let status = applicationKeychainURL.path.withCString { SecKeychainOpen($0, &keychain) }
            guard status == errSecSuccess else {
                throw EarlyAccessCredentialStoreError.unexpectedStatus(status)
            }
        } else {
            let status = applicationKeychainURL.path.withCString { path in
                "".withCString { password in
                    SecKeychainCreate(path, 0, password, false, nil, &keychain)
                }
            }
            guard status == errSecSuccess else {
                throw EarlyAccessCredentialStoreError.unexpectedStatus(status)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: applicationKeychainURL.path
            )
        }

        guard let keychain else { throw EarlyAccessCredentialStoreError.invalidValue }
        let unlockStatus = "".withCString { SecKeychainUnlock(keychain, 0, $0, true) }
        guard unlockStatus == errSecSuccess else {
            throw EarlyAccessCredentialStoreError.unexpectedStatus(unlockStatus)
        }
        return keychain
    }
}
