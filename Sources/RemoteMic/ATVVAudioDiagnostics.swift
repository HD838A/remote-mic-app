import Foundation

/// Logging only. No command, gate, audio queue or voice-key decisions belong here.
final class ATVVAudioDiagnostics {
    enum Drop: String, CaseIterable {
        case stopped, stalePeripheral = "stale_peripheral", staleGeneration = "stale_generation"
        case callbackError = "callback_error", missingValue = "missing_value"
        case lifecycle, notReady = "not_ready", cancelledOpen = "cancelled_open"
        case afterStop = "after_stop", identifier
    }

    struct Playback {
        var output = VirtualAudioOutputDiagnosticSnapshot()
        var sessionIsolated = true
        var firstPlayedAt: TimeInterval?
        var lastPlayedAt: TimeInterval?
        var maxQueueWaitMilliseconds = 0
    }

    static let progressInterval: TimeInterval = 10
    static let maximumProgressLines = 12
    static let tailObservationDelay: TimeInterval = 0.35
    static let maximumOutputObservation: TimeInterval = 10
    static let silenceObservationInterval: TimeInterval = 2
    private static var nextOperationID: UInt64 = 0 // All callers are on the original main queue.

    let operationID: UInt64
    private let createdAt: TimeInterval
    private let log: (String) -> Void
    private let uptime: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var startedAt: TimeInterval?
    private var stoppedAt: TimeInterval?
    private var stopReason = "none"
    private var streamOrigin = "unknown"
    private var lastCallbackAt: TimeInterval?
    private var firstPCMAt: TimeInterval?
    private var lastPCMAt: TimeInterval?
    private var lastProgressAt: TimeInterval
    private var previousSamples = 0
    private var progressLines = 0
    private var maxGapMilliseconds = 0
    private var gapBuckets = [20: 0, 50: 0, 100: 0, 250: 0]
    private var maxGapAtMilliseconds = 0
    private var startRejectionReason = "none"
    private var maxHandlerMilliseconds = 0
    private var minNotificationBytes: Int?
    private var maxNotificationBytes = 0
    private var nonFrameMultipleNotifications = 0
    private var partialDiscardedBytes = 0
    private var duplicateStarts = 0
    private var callbacks = 0
    private var callbackBytes = 0
    private var acceptedNotifications = 0
    private var acceptedBytes = 0
    private var frames = 0
    private var decodedBytes = 0
    private var decodedSamples = 0
    private var routedSamples = 0
    private var bufferedSamples = 0
    private var enqueueFailures = 0
    private var drops: [Drop: Int] = [:]
    private var droppedBytes = 0
    private var droppedSamples = 0
    private var firstErrorFields = "error_domain=none error_code=0"
    private var bufferLosses: [String: Int] = [:]
    private var lastBufferLossReason = "none"
    private var lastBufferLossCause = "none"
    private var softwareDownAt: TimeInterval?
    private var softwareUpAt: TimeInterval?
    private var softwareKeyMode = "unknown"
    private var softwareDownResult = "unobserved"
    private var softwareUpResult = "unobserved"
    private var softwareSubmitFailures = 0
    private var silenceEpisodes = 0
    private var silenceActive = false
    private var silenceLogged = false
    private var recoveryLogged = false
    private var maxSilenceMilliseconds = 0
    private var maxObservationLagMilliseconds = 0
    private var lastReceivedBytes = 0
    private var playback: (() -> Playback?)?
    private var fnObservation: (() -> (down: TimeInterval?, up: TimeInterval?))?
    private var observedFnDownAt: TimeInterval?
    private var fnDownAtStop: TimeInterval?
    private var audioGeneration = 0
    private var countersAtStart = VirtualAudioPlaybackCounters()
    private(set) var isFinalized = false
    var hasStarted: Bool { startedAt != nil }
    var hasStopped: Bool { stoppedAt != nil }

