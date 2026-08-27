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

    @Test func disablingRecordingDiscardsTheActiveSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicRecordingCancel-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        let completion = DispatchSemaphore(value: 0)
        var isEnabled = true
        var commitCount = 0
        var trashedCount = 0
        var finalLog = ""
        let store = RecordingAssetStore(rootDirectoryURL: root, trashItem: { url in
            trashedCount += 1
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: url,
                to: trashRoot.appendingPathComponent(UUID().uuidString)
            )
        })
        let coordinator = RecordingAssetCoordinator(
            store: store,
            isEnabled: { isEnabled },
            onCommit: { _ in commitCount += 1 },
            log: { message in
                guard message.contains("saved") || message.contains("canceled") else { return }
                finalLog = message
                completion.signal()
            }
        )

        coordinator.start(
            sessionID: UUID(),
            startedAt: Date(),
            source: .bluetoothRemote
        )
        coordinator.append(samples: Array(repeating: Int16(1200), count: 1_600))
        isEnabled = false
        coordinator.cancel(reason: "feature_disabled")

        #expect(completion.wait(timeout: .now() + 3) == .success)
        #expect(commitCount == 0)
        #expect(trashedCount == 1)
        #expect(try store.loadAll().isEmpty)
        #expect(finalLog == "RECORDING ASSET canceled reason=feature_disabled")
    }

    @Test func metadataFromARecordingDisabledSessionIsNotRetained() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicRecordingMetadata-\(UUID().uuidString)", isDirectory: true)
        let completion = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        var isEnabled = false
        var committed: RecordingAssetManifest?
        let coordinator = RecordingAssetCoordinator(
            store: RecordingAssetStore(rootDirectoryURL: root),
            isEnabled: { isEnabled },
            onCommit: { manifest in
                committed = manifest
                completion.signal()
            },
            log: { _ in }
        )

        coordinator.updateApplication(
            sessionID: sessionID,
            applicationName: "Stale App",
            bundleIdentifier: "com.example.stale"
        )
        isEnabled = true
        coordinator.start(
            sessionID: sessionID,
            startedAt: Date(),
            source: .bluetoothRemote
        )
        coordinator.append(samples: Array(repeating: Int16(1200), count: 1_600))
        coordinator.finish(endedAt: Date())

        #expect(completion.wait(timeout: .now() + 3) == .success)
        #expect(committed?.applicationName == nil)
        #expect(committed?.bundleIdentifier == nil)
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}
