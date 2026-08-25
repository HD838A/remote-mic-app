import AVFoundation
import AudioToolbox
import Foundation

final class VoiceAudioArchiveStore {
    static let sampleRate: Double = 16_000
    static let retentionInterval: TimeInterval = 4 * 60 * 60

    private final class ActiveRecording {
        let sessionID: UUID
        let temporaryURL: URL
        let finalURL: URL
        var file: AVAudioFile?
        var sampleCount = 0
        var failed = false

        init(
            sessionID: UUID,
            temporaryURL: URL,
            finalURL: URL,
            file: AVAudioFile
        ) {
            self.sessionID = sessionID
            self.temporaryURL = temporaryURL
            self.finalURL = finalURL
            self.file = file
        }
    }

    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "RemoteMic.voiceAudioArchive", qos: .utility)
    private let now: () -> Date
    private var activeRecording: ActiveRecording?

    init(
        rootDirectoryURL: URL = VoiceAudioArchiveStore.defaultRootDirectoryURL(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.fileManager = fileManager
        self.now = now
        pruneExpiredAudio()
    }

    @discardableResult
    func start(sessionID: UUID) -> Bool {
        queue.sync {
            discardActiveRecording()
            do {
                try prepareRootDirectory()
                let temporaryURL = rootDirectoryURL
                    .appendingPathComponent("\(sessionID.uuidString).recording")
                    .appendingPathExtension("m4a")
                let finalURL = rootDirectoryURL
                    .appendingPathComponent(sessionID.uuidString)
                    .appendingPathExtension("m4a")
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try fileManager.removeItem(at: temporaryURL)
                }
                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: finalURL)
                }
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let file = try AVAudioFile(
                    forWriting: temporaryURL,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                activeRecording = ActiveRecording(
                    sessionID: sessionID,
                    temporaryURL: temporaryURL,
                    finalURL: finalURL,
                    file: file
                )
                return true
            } catch {
                AppLogger.shared.write("VOICE AUDIO start_failed")
                discardActiveRecording()
                return false
            }
        }
    }

    func append(sessionID: UUID, samples: [Int16]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self,
                  let recording = activeRecording,
                  recording.sessionID == sessionID,
                  !recording.failed,
                  let file = recording.file,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)
                  ),
                  let channel = buffer.floatChannelData?[0]
            else { return }

            buffer.frameLength = AVAudioFrameCount(samples.count)
            for index in samples.indices {
                channel[index] = Float(samples[index]) / Float(Int16.max)
            }
            do {
                try file.write(from: buffer)
                recording.sampleCount += samples.count
            } catch {
                recording.failed = true
                AppLogger.shared.write("VOICE AUDIO write_failed")
            }
        }
    }

    func finish(
        sessionID: UUID,
        endedAt: Date,
        completion: @escaping (TranscriptAudioAttachment?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self,
                  let recording = activeRecording,
                  recording.sessionID == sessionID
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            activeRecording = nil
            recording.file = nil

            let attachment: TranscriptAudioAttachment?
            do {
                guard !recording.failed, recording.sampleCount > 0 else {
                    throw VoiceAudioArchiveError.emptyRecording
                }
                try fileManager.moveItem(at: recording.temporaryURL, to: recording.finalURL)
                try fileManager.setAttributes(
                    [
                        .posixPermissions: 0o600,
                        .modificationDate: endedAt,
                    ],
                    ofItemAtPath: recording.finalURL.path
                )
                let expiresAt = endedAt.addingTimeInterval(Self.retentionInterval)
                attachment = TranscriptAudioAttachment(
                    fileName: recording.finalURL.lastPathComponent,
                    duration: Double(recording.sampleCount) / Self.sampleRate,
                    expiresAt: expiresAt
                )
                scheduleDeletion(
                    fileName: recording.finalURL.lastPathComponent,
                    expiresAt: expiresAt
                )
                AppLogger.shared.write(
                    "VOICE AUDIO saved duration_ms=" +
                        "\(Int((Double(recording.sampleCount) / Self.sampleRate) * 1_000))"
                )
            } catch {
                try? fileManager.removeItem(at: recording.temporaryURL)
                attachment = nil
                AppLogger.shared.write("VOICE AUDIO finish_failed")
            }
            DispatchQueue.main.async { completion(attachment) }
        }
    }

    func cancel(sessionID: UUID) {
        queue.async { [weak self] in
            guard let self,
                  activeRecording?.sessionID == sessionID
            else { return }
            discardActiveRecording()
        }
    }

    func playableURL(
        for attachment: TranscriptAudioAttachment,
        at date: Date = Date()
    ) -> URL? {
        guard date < attachment.expiresAt,
              Self.isSafeAudioFileName(attachment.fileName)
        else { return nil }
        let url = rootDirectoryURL.appendingPathComponent(attachment.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func delete(_ attachment: TranscriptAudioAttachment?) {
        guard let attachment,
              Self.isSafeAudioFileName(attachment.fileName)
        else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let url = rootDirectoryURL.appendingPathComponent(attachment.fileName)
            try? fileManager.removeItem(at: url)
        }
    }

    func delete(_ attachments: [TranscriptAudioAttachment]) {
        for attachment in attachments {
            delete(attachment)
        }
    }

    func pruneExpiredAudio(
        referenceDate: Date? = nil,
        completion: (() -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            defer { completion?() }
            let referenceDate = referenceDate ?? now()
            guard let files = try? fileManager.contentsOfDirectory(
                at: rootDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let cutoff = referenceDate.addingTimeInterval(-Self.retentionInterval)
            for file in files where file.pathExtension == "m4a" {
                let modifiedAt = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                if modifiedAt <= cutoff {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    private func prepareRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectoryURL.path
        )
    }

    private func discardActiveRecording() {
        guard let recording = activeRecording else { return }
        activeRecording = nil
        recording.file = nil
        try? fileManager.removeItem(at: recording.temporaryURL)
    }

    private func scheduleDeletion(fileName: String, expiresAt: Date) {
        let delay = max(0, expiresAt.timeIntervalSince(now()))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, Self.isSafeAudioFileName(fileName) else { return }
            let url = rootDirectoryURL.appendingPathComponent(fileName)
            try? fileManager.removeItem(at: url)
            AppLogger.shared.write("VOICE AUDIO expired")
        }
    }

    private static func isSafeAudioFileName(_ value: String) -> Bool {
        let url = URL(fileURLWithPath: value)
        return url.lastPathComponent == value &&
            url.pathExtension == "m4a" &&
            UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    private static func defaultRootDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteMic", isDirectory: true)
            .appendingPathComponent("TranscriptAudio", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

private enum VoiceAudioArchiveError: Error {
    case emptyRecording
}

final class TranscriptAudioPlayer: NSObject, AVAudioPlayerDelegate {
    var onPlayingRecordChange: ((UUID?) -> Void)?

    private var player: AVAudioPlayer?
    private var playingRecordID: UUID?

    @discardableResult
    func toggle(recordID: UUID, url: URL) -> Bool {
        if playingRecordID == recordID {
            stop()
            return false
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else { return false }
            self.player = player
            playingRecordID = recordID
            onPlayingRecordChange?(recordID)
            return true
        } catch {
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingRecordID = nil
        onPlayingRecordChange?(nil)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        guard player === self.player else { return }
        self.player = nil
        playingRecordID = nil
        onPlayingRecordChange?(nil)
    }
}
