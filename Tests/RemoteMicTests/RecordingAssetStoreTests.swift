import Foundation
import AVFoundation
import Testing
@testable import RemoteMic

@Suite("Local recording assets")
struct RecordingAssetStoreTests {
    @Test func commitsM4AAssetAndKeepsManifestMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicRecordingTests-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        var trashed: [URL] = []
        let store = RecordingAssetStore(rootDirectoryURL: root, trashItem: { url in
            trashed.append(url)
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let destination = trashRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: destination)
        })
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_767_268_800)
        let draft = try store.begin(
            sessionID: sessionID,
            startedAt: startedAt,
            source: .bluetoothRemote,
            calendar: Calendar(identifier: .gregorian)
        )
        try Data("fixture-audio".utf8).write(to: draft.temporaryMediaURL)
        let manifest = try store.commit(
            draft: draft,
            endedAt: startedAt.addingTimeInterval(2.4),
            mediaURL: draft.temporaryMediaURL,
            applicationName: "Codex",
            bundleIdentifier: "com.openai.codex"
        )

        #expect(manifest.sessionID == sessionID)
        #expect(manifest.applicationName == "Codex")
        #expect(manifest.format == "m4a-aac")
        #expect(manifest.durationMilliseconds == 2_400)
        #expect(manifest.byteCount == Int64("fixture-audio".utf8.count))
        #expect(try store.loadAll() == [manifest])
        #expect(try store.mediaURL(for: manifest).lastPathComponent == "original.m4a")
        #expect(!FileManager.default.fileExists(atPath: draft.temporaryMediaURL.path))

        try store.updateApplication(
            sessionID: sessionID,
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let updated = try #require(try store.loadAll().first)
        #expect(updated.applicationName == "Notes")

        try store.delete(id: manifest.id)
        #expect(try store.loadAll().isEmpty)
        #expect(trashed.count == 1)
    }

    @Test func originalAudioRecordingSettingDefaultsOff() throws {
        let suiteName = "RemoteMicTests.RecordingSetting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.localOriginalAudioRecordingEnabled == false)
        settings.localOriginalAudioRecordingEnabled = true
        #expect(AppSettings(defaults: defaults).localOriginalAudioRecordingEnabled)
    }

    @Test func writerProducesReadableAACFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicRecording-\(UUID().uuidString).m4a")
        let writer = try VoiceRecordingWriter(url: url)
        writer.append(samples: Array(repeating: Int16(1200), count: 1_600))
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        writer.finish {
            succeeded = $0
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 3) == .success)
        #expect(succeeded)
        let audioFile = try AVAudioFile(forReading: url)
        #expect(audioFile.fileFormat.sampleRate == 16_000)
        #expect(audioFile.fileFormat.channelCount == 1)
        #expect(audioFile.length > 0)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    @Test func recordingOnlySessionKeepsApplicationMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicRecordingOnlyTests-\(UUID().uuidString)", isDirectory: true)
        let store = RecordingAssetStore(rootDirectoryURL: root)
        let committed = DispatchSemaphore(value: 0)
        var manifest: RecordingAssetManifest?
        let coordinator = RecordingAssetCoordinator(
            store: store,
            isEnabled: { true },
            onCommit: {
                manifest = $0
                committed.signal()
            },
            log: { _ in }
        )
        let sessionID = UUID()
        coordinator.start(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_767_268_800),
            source: .bluetoothRemote,
            applicationMetadata: FrontmostApplicationMetadata(
                applicationName: "Codex",
                bundleIdentifier: "com.openai.codex"
            )
        )
        coordinator.append(samples: Array(repeating: Int16(1200), count: 1_600))
        coordinator.finish(endedAt: Date(timeIntervalSince1970: 1_767_268_802))

        #expect(committed.wait(timeout: .now() + 3) == .success)
        let committedManifest = try #require(manifest)
        #expect(committedManifest.sessionID == sessionID)
        #expect(committedManifest.applicationName == "Codex")
        #expect(committedManifest.bundleIdentifier == "com.openai.codex")
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}
