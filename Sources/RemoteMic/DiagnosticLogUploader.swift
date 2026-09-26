import Foundation
import Sentry

struct DiagnosticLogEntry: Equatable {
    let sequence: Int
    let message: String
}

enum DiagnosticLogUploadError: Error, Equatable {
    case serviceNotConfigured
    case invalidServiceConfiguration
    case noLogs
    case uploadFailed
}

final class DiagnosticLogUploader: @unchecked Sendable {
    static let shared = DiagnosticLogUploader()

    typealias Sender = (_ entries: [DiagnosticLogEntry], _ dsn: String) throws -> Void

    private let eventProvider: () -> [PublicDiagnosticEvent]
    private let publicEventAcknowledger: ([PublicDiagnosticEvent]) -> Void
    private let dsnProvider: () -> String?
    private let sender: Sender
    private let queue = DispatchQueue(label: "RemoteMic.diagnosticUpload", qos: .userInitiated)
    private weak var privateEventProvider: (any PrivateDiagnosticUploadProvider)?

    init(
        eventProvider: @escaping () -> [PublicDiagnosticEvent] = {
            AppLogger.shared.publicDiagnosticEvents()
        },
        publicEventAcknowledger: @escaping ([PublicDiagnosticEvent]) -> Void = {
            AppLogger.shared.markPublicDiagnosticEventsUploaded($0)
        },
        dsnProvider: @escaping () -> String? = { DiagnosticLogUploader.configuredDSN() },
        sender: @escaping Sender = DiagnosticLogUploader.sendToSentry
    ) {
        self.eventProvider = eventProvider
        self.publicEventAcknowledger = publicEventAcknowledger
        self.dsnProvider = dsnProvider
        self.sender = sender
    }

    func setPrivateEventProvider(_ provider: (any PrivateDiagnosticUploadProvider)?) {
        queue.sync {
            privateEventProvider = provider
        }
    }

