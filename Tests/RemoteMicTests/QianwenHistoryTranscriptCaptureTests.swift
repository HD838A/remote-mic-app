import Foundation
import Testing
@testable import RemoteMic

@Suite("Qianwen history transcript capture")
struct QianwenHistoryTranscriptCaptureTests {
    @Test func retriesUntilTheMatchingLocalHistoryRecordAppears() throws {
        var readCount = 0
        var scheduled: (() -> Void)?
        var captures: [CapturedTranscript] = []
        var uptime: TimeInterval = 0
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 103)
        let coordinator = QianwenHistoryTranscriptCapture(
            reader: { _, _, completion in
                readCount += 1
                completion(readCount == 1 ? nil : QianwenHistoryTranscript(
                    schemaVersion: 1,
                    id: "record",
                    timestampMs: 103_500,
                    text: "微信语音"
                ))
            },
            schedule: { _, operation in
                scheduled = operation
                return VoiceFnTapScheduledTask {}
            },
            clock: { uptime },
            now: { endedAt },
            onCapture: { captures.append($0) },
            log: { _ in }
        )

        coordinator.startSession(
            startedAt: startedAt,
            source: .bluetoothRemote,
            applicationName: "微信",
            bundleIdentifier: QianwenVoiceFocusPolicy.weChatBundleIdentifier
        )
        coordinator.finishSession(endedAt: endedAt)
        #expect(captures.isEmpty)

        uptime = 0.5
        scheduled?()

        let capture = try #require(captures.first)
        #expect(capture.text == "微信语音")
        #expect(capture.bundleIdentifier == QianwenVoiceFocusPolicy.weChatBundleIdentifier)
        #expect(readCount == 2)
    }
}
