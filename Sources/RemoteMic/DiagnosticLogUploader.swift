import Foundation

struct DiagnosticLogEntry: Equatable {
    let day: String
    let sequence: Int
    let message: String
}

enum DiagnosticLogUploadError: Error, Equatable {
    case serviceNotConfigured
    case invalidServiceConfiguration
    case noLogs
    case uploadFailed
}

struct DiagnosticLogSanitizer {
    private let sensitiveValues: [String]

    init(additionalSensitiveValues: [String] = []) {
        sensitiveValues = Set(
            additionalSensitiveValues + [
                FileManager.default.homeDirectoryForCurrentUser.path,
                NSUserName(),
                NSFullUserName(),
                Host.current().localizedName ?? "",
                ProcessInfo.processInfo.hostName,
            ]
        )
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }
    }

    func sanitize(_ message: String) -> String {
        var result = message
        for value in sensitiveValues {
            result = result.replacingOccurrences(of: value, with: "<redacted>")
        }
        for (pattern, replacement) in Self.patterns {
            result = result.replacingMatches(of: pattern, with: replacement)
        }
        return result
    }

    private static let patterns: [(String, String)] = [
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
        (#"\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b"#, "<redacted-uuid>"),
        (#"(?i)\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b"#, "<redacted-address>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ip>"),
        (#"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1<redacted-token>"),
        (#"(?i)\b(api[_-]?key|token|secret|password)=\S+"#, "$1=<redacted>"),
    ]
}

final class DiagnosticLogUploader {
    static let shared = DiagnosticLogUploader()

    typealias Sender = (_ entries: [DiagnosticLogEntry], _ dsn: String) throws -> Void

    private let logger: AppLogger
    private let sanitizer: DiagnosticLogSanitizer
    private let dsnProvider: () -> String?
    private let sender: Sender
    private let dateProvider: () -> Date
    private let queue = DispatchQueue(label: "RemoteMic.diagnosticUpload", qos: .userInitiated)

    init(
        logger: AppLogger = .shared,
        sanitizer: DiagnosticLogSanitizer = DiagnosticLogSanitizer(),
        dsnProvider: @escaping () -> String? = DiagnosticLogUploader.configuredDSN,
        sender: @escaping Sender = DiagnosticLogUploader.sendToSentry,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.logger = logger
        self.sanitizer = sanitizer
        self.dsnProvider = dsnProvider
        self.sender = sender
        self.dateProvider = dateProvider
    }

    func upload(completion: @escaping (Result<Int, DiagnosticLogUploadError>) -> Void) {
        queue.async { [weak self] in
            let result = self?.uploadSynchronously() ?? .failure(.uploadFailed)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func uploadSynchronously() -> Result<Int, DiagnosticLogUploadError> {
        guard let dsn = dsnProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dsn.isEmpty
        else { return .failure(.serviceNotConfigured) }
        guard Self.isValidDSN(dsn) else {
            return .failure(.invalidServiceConfiguration)
        }

        do {
            let documents = try logger.diagnosticDocuments(referenceDate: dateProvider())
            let entries = documents.flatMap { document in
                document.lines.enumerated().map { index, line in
                    DiagnosticLogEntry(
                        day: document.day,
                        sequence: index,
                        message: sanitizer.sanitize(line)
                    )
                }
            }
            guard !entries.isEmpty else { return .failure(.noLogs) }
            try sender(entries, dsn)
            return .success(entries.count)
        } catch {
            return .failure(.uploadFailed)
        }
    }

    private static func configuredDSN() -> String? {
        if let environmentDSN = ProcessInfo.processInfo.environment["REMOTE_MIC_SENTRY_DSN"],
           !environmentDSN.isEmpty {
            return environmentDSN
        }
        return Bundle.main.object(forInfoDictionaryKey: "RemoteMicSentryDSN") as? String
    }

    private static func isValidDSN(_ dsn: String) -> Bool {
        guard let components = URLComponents(string: dsn) else { return false }
        return components.scheme == "https"
            && components.host != nil
            && components.user != nil
            && components.path.split(separator: "/").last != nil
    }

    private static func sendToSentry(entries: [DiagnosticLogEntry], dsn: String) throws {
        let endpoint = try SentryEnvelopeEndpoint(dsn: dsn)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for batch in entries.chunked(maximumCount: 250) {
            let envelope = try SentryLogEnvelope(entries: batch).data()
            var request = URLRequest(url: endpoint.url)
            request.httpMethod = "POST"
            request.httpBody = envelope
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(
                "application/x-sentry-envelope",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "X-Sentry-Auth")

            let result = SentryHTTPResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            session.dataTask(with: request) { _, response, error in
                result.error = error
                result.response = response as? HTTPURLResponse
                semaphore.signal()
            }.resume()
            guard semaphore.wait(timeout: .now() + 25) == .success,
                  result.error == nil,
                  let statusCode = result.response?.statusCode,
                  (200..<300).contains(statusCode)
            else { throw DiagnosticLogUploadError.uploadFailed }
        }
    }
}

private final class SentryHTTPResultBox: @unchecked Sendable {
    var response: HTTPURLResponse?
    var error: Error?
}

struct SentryEnvelopeEndpoint {
    let url: URL
    let authorizationHeader: String

    init(dsn: String) throws {
        guard var components = URLComponents(string: dsn),
              components.scheme == "https",
              let publicKey = components.user,
              components.host != nil
        else { throw DiagnosticLogUploadError.invalidServiceConfiguration }

        let pathComponents = components.path.split(separator: "/")
        guard let projectID = pathComponents.last, !projectID.isEmpty else {
            throw DiagnosticLogUploadError.invalidServiceConfiguration
        }
        let prefix = pathComponents.dropLast().map(String.init).joined(separator: "/")
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/" + ([prefix, "api", String(projectID), "envelope"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")) + "/"
        guard let endpointURL = components.url else {
            throw DiagnosticLogUploadError.invalidServiceConfiguration
        }

        url = endpointURL
        authorizationHeader = [
            "Sentry sentry_version=7",
            "sentry_key=\(publicKey)",
            "sentry_client=remote-mic-diagnostics/1.0",
        ].joined(separator: ", ")
    }
}

struct SentryLogEnvelope {
    let entries: [DiagnosticLogEntry]

    func data() throws -> Data {
        let payloadObject: [String: Any] = [
            "items": entries.map(logObject),
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject)
        let itemHeader: [String: Any] = [
            "type": "log",
            "item_count": entries.count,
            "content_type": "application/vnd.sentry.items.log+json",
            "length": payload.count,
        ]
        let headerData = try JSONSerialization.data(withJSONObject: [:])
        let itemHeaderData = try JSONSerialization.data(withJSONObject: itemHeader)

        var envelope = Data()
        envelope.append(headerData)
        envelope.append(0x0A)
        envelope.append(itemHeaderData)
        envelope.append(0x0A)
        envelope.append(payload)
        return envelope
    }

    private func logObject(_ entry: DiagnosticLogEntry) -> [String: Any] {
        [
            "timestamp": timestamp(from: entry.message),
            "trace_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "level": "info",
            "severity_number": 9,
            "body": entry.message,
            "attributes": [
                "diagnostic.day": ["type": "string", "value": entry.day],
                "diagnostic.sequence": ["type": "integer", "value": entry.sequence],
                "diagnostic.user_initiated": ["type": "boolean", "value": true],
            ],
        ]
    }

    private func timestamp(from message: String) -> TimeInterval {
        guard let separator = message.firstIndex(of: " ") else {
            return Date().timeIntervalSince1970
        }
        let timestamp = String(message[..<separator])
        return ISO8601DateFormatter().date(from: timestamp)?.timeIntervalSince1970
            ?? Date().timeIntervalSince1970
    }
}

private extension String {
    func replacingMatches(of pattern: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return self }
        return expression.stringByReplacingMatches(
            in: self,
            range: NSRange(startIndex..., in: self),
            withTemplate: template
        )
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map { start in
            Array(self[start..<Swift.min(start + maximumCount, count)])
        }
    }
}
