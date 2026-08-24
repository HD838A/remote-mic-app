import Foundation

final class VoiceCommandHoldSessionController {
    typealias KeySetter = (Bool) -> Bool
    typealias AudioDrainer = (@escaping () -> Void) -> Void

    private let setKeyPressed: KeySetter
    private let drainAudio: AudioDrainer
    private let onFailure: (Bool) -> Void
    private var generation: UInt64 = 0
    private(set) var isEnabled = false
    private(set) var isHeld = false

    init(
        setKeyPressed: @escaping KeySetter,
        drainAudio: @escaping AudioDrainer,
        onFailure: @escaping (Bool) -> Void = { _ in }
    ) {
        self.setKeyPressed = setKeyPressed
        self.drainAudio = drainAudio
        self.onFailure = onFailure
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { cancelVoice() }
    }

    func startVoice() -> Bool {
        guard isEnabled else { return false }
        generation &+= 1
        guard !isHeld else { return true }
        guard setKeyPressed(true) else {
            onFailure(true)
            return false
        }
        isHeld = true
        return true
    }

    func stopVoice() -> Bool {
        guard isHeld else { return false }
        let sessionGeneration = generation
        drainAudio { [weak self] in
            guard let self, self.generation == sessionGeneration else { return }
            self.release()
        }
        return true
    }

    func cancelVoice() {
        generation &+= 1
        release()
    }

    func shutdown() {
        isEnabled = false
        cancelVoice()
    }

    private func release() {
        guard isHeld else { return }
        guard setKeyPressed(false) else {
            onFailure(false)
            return
        }
        isHeld = false
    }
}
