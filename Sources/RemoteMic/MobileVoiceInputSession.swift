import Foundation

final class MobileVoiceInputSession {
    private enum Mode {
        case functionKeyTap
        case functionKeyHold
    }

    typealias Scheduler = VoiceFnTapSessionController.Scheduler
    typealias FunctionKeySetter = (Bool) -> Bool
    typealias AudioEnqueuer = ([Int16]) -> Bool
    typealias AudioDrainer = (@escaping () -> Void) -> Void
    typealias DestinationReadiness = VoiceFnTapSessionController.DestinationReadiness

    private let setFunctionKeyPressed: FunctionKeySetter
    private let enqueueAudio: AudioEnqueuer
    private let drainAudio: AudioDrainer
    private let onTapFailure: (VoiceFnTapFailure) -> Void
    private let onAudioEnqueueFailure: () -> Void
    private lazy var tapSession = VoiceFnTapSessionController(
        schedule: schedule,
        destinationReadiness: destinationReadiness,
        setFunctionKeyPressed: setFunctionKeyPressed,
        enqueueAudio: { [weak self] samples in
            self?.enqueue(samples)
        },
        drainAudio: drainAudio,
        onFailure: onTapFailure
    )

    private let schedule: Scheduler
    private let destinationReadiness: DestinationReadiness
    private var tapModeEnabled: Bool
    private var activeMode: Mode?
    private var holdLatch = VoiceFunctionKeyLatch()

    init(
        tapModeEnabled: Bool,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        destinationReadiness: @escaping DestinationReadiness = { _ in .immediate },
        setFunctionKeyPressed: @escaping FunctionKeySetter,
        enqueueAudio: @escaping AudioEnqueuer,
        drainAudio: @escaping AudioDrainer,
        onTapFailure: @escaping (VoiceFnTapFailure) -> Void,
        onAudioEnqueueFailure: @escaping () -> Void = {}
    ) {
        self.tapModeEnabled = tapModeEnabled
        self.schedule = schedule
        self.destinationReadiness = destinationReadiness
        self.setFunctionKeyPressed = setFunctionKeyPressed
        self.enqueueAudio = enqueueAudio
        self.drainAudio = drainAudio
        self.onTapFailure = onTapFailure
        self.onAudioEnqueueFailure = onAudioEnqueueFailure
    }

    func setTapModeEnabled(_ enabled: Bool) {
        tapModeEnabled = enabled
    }

    @discardableResult
    func start() -> Bool {
        guard activeMode == nil else { return false }
        if tapModeEnabled {
            tapSession.setEnabled(true)
            guard tapSession.startVoice() else { return false }
            activeMode = .functionKeyTap
            return true
        }

        guard let transition = holdLatch.transition(streaming: true) else {
            return false
        }
        guard setFunctionKeyPressed(true) else {
            holdLatch.rollback(transition)
            return false
        }
        activeMode = .functionKeyHold
        return true
    }

    @discardableResult
    func receive(_ samples: [Int16]) -> Bool {
        switch activeMode {
        case .functionKeyTap:
            return tapSession.receive(samples)
        case .functionKeyHold:
            return enqueue(samples)
        case nil:
            return false
        }
    }

    @discardableResult
    func stop(completion: (() -> Void)? = nil) -> Bool {
        switch activeMode {
        case .functionKeyTap:
            return tapSession.stopVoice { [weak self] in
                self?.activeMode = nil
                completion?()
            }
        case .functionKeyHold:
            drainAudio { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.releaseHeldFunctionKey()
                self.activeMode = nil
                completion?()
            }
            return true
        case nil:
            completion?()
            return false
        }
    }

    func shutdown() {
        switch activeMode {
        case .functionKeyTap:
            tapSession.shutdown()
        case .functionKeyHold:
            releaseHeldFunctionKey()
        case nil:
            break
        }
        activeMode = nil
    }

    private func releaseHeldFunctionKey() {
        guard let transition = holdLatch.transition(streaming: false) else { return }
        guard setFunctionKeyPressed(false) else {
            holdLatch.rollback(transition)
            onTapFailure(.stopTapFailed)
            return
        }
    }

    @discardableResult
    private func enqueue(_ samples: [Int16]) -> Bool {
        let accepted = enqueueAudio(samples)
        if !accepted {
            onAudioEnqueueFailure()
        }
        return accepted
    }
}
