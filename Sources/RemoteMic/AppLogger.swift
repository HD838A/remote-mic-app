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
    private static let defaultMaximumFileSize: UInt64 = 2 * 1_024 * 1_024
    private static let maximumPublicEvents = 256

    private let queue = DispatchQueue(label: "RemoteMic.logger")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let formatter: ISO8601DateFormatter
    private let metadata: Metadata
    private let maximumFileSize: UInt64
    private let fileManager: FileManager
    private let now: () -> Date
    private let reportFailure: (String) -> Void
    private var sessionID: Data
    private var activeLogURL: URL
    private var activeDescriptor: Int32 = -1
    private var segment = 0
    private var headerSize: UInt64 = 0
    private var needsFreshSegment = false
    private let publicKeyDataProvider: () -> Data?
    private let maximumFileCount: Int
    private let maximumDirectorySize: UInt64
    private let retentionInterval: TimeInterval
    private let retirementHandler: RetirementHandler
    private var lastMessage: String?
    private var repeatCount = 0
    private var firstRepeatDate: Date?
    private var lastRepeatDate: Date?
    private var pendingWriteFailures = 0
    private var retentionSummary: String?
    private var fileKey: SymmetricKey?
    private var nextSequence: UInt64 = 0
    private var publicEvents: [PublicDiagnosticEvent] = []
    private let publicEventStore: PublicDiagnosticEventStore?
    private let plaintextLogURL: URL
    private var usesPlaintextFallback = false

    private convenience init() {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RemoteMic", isDirectory: true)
        let sessionName = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8)
        let day = Self.dayIdentifier(Date())
        let loggingEnabled = Self.shouldEnableSharedLogging()
        self.init(
            logURL: base.appendingPathComponent(
                "sayall.app-\(day)-session-\(sessionName).rmlog"
            ),
            metadata: .current(),
            fileManager: fileManager,
            publicKeyDataProvider: { DiagnosticLogPublicKeyConfiguration.current() },
            publicEventStore: loggingEnabled ? PublicDiagnosticEventStore(fileURL:
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SayAll/Diagnostics/public-events.json")
            ) : nil,
            isEnabled: loggingEnabled
        )
    }

    init(
        logURL: URL,
        metadata: Metadata = .current(),
        maximumFileSize: UInt64 = AppLogger.defaultMaximumFileSize,
        archiveCount: Int = 15,
        fileManager: FileManager = .default,
        retirementHandler: RetirementHandler? = nil,
        maximumDirectorySize: UInt64 = 32 * 1_024 * 1_024,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping () -> Date = Date.init,
        reportFailure: ((String) -> Void)? = nil,
        publicKeyDataProvider: @escaping () -> Data? = {
            DiagnosticLogPublicKeyConfiguration.current()
        },
        publicEventStore: PublicDiagnosticEventStore? = nil,
        isEnabled: Bool = true
    ) {
        queue.setSpecific(key: queueKey, value: 1)
        self.logURL = logURL
        self.activeLogURL = logURL
        self.plaintextLogURL = Self.plaintextLogURL(for: logURL)
        self.publicKeyDataProvider = publicKeyDataProvider
        self.maximumFileCount = max(1, archiveCount + 1)
        self.maximumDirectorySize = max(maximumFileSize, maximumDirectorySize)
        self.retentionInterval = max(1, retentionInterval)
        self.retirementHandler = retirementHandler ?? { url in
            _ = try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
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

            guard publicKeyDataProvider() != nil else {
                usesPlaintextFallback = true
                try preparePlaintextLog()
                diagnose("encryption_public_key_missing")
                appendPlaintextRecord(
                    message: "LOGGING mode=plaintext reason=encryption_public_key_missing",
                    date: now()
                )
                return
            }
            try withExclusiveLogLock {
                try createSegment()
                applyRetention()
            }
        } catch {
            diagnose("session_file_create_failed", error: error)
        }
    }

    func write(_ message: String) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let date = self.now()
            let normalized = Self.singleLine(message)
            if self.lastMessage == normalized && Self.isCoalescibleState(normalized) {
                self.repeatCount += 1
                self.firstRepeatDate = self.firstRepeatDate ?? date
                self.lastRepeatDate = date
                // Emit a bounded heartbeat even if this state never changes.
                if self.repeatCount >= 100 || date.timeIntervalSince(self.firstRepeatDate ?? date) >= 30 {
                    self.flushRepeats()
                }
                return
            }
            self.flushRepeats()
            self.lastMessage = normalized
            self.appendRecord(message: normalized, date: date)
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
            self.flushRepeats()
            self.lastMessage = nil
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
            self.flushRepeats()
            self.lastMessage = nil
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
        queue.sync { flushRepeats() }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil { flushRepeats() }
        else { queue.sync { flushRepeats() } }
        if activeDescriptor >= 0 { _ = Darwin.close(activeDescriptor) }
    }

    private static func isCoalescibleState(_ message: String) -> Bool {
        // Only stable observations, never requests, errors, or terminal results.
        ["HID PERMISSIONS ", "HID FILTER ", "AUDIO HEALTH ready "].contains { message.hasPrefix($0) }
    }

    private func flushRepeats() {
        guard repeatCount > 0, let message = lastMessage,
              let first = firstRepeatDate, let last = lastRepeatDate else { return }
        appendRecord(message: "LOG REPEAT repeat_count=\(repeatCount) " +
            "first_at_ms=\(Int64(first.timeIntervalSince1970 * 1000)) " +
            "last_at_ms=\(Int64(last.timeIntervalSince1970 * 1000)) state=\(message)", date: last)
        repeatCount = 0
        firstRepeatDate = nil
        lastRepeatDate = nil
    }

    /// Test-only style entry point that still writes encrypted data.
    func writeSynchronously(_ message: String, at date: Date) {
        guard isEnabled else { return }
        queue.sync {
            flushRepeats()
            lastMessage = nil
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
        if usesPlaintextFallback {
            appendPlaintextRecord(message: message, date: date)
            return
        }
        do {
            // Size includes framing and AES-GCM overhead. Reject one oversized event,
            // rather than creating empty segments or silently breaking the size budget.
            func encryptedRecord() throws -> Data {
                guard let fileKey else { throw DiagnosticLogEnvelope.Error.invalidRecord }
                let line = "\(formatter.string(from: date)) pid=\(metadata.processID) " +
                    "ver=\(metadata.version) build=\(metadata.build) seq=\(nextSequence) " +
                    "\(Self.singleLine(message))\n"
                let sealed = try AES.GCM.seal(Data(line.utf8), using: fileKey,
                    authenticating: DiagnosticLogEnvelope.associatedData(sessionID: sessionID, sequence: nextSequence))
                guard let combined = sealed.combined, combined.count <= Int(UInt32.max)
                else { throw DiagnosticLogEnvelope.Error.invalidRecord }
                var length = UInt32(combined.count).bigEndian
                var record = withUnsafeBytes(of: &length) { Data($0) }
                record.append(combined)
                return record
            }
            var appended = false
            try withExclusiveLogLock {
                if needsFreshSegment { try rotateSegment() }
                var record = try encryptedRecord()
                guard UInt64(record.count) + headerSize <= maximumFileSize else {
                    pendingWriteFailures += 1
                    reportFailure("encrypted_log_record_too_large")
                    return
                }
                if fileSize(at: activeLogURL) + UInt64(record.count) > maximumFileSize {
                    try rotateSegment()
                    record = try encryptedRecord()
                }
                try appendAtomically(record)
                nextSequence += 1
                appended = true
            }
            guard appended else { return }
            if let summary = retentionSummary {
                retentionSummary = nil
                appendRecord(message: summary, date: date)
            }
            if pendingWriteFailures > 0 {
                let count = pendingWriteFailures
                pendingWriteFailures = 0
                appendRecord(message: "LOG GAP phase=recovered lost_record_count=\(count)", date: date)
            }
        } catch {
            pendingWriteFailures += 1
            needsFreshSegment = fileKey != nil
            diagnose("encrypted_log_write_failed", error: error)
        }
    }

    private func createSegment() throws {
        guard let publicKeyData = publicKeyDataProvider() else {
            throw DiagnosticLogEnvelope.Error.invalidPublicKey
        }
        let session = try DiagnosticLogEnvelope.makeSession(publicKeyData: publicKeyData)
        try session.header.write(to: activeLogURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeLogURL.path)
        let descriptor = Darwin.open(activeLogURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        if activeDescriptor >= 0 { _ = Darwin.close(activeDescriptor) }
        activeDescriptor = descriptor
        headerSize = UInt64(session.header.count)
        sessionID = session.sessionID
        fileKey = session.fileKey
        nextSequence = 0
    }

    private func rotateSegment() throws {
        let previousURL = activeLogURL
        segment += 1
        activeLogURL = logURL.deletingPathExtension().appendingPathExtension("part-\(segment).rmlog")
        do { try createSegment() }
        catch { activeLogURL = previousURL; throw error }
        needsFreshSegment = false
        applyRetention()
    }

    private func applyRetention() {
        do { try retireOldSegments() }
        catch {
            diagnose("encrypted_log_retirement_failed", error: error)
            retentionSummary = "LOG RETENTION phase=failed \(Self.errorFields(error))"
        }
    }

    private func retireOldSegments() throws {
        let urls = try fileManager.contentsOfDirectory(at: logDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
        var files: [(url: URL, date: Date, size: UInt64)] = []
        for url in urls {
            guard url.lastPathComponent.range(of:
                #"^sayall\.app-\d{4}-\d{2}-\d{2}-session-[A-Fa-f0-9]{8}(\.part-\d+)?\.rmlog$"#,
                options: .regularExpression) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append((url, values.contentModificationDate ?? now(), UInt64(max(0, values.fileSize ?? 0))))
        }
        files.sort { $0.date < $1.date }
        var total = files.reduce(UInt64(0)) { $0 + $1.size }
        let target = maximumDirectorySize > maximumFileSize ? maximumDirectorySize - maximumFileSize : maximumDirectorySize
        let cutoff = now().addingTimeInterval(-retentionInterval)
        var count = 0
        var remainingFileCount = files.count
        var bytes: UInt64 = 0
        var blocked = 0
        for file in files where file.url != activeLogURL && (file.date < cutoff || total > target || remainingFileCount > maximumFileCount) {
            let descriptor = Darwin.open(file.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { blocked += 1; continue }
            defer { _ = Darwin.close(descriptor) }
            // A live process keeps a shared lock. Never retire its active segment.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { blocked += 1; continue }
            do {
                try retirementHandler(file.url)
                count += 1
                remainingFileCount -= 1
                bytes += file.size
                total -= file.size
            } catch { blocked += 1; diagnose("encrypted_log_retirement_failed", error: error) }
        }
        if count > 0 || blocked > 0 {
            // Do not recurse through appendRecord while holding the directory lock.
            reportFailure("encrypted_log_retention retired_count=\(count) retired_bytes=\(bytes) blocked_count=\(blocked)")
            retentionSummary = "LOG RETENTION retired_count=\(count) retired_bytes=\(bytes) blocked_count=\(blocked)"
        }
    }

    private func appendAtomically(_ data: Data) throws {
        try appendAtomically(data, to: activeLogURL)
    }

    private func appendAtomically(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
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

    private func preparePlaintextLog() throws {
        if !fileManager.fileExists(atPath: plaintextLogURL.path) {
            guard fileManager.createFile(
                atPath: plaintextLogURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw POSIXError(.EIO)
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plaintextLogURL.path
        )
    }

    private func appendPlaintextRecord(message: String, date: Date) {
        do {
            let line = "\(formatter.string(from: date)) pid=\(metadata.processID) " +
                "ver=\(metadata.version) build=\(metadata.build) seq=\(nextSequence) " +
                "\(Self.singleLine(message))\n"
            try withExclusiveLogLock {
                try appendAtomically(Data(line.utf8), to: plaintextLogURL)
            }
            nextSequence += 1
        } catch {
            pendingWriteFailures += 1
            diagnose("plaintext_log_write_failed", error: error)
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

    private static func plaintextLogURL(for encryptedURL: URL) -> URL {
        if encryptedURL.lastPathComponent.hasPrefix("sayall.app-") {
            return encryptedURL.deletingLastPathComponent()
                .appendingPathComponent("runtime.log")
        }
        return encryptedURL.deletingPathExtension().appendingPathExtension("log")
    }
}
