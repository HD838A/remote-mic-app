import Darwin
import Foundation
import OSLog

final class AppLogger {
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

    private static let systemLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SayAll",
        category: "AppLogger"
    )
    private static let defaultMaximumFileSize = 10 * 1_024 * 1_024
    private static let defaultArchiveCount = 3

    private let queue = DispatchQueue(label: "RemoteMic.logger")
    private let formatter: ISO8601DateFormatter
    private let metadata: Metadata
    private let maximumFileSize: UInt64
    private let archiveCount: Int
    private let fileManager: FileManager
    private let retirementHandler: RetirementHandler
    private let now: () -> Date
    private let reportFailure: (String) -> Void

    private convenience init() {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RemoteMic", isDirectory: true)
        self.init(
            logURL: base.appendingPathComponent("runtime.log"),
            metadata: .current(),
            fileManager: fileManager,
            isEnabled: Self.shouldEnableSharedLogging()
        )
    }

    init(
        logURL: URL,
        metadata: Metadata,
        maximumFileSize: UInt64 = UInt64(defaultMaximumFileSize),
        archiveCount: Int = defaultArchiveCount,
        fileManager: FileManager = .default,
        retirementHandler: RetirementHandler? = nil,
        now: @escaping () -> Date = Date.init,
        reportFailure: ((String) -> Void)? = nil,
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
        self.archiveCount = max(0, archiveCount)
        self.fileManager = fileManager
        self.retirementHandler = retirementHandler ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
        self.now = now
        self.reportFailure = reportFailure ?? { message in
            Self.systemLogger.error("\(message, privacy: .public)")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = formatter

        guard isEnabled else { return }
        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            diagnose("directory_create_failed", error: error)
        }
    }

    func write(_ message: String) {
        guard isEnabled else { return }
        let eventDate = now()
        let normalizedMessage = Self.singleLine(message)
        queue.async { [self] in
            let timestamp = formatter.string(from: eventDate)
            let line = "\(timestamp) pid=\(metadata.processID) " +
                "ver=\(metadata.version) build=\(metadata.build) " +
                "\(normalizedMessage)\n"
            append(Data(line.utf8))
        }
    }

    func flush() {
        guard isEnabled else { return }
        queue.sync {}
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
        return "\(prefix)_domain=\(stableToken(domain)) " +
            "\(prefix)_code=\(code)"
    }

    static func optionalErrorFields(_ error: Error?) -> String {
        guard let error else { return "error_domain=none error_code=0" }
        return errorFields(error)
    }

    private func append(_ data: Data) {
        withExclusiveLogLock {
            if shouldRotate(forAdditionalBytes: UInt64(data.count)) {
                rotateIfPossible()
            }
            appendAtomically(data)
        }
    }

    private func shouldRotate(forAdditionalBytes additionalBytes: UInt64) -> Bool {
        guard fileManager.fileExists(atPath: logURL.path) else { return false }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
            guard let fileSize = attributes[.size] as? NSNumber else {
                reportFailure("file_size_unavailable")
                return false
            }
            let currentSize = fileSize.uint64Value
            return currentSize >= maximumFileSize ||
                additionalBytes > maximumFileSize - currentSize
        } catch {
            diagnose("file_size_failed", error: error)
            return false
        }
    }

    private func rotateIfPossible() {
        guard archiveCount > 0 else { return }

        let oldestArchiveURL = archiveURL(index: archiveCount)
        if fileManager.fileExists(atPath: oldestArchiveURL.path) {
            do {
                try retirementHandler(oldestArchiveURL)
            } catch {
                diagnose("archive_retirement_failed", error: error)
                return
            }
            guard !fileManager.fileExists(atPath: oldestArchiveURL.path) else {
                reportFailure("archive_retirement_incomplete")
                return
            }
        }

        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let sourceURL = archiveURL(index: index)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let destinationURL = archiveURL(index: index + 1)
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    reportFailure("archive_destination_occupied")
                    return
                }
                do {
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                } catch {
                    diagnose("archive_move_failed", error: error)
                    return
                }
            }
        }

        let firstArchiveURL = archiveURL(index: 1)
        guard !fileManager.fileExists(atPath: firstArchiveURL.path) else {
            reportFailure("archive_destination_occupied")
            return
        }
        do {
            try fileManager.moveItem(at: logURL, to: firstArchiveURL)
        } catch {
            diagnose("current_log_move_failed", error: error)
        }
    }

    private var lockURL: URL {
        logURL.deletingLastPathComponent()
            .appendingPathComponent(".\(logURL.lastPathComponent).lock")
    }

    private func withExclusiveLogLock(_ operation: () -> Void) {
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            diagnosePOSIX("lock_open_failed", code: errno)
            return
        }
        defer { _ = Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            let errorCode = errno
            if errorCode == EINTR { continue }
            diagnosePOSIX("lock_acquire_failed", code: errorCode)
            return
        }
        defer {
            if flock(descriptor, LOCK_UN) != 0 {
                diagnosePOSIX("lock_release_failed", code: errno)
            }
        }

        operation()
    }

    private func appendAtomically(_ data: Data) {
        let descriptor = Darwin.open(
            logURL.path,
            O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            diagnosePOSIX("file_append_open_failed", code: errno)
            return
        }
        defer { _ = Darwin.close(descriptor) }

        data.withUnsafeBytes { buffer in
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
                diagnosePOSIX("file_append_failed", code: errorCode)
                return
            }
        }
    }

    private func archiveURL(index: Int) -> URL {
        URL(fileURLWithPath: "\(logURL.path).\(index)")
    }

    private func diagnose(_ operation: String, error: Error) {
        reportFailure("\(operation) \(Self.errorFields(error))")
    }

    private func diagnosePOSIX(_ operation: String, code: Int32) {
        diagnose(
            operation,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        )
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
}
