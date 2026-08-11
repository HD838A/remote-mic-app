import Foundation

enum EarlyAccessConfiguration {
    static let infoDictionaryKey = "EarlyAccessServiceURL"
    static let environmentKey = "EARLY_ACCESS_SERVICE_URL"

    static func serviceURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL? {
        let rawValue = environment[environmentKey]
            ?? infoDictionary[infoDictionaryKey] as? String
        return validatedServiceURL(rawValue)
    }

    static func validatedServiceURL(_ rawValue: String?) -> URL? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }
        return url
    }
}

struct EarlyAccessAPIResponse: Equatable {
    let grantID: String
    let refreshCredential: String
    let entitlement: String
    let refreshAfter: Int64
    let expiresAt: Int64
    let requestID: String
    let serverTime: Date
}

protocol EarlyAccessClientProtocol {
    func redeem(
        code: String,
        anonymousDeviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> EarlyAccessAPIResponse

    func refresh(
        grantID: String,
        refreshCredential: String,
        anonymousDeviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> EarlyAccessAPIResponse

    func release(
        grantID: String,
        refreshCredential: String,
        anonymousDeviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> String?
}

enum EarlyAccessClientError: Error, Equatable {
    case unavailableConfiguration
    case invalidResponse
    case requestFailed
    case server(code: String, requestID: String?)
}

struct EarlyAccessClient: EarlyAccessClientProtocol {
    static let maximumResponseBytes = 32 * 1_024

    private let serviceURL: URL?
    private let session: URLSession

    init(serviceURL: URL? = EarlyAccessConfiguration.serviceURL(), session: URLSession = .shared) {
        self.serviceURL = serviceURL
        self.session = session
    }

    func redeem(
        code: String,
        anonymousDeviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> EarlyAccessAPIResponse {
        try await send(
            action: "redeem",
            body: [
                "anonymous_device_id": anonymousDeviceID,
                "app_build": appBuild,
                "app_version": appVersion,
                "code": code,
                "feature_key": EarlyAccessFeature.deepSeekPostDictation.rawValue,
                "platform": "macos",
            ]
        )
    }

    func refresh(
        grantID: String,
        refreshCredential: String,
        anonymousDeviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> EarlyAccessAPIResponse {
        try await send(
            action: "refresh",
            body: [
                "anonymous_device_id": anonymousDeviceID,
                "app_build": appBuild,
                "app_version": appVersion,
                "feature_key": EarlyAccessFeature.deepSeekPostDictation.rawValue,
                "grant_id": grantID,
                "platform": "macos",
                "refresh_credential": refreshCredential,
            ]
        )
    }

    func release(
        grantID: String,
        refreshCredential: String,
        anonymousDeviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> String? {
        let response = try await sendRaw(
            action: "release",
            body: [
                "anonymous_device_id": anonymousDeviceID,
                "app_build": appBuild,
                "app_version": appVersion,
                "feature_key": EarlyAccessFeature.deepSeekPostDictation.rawValue,
                "grant_id": grantID,
                "platform": "macos",
                "refresh_credential": refreshCredential,
            ]
        )
        guard response.object["released"] as? Bool == true else {
            throw EarlyAccessClientError.invalidResponse
        }
        return response.object["request_id"] as? String
    }

    private func send(action: String, body: [String: String]) async throws -> EarlyAccessAPIResponse {
        let response = try await sendRaw(action: action, body: body)
        let object = response.object
        guard object["decision"] as? String == "allow",
              let grantID = object["grant_id"] as? String,
              let refreshCredential = object["refresh_credential"] as? String,
              let entitlement = object["entitlement"] as? String,
              let refreshAfter = Self.integer(object["refresh_after"]),
              let expiresAt = Self.integer(object["expires_at"]),
              let requestID = object["request_id"] as? String,
              let serverTimeString = object["server_time"] as? String,
              let serverTime = ISO8601DateFormatter().date(from: serverTimeString),
              !grantID.isEmpty,
              refreshCredential.count >= 32,
              !entitlement.isEmpty,
              refreshAfter < expiresAt
        else { throw EarlyAccessClientError.invalidResponse }
        return EarlyAccessAPIResponse(
            grantID: grantID,
            refreshCredential: refreshCredential,
            entitlement: entitlement,
            refreshAfter: refreshAfter,
            expiresAt: expiresAt,
            requestID: requestID,
            serverTime: serverTime
        )
    }

    private func sendRaw(
        action: String,
        body: [String: String]
    ) async throws -> (object: [String: Any], response: HTTPURLResponse) {
        guard let serviceURL else { throw EarlyAccessClientError.unavailableConfiguration }
        let endpoint = serviceURL
            .appendingPathComponent("v1/apps")
            .appendingPathComponent(EarlyAccessEntitlementVerifier.applicationKey)
            .appendingPathComponent(action)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard request.httpBody != nil else { throw EarlyAccessClientError.invalidResponse }

        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch {
            throw EarlyAccessClientError.requestFailed
        }
        guard data.count <= Self.maximumResponseBytes,
              let response = rawResponse as? HTTPURLResponse,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EarlyAccessClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let errorObject = object["error"] as? [String: Any]
            throw EarlyAccessClientError.server(
                code: errorObject?["code"] as? String ?? "feature_unavailable",
                requestID: object["request_id"] as? String
            )
        }
        return (object, response)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}
