import Foundation
import Network
import UIKit

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    private let queue = DispatchQueue(label: "RemoteMicIOS.diagnostics")
    private let fileManager: FileManager
    private let directoryURL: URL
    private let maxFileBytes: Int
    private let maxArchivedFiles: Int
    private let now: () -> Date
    private let formatter: ISO8601DateFormatter

    private var currentLogURL: URL {
        directoryURL.appendingPathComponent("current.log")
    }

    init(
        directoryURL: URL? = nil,
        maxFileBytes: Int = 256 * 1024,
        maxArchivedFiles: Int = 3,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.maxFileBytes = maxFileBytes
        self.maxArchivedFiles = maxArchivedFiles
        self.now = now
        formatter = ISO8601DateFormatter()
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directoryURL = caches.appendingPathComponent("Diagnostics", isDirectory: true)
        }
        prepareDirectory()
        record("app_start", fields: Self.environmentFields)
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        let timestamp = formatter.string(from: now())
        let safeEvent = Self.sanitize(event)
        let safeFields = fields
            .map { (Self.sanitize($0.key), Self.sanitize($0.value)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: " ")
        let line = safeFields.isEmpty
            ? "\(timestamp) \(safeEvent)\n"
            : "\(timestamp) \(safeEvent) \(safeFields)\n"
        let data = Data(line.utf8)
        queue.async { [weak self] in
            self?.append(data)
        }
    }

    func makeShareFile() -> URL? {
        queue.sync {
            prepareDirectory()
            let timestamp = Self.fileTimestamp(now())
            let version = Self.appVersionText.replacingOccurrences(of: " ", with: "-")
            let shareURL = fileManager.temporaryDirectory.appendingPathComponent(
                "RemoteMicIOS-Diagnostics-\(version)-\(timestamp).txt"
            )
            var data = Data("RemoteMic iOS Diagnostics\n\n".utf8)
            for url in logURLsInChronologicalOrder() {
                guard let logData = try? Data(contentsOf: url) else { continue }
                data.append(logData)
            }
            guard (try? data.write(to: shareURL, options: .atomic)) != nil else { return nil }
            return shareURL
        }
    }

    func removeShareFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    static func networkErrorCode(_ error: NWError) -> String {
        switch error {
        case let .posix(code): return "posix.\(code.rawValue)"
        case let .dns(code): return "dns.\(code)"
        case let .tls(code): return "tls.\(code)"
        case let .wifiAware(code): return "wifi_aware.\(code)"
        @unknown default: return "unknown"
        }
    }

    static var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return MacAppInformationScreen.appVersionText(
            marketingVersion: version,
            buildNumber: build
        )
    }

    private static var environmentFields: [String: String] {
        [
            "app": appVersionText,
            "device": deviceModelIdentifier,
            "os": UIDevice.current.systemVersion,
        ]
    }

    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private func prepareDirectory() {
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
    }

    private func append(_ data: Data) {
        prepareDirectory()
        let currentSize = ((try? fileManager.attributesOfItem(atPath: currentLogURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if currentSize > 0, currentSize + data.count > maxFileBytes {
            rotateLogs()
        }
        if fileManager.fileExists(atPath: currentLogURL.path),
           let handle = try? FileHandle(forWritingTo: currentLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: currentLogURL, options: .atomic)
        }
    }

    private func rotateLogs() {
        guard maxArchivedFiles > 0 else {
            try? fileManager.removeItem(at: currentLogURL)
            return
        }
        for index in stride(from: maxArchivedFiles, through: 1, by: -1) {
            let source = directoryURL.appendingPathComponent("archive-\(index).log")
            if index == maxArchivedFiles {
                try? fileManager.removeItem(at: source)
            } else if fileManager.fileExists(atPath: source.path) {
                let destination = directoryURL.appendingPathComponent("archive-\(index + 1).log")
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if fileManager.fileExists(atPath: currentLogURL.path) {
            let firstArchive = directoryURL.appendingPathComponent("archive-1.log")
            try? fileManager.moveItem(at: currentLogURL, to: firstArchive)
        }
    }

    private func logURLsInChronologicalOrder() -> [URL] {
        let archives = stride(from: maxArchivedFiles, through: 1, by: -1).map {
            directoryURL.appendingPathComponent("archive-\($0).log")
        }
        return (archives + [currentLogURL]).filter {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    private static func sanitize(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .prefix(160)
        )
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
