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
    typealias AudioDrainer = (@escaping () -> Void) -> Void
    typealias DestinationReadiness = (
        @escaping (VoiceInputDestinationWaitResult) -> Void
    ) -> VoiceInputDestinationWait

    private struct PendingVoice {
        var samples: [Int16] = []
        var ended = false
    }

    private let startDelay: TimeInterval
    private let tapDuration: TimeInterval
    private let maximumPreRollSampleCount: Int
    private let schedule: Scheduler
    private let destinationReadiness: DestinationReadiness
    private let setFunctionKeyPressed: FunctionKeySetter
    private let enqueueAudio: AudioEnqueuer
    private let drainAudio: AudioDrainer
    private let onFailure: (VoiceFnTapFailure) -> Void

    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    private(set) var isSuspended = false
    private var generation: UInt64 = 0
    private var preRoll: [Int16] = []
    private var remoteEnded = false
    private var pendingVoice: PendingVoice?
    private var scheduledTasks: [VoiceFnTapScheduledTask] = []
    private var functionKeyIsPressed = false
    private var idleCompletions: [() -> Void] = []
    private var suppressAudioUntilRemoteStop = false

    var requiresCleanupBeforeMapping: Bool {
        phase != .idle || functionKeyIsPressed || suppressAudioUntilRemoteStop
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
        onFailure: @escaping (VoiceFnTapFailure) -> Void
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
    }

    func setEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        isEnabled = enabled
        if enabled {
            completion?()
            return
        }
        let hasSession = phase != .idle
        terminateCurrentSession(
            remoteHasEnded: remoteEnded,
            suppressUntilRemoteStop: hasSession && !remoteEnded,
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
        switch phase {
        case .idle:
            beginSession()
        case .draining, .stopping:
            if pendingVoice == nil {
                pendingVoice = PendingVoice()
            }
        case .starting, .active:
            break
        }
        return true
    }

    @discardableResult
    func receive(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else {
            return phase != .idle || pendingVoice != nil || suppressAudioUntilRemoteStop
        }
        if pendingVoice != nil {
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
    func stopVoice() -> Bool {
        suppressAudioUntilRemoteStop = false
        if pendingVoice != nil {
            pendingVoice?.ended = true
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

    func shutdown() {
        isEnabled = false
        isSuspended = true
        pendingVoice = nil
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
        resetSessionState()
        runIdleCompletions()
    }

    private func beginSession(preloaded: PendingVoice? = nil) {
        generation &+= 1
        let sessionGeneration = generation
        phase = .starting(sessionGeneration)
        preRoll = preloaded?.samples ?? []
        remoteEnded = preloaded?.ended ?? false
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
        let shouldSuppressAudioUntilRemoteStop = !remoteEnded
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
        drainAudio { [weak self] in
            self?.beginStopTap(generation: sessionGeneration)
        }
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
        pendingVoice = nil
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

    private func finishSession() {
        resetSessionState()
        runIdleCompletions()
        guard isEnabled, !isSuspended, let pendingVoice else {
            self.pendingVoice = nil
            return
        }
        self.pendingVoice = nil
        beginSession(preloaded: pendingVoice)
    }

    private func fail(_ failure: VoiceFnTapFailure) {
        isEnabled = false
        pendingVoice = nil
        generation &+= 1
        cancelScheduledTasks()
        releaseFunctionKeyIfNeeded()
        resetSessionState()
        runIdleCompletions()
        onFailure(failure)
    }

    private func resetSessionState() {
        phase = .idle
        preRoll.removeAll(keepingCapacity: false)
        remoteEnded = false
        cancelScheduledTasks()
        releaseFunctionKeyIfNeeded()
    }

    private func cancelScheduledTasks() {
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

    private func appendPreRoll(_ samples: [Int16], toPendingVoice: Bool) {
        if toPendingVoice {
            pendingVoice?.samples.append(contentsOf: samples)
            if let count = pendingVoice?.samples.count, count > maximumPreRollSampleCount {
                pendingVoice?.samples.removeFirst(count - maximumPreRollSampleCount)
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
