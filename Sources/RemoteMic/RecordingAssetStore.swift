import AVFoundation
import CryptoKit
import Foundation

struct RecordingAssetManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let localDateKey: String
    let timeZoneIdentifier: String
    let source: UsageEventSource
    var applicationKey: String?
    var applicationName: String?
    var bundleIdentifier: String?
    let relativeMediaPath: String
    let durationMilliseconds: Int
    let byteCount: Int64
    let sha256: String
    let format: String

    var duration: TimeInterval {
        TimeInterval(durationMilliseconds) / 1_000
    }
}

struct RecordingAssetDraft: Sendable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let localDateKey: String
    let timeZoneIdentifier: String
    let source: UsageEventSource
    let directoryURL: URL
    let temporaryMediaURL: URL
}

enum RecordingAssetStoreError: Error {
    case invalidAsset
    case unsupportedFormat
    case missingAsset
    case unsafePath
}

final class RecordingAssetStore {
    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let trashItem: (URL) throws -> Void
    private let queue = DispatchQueue(label: "RemoteMic.recordingAssets")

    init(
        rootDirectoryURL: URL = RecordingAssetStore.defaultRootDirectoryURL(),
        fileManager: FileManager = .default,
        trashItem: ((URL) throws -> Void)? = nil
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.fileManager = fileManager
        self.trashItem = trashItem ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func begin(
        sessionID: UUID,
        startedAt: Date,
        source: UsageEventSource,
        calendar: Calendar = .current
    ) throws -> RecordingAssetDraft {
        try queue.sync {
            let localDateKey = Self.localDateKey(for: startedAt, calendar: calendar)
            let directoryURL = rootDirectoryURL
                .appendingPathComponent(localDateKey, isDirectory: true)
                .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            try createDirectory(directoryURL)
            let id = UUID()
            let temporaryMediaURL = directoryURL.appendingPathComponent("recording.partial.m4a")
            return RecordingAssetDraft(
                id: id,
                sessionID: sessionID,
                startedAt: startedAt,
                localDateKey: localDateKey,
                timeZoneIdentifier: calendar.timeZone.identifier,
                source: source,
                directoryURL: directoryURL,
                temporaryMediaURL: temporaryMediaURL
            )
        }
    }

    func commit(
        draft: RecordingAssetDraft,
        endedAt: Date,
        mediaURL: URL,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil
    ) throws -> RecordingAssetManifest {
        try queue.sync {
            guard mediaURL.standardizedFileURL == draft.temporaryMediaURL.standardizedFileURL,
                  fileManager.fileExists(atPath: mediaURL.path),
                  !isSymbolicLink(mediaURL)
            else { throw RecordingAssetStoreError.invalidAsset }

            let finalMediaURL = draft.directoryURL.appendingPathComponent("original.m4a")
            guard !fileManager.fileExists(atPath: finalMediaURL.path) else {
                throw RecordingAssetStoreError.invalidAsset
            }
            try fileManager.moveItem(at: mediaURL, to: finalMediaURL)

            do {
                let byteCount = try fileSize(of: finalMediaURL)
                let digest = try sha256(of: finalMediaURL)
                let durationMilliseconds = max(
                    0,
                    Int((endedAt.timeIntervalSince(draft.startedAt) * 1_000).rounded())
                )
                let manifest = RecordingAssetManifest(
                    schemaVersion: RecordingAssetManifest.currentSchemaVersion,
                    id: draft.id,
                    sessionID: draft.sessionID,
                    startedAt: draft.startedAt,
                    endedAt: endedAt,
                    localDateKey: draft.localDateKey,
                    timeZoneIdentifier: draft.timeZoneIdentifier,
                    source: draft.source,
                    applicationKey: Self.applicationKey(
                        applicationName: applicationName,
                        bundleIdentifier: bundleIdentifier
                    ),
                    applicationName: applicationName,
                    bundleIdentifier: bundleIdentifier,
                    relativeMediaPath: relativePath(for: finalMediaURL),
                    durationMilliseconds: durationMilliseconds,
                    byteCount: byteCount,
                    sha256: digest,
                    format: "m4a-aac"
                )
                try write(manifest, to: draft.directoryURL.appendingPathComponent("manifest.json"))
                return manifest
            } catch {
                try? trashItem(draft.directoryURL)
                throw error
            }
        }
    }

    func discard(draft: RecordingAssetDraft) throws {
        try queue.sync {
            guard draft.directoryURL.standardizedFileURL.path.hasPrefix(
                rootDirectoryURL.standardizedFileURL.path + "/"
            ), fileManager.fileExists(atPath: draft.directoryURL.path) else { return }
            try trashItem(draft.directoryURL)
        }
    }

    func loadAll() throws -> [RecordingAssetManifest] {
        try queue.sync {
            try loadAllUnlocked()
        }
    }

    func updateApplication(
        sessionID: UUID,
        applicationName: String,
        bundleIdentifier: String
    ) throws {
        try queue.sync {
            guard let match = try findManifest(sessionID: sessionID) else { return }
            var manifest = match.manifest
            manifest.applicationKey = Self.applicationKey(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier
            )
            manifest.applicationName = applicationName
            manifest.bundleIdentifier = bundleIdentifier
            try write(manifest, to: match.manifestURL)
        }
    }

    func mediaURL(for manifest: RecordingAssetManifest) throws -> URL {
        try queue.sync {
            guard Self.isSafePathComponent(manifest.relativeMediaPath) else {
                throw RecordingAssetStoreError.unsafePath
            }
            let url = rootDirectoryURL.appendingPathComponent(manifest.relativeMediaPath)
            guard url.standardizedFileURL.path.hasPrefix(rootDirectoryURL.standardizedFileURL.path + "/"),
                  fileManager.fileExists(atPath: url.path),
                  !isSymbolicLink(url)
            else { throw RecordingAssetStoreError.missingAsset }
            return url
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            guard let match = try findManifest(id: id) else { return }
            try trashItem(match.sessionDirectory)
        }
    }

    func deleteApplication(applicationKey: String) throws {
        try queue.sync {
            guard Self.isSafePathComponent(applicationKey) else {
                throw RecordingAssetStoreError.invalidAsset
            }
            for match in try findManifestsUnlocked() where match.manifest.applicationKey == applicationKey {
                try trashItem(match.sessionDirectory)
            }
        }
    }

    func deleteAll() throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: rootDirectoryURL.path) else { return }
            try trashItem(rootDirectoryURL)
        }
    }

    static func applicationKey(applicationName: String?, bundleIdentifier: String?) -> String? {
        let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty || !bundle.isEmpty else { return nil }
        return TranscriptArchiveStore.applicationKey(
            bundleIdentifier: bundle,
            applicationName: name
        )
    }

    private struct ManifestMatch {
        let manifest: RecordingAssetManifest
        let manifestURL: URL
        let sessionDirectory: URL
    }

    private func findManifest(id: UUID) throws -> ManifestMatch? {
        try findManifestsUnlocked().first { $0.manifest.id == id }
    }

    private func findManifest(sessionID: UUID) throws -> ManifestMatch? {
        try findManifestsUnlocked().first { $0.manifest.sessionID == sessionID }
    }

    private func loadAllUnlocked() throws -> [RecordingAssetManifest] {
        guard fileManager.fileExists(atPath: rootDirectoryURL.path) else { return [] }
        var manifests: [RecordingAssetManifest] = []
        for dateDirectory in try directoryContents(at: rootDirectoryURL) {
            guard !isSymbolicLink(dateDirectory), isDirectory(dateDirectory),
                  Self.isLocalDateKey(dateDirectory.lastPathComponent)
            else { continue }
            for sessionDirectory in try directoryContents(at: dateDirectory) {
                guard !isSymbolicLink(sessionDirectory), isDirectory(sessionDirectory) else {
                    continue
                }
                let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
                guard !isSymbolicLink(manifestURL),
                      let manifest = try? load(at: manifestURL),
                      manifest.schemaVersion == RecordingAssetManifest.currentSchemaVersion,
                      manifest.localDateKey == dateDirectory.lastPathComponent,
                      Self.isSafePathComponent(manifest.relativeMediaPath)
                else { continue }
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.endedAt > $1.endedAt }
    }

    private func findManifestsUnlocked() throws -> [ManifestMatch] {
        try loadAllUnlocked().compactMap { manifest in
            guard let url = try? mediaURLWithoutQueue(manifest) else { return nil }
            let manifestURL = url.deletingLastPathComponent().appendingPathComponent("manifest.json")
            return ManifestMatch(
                manifest: manifest,
                manifestURL: manifestURL,
                sessionDirectory: url.deletingLastPathComponent()
            )
        }
    }

    private func mediaURLWithoutQueue(_ manifest: RecordingAssetManifest) throws -> URL {
        guard Self.isSafePathComponent(manifest.relativeMediaPath) else {
            throw RecordingAssetStoreError.unsafePath
        }
        return rootDirectoryURL.appendingPathComponent(manifest.relativeMediaPath)
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var current = url
        while current.path.hasPrefix(rootDirectoryURL.path), current.path != rootDirectoryURL.path {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            current.deleteLastPathComponent()
        }
        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectoryURL.path)
    }

    private func write(_ manifest: RecordingAssetManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func load(at url: URL) throws -> RecordingAssetManifest {
        try JSONDecoder().decode(RecordingAssetManifest.self, from: Data(contentsOf: url))
    }

    private func directoryContents(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw RecordingAssetStoreError.invalidAsset }
        return size.int64Value
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(for url: URL) -> String {
        url.path.replacingOccurrences(of: rootDirectoryURL.path + "/", with: "")
    }

    private static func localDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_/"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafePathComponent(_ value: String?) -> Bool {
        guard let value else { return false }
        return isSafePathComponent(value)
    }

    private static func isLocalDateKey(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func defaultRootDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteMic", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

final class VoiceRecordingWriter {
    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1

    private let queue = DispatchQueue(label: "RemoteMic.voiceRecordingWriter", qos: .utility)
    private let pcmFormat: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var isFinished = false

    init(url: URL) throws {
        guard let pcmFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: Self.channelCount
        ) else { throw RecordingAssetStoreError.unsupportedFormat }
        self.pcmFormat = pcmFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
    }

    func append(samples: [Int16]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.isFinished, let audioFile = self.audioFile else { return }
            do {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: self.pcmFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ), let channel = buffer.floatChannelData?[0]
                else { throw RecordingAssetStoreError.unsupportedFormat }
                for index in samples.indices {
                    channel[index] = Float(samples[index]) / Float(Int16.max)
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try audioFile.write(from: buffer)
            } catch {
                self.isFinished = true
                self.audioFile = nil
            }
        }
    }

    func finish(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let succeeded = !self.isFinished && self.audioFile != nil
            self.isFinished = true
            self.audioFile = nil
            completion(succeeded)
        }
    }
}

