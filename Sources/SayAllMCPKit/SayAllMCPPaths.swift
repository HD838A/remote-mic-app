import Darwin
import Foundation

public struct SayAllMCPPaths: Sendable {
    public let transcriptRoot: URL
    public let accessRoot: URL

    public init(transcriptRoot: URL, accessRoot: URL) {
        self.transcriptRoot = transcriptRoot
        self.accessRoot = accessRoot
    }

    public static func defaults(fileManager: FileManager = .default) -> Self {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return Self(
            transcriptRoot: applicationSupport
                .appendingPathComponent("RemoteMic", isDirectory: true)
                .appendingPathComponent("Transcripts", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true),
            accessRoot: applicationSupport
                .appendingPathComponent("RemoteMic", isDirectory: true)
                .appendingPathComponent("MCP", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        )
    }
}

enum SayAllMCPFileSecurity {
    static func ensurePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let status = try fileStatus(at: directory)
        guard status.isDirectory, !status.isSymbolicLink else {
            throw SayAllMCPStorageError.invalidPrivatePath
        }
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func appendPrivateLine(_ line: String, directory: URL, file: URL) throws {
        try ensurePrivateDirectory(directory)
        let descriptor = Darwin.open(
            file.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else {
            throw SayAllMCPStorageError.invalidPrivatePath
        }

        var bytes = Array((line + "\n").utf8)
        var written = 0
        let totalBytes = bytes.count
        while written < totalBytes {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    totalBytes - written
                )
            }
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += count
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func readPrivateLines(from file: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let status = try fileStatus(at: file)
        guard status.isRegularFile, !status.isSymbolicLink else {
            throw SayAllMCPStorageError.invalidPrivatePath
        }
        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func readPrivateData(from file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let status = try fileStatus(at: file)
        guard status.isRegularFile, !status.isSymbolicLink else {
            throw SayAllMCPStorageError.invalidPrivatePath
        }
        return try Data(contentsOf: file, options: [.mappedIfSafe])
    }

    static func writePrivateData(_ data: Data, directory: URL, file: URL) throws {
        try ensurePrivateDirectory(directory)
        if FileManager.default.fileExists(atPath: file.path) {
            let status = try fileStatus(at: file)
            guard status.isRegularFile, !status.isSymbolicLink else {
                throw SayAllMCPStorageError.invalidPrivatePath
            }
        }
        try data.write(to: file, options: .atomic)
        guard Darwin.chmod(file.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let status = try fileStatus(at: file)
        guard status.isRegularFile, !status.isSymbolicLink else {
            throw SayAllMCPStorageError.invalidPrivatePath
        }
    }

    static func fileStatus(at url: URL) throws -> FileStatus {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileStatus(mode: metadata.st_mode, size: metadata.st_size)
    }

    struct FileStatus {
        let mode: mode_t
        let size: off_t

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
        var isSymbolicLink: Bool { mode & S_IFMT == S_IFLNK }
    }
}

public enum SayAllMCPStorageError: Error, Equatable {
    case invalidPrivatePath
    case invalidAccessState
    case invalidTranscriptRoot
}
