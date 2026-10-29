import Foundation

struct VoiceFnTapScheduledTask {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }

    static func mainQueue(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) -> VoiceFnTapScheduledTask {
        var workItem: DispatchWorkItem?
        let item = DispatchWorkItem {
            guard workItem?.isCancelled == false else { return }
            operation()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return VoiceFnTapScheduledTask { item.cancel() }
    }
}

enum VoiceFnTapFailure: String, Equatable {
    case startTapFailed = "start_tap_failed"
    case stopTapFailed = "stop_tap_failed"
}

final class VoiceFnTapSessionController {
    enum Phase: Equatable {
        case idle
        case starting(UInt64)
        case active(UInt64)
        case draining(UInt64)
        case stopping(UInt64)
    }

    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask
    typealias FunctionKeySetter = (Bool) -> Bool
    typealias AudioEnqueuer = ([Int16]) -> Void
    typealias AudioDrainer = (UInt64, @escaping () -> Void) -> Void
    typealias DestinationReadiness = (
        @escaping (VoiceInputDestinationWaitResult) -> Void
    ) -> VoiceInputDestinationWait

    private struct PendingVoice {
        var samples: [Int16] = []
        var ended = false
        /// Measured from release, including time spent queued.
        var continuationDeadline: TimeInterval?
    }

    /// Upper bound on `.draining`. Comfortably above the audio side's own drain fallback,
    /// so a healthy session always leaves `.draining` through `drainAudio` and this only
    /// fires when no drain answer arrives at all.
    private let drainTimeout: TimeInterval = 2
    private let startDelay: TimeInterval
    private let tapDuration: TimeInterval
    private let maximumPreRollSampleCount: Int
    private let schedule: Scheduler
    private let destinationReadiness: DestinationReadiness
    private let setFunctionKeyPressed: FunctionKeySetter
    private let enqueueAudio: AudioEnqueuer
    private let drainAudio: AudioDrainer
    private let onFailure: (VoiceFnTapFailure) -> Void
    private let logger: (String) -> Void
    private let uptime: () -> TimeInterval

    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    private(set) var isSuspended = false
    private var generation: UInt64 = 0
    private var preRoll: [Int16] = []
    private var continuationDeadline: TimeInterval?
    private var remoteEnded = false
    private var continuationTask: VoiceFnTapScheduledTask?
    private var continuationGeneration: UInt64 = 0
    /// Replay from the front; append incoming audio to the last segment.
    private var pendingVoices: [PendingVoice] = []
    private var scheduledTasks: [VoiceFnTapScheduledTask] = []
    private var functionKeyIsPressed = false
    private var idleCompletions: [() -> Void] = []
    private var suppressAudioUntilRemoteStop = false
    private var drainOperationID: UInt64?
    private var drainStartedAtUptime: TimeInterval?

    var requiresCleanupBeforeMapping: Bool {
        phase != .idle || functionKeyIsPressed || suppressAudioUntilRemoteStop
    }

    private var isWaitingForContinuation: Bool {
        if let tail = pendingVoices.last { return tail.continuationDeadline != nil }
        return continuationTask != nil
    }


    private var heldPendingIndex: Int? {
        guard let index = pendingVoices.indices.last else { return nil }
        let tail = pendingVoices[index]
        return !tail.ended && tail.continuationDeadline == nil ? index : nil
    }


    private var currentSessionIsClosing: Bool {
        switch phase {
        case .starting, .active:
            return remoteEnded
        case .draining, .stopping:
            return true
        case .idle:
            return false
        }
    }