final class RecordingAssetCoordinator {
    typealias CommitHandler = (RecordingAssetManifest) -> Void
    typealias Logger = (String) -> Void

    private struct ActiveSession {
        let draft: RecordingAssetDraft
        let writer: VoiceRecordingWriter
    }

    private let store: RecordingAssetStore
    private let isEnabled: () -> Bool
    private let onCommit: CommitHandler
    private let log: Logger
    private var activeSession: ActiveSession?
    private var pendingApplicationMetadata: [UUID: (name: String, bundleIdentifier: String)] = [:]

    init(
        store: RecordingAssetStore,
        isEnabled: @escaping () -> Bool,
        onCommit: @escaping CommitHandler,
        log: @escaping Logger = AppLogger.shared.write
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.onCommit = onCommit
        self.log = log
    }

    func start(sessionID: UUID, startedAt: Date, source: UsageEventSource) {
        guard isEnabled() else { return }
        finish(reason: "superseded")
        do {
            let draft = try store.begin(sessionID: sessionID, startedAt: startedAt, source: source)
            let writer: VoiceRecordingWriter
            do {
                writer = try VoiceRecordingWriter(url: draft.temporaryMediaURL)
            } catch {
                try? store.discard(draft: draft)
                throw error
            }
            activeSession = ActiveSession(draft: draft, writer: writer)
            log("RECORDING ASSET started")
        } catch {
            log("RECORDING ASSET start_failed")
        }
    }

