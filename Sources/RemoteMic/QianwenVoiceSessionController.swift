import Foundation

enum QianwenVoiceFocusPolicy {
    static func shouldFocusInput(
        modeEnabled: Bool,
        durationMilliseconds: Int
    ) -> Bool {
        modeEnabled && durationMilliseconds < HIDRemoteTiming.longPressMilliseconds
    }
}

final class QianwenVoiceSessionController {
    typealias MappingSetter = (_ rightCommand: Bool) -> Bool
    typealias AudioDrainer = (@escaping () -> Void) -> Void
    typealias Action = () -> Bool
    typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> Void

    private let setMapping: MappingSetter
    private let drainAudio: AudioDrainer
    private let releaseCommand: Action
    private let confirmVoice: Action
    private let schedule: Scheduler
    private var generation: UInt64 = 0
    private(set) var isEnabled = false

    init(
        setMapping: @escaping MappingSetter,
        drainAudio: @escaping AudioDrainer,
        releaseCommand: @escaping Action,
        confirmVoice: @escaping Action,
        schedule: @escaping Scheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.setMapping = setMapping
        self.drainAudio = drainAudio
        self.releaseCommand = releaseCommand
        self.confirmVoice = confirmVoice
        self.schedule = schedule
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { cancelVoice() }
    }

    func startVoice() -> Bool {
        guard isEnabled else { return false }
        generation &+= 1
        return true
    }

    func prepareDestinationIfNeeded(destinationIsReady: Bool) -> Bool {
        guard isEnabled, !destinationIsReady else { return false }
        generation &+= 1
        _ = setMapping(false)
        _ = releaseCommand()
        return true
    }

    @discardableResult
    func armHardwareMapping() -> Bool {
        guard isEnabled else { return false }
        return setMapping(true)
    }

    func stopVoice() -> Bool {
        guard isEnabled else { return false }
        let sessionGeneration = generation
        drainAudio { [weak self] in
            guard let self, self.generation == sessionGeneration else { return }
            self.finishVoice(generation: sessionGeneration)
        }
        return true
    }

    func cancelVoice() {
        generation &+= 1
        _ = releaseCommand()
    }

    func shutdown() {
        isEnabled = false
        cancelVoice()
    }

    private func finishVoice(generation sessionGeneration: UInt64) {
        guard setMapping(false) else { return }
        _ = releaseCommand()
        _ = confirmVoice()
        schedule(0.15) { [weak self] in
            guard let self,
                  self.isEnabled,
                  self.generation == sessionGeneration
            else { return }
            _ = self.setMapping(true)
        }
    }
}
