import CryptoKit
import Darwin
import Foundation
import OSLog

final class AppLogger: PublicDiagnosticEventSink {
    struct Metadata: Equatable {
        let processID: Int32
        let version: String
        let build: String

        static func current(
            bundle: Bundle = .main,
            processInfo: ProcessInfo = .processInfo
        ) -> Metadata {
            Metadata(
                processID: processInfo.processIdentifier,
                version: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                build: bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown"
            )
        }
    }

    typealias RetirementHandler = (URL) throws -> Void

    static let shared = AppLogger()

    let logURL: URL
    let isEnabled: Bool

    var logDirectoryURL: URL {
        logURL.deletingLastPathComponent()
    }

    private static let systemLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SayAll",
        category: "AppLogger"
    )
    private static let defaultMaximumFileSize: UInt64 = 10 * 1_024 * 1_024
    private static let maximumPublicEvents = 256

    private let queue = DispatchQueue(label: "RemoteMic.logger")
    private let formatter: ISO8601DateFormatter
    private let metadata: Metadata
    private let maximumFileSize: UInt64
    private let fileManager: FileManager
    private let now: () -> Date
    private let reportFailure: (String) -> Void
    private let sessionID: Data
    private var fileKey: SymmetricKey?
    private var nextSequence: UInt64 = 0
    private var publicEvents: [PublicDiagnosticEvent] = []
    private let publicEventStore: PublicDiagnosticEventStore?

    private convenience init() {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RemoteMic", isDirectory: true)
        let sessionName = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8)
        let day = Self.dayIdentifier(Date())
        self.init(
            logURL: base.appendingPathComponent(
                "sayall.app-\(day)-session-\(sessionName).rmlog"
            ),
            metadata: .current(),
            fileManager: fileManager,
            publicKeyDataProvider: { DiagnosticLogPublicKeyConfiguration.current() },
            publicEventStore: PublicDiagnosticEventStore(fileURL:
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SayAll/Diagnostics/public-events.json")
            ),
            isEnabled: Self.shouldEnableSharedLogging()
        )
    }

    init(
        logURL: URL,
        metadata: Metadata = .current(),
        maximumFileSize: UInt64 = AppLogger.defaultMaximumFileSize,
        archiveCount _: Int = 0,
        fileManager: FileManager = .default,
        retirementHandler _: RetirementHandler? = nil,
        now: @escaping () -> Date = Date.init,
        reportFailure: ((String) -> Void)? = nil,
        publicKeyDataProvider: @escaping () -> Data? = {
            DiagnosticLogPublicKeyConfiguration.current()
        },
        publicEventStore: PublicDiagnosticEventStore? = nil,
        isEnabled: Bool = true
    ) {
        self.logURL = logURL
        self.isEnabled = isEnabled
        self.metadata = Metadata(
            processID: metadata.processID,
            version: Self.stableToken(metadata.version),
            build: Self.stableToken(metadata.build)
        )
        self.maximumFileSize = max(1, maximumFileSize)
        self.fileManager = fileManager
        self.now = now
        self.reportFailure = reportFailure ?? { message in
            Self.systemLogger.error("\(message, privacy: .public)")
        }
        self.sessionID = DiagnosticLogEnvelope.sessionID()
        self.publicEventStore = publicEventStore

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = formatter

        guard isEnabled else { return }
        do {
            try fileManager.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logDirectoryURL.path
            )

            guard let publicKeyData = publicKeyDataProvider() else {
                diagnose("encryption_public_key_missing")
                return
            }
            let session = try DiagnosticLogEnvelope.makeSession(
                publicKeyData: publicKeyData,
                sessionID: sessionID
            )
            try session.header.write(to: logURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
            self.fileKey = session.fileKey
        } catch {
            diagnose("session_file_create_failed", error: error)
        }
    }

    func write(_ message: String) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.appendRecord(message: message, date: self.now())
        }
    }

    /// Writes a redacted diagnostic snapshot as ordered encrypted records.
    func writeDiagnosticSummary(_ summary: String, event: String) {
        guard isEnabled else { return }
        let normalizedEvent = Self.singleLine(event)
        let lines = summary
            .split(omittingEmptySubsequences: false) { character in
                character == "\n" || character == "\r"
            }
            .map { Self.singleLine(String($0)) }
        queue.async { [weak self] in
            guard let self else { return }
            let eventDate = self.now()
            self.appendRecord(message: "\(normalizedEvent) BEGIN", date: eventDate)
            for line in lines {
                self.appendRecord(
                    message: "\(normalizedEvent) FIELD \(line)",
                    date: eventDate
                )
            }
            self.appendRecord(message: "\(normalizedEvent) END", date: eventDate)
        }
    }

    /// Retains upload-approved events across launches and writes the encrypted
    /// local file. The private transport never reads the local file.
    func record(_ event: PublicDiagnosticEvent) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if let publicEventStore = self.publicEventStore, event.isApprovedForUpload {
                do { try publicEventStore.append(event) }
                catch {
                    self.publicEvents.append(event)
                    self.diagnose("public_event_store_write_failed", error: error)
                }
            } else {
                self.publicEvents.append(event)
            }
            if self.publicEvents.count > Self.maximumPublicEvents {
                self.publicEvents.removeFirst(self.publicEvents.count - Self.maximumPublicEvents)
            }
            self.appendRecord(message: event.canonicalLine, date: self.now())
        }
    }

    func write(publicEvent: PublicDiagnosticEvent) {
        record(publicEvent)
    }

    func publicDiagnosticEvents() -> [PublicDiagnosticEvent] {
        guard isEnabled else { return [] }
        return queue.sync {
            guard let publicEventStore else { return publicEvents }
            let stored = publicEventStore.pending()
            let pending = stored + publicEvents.filter { $0.isApprovedForUpload && !stored.contains($0) }
            return Array(pending.suffix(Self.maximumPublicEvents))
        }
    }

    func markPublicDiagnosticEventsUploaded(_ uploadedEvents: [PublicDiagnosticEvent]) {
        guard isEnabled, !uploadedEvents.isEmpty else { return }
        queue.sync {
            do { try publicEventStore?.acknowledge(uploadedEvents) }
            catch { diagnose("public_event_store_acknowledge_failed", error: error) }
            for uploadedEvent in uploadedEvents {
                guard let index = publicEvents.firstIndex(of: uploadedEvent) else { continue }
                publicEvents.remove(at: index)
            }
        }
    }

    func flush() {
        guard isEnabled else { return }
        queue.sync {}
    }

    /// Test-only style entry point that still writes encrypted data.
    func writeSynchronously(_ message: String, at date: Date) {
        guard isEnabled else { return }
        queue.sync {
            appendRecord(message: message, date: date)
        }
    }

    static func shouldEnableSharedLogging(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let isXCTestProcess = arguments.contains { argument in
            argument.contains(".xctest")
        }
        let hasTestEnvironment = environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil
        return !isXCTestProcess && !hasTestEnvironment
    }

    static func errorFields(_ error: Error) -> String {
        let cocoaError = error as NSError
        return errorFields(domain: cocoaError.domain, code: cocoaError.code)
    }

    static func errorFields(
        domain: String,
        code: Int,
        fieldPrefix: String = "error"
    ) -> String {
        let prefix = stableToken(fieldPrefix)
        return "\(prefix)_domain=\(stableToken(domain)) \(prefix)_code=\(code)"
    }

    static func optionalErrorFields(_ error: Error?) -> String {
        guard let error else { return "error_domain=none error_code=0" }
        return errorFields(error)
    }

    static func stableToken(_ value: String) -> String {
        let token = String(value.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        })
        return token.isEmpty ? "unknown" : token
    }

    private func appendRecord(message: String, date: Date) {
        do {
            guard let fileKey else { throw DiagnosticLogEnvelope.Error.invalidRecord }
            let sequence = nextSequence
            let line = "\(formatter.string(from: date)) pid=\(metadata.processID) " +
                "ver=\(metadata.version) build=\(metadata.build) seq=\(sequence) " +
                "\(Self.singleLine(message))\n"
            let sealed = try AES.GCM.seal(
                Data(line.utf8),
                using: fileKey,
                authenticating: DiagnosticLogEnvelope.associatedData(
                    sessionID: sessionID,
                    sequence: sequence
                )
            )
            guard let combined = sealed.combined,
                  combined.count <= Int(UInt32.max)
            else { throw DiagnosticLogEnvelope.Error.invalidRecord }

            var length = UInt32(combined.count).bigEndian
            var record = withUnsafeBytes(of: &length) { Data($0) }
            record.append(combined)
            let appended = try withExclusiveLogLock {
                let existingSize = fileSize(at: logURL)
                guard existingSize + UInt64(record.count) <= maximumFileSize else {
                    reportFailure("encrypted_log_size_limit_reached")
                    return false
                }
                try appendAtomically(record)
                return true
            }
            if appended {
                nextSequence += 1
            }
        } catch {
            diagnose("encrypted_log_write_failed", error: error)
        }
    }

    private func appendAtomically(_ data: Data) throws {
        let descriptor = Darwin.open(
            logURL.path,
            O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                let errorCode = written == 0 ? EIO : errno
                if errorCode == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
        }
    }

    private func withExclusiveLogLock<T>(_ operation: () throws -> T) throws -> T {
        let lockURL = logURL.deletingLastPathComponent()
            .appendingPathComponent(".sayall-diagnostic-log.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            let errorCode = errno
            if errorCode == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber
        else { return 0 }
        return value.uint64Value
    }

    private func diagnose(_ operation: String, error: Error? = nil) {
        if let error {
            reportFailure("\(operation) \(Self.errorFields(error))")
        } else {
            reportFailure(operation)
        }
    }

    private static func singleLine(_ message: String) -> String {
        String(message.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) ||
                CharacterSet.newlines.contains(scalar)
            {
                return " "
            }
            return Character(String(scalar))
        })
    }

    private static func dayIdentifier(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