    func append(samples: [Int16]) {
        guard isEnabled(), let activeSession else { return }
        activeSession.writer.append(samples: samples)
    }

    func finish(endedAt: Date, reason: String = "session_end") {
        guard let activeSession else { return }
        self.activeSession = nil
        activeSession.writer.finish { [weak self] succeeded in
            guard let self else { return }
            guard succeeded else {
                self.log("RECORDING ASSET finalize_failed reason=writer")
                return
            }
            do {
                let metadata = self.pendingApplicationMetadata.removeValue(forKey: activeSession.draft.sessionID)
                let manifest = try self.store.commit(
                    draft: activeSession.draft,
                    endedAt: endedAt,
                    mediaURL: activeSession.draft.temporaryMediaURL,
                    applicationName: metadata?.name,
                    bundleIdentifier: metadata?.bundleIdentifier
                )
                self.log(
                    "RECORDING ASSET saved reason=\(reason) " +
                        "duration_ms=\(manifest.durationMilliseconds) bytes=\(manifest.byteCount)"
                )
                self.onCommit(manifest)
            } catch {
                self.log("RECORDING ASSET finalize_failed reason=store")
            }
        }
    }

    func finish(reason: String) {
        finish(endedAt: Date(), reason: reason)
    }

    func cancel(reason: String = "external") {
        guard let activeSession else { return }
        self.activeSession = nil
        pendingApplicationMetadata.removeValue(forKey: activeSession.draft.sessionID)
        let store = self.store
        let log = self.log
        activeSession.writer.finish { _ in
            do {
                try store.discard(draft: activeSession.draft)
                log("RECORDING ASSET canceled reason=\(reason)")
            } catch {
                log("RECORDING ASSET cancel_failed reason=\(reason)")
            }
        }
    }

    func updateApplication(
        sessionID: UUID,
        applicationName: String,
        bundleIdentifier: String
    ) {
        if activeSession?.draft.sessionID == sessionID {
            pendingApplicationMetadata[sessionID] = (applicationName, bundleIdentifier)
        }
        do {
            try store.updateApplication(
                sessionID: sessionID,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier
            )
        } catch {
            log("RECORDING ASSET metadata_update_failed")
        }
    }
}