    init(
        startDelay: TimeInterval = 0.15,
        tapDuration: TimeInterval = 0.12,
        maximumPreRollSampleCount: Int = 80_000,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        destinationReadiness: @escaping DestinationReadiness = { _ in .immediate },
        setFunctionKeyPressed: @escaping FunctionKeySetter,
        enqueueAudio: @escaping AudioEnqueuer,
        drainAudio: @escaping AudioDrainer,
        onFailure: @escaping (VoiceFnTapFailure) -> Void,
        logger: @escaping (String) -> Void = { _ in },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.startDelay = startDelay
        self.tapDuration = tapDuration
        self.maximumPreRollSampleCount = maximumPreRollSampleCount
        self.schedule = schedule
        self.destinationReadiness = destinationReadiness
        self.setFunctionKeyPressed = setFunctionKeyPressed
        self.enqueueAudio = enqueueAudio
        self.drainAudio = drainAudio
        self.onFailure = onFailure
        self.logger = logger
        self.uptime = uptime
    }

    func setEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        isEnabled = enabled
        if enabled {
            completion?()
            return
        }
        let hasSession = phase != .idle
        let remoteHasEnded = pendingVoices.last.map {
            $0.ended || $0.continuationDeadline != nil
        } ?? (remoteEnded || isWaitingForContinuation)
        terminateCurrentSession(
            remoteHasEnded: remoteHasEnded,
            suppressUntilRemoteStop: hasSession && !remoteHasEnded,
            completion: completion
        )
    }

    func suspend(completion: (() -> Void)? = nil) {
        isSuspended = true
        terminateCurrentSession(
            remoteHasEnded: true,
            suppressUntilRemoteStop: false,
            completion: completion
        )
    }

    func resume() {
        isSuspended = false
    }

    @discardableResult
    func startVoice() -> Bool {
        guard isEnabled, !isSuspended else { return false }
        if let deadline = continuationDeadline, uptime() >= deadline {
            _ = stopVoice()
        }
        if continuationTask != nil {
            cancelContinuation()
            remoteEnded = false
            logger("VOICE FN TAP continuation operation_id=\(generation) phase=completed result=resumed")
        }
        if currentSessionIsClosing {
            let now = uptime()
            if let index = pendingVoices.indices.last {
                let tail = pendingVoices[index]
                if !tail.ended, tail.continuationDeadline.map({ $0 > now }) ?? true {
                    pendingVoices[index].continuationDeadline = nil
                } else {
                    pendingVoices.append(PendingVoice())
                    logger(
                        "VOICE FN TAP continuation operation_id=\(generation) " +
                            "phase=queued result=separate_segment"
                    )
                }
            } else {
                pendingVoices.append(PendingVoice())
            }
        } else if phase == .idle {
            beginSession()
        }
        return true
    }

    @discardableResult
    func receive(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else {
            return phase != .idle || !pendingVoices.isEmpty || suppressAudioUntilRemoteStop
        }
        if currentSessionIsClosing, !pendingVoices.isEmpty {
            appendPreRoll(samples, toPendingVoice: true)
            return true
        }
        switch phase {
        case .starting:
            appendPreRoll(samples, toPendingVoice: false)
            return true
        case .active:
            enqueueAudio(samples)
            return true
        case .draining, .stopping:
            return true
        case .idle:
            return suppressAudioUntilRemoteStop
        }
    }

    @discardableResult
    func stopVoice(continuationDelay: TimeInterval = 0, completion: (() -> Void)? = nil) -> Bool {
        if let completion { idleCompletions.append(completion) }
        if continuationDelay > 0, isEnabled, !isSuspended {

            if let index = heldPendingIndex {
                pendingVoices[index].continuationDeadline = uptime() + continuationDelay
                logger("VOICE FN TAP continuation operation_id=\(generation) phase=queued result=waiting")
                return true
            }
            if !pendingVoices.isEmpty { return true }
            switch phase {
            case .starting, .active:
                guard continuationTask == nil else { return true }
                armContinuation(expiringAt: uptime() + continuationDelay)
                logger("VOICE FN TAP continuation operation_id=\(generation) phase=started result=waiting")
                return true
            case .draining, .stopping:
                break
            case .idle:
                break
            }
        }
        cancelContinuation()
        suppressAudioUntilRemoteStop = false
        if let index = pendingVoices.indices.last {
            if !pendingVoices[index].ended {
                pendingVoices[index].ended = true
                pendingVoices[index].continuationDeadline = nil
            }
            return true
        }
        switch phase {
        case .starting:
            remoteEnded = true
            return true
        case let .active(sessionGeneration):
            remoteEnded = true
            beginDrain(generation: sessionGeneration)
            return true
        case .draining, .stopping:
            remoteEnded = true
            return true
        case .idle:
            runIdleCompletions()
            return false
        }
    }

    func finishContinuationIfWaiting() {
        for index in pendingVoices.indices where pendingVoices[index].continuationDeadline != nil {
            pendingVoices[index].continuationDeadline = nil
            pendingVoices[index].ended = true
        }
        if continuationTask != nil { _ = stopVoice() }
    }

    func shutdown() {
        isEnabled = false
        isSuspended = true
        pendingVoices.removeAll()
        generation &+= 1
        cancelScheduledTasks()
        let completedInFlightTap = releaseFunctionKeyIfNeeded()
        let needsStopTap: Bool
        switch phase {
        case .active, .draining:
            needsStopTap = true
        case .stopping:
            // Releasing the in-flight key-down above completes the stop tap.
            // Posting another tap here would toggle the target back on.
            needsStopTap = false
        case .starting:
            needsStopTap = completedInFlightTap
        case .idle:
            needsStopTap = false
        }
        if needsStopTap, !postImmediateFunctionKeyTap() {
            onFailure(.stopTapFailed)
        }
        logDrainTerminalIfNeeded(result: "cancelled", reason: "shutdown")
        resetSessionState()
        runIdleCompletions()
    }

    private func beginSession(preloaded: PendingVoice? = nil) {
        generation &+= 1
        let sessionGeneration = generation
        phase = .starting(sessionGeneration)
        preRoll = preloaded?.samples ?? []
        remoteEnded = preloaded?.ended ?? false
        if !remoteEnded, let deadline = preloaded?.continuationDeadline {
            if deadline > uptime() {
                armContinuation(expiringAt: deadline)
                logger("VOICE FN TAP continuation operation_id=\(sessionGeneration) phase=handover result=waiting")
            } else {

                logger("VOICE FN TAP continuation operation_id=\(sessionGeneration) phase=handover result=expired")
                remoteEnded = true
            }
        }
        switch destinationReadiness({ [weak self] result in
            self?.destinationReadinessCompleted(result, generation: sessionGeneration)
        }) {
        case .immediate:
            scheduleStartTap(generation: sessionGeneration, after: startDelay)
        case .cancelled:
            cancelSessionAwaitingDestination(generation: sessionGeneration)
        case let .waiting(task):
            scheduledTasks.append(task)
        }
    }

    private func destinationReadinessCompleted(
        _ result: VoiceInputDestinationWaitResult,
        generation sessionGeneration: UInt64
    ) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        switch result {
        case .ready:
            beginStartTap(generation: sessionGeneration)
        case .cancelled:
            cancelSessionAwaitingDestination(generation: sessionGeneration)
        }
    }

    private func scheduleStartTap(generation sessionGeneration: UInt64, after delay: TimeInterval) {
        let task = schedule(delay) { [weak self] in
            self?.beginStartTap(generation: sessionGeneration)
        }
        scheduledTasks.append(task)
    }

    private func cancelSessionAwaitingDestination(generation sessionGeneration: UInt64) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        let shouldSuppressAudioUntilRemoteStop = !remoteEnded && !isWaitingForContinuation
        generation &+= 1
        resetSessionState()
        suppressAudioUntilRemoteStop = shouldSuppressAudioUntilRemoteStop
        runIdleCompletions()
    }

    private func beginStartTap(generation sessionGeneration: UInt64) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        performFunctionKeyTap(generation: sessionGeneration) { [weak self] success in
            guard let self,
                  self.phase == .starting(sessionGeneration),
                  self.generation == sessionGeneration
            else { return }
            guard success else {
                self.fail(.startTapFailed)
                return
            }
            self.phase = .active(sessionGeneration)
            if !self.preRoll.isEmpty {
                self.enqueueAudio(self.preRoll)
                self.preRoll.removeAll(keepingCapacity: false)
            }
            if self.remoteEnded {
                self.beginDrain(generation: sessionGeneration)
            }
        }
    }

    private func beginDrain(generation sessionGeneration: UInt64) {
        guard generation == sessionGeneration else { return }
        switch phase {
        case .active(sessionGeneration):
            phase = .draining(sessionGeneration)
        case .draining(sessionGeneration), .stopping(sessionGeneration):
            return
        default:
            return
        }
        drainOperationID = sessionGeneration
        drainStartedAtUptime = uptime()
        logger(
            "VOICE FN TAP drain operation_id=\(sessionGeneration) " +
                "phase=requested result=pending timeout_ms=\(Int(drainTimeout * 1_000))"
        )
        // Safety net for a drain answer that never arrives at all: the audio side's own
        // fallback holds its output weakly, so a released output reports nothing and this
        // session would sit in `.draining` refusing every later voice press. Armed before
        // `drainAudio` so a synchronous answer cancels it through `resetSessionState`, and
        // funnelled through the generation-guarded `beginStopTap` so a late fire cannot
        // touch a healthy later session.
        scheduledTasks.append(schedule(drainTimeout) { [weak self] in
            self?.resolveDrain(generation: sessionGeneration, result: "timed_out")
        })
        drainAudio(sessionGeneration) { [weak self] in
            self?.resolveDrain(generation: sessionGeneration, result: "answered")
        }
    }

    private func resolveDrain(generation sessionGeneration: UInt64, result: String) {
        guard phase == .draining(sessionGeneration), generation == sessionGeneration else {
            logger(
                "VOICE FN TAP drain operation_id=\(sessionGeneration) " +
                    "phase=ignored result=stale trigger=\(result)"
            )
            return
        }
        logger(
            "VOICE FN TAP drain operation_id=\(sessionGeneration) " +
                "phase=resolved result=\(result) elapsed_ms=\(drainElapsedMilliseconds())"
        )
        beginStopTap(generation: sessionGeneration)
    }

    private func beginStopTap(generation sessionGeneration: UInt64) {
        guard phase == .draining(sessionGeneration), generation == sessionGeneration else { return }
        phase = .stopping(sessionGeneration)
        performFunctionKeyTap(generation: sessionGeneration) { [weak self] success in
            guard let self,
                  self.phase == .stopping(sessionGeneration),
                  self.generation == sessionGeneration
            else { return }
            guard success else {
                self.fail(.stopTapFailed)
                return
            }
            self.logDrainTerminalIfNeeded(result: "session_closed", reason: "stop_tap_completed")
            self.finishSession()
        }
    }

    private func performFunctionKeyTap(
        generation sessionGeneration: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == sessionGeneration else { return }
        guard setFunctionKeyPressed(true) else {
            completion(false)
            return
        }
        functionKeyIsPressed = true
        let task = schedule(tapDuration) { [weak self] in
            guard let self, self.generation == sessionGeneration else { return }
            let success = self.setFunctionKeyPressed(false)
            self.functionKeyIsPressed = !success
            completion(success)
        }
        scheduledTasks.append(task)
    }

    private func terminateCurrentSession(
        remoteHasEnded: Bool,
        suppressUntilRemoteStop: Bool,
        completion: (() -> Void)?
    ) {
        if let completion {
            idleCompletions.append(completion)
        }
        cancelContinuation()
        pendingVoices.removeAll()
        suppressAudioUntilRemoteStop = suppressUntilRemoteStop
        switch phase {
        case .idle:
            runIdleCompletions()
        case .starting:
            generation &+= 1
            cancelScheduledTasks()
            let completedStartTap = releaseFunctionKeyIfNeeded()
            if completedStartTap, !postImmediateFunctionKeyTap() {
                onFailure(.stopTapFailed)
            }
            resetSessionState()
            runIdleCompletions()
        case let .active(sessionGeneration):
            remoteEnded = remoteHasEnded
            beginDrain(generation: sessionGeneration)
        case .draining, .stopping:
            remoteEnded = remoteHasEnded
        }
    }

    private func armContinuation(expiringAt deadline: TimeInterval) {
        continuationDeadline = deadline
        continuationGeneration &+= 1
        let token = continuationGeneration
        continuationTask = schedule(max(0, deadline - uptime())) { [weak self] in
            guard let self, self.continuationGeneration == token else { return }
            self.continuationTask = nil
            self.logger("VOICE FN TAP continuation operation_id=\(self.generation) phase=completed result=expired")
            _ = self.stopVoice()
        }
    }

    private func finishSession() {
        resetSessionState()
        runIdleCompletions()
        guard isEnabled, !isSuspended, !pendingVoices.isEmpty else {
            pendingVoices.removeAll()
            return
        }
        beginSession(preloaded: pendingVoices.removeFirst())
    }

    private func fail(_ failure: VoiceFnTapFailure) {
        isEnabled = false
        pendingVoices.removeAll()
        generation &+= 1
        cancelScheduledTasks()
        releaseFunctionKeyIfNeeded()
        logDrainTerminalIfNeeded(result: "failed", reason: failure.rawValue)
        resetSessionState()
        onFailure(failure)
        runIdleCompletions()
    }

    private func resetSessionState() {
        phase = .idle
        preRoll.removeAll(keepingCapacity: false)
        remoteEnded = false
        drainOperationID = nil
        drainStartedAtUptime = nil
        cancelScheduledTasks()
        releaseFunctionKeyIfNeeded()
    }

    private func cancelContinuation() {
        continuationGeneration &+= 1
        continuationTask?.cancel()
        continuationTask = nil
        continuationDeadline = nil
    }

    private func cancelScheduledTasks() {
        cancelContinuation()
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }

    @discardableResult
    private func releaseFunctionKeyIfNeeded() -> Bool {
        guard functionKeyIsPressed else { return false }
        let success = setFunctionKeyPressed(false)
        functionKeyIsPressed = !success
        return success
    }

    private func postImmediateFunctionKeyTap() -> Bool {
        let down = setFunctionKeyPressed(true)
        let up = setFunctionKeyPressed(false)
        return down && up
    }

    private func logDrainTerminalIfNeeded(result: String, reason: String) {
        guard let drainOperationID, drainStartedAtUptime != nil else { return }
        logger(
            "VOICE FN TAP drain operation_id=\(drainOperationID) " +
                "phase=completed result=\(result) reason=\(reason) " +
                "elapsed_ms=\(drainElapsedMilliseconds())"
        )
    }

    private func drainElapsedMilliseconds() -> Int {
        guard let drainStartedAtUptime else { return 0 }
        return max(0, Int((uptime() - drainStartedAtUptime) * 1_000))
    }

    private func appendPreRoll(_ samples: [Int16], toPendingVoice: Bool) {
        if toPendingVoice {
            guard let index = pendingVoices.indices.last else { return }
            pendingVoices[index].samples.append(contentsOf: samples)
            let count = pendingVoices[index].samples.count
            if count > maximumPreRollSampleCount {
                pendingVoices[index].samples.removeFirst(count - maximumPreRollSampleCount)
            }
            return
        }
        preRoll.append(contentsOf: samples)
        if preRoll.count > maximumPreRollSampleCount {
            preRoll.removeFirst(preRoll.count - maximumPreRollSampleCount)
        }
    }

    private func runIdleCompletions() {
        guard phase == .idle, !suppressAudioUntilRemoteStop else { return }
        let completions = idleCompletions
        idleCompletions.removeAll()
        completions.forEach { $0() }
    }
}
