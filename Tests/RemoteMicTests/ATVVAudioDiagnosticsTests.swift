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

    @Test func finalCorrelatesControlTailAndPerWindowDeliveryWithoutPayloads() throws {
        let clock = Clock()
        let diagnostic = clock.make(42)
        diagnostic.configure(generation: 9, version: 0x0100, codec: 2, frameBytes: 120, sampleRate: 16_000)
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.control(.start, at: clock.now)
        for index in 0..<80 {
            clock.now = 100 + Double(index) * 0.015
            diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
            diagnostic.accept(bytes: 120)
            diagnostic.decoded(bytes: 120, samples: 240)
            diagnostic.routed(samples: 240, enqueued: true)
            diagnostic.handlerFinished(since: clock.now)
        }
        diagnostic.control(.stop, at: clock.now)
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        let final = try #require(clock.finals.first)
        #expect(final.contains("ble_generation=9 protocol_version=256 codec=2 frame_bytes=120 sample_rate=16000"))
        #expect(final.contains("control_tail_schema=kind,offset_ms,callbacks,pcm_samples"))
        #expect(final.contains("control_tail=start:"))
        #expect(final.contains("timeline_schema=v1"))
        #expect(final.contains("capture_samples=unknown radio_sequence=unknown"))
        #expect(!final.contains("pcm="))
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

    @Test func missingCallbacksWithoutStopAreObservedOnceAndNeverEndTheBusinessSession() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        clock.advance(2)
        clock.advance(8)
        #expect(clock.lines.filter { $0.contains("phase=receive_stalled") }.count == 1)
        #expect(clock.finals.isEmpty)
        #expect(!diagnostic.hasStopped)
        #expect(clock.lines.last?.contains("business_action=none terminal_result=pending") == true)
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        clock.advance(2)
        diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
        #expect(clock.lines.filter { $0.contains("phase=receive_resumed") }.count == 1)
        diagnostic.stop(reason: "session_reset")
        clock.advance(0.4)
        #expect(try #require(clock.finals.first).contains("silence_episodes=2"))
        let lineCount = clock.lines.count
        clock.advance(30)
        #expect(clock.lines.count == lineCount)
    }

    @Test func delayedObserverMeasuresItsOwnQueueLagWithoutClaimingBLEArrival() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        clock.advance(5) // The two-second observation runs three seconds late.
        let stalled = try #require(clock.lines.first { $0.contains("phase=receive_stalled") })
        #expect(stalled.contains("observation_lag_ms=3000"))
        #expect(stalled.contains("transport_arrival=unknown"))
        diagnostic.stop(reason: "session_reset")
        clock.advance(0.4)
        #expect(try #require(clock.finals.first).contains("observation_max_lag_ms=3000"))
    }

    @Test func softwareReleaseRetryKeepsOneEdgeLogAndItsActualSubmissionTime() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        var output = VirtualAudioOutputDiagnosticSnapshot()
        output.boundToSelectedDevice = true
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.bindOutput(generation: 4, snapshot: {
            .init(output: output, lastPlayedAt: 100.135)
        }, fn: { (nil, nil) })
        diagnostic.softwareKey(edge: "down", mode: "right_command", result: "event_submitted")
        clock.advance(0.02)
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.routed(samples: 240, enqueued: true)
        clock.advance(0.08)
        diagnostic.softwareKey(edge: "up", mode: "right_command", result: "event_submit_failed")
        diagnostic.softwareKey(edge: "up", mode: "right_command", result: "event_submitted")
        output.counters.scheduledSamples = 240
        output.counters.playedSamples = 240
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        let final = try #require(clock.finals.first)
        #expect(final.contains("completion=normal"))
        #expect(final.contains("software_up_result=event_submitted software_submit_failures=1"))
        #expect(final.contains("software_down_to_first_pcm_ms=20 software_up_to_last_playback_ms=35"))
        #expect(final.contains("trigger_down_to_first_pcm_ms=unknown"))
        #expect(clock.lines.filter { $0.contains("phase=software_trigger") }.count == 2)
    }

    @Test func unreleasedSoftwareKeyCannotProduceANormalAudioFinal() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        var output = VirtualAudioOutputDiagnosticSnapshot()
        output.boundToSelectedDevice = true
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.bindOutput(generation: 4, snapshot: { .init(output: output) }, fn: { (nil, nil) })
        diagnostic.decoded(bytes: 120, samples: 240)
        diagnostic.routed(samples: 240, enqueued: true)
        output.counters.scheduledSamples = 240
        output.counters.playedSamples = 240
        diagnostic.softwareKey(edge: "up", mode: "right_command", result: "event_submit_failed")
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        #expect(try #require(clock.finals.first).contains("completion=forced observed_result=local_delivery_failed"))
    }

    @Test func cappedBuffersAccountForOverflowAndCancellationAgainstDecodedSamples() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        var buffer = CommandVoiceActivationAudioBuffer(maximumSampleCount: 32_000)
        buffer.begin()
        for _ in 0..<400 {
            let samples = Array(repeating: Int16(10), count: 240)
            diagnostic.decoded(bytes: 120, samples: samples.count)
            let before = buffer.bufferedSampleCount
            let accepted = buffer.appendIfWaiting(samples)
            #expect(accepted)
            diagnostic.buffered(samples: samples.count)
            diagnostic.bufferLost(samples: before + samples.count - buffer.bufferedSampleCount,
                                  stage: "configuration", reason: "overflow")
        }
        #expect(buffer.bufferedSampleCount == 32_000)
        diagnostic.bufferLost(samples: buffer.bufferedSampleCount, stage: "configuration",
                              reason: "cancelled", cause: "stop_before_audio_ready")
        buffer.cancel()
        diagnostic.stop(reason: "remote_stop")
        clock.advance(0.4)
        let final = try #require(clock.finals.first)
        #expect(final.contains("decoded_samples=96000"))
        #expect(final.contains("dropped_samples=96000"))
        #expect(final.contains("buffer_configuration_overflow_samples=64000 buffer_configuration_cancelled_samples=32000"))
        #expect(final.contains("last_buffer_loss_cause=stop_before_audio_ready"))
        #expect(final.contains("completion=forced"))
        #expect(buffer.bufferedSampleCount == 0)
    }

    @Test func allNewObservationsRemainWithinTwentyLinesAcrossRepeatedStallsAndTwentyThousandPackets() throws {
        let clock = Clock()
        let diagnostic = clock.make()
        diagnostic.start(frameSamples: 240, origin: "remote_initiated")
        diagnostic.softwareKey(edge: "down", mode: "right_command", result: "event_submitted")
        clock.advance(2)
        for index in 0..<20_000 {
            clock.now = 102 + Double(index) * 0.015
            diagnostic.receive(bytes: 120, frameSize: 120, at: clock.now)
            diagnostic.accept(bytes: 120)
            diagnostic.decoded(bytes: 120, samples: 240)
            diagnostic.routed(samples: 240, enqueued: true)
            diagnostic.handlerFinished(since: clock.now)
        }
        clock.advance(3)
        diagnostic.receive(bytes: 0, frameSize: 120, at: clock.now)
        diagnostic.softwareKey(edge: "up", mode: "right_command", result: "event_submit_failed")
        diagnostic.softwareKey(edge: "up", mode: "right_command", result: "event_submitted")
        diagnostic.stop(reason: "session_reset")
        clock.advance(0.4)
        #expect(clock.lines.count == 20)
        #expect(clock.lines.reduce(0) { $0 + $1.utf8.count } < 20_000)
        #expect(try #require(clock.finals.first).contains("decoded_samples=4800000 routed_samples=4800000"))
        #expect(clock.finals.count == 1)
    }
}
