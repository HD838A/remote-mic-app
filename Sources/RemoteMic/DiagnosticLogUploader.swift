import Foundation
import Sentry

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
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SayAll-Sentry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            runOnMainThread {
                if SentrySDK.isEnabled {
                    SentrySDK.close()
                }
            }
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        runOnMainThread {
            SentrySDK.start { options in
                options.dsn = dsn
                options.enableLogs = true
                options.enableCrashHandler = false
                options.enableUncaughtNSExceptionReporting = false
                options.enableSigtermReporting = false
                options.enableAutoSessionTracking = false
                options.enableWatchdogTerminationTracking = false
                options.enableAutoPerformanceTracing = false
                options.enableNetworkTracking = false
                options.enableNetworkBreadcrumbs = false
                options.enableFileIOTracing = false
                options.enableDataSwizzling = false
                options.enableFileManagerSwizzling = false
                options.enableSwizzling = false
                options.enableCoreDataTracing = false
                options.enableAppHangTracking = false
                options.enableAutoBreadcrumbTracking = false
                options.enableCaptureFailedRequests = false
                options.enableMetricKit = false
                options.enableMetricKitRawPayload = false
                options.enableMetrics = false
                options.sendClientReports = false
                options.attachStacktrace = false
                options.sendDefaultPii = false
                options.maxBreadcrumbs = 0
                options.tracesSampleRate = 0
                options.cacheDirectoryPath = cacheDirectory.path
                options.shutdownTimeInterval = 0
                options.beforeSend = { _ in nil }
            }
        }
        guard SentrySDK.isEnabled else { throw DiagnosticLogUploadError.uploadFailed }

        let sentryLogger = SentrySDK.logger
        for entry in entries {
            sentryLogger.info(
                entry.message,
                attributes: [
                    "diagnostic.day": entry.day,
                    "diagnostic.sequence": entry.sequence,
                    "diagnostic.user_initiated": true,
                ]
            )
        }
        SentrySDK.flush(timeout: 25)
        guard !hasPendingSentryEnvelopes(in: cacheDirectory) else {
            throw DiagnosticLogUploadError.uploadFailed
        }
    }

    private static func runOnMainThread(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private static func hasPendingSentryEnvelopes(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        for case let url as URL in enumerator where url.pathComponents.contains("envelopes") {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
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