    init(
        operationID: UInt64? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, operation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
        },
        log: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        if let operationID {
            self.operationID = operationID
        } else {
            Self.nextOperationID &+= 1
            self.operationID = Self.nextOperationID
        }
        self.uptime = uptime
        self.schedule = schedule
        self.log = log
        createdAt = uptime()
        lastProgressAt = createdAt
    }

    func receive(bytes: Int, frameSize: Int, at time: TimeInterval) {
        callbacks += 1
        lastReceivedBytes = bytes
        callbackBytes += bytes
        minNotificationBytes = min(minNotificationBytes ?? bytes, bytes)
        maxNotificationBytes = max(maxNotificationBytes, bytes)
        if frameSize > 0, bytes > 0, bytes % frameSize != 0 { nonFrameMultipleNotifications += 1 }
        if let previous = lastCallbackAt {
            let gap = milliseconds(time - previous)
            if gap > maxGapMilliseconds {
                maxGapMilliseconds = gap
                maxGapAtMilliseconds = milliseconds(time - (startedAt ?? createdAt))
            }
            for threshold in [20, 50, 100, 250] where gap >= threshold {
                gapBuckets[threshold, default: 0] += 1
            }
        }
        lastCallbackAt = time
        if silenceActive, !hasStopped {
            silenceActive = false
            if !recoveryLogged {
                recoveryLogged = true
                log("ATVV AUDIO diagnostic operation_id=\(operationID) phase=receive_resumed " +
                    "result=callback_observed silence_episodes=\(silenceEpisodes) transport_arrival=unknown")
            }
        }
        // One bounded idle aggregate even when every notification is rejected before START.
        if callbacks == 1 {
            schedule(Self.progressInterval) { [self] in
                if !hasStarted && !hasStopped { stop(reason: "no_stream_start") }
            }
        }
    }

    func start(frameSamples: Int, origin: String) {
        guard !hasStarted else { duplicateStarts += 1; return }
        startedAt = uptime()
        lastProgressAt = startedAt!
        streamOrigin = origin
        log("ATVV AUDIO diagnostic operation_id=\(operationID) phase=started " +
            "callback_queue=main callback_wait_ms=unknown transport_arrival=unknown stream_origin=\(origin) frame_samples=\(frameSamples)")
        observeSilence()
    }

    private func observeSilence() {
        let dueAt = uptime() + Self.silenceObservationInterval
        schedule(Self.silenceObservationInterval) { [weak self] in
            guard let self, !self.hasStopped else { return }
            let now = self.uptime()
            self.maxObservationLagMilliseconds = max(self.maxObservationLagMilliseconds, self.milliseconds(now - dueAt))
            let age = self.milliseconds(now - (self.lastCallbackAt ?? self.startedAt ?? self.createdAt))
            self.maxSilenceMilliseconds = max(self.maxSilenceMilliseconds, age)
            if age >= self.milliseconds(Self.silenceObservationInterval), !self.silenceActive {
                self.silenceActive = true
                self.silenceEpisodes += 1
                if !self.silenceLogged {
                    self.silenceLogged = true
                    self.log("ATVV AUDIO diagnostic operation_id=\(self.operationID) phase=receive_stalled " +
                        "result=observation_only reason=no_audio_callback callback_age_ms=\(age) " +
                        "threshold_ms=\(self.milliseconds(Self.silenceObservationInterval)) " +
                        "observation_lag_ms=\(self.maxObservationLagMilliseconds) " +
                        "decoded_samples=\(self.decodedSamples) business_action=none terminal_result=pending transport_arrival=unknown")
                }
            }
            self.observeSilence()
        }
    }

    /// Records submission to the public keyboard API, never physical hardware or target acceptance.
    func softwareKey(edge: String, mode: String, result: String) {
        guard !isFinalized else { return }
        softwareKeyMode = mode
        if result == "event_submit_failed" { softwareSubmitFailures += 1 }
        if edge == "down" {
            let first = softwareDownResult == "unobserved"
            if softwareDownAt == nil || result == "event_submitted" { softwareDownResult = result }
            if result == "event_submitted", softwareDownAt == nil { softwareDownAt = uptime() }
            if !first { return }
        } else {
            let first = softwareUpResult == "unobserved"
            if softwareUpAt == nil || result == "event_submitted" { softwareUpResult = result }
            if result == "event_submitted", softwareUpAt == nil { softwareUpAt = uptime() }
            if !first { return }
        }
        log("ATVV AUDIO diagnostic operation_id=\(operationID) phase=software_trigger edge=\(edge) " +
            "mode=\(mode) result=\(result) target_response=unknown physical_trigger=unobserved")
    }

    func bufferLost(samples: Int, stage: String, reason: String, cause: String? = nil) {
        guard samples > 0 else { return }
        bufferLosses["\(stage)_\(reason)", default: 0] += samples
        droppedSamples += samples
        lastBufferLossReason = reason
        lastBufferLossCause = cause ?? reason
    }

    func bindOutput(
        generation: Int,
        snapshot: @escaping () -> Playback?,
        fn: @escaping () -> (down: TimeInterval?, up: TimeInterval?)
    ) {
        audioGeneration = generation
        playback = snapshot
        fnObservation = fn
        countersAtStart = snapshot()?.output.counters ?? .init()
    }

    func reject(_ reason: Drop, samples: Int = 0, errorFields: String? = nil) {
        drops[reason, default: 0] += 1
        if reason == .identifier {
            droppedSamples += samples
        } else {
            droppedBytes += lastReceivedBytes
        }
        if let errorFields, firstErrorFields == "error_domain=none error_code=0" {
            firstErrorFields = errorFields
        }
    }

    func accept(bytes: Int) { acceptedNotifications += 1; acceptedBytes += bytes }
    func discardPartial(bytes: Int) { partialDiscardedBytes += bytes }

    func decoded(bytes: Int, samples: Int) {
        frames += 1
        decodedBytes += bytes
        decodedSamples += samples
        lastPCMAt = uptime()
        if firstPCMAt == nil {
            firstPCMAt = lastPCMAt
            observedFnDownAt = fnObservation?().down
            log("ATVV AUDIO diagnostic operation_id=\(operationID) phase=first_pcm " +
                "stream_start_to_first_pcm_ms=\(milliseconds(lastPCMAt! - (startedAt ?? createdAt))) " +
                "trigger_down_to_first_pcm_ms=unknown trigger_identity=unobserved")
        }
    }

    func buffered(samples: Int) { bufferedSamples += samples }

    func routed(samples: Int, enqueued: Bool, buffered: Bool = false) {
        routedSamples += samples
        if buffered { bufferedSamples += samples }
        if !enqueued { enqueueFailures += 1 }
    }

    func handlerFinished(since time: TimeInterval) {
        maxHandlerMilliseconds = max(maxHandlerMilliseconds, milliseconds(uptime() - time))
        guard !hasStopped, uptime() - lastProgressAt >= Self.progressInterval,
              progressLines < Self.maximumProgressLines else { return }
        let interval = uptime() - lastProgressAt
        let coverage = ATVVProtocol.audioCoveragePercent(
            receivedSamples: decodedSamples - previousSamples,
            durationMilliseconds: milliseconds(interval)
        )
        previousSamples = decodedSamples
        lastProgressAt = uptime()
        progressLines += 1
        log("ATVV AUDIO diagnostic operation_id=\(operationID) phase=progress " +
            counts() + " interval_coverage_pct=\(String(format: "%.1f", coverage)) " +
            "interval_basis=main_callback_processing")
    }

    func rejectStart(reason: String) {
        if startRejectionReason == "none" { startRejectionReason = reason }
        stop(reason: "start_rejected")
    }

    func stop(reason: String) {
        guard !hasStopped else { return }
        stoppedAt = uptime()
        fnDownAtStop = fnObservation?().down
        stopReason = reason
        log("ATVV AUDIO diagnostic operation_id=\(operationID) phase=stopping reason=\(reason) " +
            "audio_generation=\(audioGeneration) terminal_result=pending")
        // Observation only: never closes the microphone, flushes audio or delays a voice edge.
        schedule(Self.tailObservationDelay) { [self] in finishIfObserved() }
    }

    private func finishIfObserved() {
        guard !isFinalized, let stoppedAt else { return }
        let observed = playback?()
        let output = observed?.output
        let elapsed = uptime() - stoppedAt
        let played = output.map { max(0, $0.counters.playedSamples - countersAtStart.playedSamples) }
        let scheduled = output.map { max(0, $0.counters.scheduledSamples - countersAtStart.scheduledSamples) }
        let interrupted = output.map { max(0, $0.counters.interruptedSamples - countersAtStart.interruptedSamples) }
        let attributionKnown = observed?.sessionIsolated == true
        let locallyFailed = (interrupted ?? 0) > 0 || enqueueFailures > 0 || droppedSamples > 0 ||
            startRejectionReason != "none" || softwareUpResult == "event_submit_failed"
        // An empty player queue does not include configuration, command or FnTap buffers.
        let unaccountedSamples = max(0, decodedSamples - droppedSamples - (scheduled ?? 0))
        let fullyPlayed = attributionKnown && output != nil && decodedSamples > 0 &&
            routedSamples == decodedSamples && scheduled == decodedSamples &&
            played == decodedSamples && output?.pendingSamples == 0 &&
            output?.boundToSelectedDevice == true && !locallyFailed
        if hasStarted, stopReason == "remote_stop", output != nil, attributionKnown,
           !locallyFailed, !fullyPlayed,
           ((output?.pendingSamples ?? 0) > 0 || unaccountedSamples > 0 || (scheduled ?? 0) > (played ?? 0)),
           elapsed < Self.maximumOutputObservation {
            schedule(0.5) { [self] in finishIfObserved() }
            return
        }
        isFinalized = true
        let completion: String
        if !hasStarted {
            completion = "no_session"
        } else if stopReason != "remote_stop" || locallyFailed {
            completion = "forced"
        } else {
            completion = fullyPlayed ? "normal" : "unknown"
        }
        let fn = fnObservation?()
        let fnUp = fn?.down == fnDownAtStop ? fn?.up : nil
        let result = decodedSamples == 0 ? "no_pcm"
            : locallyFailed ? "local_delivery_failed"
            : !fullyPlayed ? "output_unknown"
            : "received_audio_playback_observed"
        let duration = milliseconds(stoppedAt - (startedAt ?? createdAt))
        let coverage = ATVVProtocol.audioCoveragePercent(receivedSamples: decodedSamples, durationMilliseconds: duration)
        // Keep each expression small for the older Swift compiler used by CI.
        var fields: [String] = []
        fields.append("ATVV AUDIO diagnostic operation_id=\(operationID) phase=completed completion=\(completion) observed_result=\(result)")
        fields.append("reason=\(stopReason) audio_generation=\(audioGeneration)")
        fields.append(counts())
        fields.append("duration_ms=\(duration) coverage_pct=\(String(format: "%.1f", coverage))")
        fields.append("coverage_basis=main_callback_processing callback_wait_ms=unknown transport_arrival=unknown")
        fields.append("max_callback_gap_ms=\(maxGapMilliseconds) max_gap_at_ms=\(maxGapAtMilliseconds)")
        for threshold in [20, 50, 100, 250] {
            fields.append("gaps_ge_\(threshold)ms=\(gapBuckets[threshold, default: 0])")
        }
        fields.append("max_handler_ms=\(maxHandlerMilliseconds) notify_bytes_min=\(minNotificationBytes ?? 0)")
        fields.append("notify_bytes_max=\(maxNotificationBytes) not_frame_multiple=\(nonFrameMultipleNotifications)")
        fields.append("partial_discarded_bytes=\(partialDiscardedBytes) duplicate_starts=\(duplicateStarts)")
        fields.append("start_rejection=\(startRejectionReason) output_attribution=\(attributionKnown ? "isolated" : "unknown_shared_generation")")
        fields.append("unaccounted_samples=\(unaccountedSamples) scheduled_samples=\(token(scheduled)) played_samples=\(token(played))")
        fields.append("interrupted_samples=\(token(interrupted)) pending_samples=\(token(output?.pendingSamples))")
        fields.append("output_bound=\(output?.boundToSelectedDevice.map(String.init) ?? "unknown")")
        fields.append("output_selected=\(output?.selectedDeviceKind.rawValue ?? "unknown")")
        fields.append("output_actual=\(output?.actualDeviceKind.rawValue ?? "unknown")")
        fields.append("output_queue_max_wait_ms=\(observed.map { String($0.maxQueueWaitMilliseconds) } ?? "unknown")")
        fields.append("observed_fn_down_to_first_pcm_ms=\(interval(observedFnDownAt, firstPCMAt))")
        fields.append("observed_fn_up_to_last_playback_ms=\(interval(fnUp, observed?.lastPlayedAt))")
        fields.append("software_key_mode=\(softwareKeyMode) software_down_result=\(softwareDownResult) software_up_result=\(softwareUpResult) software_submit_failures=\(softwareSubmitFailures)")
        fields.append("software_down_to_first_pcm_ms=\(interval(softwareDownAt, firstPCMAt)) software_up_to_last_playback_ms=\(interval(softwareUpAt, observed?.lastPlayedAt))")
        fields.append("silence_episodes=\(silenceEpisodes) receive_stalled_at_stop=\(silenceActive) max_silence_ms=\(maxSilenceMilliseconds) observation_max_lag_ms=\(maxObservationLagMilliseconds)")
        fields.append("last_buffer_loss_reason=\(lastBufferLossReason) last_buffer_loss_cause=\(lastBufferLossCause)")
        fields.append("fn_source=global_unattributed trigger_down_to_first_pcm_ms=unknown")
        fields.append("transcript_commit=unknown external_capture=unknown")
        fields.append("diagnostic_boundary=transport_and_external_tool_unobservable")
        fields.append("observation_ms=\(milliseconds(elapsed)) progress_lines=\(progressLines)")
        fields.append(firstErrorFields)
        log(fields.joined(separator: " "))
    }

    private func counts() -> String {
        let reasons = Drop.allCases.map { "drop_\($0.rawValue)=\(drops[$0, default: 0])" }.joined(separator: " ")
        let losses = ["configuration", "command"].flatMap { stage in
            ["overflow", "cancelled", "configuration_failed"].map { reason in
                let key = "\(stage)_\(reason)"
                return "buffer_\(key)_samples=\(bufferLosses[key, default: 0])"
            }
        }.joined(separator: " ")
        return "callbacks=\(callbacks) callback_bytes=\(callbackBytes) accepted_notifications=\(acceptedNotifications) " +
            "accepted_bytes=\(acceptedBytes) frames=\(frames) decoded_bytes=\(decodedBytes) " +
            "decoded_samples=\(decodedSamples) routed_samples=\(routedSamples) buffered_samples=\(bufferedSamples) " +
            "enqueue_failures=\(enqueueFailures) dropped_bytes=\(droppedBytes) dropped_samples=\(droppedSamples) " + reasons + " " + losses
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 1_000).rounded())) }
    private func token(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }
    private func interval(_ start: TimeInterval?, _ end: TimeInterval?) -> String {
        guard let start, let end else { return "unknown" }
        return String(Int(((end - start) * 1_000).rounded()))
    }
}