    func upload(completion: @escaping (Result<Int, DiagnosticLogUploadError>) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.failure(.uploadFailed)) }
                return
            }
            guard let dsn = self.validatedDSN() else {
                let result = self.dsnFailure()
                DispatchQueue.main.async { completion(result) }
                return
            }
            let approvedPublicEvents = self.approvedPublicEvents()
            let publicEntries = Self.publicEntries(approvedPublicEvents)
            let provider = self.privateEventProvider
            Task {
                let privateRecords = await provider?.pendingPrivateDiagnosticRecords() ?? []
                self.queue.async {
                    let approvedPrivateRecords = Self.approvedPrivateRecords(privateRecords)
                    let privateEntries = Self.privateEntries(
                        approvedPrivateRecords,
                        startingAt: publicEntries.count
                    )
                    let entries = publicEntries + privateEntries
                    guard !entries.isEmpty else {
                        DispatchQueue.main.async { completion(.failure(.noLogs)) }
                        return
                    }
                    do {
                        try self.sender(entries, dsn)
                    } catch {
                        DispatchQueue.main.async { completion(.failure(.uploadFailed)) }
                        return
                    }
                    self.publicEventAcknowledger(approvedPublicEvents)
                    let uploadedRecordIDs = Set(approvedPrivateRecords.map(\.recordID))
                    Task {
                        await provider?.markPrivateDiagnosticRecordsUploaded(uploadedRecordIDs)
                        DispatchQueue.main.async { completion(.success(entries.count)) }
                    }
                }
            }
        }
    }

    func uploadSynchronously() -> Result<Int, DiagnosticLogUploadError> {
        uploadSynchronously(privateRecords: [])
    }

    func uploadSynchronously(
        privateRecords: [PrivateDiagnosticUploadRecord]
    ) -> Result<Int, DiagnosticLogUploadError> {
        guard let dsn = validatedDSN() else { return dsnFailure() }
        let approvedPublicEvents = approvedPublicEvents()
        let publicEntries = Self.publicEntries(approvedPublicEvents)
        let entries = publicEntries + Self.privateEntries(
            Self.approvedPrivateRecords(privateRecords),
            startingAt: publicEntries.count
        )
        guard !entries.isEmpty else { return .failure(.noLogs) }

        do {
            try sender(entries, dsn)
            publicEventAcknowledger(approvedPublicEvents)
            return .success(entries.count)
        } catch {
            return .failure(.uploadFailed)
        }
    }

    private func validatedDSN() -> String? {
        guard let dsn = dsnProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dsn.isEmpty,
              Self.isValidDSN(dsn) else { return nil }
        return dsn
    }

    private func dsnFailure() -> Result<Int, DiagnosticLogUploadError> {
        guard let dsn = dsnProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dsn.isEmpty else { return .failure(.serviceNotConfigured) }
        return .failure(.invalidServiceConfiguration)
    }

    private func approvedPublicEvents() -> [PublicDiagnosticEvent] {
        eventProvider().filter { event in
            guard event.isApprovedForUpload,
                  PublicDiagnosticEvent.parse(event.canonicalLine) != nil
            else { return false }
            return true
        }
    }

    private static func publicEntries(
        _ events: [PublicDiagnosticEvent]
    ) -> [DiagnosticLogEntry] {
        events.enumerated().map { index, event in
            return DiagnosticLogEntry(sequence: index, message: event.canonicalLine)
        }
    }

    private static func privateEntries(
        _ records: [PrivateDiagnosticUploadRecord],
        startingAt offset: Int
    ) -> [DiagnosticLogEntry] {
        records.enumerated().map { index, record in
            DiagnosticLogEntry(
                sequence: offset + index,
                message: record.canonicalLine
            )
        }
    }

    private static func approvedPrivateRecords(
        _ records: [PrivateDiagnosticUploadRecord]
    ) -> [PrivateDiagnosticUploadRecord] {
        var approved: [PrivateDiagnosticUploadRecord] = []
        var seenRecordIDs = Set<String>()
        for record in records.prefix(256) {
            guard seenRecordIDs.insert(record.recordID).inserted,
                  PrivateDiagnosticUploadRecord.parse(record.canonicalLine) == record
            else { continue }
            approved.append(record)
        }
        return approved
    }

    static func configuredDSN(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        let value = environment["REMOTE_MIC_SENTRY_DSN"] ??
            infoDictionary?["SayAllSentryDSN"] as? String
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func isValidDSN(_ dsn: String) -> Bool {
        guard let components = URLComponents(string: dsn) else { return false }
        return components.scheme == "https" &&
            components.host != nil &&
            components.user != nil &&
            components.password == nil &&
            components.port == nil &&
            components.query == nil &&
            components.fragment == nil &&
            components.path.split(separator: "/").last != nil
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
            try? FileManager.default.trashItem(at: cacheDirectory, resultingItemURL: nil)
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
                options.beforeSendLog = { log in
                    let canonicalBody: String
                    if let event = PublicDiagnosticEvent.parse(log.body),
                       event.isApprovedForUpload {
                        canonicalBody = event.canonicalLine
                    } else if let record = PrivateDiagnosticUploadRecord.parse(log.body) {
                        canonicalBody = record.canonicalLine
                    } else {
                        return nil
                    }

                    var attributes: [String: SentryLog.Attribute] = [
                        "diagnostic.user_initiated": SentryLog.Attribute(boolean: true),
                        "diagnostic.schema_version": SentryLog.Attribute(integer: PublicDiagnosticEvent.schemaVersion),
                    ]
                    if let sequence = log.attributes["diagnostic.sequence"]?.value as? Int,
                       sequence >= 0 {
                        attributes["diagnostic.sequence"] = SentryLog.Attribute(integer: sequence)
                    }
                    return SentryLog(
                        level: log.level,
                        body: canonicalBody,
                        attributes: attributes
                    )
                }
            }
            SentrySDK.configureScope { scope in
                scope.clear()
            }
            SentrySDK.setUser(nil)
        }
        guard SentrySDK.isEnabled else { throw DiagnosticLogUploadError.uploadFailed }

        let sentryLogger = SentrySDK.logger
        for entry in entries {
            let canonicalBody: String
            if let event = PublicDiagnosticEvent.parse(entry.message),
               event.isApprovedForUpload {
                canonicalBody = event.canonicalLine
            } else if let record = PrivateDiagnosticUploadRecord.parse(entry.message) {
                canonicalBody = record.canonicalLine
            } else {
                continue
            }
            sentryLogger.info(
                canonicalBody,
                attributes: [
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
