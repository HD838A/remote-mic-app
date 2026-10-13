import Foundation
import Testing
@testable import RemoteMic

@Suite("ATVV bounded audio diagnostics")
struct ATVVAudioDiagnosticsTests {
    private final class Clock {
        var now: TimeInterval = 100
        var tasks: [(TimeInterval, () -> Void)] = []
        var lines: [String] = []

        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = tasks.indices.first(where: { tasks[$0].0 <= now }) {
                let task = tasks.remove(at: index)
                task.1()
            }
        }

        func make(_ operationID: UInt64 = 7) -> ATVVAudioDiagnostics {
            ATVVAudioDiagnostics(
                operationID: operationID,
                uptime: { self.now },
                schedule: { self.tasks.append((self.now + $0, $1)) },
                log: { self.lines.append($0) }
            )
        }

        var finals: [String] { lines.filter { $0.contains("phase=completed") } }
    }

    @Test func everyCallbackIsAcceptedOrAttributedIncludingCancelledAndStaleData() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        diagnostic.accept(bytes: 120)
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.routed(samples: 240, enqueued: true)
        for reason in ATVVAudioDiagnostics.Drop.allCases where reason != .identifier {
            diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
            diagnostic.reject(reason)
        }
        diagnostic.reject(.identifier, samples: 240)
        diagnostic.discardPartial(bytes: 3)
        diagnostic.stop(reason: "session_reset")
        clock.advance(0.4)
        let final = try #require(clock.finals.first)
        #expect(final.contains("callbacks=10 callback_bytes=1200 accepted_notifications=1 accepted_bytes=120"))
        #expect(final.contains("dropped_bytes=1080 dropped_samples=240"))
        for reason in ATVVAudioDiagnostics.Drop.allCases {
            #expect(final.contains("drop_\(reason.rawValue)=1"))
        }
        #expect(final.contains("partial_discarded_bytes=3"))
        #expect(final.contains("completion=forced"))
    }

    @Test func lateStopPacketsReachTheOneFinalEvenWhenNextSessionAlreadyStarted() throws {
        let clock = Clock()
        let first = clock.make(7)
        first.start(frameSamples: 240, origin: "remote_initiated")
        first.stop(reason: "remote_stop")
        clock.advance(0.1)
        first.receive(bytes: 120, frameSize: 120, at: clock.now)
        first.reject(.afterStop)
        let second = clock.make(8)
        second.start(frameSamples: 240, origin: "remote_initiated")
        clock.advance(0.3)
        first.stop(reason: "session_reset")
        clock.advance(15)
        #expect(clock.finals.count == 1)
        let final = try #require(clock.finals.first)
        #expect(final.contains("operation_id=7"))
        #expect(final.contains("drop_after_stop=1"))
    }

    @Test func outputPendingIsObservedWithoutFlushingOrReportingSuccessEarly() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        var output = VirtualAudioOutputDiagnosticSnapshot()
        output.boundToSelectedDevice = true
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.bindOutput(generation: 4, snapshot: { .init(output: output) }, fn: { (nil, nil) })
        output.pendingSamples = 240
        output.counters.scheduledSamples = 240
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        diagnostic.accept(bytes: 120)
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.routed(samples: 240, enqueued: true)
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        #expect(clock.finals.isEmpty)
        #expect(output.pendingSamples == 240)
        output.pendingSamples = 0
        output.counters.playedSamples = 240
        clock.advance(0.5)
        let final = try #require(clock.finals.first)
        #expect(final.contains("completion=normal"))
        #expect(final.contains("scheduled_samples=240 played_samples=240 interrupted_samples=0 pending_samples=0"))
        #expect(final.contains("transcript_commit=unknown external_capture=unknown"))
        clock.advance(20)
        #expect(clock.finals.count == 1)
    }

    @Test func diagnosticDeadlineDoesNotAlterAudioAndUsesUnknownCompletion() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        let output = VirtualAudioOutputDiagnosticSnapshot(pendingSamples: 240)
        diagnostic.start(frameSamples: 240, origin: "host_requested")
        diagnostic.bindOutput(generation: 3, snapshot: { .init(output: output) }, fn: { (nil, nil) })
        diagnostic.stop(reason: "remote_stop")
        clock.advance(11)
        let final = try #require(clock.finals.first)
        #expect(final.contains("completion=unknown"))
        #expect(final.contains("pending_samples=240"))
        #expect(output.pendingSamples == 240)
    }

    @Test func interruptedPlaybackIsForcedAndNotMisreportedAsNormal() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        var output = VirtualAudioOutputDiagnosticSnapshot()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.bindOutput(generation: 2, snapshot: { .init(output: output) }, fn: { (nil, nil) })
        diagnostic.decoded(bytes: 120, samples: 240)
        output.counters.interruptedSamples = 240
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        #expect(try #require(clock.finals.first).contains("completion=forced"))
    }

    @Test func configurationAndFnTapBuffersCannotMasqueradeAsAnEmptySuccessfulPlayer() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        var output = VirtualAudioOutputDiagnosticSnapshot()
        output.boundToSelectedDevice = true
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.bindOutput(generation: 5, snapshot: { .init(output: output) }, fn: { (nil, nil) })
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.buffered(samples: 240)
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        #expect(clock.finals.isEmpty)
        clock.advance(10)
        let final = try #require(clock.finals.first)
        #expect(final.contains("completion=unknown observed_result=output_unknown"))
        #expect(final.contains("unaccounted_samples=240"))
        #expect(output.pendingSamples == 0)
    }

    @Test func delayedBufferDeliveryCanStillBecomeObservedCompleteWithinTheWindow() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        var output = VirtualAudioOutputDiagnosticSnapshot()
        output.boundToSelectedDevice = true
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.bindOutput(generation: 5, snapshot: { .init(output: output) }, fn: { (nil, nil) })
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.buffered(samples: 240)
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        #expect(clock.finals.isEmpty)
        diagnostic.routed(samples: 240, enqueued: true)
        output.counters.scheduledSamples = 240
        output.counters.playedSamples = 240
        clock.advance(0.5)
        #expect(try #require(clock.finals.first).contains("completion=normal"))
    }

    @Test func sharedPlaybackAndIncompleteCountersRemainUnknown() throws {
        for shared in [true, false] {
            let clock = Clock()
            let diagnostic = clock.make()
            var output = VirtualAudioOutputDiagnosticSnapshot()
            output.boundToSelectedDevice = true
            diagnostic.start(frameSamples: 240, origin: "remote_initiated")
            diagnostic.bindOutput(generation: 5, snapshot: { .init(output: output, sessionIsolated: !shared) }, fn: { (nil, nil) })
            diagnostic.decoded(bytes: 120, samples: 240)
            diagnostic.routed(samples: 240, enqueued: true)
            output.counters.scheduledSamples = 240
            output.counters.playedSamples = shared ? 240 : 120
            diagnostic.stop(reason: "remote_stop")
            clock.advance(11)
            #expect(try #require(clock.finals.first).contains("completion=unknown observed_result=output_unknown"))
        }
    }

    @Test func startRejectionWithoutAudioStillHasOneCorrelatedFinal() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.rejectStart(reason: "audio_output_unavailable")
        diagnostic.rejectStart(reason: "voice_key_press_failed")
        clock.advance(1)
        #expect(clock.finals.count == 1)
        #expect(try #require(clock.finals.first).contains("start_rejection=audio_output_unavailable"))
    }

    @Test func failureDuringDeferredStartOverridesAnEarlierStopRequest() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.stop(reason: "remote_stop")
        diagnostic.rejectStart(reason: "audio_output_unavailable")
        clock.advance(1)
        let final = try #require(clock.finals.first)
        #expect(final.contains("completion=forced"))
        #expect(final.contains("start_rejection=audio_output_unavailable"))
    }

    @Test func highRateAndRepeatedDropsHaveAConstantSessionLogBudget() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        for index in 0..<20_000 {
            clock.now = 100 + Double(index) * 0.015
            diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
            diagnostic.reject(.notReady)
            diagnostic.handlerFinished(since: clock.now)
        }
        diagnostic.stop(reason: "session_reset")
        clock.advance(1)
        #expect(clock.lines.filter { $0.contains("phase=progress") }.count == 12)
        #expect(clock.lines.count == 15) // start + 12 progress + stopping + one final
        #expect(try #require(clock.finals.first).contains("drop_not_ready=20000"))
        #expect(clock.lines.reduce(0) { $0 + $1.utf8.count } < 16_000)
    }

    @Test func highRatePCMRetainsAllSamplesWithinSixteenDiagnosticLines() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        for index in 0..<20_000 {
            clock.now = 100 + Double(index) * 0.015
            diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
            diagnostic.accept(bytes: 120)
            diagnostic.decoded(bytes: 120, samples: 240)
            diagnostic.routed(samples: 240, enqueued: true)
            diagnostic.handlerFinished(since: clock.now)
        }
        diagnostic.stop(reason: "session_reset")
        clock.advance(1)
        #expect(clock.lines.count == 16)
        #expect(clock.lines.reduce(0) { $0 + $1.utf8.count } < 16_000)
        #expect(try #require(clock.finals.first).contains("decoded_samples=4800000 routed_samples=4800000"))
    }

    @Test func recorderSummaryCorrelatesActualWritesWithoutExposingContentOrIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) } }
        let done = DispatchSemaphore(value: 0)
        var lines: [String] = []
        let sessionID = UUID()
        let coordinator = RecordingAssetCoordinator(
            store: RecordingAssetStore(rootDirectoryURL: root), isEnabled: { true },
            onCommit: { _ in done.signal() }, log: { lines.append($0) }
        )
        coordinator.start(sessionID: sessionID, startedAt: Date(), source: .bluetoothRemote, diagnosticOperationID: 7)
        coordinator.append(samples: Array(repeating: 1200, count: 1600))
        coordinator.finish(endedAt: Date())
        #expect(done.wait(timeout: .now() + 3) == .success)
        let final = try #require(lines.first { $0.contains("RECORDING ASSET saved") })
        #expect(final.contains("audio_ms=100 audio_samples=1600"))
        #expect(final.contains("operation_id=7 audio_written_samples=1600 audio_written_ms=100"))
        #expect(final.contains("writer_rejected_samples=0 writer_failures=0"))
        #expect(!lines.joined().contains(sessionID.uuidString))
        #expect(!lines.joined().contains(root.path))
    }

    @Test func rejectedOrphanNotificationsAreEventuallySummarizedWithoutAStream() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        for _ in 0..<1_000 {
            diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
            diagnostic.reject(.lifecycle)
            diagnostic.handlerFinished(since: clock.now)
        }
        #expect(clock.lines.isEmpty)
        clock.advance(10)
        clock.advance(0.4)
        let final = try #require(clock.finals.first)
        #expect(final.contains("completion=no_session"))
        #expect(final.contains("drop_lifecycle=1000"))
        #expect(clock.lines.count == 2)
    }

    @Test func duplicateStartDoesNotEraseTheAudioLedger() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        diagnostic.accept(bytes: 120)
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.stop(reason: "remote_stop")
        clock.advance(1)
        let final = try #require(clock.finals.first)
        #expect(final.contains("accepted_bytes=120"))
        #expect(final.contains("duplicate_starts=1"))
    }

    @Test func callbackAndHandlerTimingNeverClaimsTransportArrivalOrTriggerIdentity() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        clock.advance(0.2)
        diagnostic.handlerFinished(since: 100)
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        let final = try #require(clock.finals.first)
        #expect(final.contains("max_callback_gap_ms=200"))
        #expect(final.contains("max_handler_ms=200"))
        #expect(final.contains("callback_wait_ms=unknown transport_arrival=unknown"))
        #expect(final.contains("trigger_down_to_first_pcm_ms=unknown"))
    }

    @Test func callbackQueueAndVoiceBusinessPathRemainAtTheStableBaseline() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/XiaomiBluetoothBridge.swift"), encoding: .utf8)
        #expect(bridge.contains("queue: .main"))
        #expect(!bridge.contains("onMain"))
        #expect(!bridge.contains("queue: bluetoothQueue"))
        #expect(bridge.contains("guard let data = characteristic.value"))
        let diagnostic = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/ATVVAudioDiagnostics.swift"), encoding: .utf8)
        #expect(!diagnostic.contains("microphoneClose("))
        #expect(!diagnostic.contains("microphoneExtend("))
        #expect(!diagnostic.contains("flushPlayer("))
        #expect(!diagnostic.contains("setVoiceKeyPressed("))
    }
}
