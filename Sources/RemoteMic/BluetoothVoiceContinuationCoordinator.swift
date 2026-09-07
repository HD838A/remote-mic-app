import Foundation

struct BluetoothVoiceContinuationPolicy {
    let countdownDuration: TimeInterval = 60
    let minimumDuration: TimeInterval = 50
    let maximumDuration: TimeInterval = 60
    let waitDuration: TimeInterval = 2
    let silenceFrameInterval: TimeInterval = 0.02
    let silenceFrameSampleCount = 320

    func shouldWait(after duration: TimeInterval) -> Bool {
        duration >= minimumDuration && duration <= maximumDuration
    }
}

enum BluetoothVoiceContinuationStopAction {
    case wait
    case finish(duration: TimeInterval)
}

final class BluetoothVoiceContinuationCoordinator {
    private let policy: BluetoothVoiceContinuationPolicy
    private let enqueueSilence: ([Int16]) -> Void
    private let updateRemainingSeconds: (Int?) -> Void
    private let finishAfterTimeout: (TimeInterval) -> Void
    private let log: (String) -> Void
    private var activeDeviceIdentifier: UUID?
    private var segmentStartedAt: Date?
    private var waitingContinuation = false
    private var waitingStopDuration: TimeInterval?
    private var countdownTimer: DispatchSourceTimer?
    private var countdownGeneration: UInt64 = 0
    private var continuationTimer: DispatchSourceTimer?
    private var silenceTimer: DispatchSourceTimer?
    private var continuationGeneration: UInt64 = 0

    init(
        policy: BluetoothVoiceContinuationPolicy = BluetoothVoiceContinuationPolicy(),
        enqueueSilence: @escaping ([Int16]) -> Void,
        updateRemainingSeconds: @escaping (Int?) -> Void,
        finishAfterTimeout: @escaping (TimeInterval) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.policy = policy
        self.enqueueSilence = enqueueSilence
        self.updateRemainingSeconds = updateRemainingSeconds
        self.finishAfterTimeout = finishAfterTimeout
        self.log = log
    }

    func isWaiting(for deviceIdentifier: UUID) -> Bool {
        waitingContinuation && activeDeviceIdentifier == deviceIdentifier
    }

    func start(deviceIdentifier: UUID) {
        resetContinuation(logReason: nil)
        activeDeviceIdentifier = deviceIdentifier
        segmentStartedAt = Date()
        startCountdown()
    }

    func resume(deviceIdentifier: UUID) {
        guard isWaiting(for: deviceIdentifier) else { return }
        waitingContinuation = false
        continuationGeneration &+= 1
        continuationTimer?.cancel()
        continuationTimer = nil
        stopSilenceOutput()
        waitingStopDuration = nil
        segmentStartedAt = Date()
        startCountdown()
        log("ATVV STREAM continuation_started; existing_logical_session=true")
    }

    func stop(
        deviceIdentifier: UUID,
        allowContinuation: Bool
    ) -> BluetoothVoiceContinuationStopAction {
        guard deviceIdentifier == activeDeviceIdentifier else {
            return .finish(duration: 0)
        }
        let duration = currentSegmentDuration()
        if allowContinuation && policy.shouldWait(after: duration) {
            beginContinuationWait(duration: duration)
            return .wait
        }
        return .finish(duration: duration)
    }

    func currentSegmentDuration() -> TimeInterval {
        guard let segmentStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(segmentStartedAt))
    }

    func cancel(reason: String) {
        resetContinuation(logReason: reason)
    }

    func finish(reason: String) {
        resetContinuation(logReason: reason)
    }

    private func beginContinuationWait(duration: TimeInterval) {
        guard !waitingContinuation else { return }
        waitingContinuation = true
        waitingStopDuration = duration
        continuationGeneration &+= 1
        let generation = continuationGeneration
        startSilenceOutput(generation: generation)
        log(
            "ATVV STREAM continuation_wait duration_ms=" +
                "\(Int(duration * 1_000)) " +
                "seconds=\(Int(policy.waitDuration))"
        )

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + policy.waitDuration)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.waitingContinuation,
                  self.continuationGeneration == generation,
                  let duration = self.waitingStopDuration
            else { return }
            self.finishAfterTimeout(duration)
        }
        continuationTimer = timer
        timer.resume()
    }

    private func startSilenceOutput(generation: UInt64) {
        stopSilenceOutput()
        let silence = Array(
            repeating: Int16(0),
            count: policy.silenceFrameSampleCount
        )
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: policy.silenceFrameInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.waitingContinuation,
                  self.continuationGeneration == generation
            else { return }
            self.enqueueSilence(silence)
        }
        silenceTimer = timer
        timer.resume()
    }

    private func stopSilenceOutput() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    private func startCountdown() {
        stopCountdown()
        let generation = countdownGeneration
        let startedAt = Date()
        publishRemainingSeconds(
            max(0, Int(ceil(policy.countdownDuration)))
        )

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.activeDeviceIdentifier != nil,
                  self.countdownGeneration == generation
            else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            self.publishRemainingSeconds(
                max(0, Int(ceil(self.policy.countdownDuration - elapsed)))
            )
        }
        countdownTimer = timer
        timer.resume()
    }

    private func stopCountdown() {
        countdownGeneration &+= 1
        countdownTimer?.cancel()
        countdownTimer = nil
        publishRemainingSeconds(nil)
    }

    private func publishRemainingSeconds(_ value: Int?) {
        updateRemainingSeconds(value)
    }

    private func resetContinuation(logReason: String?) {
        let hadContinuation = waitingContinuation ||
            continuationTimer != nil ||
            silenceTimer != nil
        continuationGeneration &+= 1
        continuationTimer?.cancel()
        continuationTimer = nil
        stopSilenceOutput()
        waitingContinuation = false
        waitingStopDuration = nil
        activeDeviceIdentifier = nil
        segmentStartedAt = nil
        stopCountdown()
        if hadContinuation, let logReason {
            log("ATVV STREAM continuation_cancelled reason=\(logReason)")
        }
    }
}
