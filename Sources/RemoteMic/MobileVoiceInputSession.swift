import Foundation

final class MobileVoiceInputSession {
    private enum Mode {
        case functionKeyTap
        case heldVoiceKey
    }

    typealias Scheduler = VoiceFnTapSessionController.Scheduler
    typealias DestinationReadiness = VoiceFnTapSessionController.DestinationReadiness
    typealias KeyStateSetter = (Bool) -> Bool
    typealias AudioEnqueuer = ([Int16]) -> Bool
    typealias AudioDrainer = (@escaping () -> Void) -> Void

    private let setHeldVoiceKeyPressed: KeyStateSetter
    private let enqueueAudio: AudioEnqueuer
    private let drainAudio: AudioDrainer
    private let onTapFailure: (VoiceFnTapFailure) -> Void
    private var activeMode: Mode?
    private var tapStopCompletion: (() -> Void)?

    private lazy var tapSession = VoiceFnTapSessionController(
        schedule: schedule,
        destinationReadiness: destinationReadiness,
        setFunctionKeyPressed: setFunctionKeyPressed,
        enqueueAudio: { [weak self] samples in
            _ = self?.enqueueAudio(samples)
        },
        drainAudio: drainAudio,
        onFailure: { [weak self] failure in
            guard let self else { return }
            self.activeMode = nil
            self.onTapFailure(failure)
            self.completePendingTapStop()
        }
    )

    private let schedule: Scheduler
    private let destinationReadiness: DestinationReadiness
    private let setFunctionKeyPressed: KeyStateSetter

    init(
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        destinationReadiness: @escaping DestinationReadiness = { _ in .immediate },
        setFunctionKeyPressed: @escaping KeyStateSetter,
        setHeldVoiceKeyPressed: @escaping KeyStateSetter,
        enqueueAudio: @escaping AudioEnqueuer,
        drainAudio: @escaping AudioDrainer,
        onTapFailure: @escaping (VoiceFnTapFailure) -> Void
    ) {
        self.schedule = schedule
        self.destinationReadiness = destinationReadiness
        self.setFunctionKeyPressed = setFunctionKeyPressed
        self.setHeldVoiceKeyPressed = setHeldVoiceKeyPressed
        self.enqueueAudio = enqueueAudio
        self.drainAudio = drainAudio
        self.onTapFailure = onTapFailure
    }

    var usesFnTapForActiveSession: Bool {
        activeMode == .functionKeyTap
    }

    @discardableResult
    func start(useFnTap: Bool) -> Bool {
        guard activeMode == nil else { return false }
        if useFnTap {
            tapSession.setEnabled(true)
            guard tapSession.startVoice() else { return false }
            activeMode = .functionKeyTap
            return true
        }

        guard setHeldVoiceKeyPressed(true) else { return false }
        activeMode = .heldVoiceKey
        return true
    }

    @discardableResult
    func receive(_ samples: [Int16]) -> Bool {
        switch activeMode {
        case .functionKeyTap:
            return tapSession.receive(samples)
        case .heldVoiceKey:
            return enqueueAudio(samples)
        case nil:
            return false
        }
    }

    @discardableResult
    func stop(completion: @escaping () -> Void) -> Bool {
        switch activeMode {
        case .functionKeyTap:
            tapStopCompletion = completion
            return tapSession.stopVoice { [weak self] in
                self?.finishTapStop()
            }
        case .heldVoiceKey:
            drainAudio { [weak self] in
                guard let self else { return }
                _ = self.setHeldVoiceKeyPressed(false)
                self.activeMode = nil
                completion()
            }
            return true
        case nil:
            completion()
            return false
        }
    }

    func shutdown() {
        tapStopCompletion = nil
        switch activeMode {
        case .functionKeyTap:
            tapSession.shutdown()
        case .heldVoiceKey:
            _ = setHeldVoiceKeyPressed(false)
        case nil:
            break
        }
        activeMode = nil
    }

    private func finishTapStop() {
        guard tapSession.isEnabled else { return }
        activeMode = nil
        completePendingTapStop()
    }

    private func completePendingTapStop() {
        activeMode = nil
        let completion = tapStopCompletion
        tapStopCompletion = nil
        completion?()
    }
}
