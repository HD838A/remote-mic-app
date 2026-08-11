import Foundation
import Testing
@testable import RemoteMic

private final class EarlyAccessURLProtocol: URLProtocol {
    static var response: HTTPURLResponse?
    static var data = Data()
    static var requestHandler: ((URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestHandler?(request)
        if let response = Self.response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Early Access client", .serialized)
struct EarlyAccessClientTests {
    @Test func sendsOnlyExpectedMetadataAndParsesBoundedResponse() async throws {
        let endpoint = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EarlyAccessURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let serverTime = "2026-08-12T00:00:00Z"
        EarlyAccessURLProtocol.response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        EarlyAccessURLProtocol.data = try JSONSerialization.data(withJSONObject: [
            "decision": "allow",
            "entitlement": "header.payload.signature",
            "expires_at": 2_000,
            "grant_id": "gr_12345678901234567890",
            "refresh_after": 1_500,
            "refresh_credential": String(repeating: "r", count: 43),
            "request_id": "req_test",
            "server_time": serverTime,
        ])
        EarlyAccessURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/v1/apps/remote-mic-macos/redeem")
            let object = requestBody(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: String]
            }
            #expect(object?["code"] == "EA-TEST-CODE")
            #expect(object?["feature_key"] == "deepseek_post_dictation")
            #expect(object?.keys.sorted() == [
                "anonymous_device_id", "app_build", "app_version", "code", "feature_key", "platform",
            ])
        }

        let response = try await EarlyAccessClient(serviceURL: endpoint, session: session).redeem(
            code: "EA-TEST-CODE",
            anonymousDeviceID: "anonymous-device-id-123456",
            appVersion: "1.8.12",
            appBuild: "104"
        )
        #expect(response.requestID == "req_test")
        #expect(response.refreshAfter == 1_500)
    }

    @Test func mapsServerDenialWithoutLeakingRequestBody() async throws {
        let endpoint = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EarlyAccessURLProtocol.self]
        let session = URLSession(configuration: configuration)
        EarlyAccessURLProtocol.response = HTTPURLResponse(
            url: endpoint,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )
        EarlyAccessURLProtocol.data = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "revoked"],
            "request_id": "req_denied",
        ])
        EarlyAccessURLProtocol.requestHandler = nil

        do {
            _ = try await EarlyAccessClient(serviceURL: endpoint, session: session).refresh(
                grantID: "gr_12345678901234567890",
                refreshCredential: String(repeating: "r", count: 43),
                anonymousDeviceID: "anonymous-device-id-123456",
                appVersion: "1.8.12",
                appBuild: "104"
            )
            Issue.record("Expected a server denial")
        } catch {
            #expect(error as? EarlyAccessClientError == .server(code: "revoked", requestID: "req_denied"))
        }
    }
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}
