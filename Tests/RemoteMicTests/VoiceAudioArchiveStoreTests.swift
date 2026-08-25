import Foundation
import Testing
@testable import RemoteMic

@Suite("Temporary voice audio archive")
struct VoiceAudioArchiveStoreTests {
    @Test func writesCompactAudioAndPrunesAtFourHours() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicVoiceAudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let endedAt = Date(timeIntervalSince1970: 1_767_268_800)
        let sessionID = UUID()
        let store = VoiceAudioArchiveStore(rootDirectoryURL: root, now: { endedAt })
        #expect(store.start(sessionID: sessionID))

        let samples = (0..<16_000).map { index in
            Int16(Double(Int16.max) * 0.2 * sin(2 * .pi * 440 * Double(index) / 16_000))
        }
        store.append(sessionID: sessionID, samples: samples)
        let attachment = await withCheckedContinuation {
            (continuation: CheckedContinuation<TranscriptAudioAttachment?, Never>) in
            store.finish(sessionID: sessionID, endedAt: endedAt) { attachment in
                continuation.resume(returning: attachment)
            }
        }

        let saved = try #require(attachment)
        let url = try #require(store.playableURL(for: saved, at: endedAt))
        #expect(url.pathExtension == "m4a")
        #expect(abs(saved.duration - 1) < 0.001)
        #expect(saved.expiresAt == endedAt.addingTimeInterval(4 * 60 * 60))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[
            .posixPermissions
        ] as? Int
        #expect(permissions == 0o600)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.pruneExpiredAudio(referenceDate: saved.expiresAt) {
                continuation.resume()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.playableURL(for: saved, at: saved.expiresAt) == nil)
    }
}
