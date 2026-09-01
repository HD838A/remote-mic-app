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

enum VoiceFnTapTerminationReason: String, Equatable {
    case modeDisabled = "mode_disabled"
    case modeChanged = "mode_changed"
    case permissionRevoked = "permission_revoked"
    case bluetoothNotReady = "bluetooth_not_ready"
    case appShutdown = "app_shutdown"
    case priorSessionFailed = "prior_session_failed"
}

final class VoiceFnTapSessionController {
    static let defaultDictationLeadInSampleCount = 4_000

    enum TapPattern: Equatable {
        case function
        case macOSDictation

        fileprivate var tapCount: Int {
            switch self {
            case .function: return 1
            case .macOSDictation: return 2
            }
        }
    }

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
        let sessionIdentity: UInt64
        let tapPattern: TapPattern
        let operationID: UInt64?
        var samples: [Int16] = []
        var ended = false
    }

    private struct PendingTermination {
        let sessionIdentity: UInt64
        let reason: VoiceFnTapTerminationReason
        let tapPattern: TapPattern
        let operationID: UInt64?
    }

    private let startDelay: TimeInterval
    private let tapDuration: TimeInterval
    private let controlTapDuration: TimeInterval
    private let interTapDelay: TimeInterval
    private let dictationLeadInSampleCount: Int
    private let maximumPreRollSampleCount: Int
    private let schedule: Scheduler
    private let destinationReadiness: DestinationReadiness
    private let setFunctionKeyPressed: FunctionKeySetter
    private let setControlKeyPressed: FunctionKeySetter
    private let enqueueAudio: AudioEnqueuer
    private let drainAudio: AudioDrainer
    private let onFailure: (VoiceFnTapFailure, UInt64?) -> Void
    private let onCancellation: (VoiceInputDestinationCancellation, UInt64?) -> Void
    private let onCompletion: (TapPattern, UInt64?) -> Void
    private let onTermination: (VoiceFnTapTerminationReason, TapPattern, UInt64?) -> Void

    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    private(set) var isSuspended = false
    private var generation: UInt64 = 0
    private var sessionIdentitySequence: UInt64 = 0
    private var preRoll: [Int16] = []
    private var remoteEnded = false
    private var pendingVoice: PendingVoice?
    private var scheduledTasks: [VoiceFnTapScheduledTask] = []
    private var activeSessionIdentity: UInt64?
    private var activeTapPattern: TapPattern?
    private var activeOperationID: UInt64?
    private var pressedTapPattern: TapPattern?
    private var tapKeyIsPressed = false
    private var completedTapCount = 0
    private var targetTapCount = 0
    private var pendingCleanupTapPattern: TapPattern?
    private var pendingCleanupTapCount = 0
    private var pendingCleanupOperationID: UInt64?
    private var pendingCleanupNeedsFreshDictationPairOnFailure = false
    private var scheduledCleanupTask: VoiceFnTapScheduledTask?
    private var idleCompletions: [() -> Void] = []
    private var pendingTerminations: [PendingTermination] = []
    private var suppressAudioUntilRemoteStop = false
    private var completionEligible = false

    var requiresCleanupBeforeMapping: Bool {
        phase != .idle ||
            tapKeyIsPressed ||
            pendingCleanupTapCount > 0 ||
            suppressAudioUntilRemoteStop
    }

    var hasCleanupBlockingNewVoice: Bool {
        phase == .idle && (
            tapKeyIsPressed ||
                pendingCleanupTapCount > 0 ||
                suppressAudioUntilRemoteStop
        )
    }

    init(
        startDelay: TimeInterval = 0.15,
        tapDuration: TimeInterval = 0.12,
        controlTapDuration: TimeInterval = 0.06,
        interTapDelay: TimeInterval = 0.08,
        dictationLeadInSampleCount: Int = VoiceFnTapSessionController
            .defaultDictationLeadInSampleCount,
        maximumPreRollSampleCount: Int = 80_000,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        destinationReadiness: @escaping DestinationReadiness = { _ in .immediate },
        setFunctionKeyPressed: @escaping FunctionKeySetter,
        setControlKeyPressed: @escaping FunctionKeySetter = { _ in false },
        enqueueAudio: @escaping AudioEnqueuer,
        drainAudio: @escaping AudioDrainer,
        onFailure: @escaping (VoiceFnTapFailure, UInt64?) -> Void,
        onCancellation: @escaping (VoiceInputDestinationCancellation, UInt64?) -> Void = { _, _ in },
        onCompletion: @escaping (TapPattern, UInt64?) -> Void = { _, _ in },
        onTermination: @escaping (
            VoiceFnTapTerminationReason,
            TapPattern,
            UInt64?
        ) -> Void = { _, _, _ in }
    ) {
        self.startDelay = startDelay
        self.tapDuration = tapDuration
        self.controlTapDuration = controlTapDuration
        self.interTapDelay = interTapDelay
        self.dictationLeadInSampleCount = max(0, dictationLeadInSampleCount)
        self.maximumPreRollSampleCount = maximumPreRollSampleCount
        self.schedule = schedule
        self.destinationReadiness = destinationReadiness
        self.setFunctionKeyPressed = setFunctionKeyPressed
        self.setControlKeyPressed = setControlKeyPressed
        self.enqueueAudio = enqueueAudio
        self.drainAudio = drainAudio
        self.onFailure = onFailure
        self.onCancellation = onCancellation
        self.onCompletion = onCompletion
        self.onTermination = onTermination
    }

    func setEnabled(
        _ enabled: Bool,
        reason: VoiceFnTapTerminationReason = .modeDisabled,
        completion: (() -> Void)? = nil
    ) {
        if !enabled {
            queuePendingTerminations(reason: reason)
        }
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

    func suspend(
        reason: VoiceFnTapTerminationReason = .bluetoothNotReady,
        completion: (() -> Void)? = nil
    ) {
        queuePendingTerminations(reason: reason)
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
    func startVoice(
        pattern: TapPattern = .function,
        operationID: UInt64? = nil
    ) -> Bool {
        guard isEnabled, !isSuspended, !hasCleanupBlockingNewVoice else { return false }
        switch phase {
        case .idle:
            beginSession(
                identity: makeSessionIdentity(),
                pattern: pattern,
                operationID: operationID
            )
            return isEnabled && phase != .idle
        case .draining, .stopping:
            guard pendingVoice == nil else { return false }
            pendingVoice = PendingVoice(
                sessionIdentity: makeSessionIdentity(),
                tapPattern: pattern,
                operationID: operationID
            )
        case .starting where remoteEnded:
            guard pendingVoice == nil else { return false }
            pendingVoice = PendingVoice(
                sessionIdentity: makeSessionIdentity(),
                tapPattern: pattern,
                operationID: operationID
            )
        case .starting, .active:
            return false
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

    func shutdown(reason: VoiceFnTapTerminationReason = .appShutdown) {
        queuePendingTerminations(reason: reason)
        isEnabled = false
        isSuspended = true
        pendingVoice = nil
        suppressAudioUntilRemoteStop = false
        let interruptedPhase = phase
        let interruptedSessionIdentity = activeSessionIdentity
        let interruptedPattern = activeTapPattern
        let interruptedOperationID = activeOperationID ?? pendingCleanupOperationID
        let completedBeforeRelease = completedTapCount
        let hadPressedKey = tapKeyIsPressed
        generation &+= 1
        cancelScheduledTasks()
        if let interruptedPattern {
            switch interruptedPhase {
            case .active, .draining:
                queueCleanupTaps(
                    count: interruptedPattern.tapCount,
                    pattern: interruptedPattern,
                    operationID: interruptedOperationID
                )
            case .stopping:
                queueCleanupTaps(
                    count: max(0, interruptedPattern.tapCount - completedBeforeRelease),
                    pattern: interruptedPattern,
                    operationID: interruptedOperationID,
                    needsFreshDictationPairOnFailure:
                        interruptedPattern == .macOSDictation &&
                        (completedBeforeRelease > 0 || hadPressedKey)
                )
            case .starting:
                if targetTapCount > 0,
                   (completedBeforeRelease > 0 || hadPressedKey) {
                    if interruptedPattern == .macOSDictation,
                       completedBeforeRelease == 0 {
                        queueCleanupTaps(
                            count: hadPressedKey ? 1 : 0,
                            pattern: interruptedPattern,
                            operationID: interruptedOperationID
                        )
                    } else if interruptedPattern == .macOSDictation,
                              completedBeforeRelease == 1,
                              !hadPressedKey {
                        break
                    } else {
                        queueCleanupTaps(
                            count: max(0, interruptedPattern.tapCount - completedBeforeRelease) +
                                interruptedPattern.tapCount,
                            pattern: interruptedPattern,
                            operationID: interruptedOperationID
                        )
                    }
                }
            case .idle:
                break
            }
        }
        resetSessionState()
        retryIdleCleanupIfNeeded(forceSynchronous: true)
        if tapKeyIsPressed || pendingCleanupTapCount > 0 {
            discardPendingTermination(
                sessionIdentity: interruptedSessionIdentity
            )
            onFailure(
                .stopTapFailed,
                interruptedOperationID ?? pendingCleanupOperationID
            )
            reportPendingTerminations()
        }
        runIdleCompletions()
    }

    private func makeSessionIdentity() -> UInt64 {
        sessionIdentitySequence &+= 1
        return sessionIdentitySequence
    }

    private func beginSession(
        identity: UInt64,
        pattern: TapPattern,
        operationID: UInt64?,
        preloaded: PendingVoice? = nil
    ) {
        generation &+= 1
        let sessionGeneration = generation
        phase = .starting(sessionGeneration)
        activeSessionIdentity = identity
        activeTapPattern = pattern
        activeOperationID = operationID
        completionEligible = true
        preRoll = preloaded?.samples ?? []
        remoteEnded = preloaded?.ended ?? false
        switch destinationReadiness({ [weak self] result in
            self?.destinationReadinessCompleted(result, generation: sessionGeneration)
        }) {
        case .immediate:
            scheduleStartTap(
                generation: sessionGeneration,
                after: startDelay(for: pattern)
            )
        case let .cancelled(reason):
            cancelSessionAwaitingDestination(reason, generation: sessionGeneration)
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
        case let .cancelled(reason):
            cancelSessionAwaitingDestination(reason, generation: sessionGeneration)
        }
    }

    private func scheduleStartTap(generation sessionGeneration: UInt64, after delay: TimeInterval) {
        if delay <= 0 {
            beginStartTap(generation: sessionGeneration)
            return
        }
        let task = schedule(delay) { [weak self] in
            self?.beginStartTap(generation: sessionGeneration)
        }
        scheduledTasks.append(task)
    }

    private func cancelSessionAwaitingDestination(
        _ reason: VoiceInputDestinationCancellation,
        generation sessionGeneration: UInt64
    ) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        let cancelledSessionIdentity = activeSessionIdentity
        let cancelledOperationID = activeOperationID
        let cancelledPendingVoice = pendingVoice
        let shouldSuppressAudioUntilRemoteStop = !remoteEnded
        pendingVoice = nil
        generation &+= 1
        resetSessionState()
        suppressAudioUntilRemoteStop = shouldSuppressAudioUntilRemoteStop
        discardPendingTermination(
            sessionIdentity: cancelledSessionIdentity
        )
        if let cancelledPendingVoice {
            discardPendingTermination(
                sessionIdentity: cancelledPendingVoice.sessionIdentity
            )
        }
        onCancellation(reason, cancelledOperationID)
        if let cancelledPendingVoice,
           cancelledPendingVoice.operationID == nil ||
           cancelledPendingVoice.operationID != cancelledOperationID {
            onCancellation(reason, cancelledPendingVoice.operationID)
        }
        runIdleCompletions()
    }

    private func beginStartTap(generation sessionGeneration: UInt64) {
        guard phase == .starting(sessionGeneration),
              generation == sessionGeneration,
              let activeTapPattern
        else { return }
        performTapSequence(
            pattern: activeTapPattern,
            generation: sessionGeneration
        ) { [weak self] success in
            guard let self,
                  self.phase == .starting(sessionGeneration),
                  self.generation == sessionGeneration
            else { return }
            guard success else {
                self.fail(.startTapFailed)
                return
            }
            self.phase = .active(sessionGeneration)
            if activeTapPattern == .macOSDictation,
               self.dictationLeadInSampleCount > 0 {
                var openingAudio = [Int16](
                    repeating: 0,
                    count: self.dictationLeadInSampleCount
                )
                openingAudio.append(contentsOf: self.preRoll)
                self.enqueueAudio(openingAudio)
                self.preRoll.removeAll(keepingCapacity: false)
            } else if !self.preRoll.isEmpty {
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
        guard phase == .draining(sessionGeneration),
              generation == sessionGeneration,
              let activeTapPattern
        else { return }
        phase = .stopping(sessionGeneration)
        performTapSequence(
            pattern: activeTapPattern,
            generation: sessionGeneration
        ) { [weak self] success in
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

    private func performTapSequence(
        pattern: TapPattern,
        generation sessionGeneration: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == sessionGeneration else { return }
        completedTapCount = 0
        targetTapCount = pattern.tapCount
        performNextTap(
            pattern: pattern,
            generation: sessionGeneration,
            completion: completion
        )
    }

    private func performNextTap(
        pattern: TapPattern,
        generation sessionGeneration: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == sessionGeneration else { return }
        guard setTapKeyPressed(true, pattern: pattern) else {
            completion(false)
            return
        }
        tapKeyIsPressed = true
        pressedTapPattern = pattern
        let task = schedule(tapDuration(for: pattern)) { [weak self] in
            guard let self, self.generation == sessionGeneration else { return }
            let success = self.setTapKeyPressed(false, pattern: pattern)
            self.tapKeyIsPressed = !success
            self.pressedTapPattern = success ? nil : pattern
            guard success else {
                completion(false)
                return
            }
            self.completedTapCount += 1
            guard self.completedTapCount < self.targetTapCount else {
                self.completedTapCount = 0
                self.targetTapCount = 0
                completion(true)
                return
            }
            let nextTask = self.schedule(self.interTapDelay) { [weak self] in
                self?.performNextTap(
                    pattern: pattern,
                    generation: sessionGeneration,
                    completion: completion
                )
            }
            self.scheduledTasks.append(nextTask)
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
        completionEligible = false
        pendingVoice = nil
        if remoteHasEnded {
            suppressAudioUntilRemoteStop = false
        } else {
            suppressAudioUntilRemoteStop =
                suppressAudioUntilRemoteStop || suppressUntilRemoteStop
        }
        switch phase {
        case .idle:
            retryIdleCleanupIfNeeded()
            runIdleCompletions()
        case .starting:
            if activeTapPattern == .macOSDictation, targetTapCount > 0 {
                // Once an opening Control sequence has begun, let it finish.
                // Cancelling after only one Control tap would make the next
                // physical press part of an unrelated system double-tap.
                remoteEnded = true
            } else {
                let interruptedSessionIdentity = activeSessionIdentity
                let interruptedPattern = activeTapPattern
                let interruptedOperationID = activeOperationID
                let completedBeforeRelease = completedTapCount
                let hadPressedKey = tapKeyIsPressed
                generation &+= 1
                cancelScheduledTasks()
                if let interruptedPattern,
                   targetTapCount > 0,
                   (completedBeforeRelease > 0 || hadPressedKey) {
                    queueCleanupTaps(
                        count: max(0, interruptedPattern.tapCount - completedBeforeRelease) +
                            interruptedPattern.tapCount,
                        pattern: interruptedPattern,
                        operationID: interruptedOperationID
                    )
                }
                resetSessionState()
                retryIdleCleanupIfNeeded()
                if tapKeyIsPressed || pendingCleanupTapCount > 0 {
                    discardPendingTermination(
                        sessionIdentity: interruptedSessionIdentity
                    )
                    onFailure(
                        .stopTapFailed,
                        interruptedOperationID ?? pendingCleanupOperationID
                    )
                    retryIdleCleanupIfNeeded()
                }
                runIdleCompletions()
            }
        case let .active(sessionGeneration):
            remoteEnded = remoteHasEnded
            beginDrain(generation: sessionGeneration)
        case .draining, .stopping:
            remoteEnded = remoteHasEnded
        }
    }

    private func finishSession() {
        let completedSessionIdentity = activeSessionIdentity
        let completedPattern = activeTapPattern
        let completedOperationID = activeOperationID
        let shouldReportCompletion = completionEligible
        resetSessionState()
        if shouldReportCompletion, let completedPattern {
            discardPendingTermination(
                sessionIdentity: completedSessionIdentity
            )
            onCompletion(completedPattern, completedOperationID)
        }
        runIdleCompletions()
        guard isEnabled, !isSuspended, let pendingVoice else {
            self.pendingVoice = nil
            return
        }
        self.pendingVoice = nil
        beginSession(
            identity: pendingVoice.sessionIdentity,
            pattern: pendingVoice.tapPattern,
            operationID: pendingVoice.operationID,
            preloaded: pendingVoice
        )
    }

    private func fail(_ failure: VoiceFnTapFailure) {
        let interruptedPhase = phase
        let interruptedSessionIdentity = activeSessionIdentity
        let interruptedPattern = activeTapPattern
        let interruptedOperationID = activeOperationID
        let interruptedPendingVoice = pendingVoice
        let completedBeforeRelease = completedTapCount
        let hadPressedKey = tapKeyIsPressed
        isEnabled = false
        pendingVoice = nil
        suppressAudioUntilRemoteStop = false
        generation &+= 1
        cancelScheduledTasks()
        if let interruptedPattern {
            switch interruptedPhase {
            case .starting where targetTapCount > 0 && hadPressedKey:
                if interruptedPattern == .macOSDictation,
                   completedBeforeRelease == 0 {
                    // A failed release on the first Control press leaves the
                    // opener off. Release that key only; replaying three taps
                    // after the double-tap window could turn Dictation on.
                    queueCleanupTaps(
                        count: 1,
                        pattern: interruptedPattern,
                        operationID: interruptedOperationID
                    )
                } else {
                    queueCleanupTaps(
                        count: max(0, interruptedPattern.tapCount - completedBeforeRelease) +
                            interruptedPattern.tapCount,
                        pattern: interruptedPattern,
                        operationID: interruptedOperationID
                    )
                }
            case .stopping:
                queueCleanupTaps(
                    count: max(0, interruptedPattern.tapCount - completedBeforeRelease),
                    pattern: interruptedPattern,
                    operationID: interruptedOperationID,
                    needsFreshDictationPairOnFailure:
                        interruptedPattern == .macOSDictation &&
                        (completedBeforeRelease > 0 || hadPressedKey)
                )
            case .idle, .starting, .active, .draining:
                break
            }
        }
        resetSessionState()
        discardPendingTermination(
            sessionIdentity: interruptedSessionIdentity
        )
        queuePriorSessionFailureTermination(
            pendingVoice: interruptedPendingVoice,
            failedSessionIdentity: interruptedSessionIdentity
        )
        onFailure(failure, interruptedOperationID)
        runIdleCompletions()
    }

    private func resetSessionState() {
        phase = .idle
        preRoll.removeAll(keepingCapacity: false)
        remoteEnded = false
        cancelScheduledTasks()
        releaseTapKeyIfNeeded()
        activeSessionIdentity = nil
        activeTapPattern = nil
        activeOperationID = nil
        completedTapCount = 0
        targetTapCount = 0
        completionEligible = false
    }

    private func cancelScheduledTasks() {
        scheduledCleanupTask?.cancel()
        scheduledCleanupTask = nil
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }

    @discardableResult
    private func releaseTapKeyIfNeeded() -> Bool {
        guard tapKeyIsPressed, let pressedTapPattern else { return false }
        let success = setTapKeyPressed(false, pattern: pressedTapPattern)
        tapKeyIsPressed = !success
        self.pressedTapPattern = success ? nil : pressedTapPattern
        if success,
           pendingCleanupTapPattern == pressedTapPattern,
           pendingCleanupTapCount > 0 {
            pendingCleanupTapCount -= 1
            if pendingCleanupTapCount == 0 {
                pendingCleanupTapPattern = nil
                pendingCleanupOperationID = nil
                pendingCleanupNeedsFreshDictationPairOnFailure = false
            } else if pressedTapPattern == .macOSDictation {
                // A Dictation tap just completed. Preserve the normal gap
                // before the next tap, and restart with a fresh pair if that
                // next down cannot be posted.
                pendingCleanupNeedsFreshDictationPairOnFailure = true
            }
        }
        return success
    }

    private func queueCleanupTaps(
        count: Int,
        pattern: TapPattern,
        operationID: UInt64? = nil,
        needsFreshDictationPairOnFailure: Bool = false
    ) {
        guard count > 0 else { return }
        if pendingCleanupTapCount > 0 {
            guard pendingCleanupTapPattern == pattern else { return }
            pendingCleanupTapCount = max(pendingCleanupTapCount, count)
            pendingCleanupOperationID = pendingCleanupOperationID ?? operationID
            pendingCleanupNeedsFreshDictationPairOnFailure =
                pendingCleanupNeedsFreshDictationPairOnFailure ||
                needsFreshDictationPairOnFailure
            return
        }
        pendingCleanupTapPattern = pattern
        pendingCleanupTapCount = count
        pendingCleanupOperationID = operationID
        pendingCleanupNeedsFreshDictationPairOnFailure =
            needsFreshDictationPairOnFailure
    }

    private func retryIdleCleanupIfNeeded(forceSynchronous: Bool = false) {
        if forceSynchronous {
            scheduledCleanupTask?.cancel()
            scheduledCleanupTask = nil
        } else if scheduledCleanupTask != nil {
            return
        }
        if tapKeyIsPressed, !releaseTapKeyIfNeeded() {
            return
        }
        guard pendingCleanupTapCount > 0,
              let pendingCleanupTapPattern
        else {
            runIdleCompletions()
            return
        }
        if pendingCleanupTapPattern == .macOSDictation,
           !forceSynchronous {
            scheduleDictationCleanupDown(
                after: pendingCleanupNeedsFreshDictationPairOnFailure
                    ? interTapDelay
                    : 0
            )
            return
        }
        while pendingCleanupTapCount > 0 {
            guard setTapKeyPressed(true, pattern: pendingCleanupTapPattern) else {
                replacePartialDictationCleanupWithFreshPairIfNeeded()
                return
            }
            tapKeyIsPressed = true
            pressedTapPattern = pendingCleanupTapPattern
            guard releaseTapKeyIfNeeded() else { return }
        }
    }

    private func scheduleDictationCleanupDown(after delay: TimeInterval) {
        let cleanupGeneration = generation
        scheduledCleanupTask = schedule(delay) { [weak self] in
            guard let self else { return }
            self.scheduledCleanupTask = nil
            guard self.generation == cleanupGeneration,
                  self.phase == .idle,
                  self.pendingCleanupTapPattern == .macOSDictation,
                  self.pendingCleanupTapCount > 0
            else { return }
            guard self.setTapKeyPressed(true, pattern: .macOSDictation) else {
                self.replacePartialDictationCleanupWithFreshPairIfNeeded()
                return
            }
            self.tapKeyIsPressed = true
            self.pressedTapPattern = .macOSDictation
            self.scheduleDictationCleanupRelease(generation: cleanupGeneration)
        }
    }

    private func scheduleDictationCleanupRelease(generation cleanupGeneration: UInt64) {
        scheduledCleanupTask = schedule(controlTapDuration) { [weak self] in
            guard let self else { return }
            self.scheduledCleanupTask = nil
            guard self.generation == cleanupGeneration,
                  self.phase == .idle,
                  self.tapKeyIsPressed,
                  self.pressedTapPattern == .macOSDictation
            else { return }
            guard self.releaseTapKeyIfNeeded() else { return }
            self.retryIdleCleanupIfNeeded()
        }
    }

    private func replacePartialDictationCleanupWithFreshPairIfNeeded() {
        guard pendingCleanupNeedsFreshDictationPairOnFailure,
              pendingCleanupTapPattern == .macOSDictation
        else { return }
        pendingCleanupTapCount = TapPattern.macOSDictation.tapCount
        pendingCleanupNeedsFreshDictationPairOnFailure = false
    }

    private func setTapKeyPressed(_ isPressed: Bool, pattern: TapPattern) -> Bool {
        switch pattern {
        case .function:
            return setFunctionKeyPressed(isPressed)
        case .macOSDictation:
            return setControlKeyPressed(isPressed)
        }
    }

    private func startDelay(for pattern: TapPattern) -> TimeInterval {
        switch pattern {
        case .function: return startDelay
        case .macOSDictation: return 0
        }
    }

    private func tapDuration(for pattern: TapPattern) -> TimeInterval {
        switch pattern {
        case .function: return tapDuration
        case .macOSDictation: return controlTapDuration
        }
    }

    private func queuePendingTerminations(reason: VoiceFnTapTerminationReason) {
        if phase != .idle,
           let activeSessionIdentity,
           let activeTapPattern {
            appendPendingTermination(
                sessionIdentity: activeSessionIdentity,
                reason: reason,
                pattern: activeTapPattern,
                operationID: activeOperationID
            )
        }
        if let pendingVoice {
            appendPendingTermination(
                sessionIdentity: pendingVoice.sessionIdentity,
                reason: reason,
                pattern: pendingVoice.tapPattern,
                operationID: pendingVoice.operationID
            )
        }
    }

    private func appendPendingTermination(
        sessionIdentity: UInt64,
        reason: VoiceFnTapTerminationReason,
        pattern: TapPattern,
        operationID: UInt64?
    ) {
        if pendingTerminations.contains(where: {
            $0.sessionIdentity == sessionIdentity
        }) {
            return
        }
        pendingTerminations.append(PendingTermination(
            sessionIdentity: sessionIdentity,
            reason: reason,
            tapPattern: pattern,
            operationID: operationID
        ))
    }

    private func queuePriorSessionFailureTermination(
        pendingVoice: PendingVoice?,
        failedSessionIdentity: UInt64?
    ) {
        guard let pendingVoice,
              pendingVoice.sessionIdentity != failedSessionIdentity
        else { return }
        appendPendingTermination(
            sessionIdentity: pendingVoice.sessionIdentity,
            reason: .priorSessionFailed,
            pattern: pendingVoice.tapPattern,
            operationID: pendingVoice.operationID
        )
    }

    private func discardPendingTermination(
        sessionIdentity: UInt64?
    ) {
        if let sessionIdentity,
           let index = pendingTerminations.firstIndex(where: {
               $0.sessionIdentity == sessionIdentity
           }) {
            pendingTerminations.remove(at: index)
        }
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

    private func reportPendingTerminations() {
        let terminations = pendingTerminations
        pendingTerminations.removeAll()
        terminations.forEach {
            onTermination($0.reason, $0.tapPattern, $0.operationID)
        }
    }

    private func runIdleCompletions() {
        guard phase == .idle,
              !tapKeyIsPressed,
              pendingCleanupTapCount == 0,
              !suppressAudioUntilRemoteStop
        else { return }
        let completions = idleCompletions
        idleCompletions.removeAll()
        reportPendingTerminations()
        completions.forEach { $0() }
    }
}
