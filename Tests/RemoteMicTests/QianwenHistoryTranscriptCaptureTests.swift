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
            bundleIdentifier: WeChatHistoryPolicy.weChatBundleIdentifier
        )
        coordinator.finishSession(endedAt: endedAt)
        #expect(captures.isEmpty)

        uptime = 0.5
        scheduled?()

        let capture = try #require(captures.first)
        #expect(capture.text == "微信语音")
        #expect(capture.bundleIdentifier == WeChatHistoryPolicy.weChatBundleIdentifier)
        #expect(readCount == 2)
    }

    @Test @MainActor func readerReturnsOneDecodedTranscript() async {
        let output = Data(
            #"{"schemaVersion":1,"id":"record","timestampMs":103500,"text":"微信语音"}"#.utf8
        )
        let reader = QianwenHistoryReader { _, _, _, _ in
            QianwenHistoryProcessResult(
                terminationStatus: 0,
                output: output,
                timedOut: false,
                forceKilled: false
            )
        }
        var completionCount = 0

        let transcript = await withCheckedContinuation { continuation in
            reader.readLatest(
                after: Date(timeIntervalSince1970: 100),
                before: Date(timeIntervalSince1970: 104)
            ) { result in
                completionCount += 1
                continuation.resume(returning: result)
            }
        }

        #expect(completionCount == 1)
        #expect(transcript?.text == "微信语音")
    }

    @Test @MainActor func readerFailsClosedAfterProcessTimeout() async {
        let reader = QianwenHistoryReader { _, _, _, _ in
            QianwenHistoryProcessResult(
                terminationStatus: -1,
                output: Data(),
                timedOut: true,
                forceKilled: true
            )
        }

        let transcript = await withCheckedContinuation { continuation in
            reader.readLatest(after: Date(), before: Date()) { result in
                continuation.resume(returning: result)
            }
        }

        #expect(transcript == nil)
    }

    @Test func processRunnerReportsLaunchFailure() {
        let result = QianwenHistoryReader.runProcess(
            executableURL: URL(fileURLWithPath: "/private/tmp/missing-qianwen-reader"),
            arguments: [],
            currentDirectoryURL: URL(fileURLWithPath: "/private/var/empty"),
            timeout: 0.1
        )

        #expect(result.terminationStatus == -1)
        #expect(!result.timedOut)
        #expect(!result.forceKilled)
    }

    @Test func processRunnerForceKillsAProcessThatIgnoresTermination() {
        let result = QianwenHistoryReader.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            currentDirectoryURL: URL(fileURLWithPath: "/private/var/empty"),
            timeout: 0.05
        )

        #expect(result.timedOut)
        #expect(result.forceKilled)
    }

    @Test func coordinatorDoesNotStartAnotherPollWhileTheReaderIsRunning() {
        var pendingCompletion: ((QianwenHistoryTranscript?) -> Void)?
        var scheduled = false
        let coordinator = QianwenHistoryTranscriptCapture(
            reader: { _, _, completion in pendingCompletion = completion },
            schedule: { _, _ in
                scheduled = true
                return VoiceFnTapScheduledTask {}
            },
            onCapture: { _ in },
            log: { _ in }
        )

        coordinator.startSession(
            startedAt: Date(),
            source: .bluetoothRemote,
            applicationName: "微信",
            bundleIdentifier: WeChatHistoryPolicy.weChatBundleIdentifier
        )
        coordinator.finishSession(endedAt: Date())

        #expect(pendingCompletion != nil)
        #expect(!scheduled)
        pendingCompletion?(nil)
        #expect(scheduled)
    }
}
