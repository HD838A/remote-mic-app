import Foundation

struct VoiceKeyDefaultInputBorrow: Equatable {
    let originalUID: String
    let targetUID: String
    let sessionID: UUID
    let switchedAt: Date
}

enum VoiceKeyDefaultInputDecision: Equatable {
    case noChange
    case switchInput(fromUID: String, toUID: String)
    case restoreInput(fromUID: String, toUID: String)
    case clearWithoutRestore
}

enum VoiceKeyDefaultInputPolicy {
    static func resolveTargetDeviceUID(
        selectedAudioDeviceUID: String,
        availableInputs: [AudioDeviceInfo]
    ) -> String? {
        if !selectedAudioDeviceUID.isEmpty,
           availableInputs.contains(where: { $0.uid == selectedAudioDeviceUID }) {
            return selectedAudioDeviceUID
        }
        let fallbackVirtual = availableInputs.first {
            switch VirtualAudioDeviceDiagnosticKind.classify($0) {
            case .miRemoteV2ch, .blackHole2ch: return true
            case .other, .unavailable: return false
            }
        }
        return fallbackVirtual?.uid
    }

    static func evaluateBorrow(
        isEnabled: Bool,
        currentDefaultUID: String?,
        targetUID: String?,
        activeBorrow: VoiceKeyDefaultInputBorrow?
    ) -> VoiceKeyDefaultInputDecision {
        guard isEnabled,
              let targetUID, !targetUID.isEmpty,
              let currentDefaultUID, !currentDefaultUID.isEmpty
        else { return .noChange }

        if activeBorrow != nil {
            return .noChange
        }

        if currentDefaultUID == targetUID {
            return .noChange
        }

        return .switchInput(fromUID: currentDefaultUID, toUID: targetUID)
    }

    static func evaluateRestore(
        activeBorrow: VoiceKeyDefaultInputBorrow?,
        currentDefaultUID: String?
    ) -> VoiceKeyDefaultInputDecision {
        guard let borrow = activeBorrow else { return .noChange }

        if currentDefaultUID == borrow.targetUID {
            return .restoreInput(fromUID: borrow.targetUID, toUID: borrow.originalUID)
        }

        return .clearWithoutRestore
    }
}

final class VoiceKeyDefaultInputCoordinator {
    private let isEnabled: () -> Bool
    private let selectedAudioDeviceUID: () -> String
    private let defaultInputDevice: () -> AudioDeviceInfo?
    private let availableInputDevices: () -> [AudioDeviceInfo]
    private let setDefaultInputDevice: (AudioDeviceInfo) -> OSStatus
    private let log: (String) -> Void
    private let mainQueueAsyncAfter: (TimeInterval, @escaping () -> Void) -> Void

    private(set) var activeBorrow: VoiceKeyDefaultInputBorrow?
    private var pendingRestoreGeneration: UInt64 = 0
    private var restoreWorkItem: DispatchWorkItem?

    static let defaultTailGracePeriod: TimeInterval = 0.35

    init(
        isEnabled: @escaping () -> Bool,
        selectedAudioDeviceUID: @escaping () -> String,
        defaultInputDevice: @escaping () -> AudioDeviceInfo? = CoreAudioDeviceCatalog.defaultInputDevice,
        availableInputDevices: @escaping () -> [AudioDeviceInfo] = CoreAudioDeviceCatalog.inputDevices,
        setDefaultInputDevice: @escaping (AudioDeviceInfo) -> OSStatus = CoreAudioDeviceCatalog.setDefaultInputDevice,
        log: @escaping (String) -> Void = AppLogger.shared.write,
        mainQueueAsyncAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
    ) {
        self.isEnabled = isEnabled
        self.selectedAudioDeviceUID = selectedAudioDeviceUID
        self.defaultInputDevice = defaultInputDevice
        self.availableInputDevices = availableInputDevices
        self.setDefaultInputDevice = setDefaultInputDevice
        self.log = log
        self.mainQueueAsyncAfter = mainQueueAsyncAfter
    }

    func cancelPendingRestore() {
        if restoreWorkItem != nil {
            pendingRestoreGeneration &+= 1
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            log("VOICE_KEY DEFAULT_INPUT pending_restore_cancelled")
        }
    }

    func borrowInputDeviceIfNeeded(sessionID: UUID) {
        cancelPendingRestore()

        guard activeBorrow == nil else {
            log("VOICE_KEY DEFAULT_INPUT borrow_skipped reason=already_borrowed session=\(sessionID)")
            return
        }

        let inputs = availableInputDevices()
        let targetUID = VoiceKeyDefaultInputPolicy.resolveTargetDeviceUID(
            selectedAudioDeviceUID: selectedAudioDeviceUID(),
            availableInputs: inputs
        )
        let currentDefault = defaultInputDevice()
        let decision = VoiceKeyDefaultInputPolicy.evaluateBorrow(
            isEnabled: isEnabled(),
            currentDefaultUID: currentDefault?.uid,
            targetUID: targetUID,
            activeBorrow: activeBorrow
        )

        switch decision {
        case .noChange:
            break
        case let .switchInput(fromUID, toUID):
            guard let targetDevice = inputs.first(where: { $0.uid == toUID }) else {
                log("VOICE_KEY DEFAULT_INPUT switch_failed reason=target_device_not_found target=\(toUID)")
                return
            }
            let status = setDefaultInputDevice(targetDevice)
            if status == noErr {
                activeBorrow = VoiceKeyDefaultInputBorrow(
                    originalUID: fromUID,
                    targetUID: toUID,
                    sessionID: sessionID,
                    switchedAt: Date()
                )
                log("VOICE_KEY DEFAULT_INPUT switched_to_remote from=\(fromUID) to=\(toUID) session=\(sessionID)")
            } else {
                log("VOICE_KEY DEFAULT_INPUT switch_failed status=\(status) from=\(fromUID) to=\(toUID)")
            }
        case .restoreInput, .clearWithoutRestore:
            break
        }
    }

    func restoreInputDeviceIfNeeded(
        after delay: TimeInterval = defaultTailGracePeriod,
        reason: String
    ) {
        guard activeBorrow != nil else { return }

        cancelPendingRestore()
        pendingRestoreGeneration &+= 1
        let currentGeneration = pendingRestoreGeneration

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingRestoreGeneration == currentGeneration else { return }
            self.executeRestore(reason: reason)
        }
        self.restoreWorkItem = workItem
        mainQueueAsyncAfter(delay) {
            workItem.perform()
        }
    }

    func forceRestoreImmediate(reason: String) {
        cancelPendingRestore()
        guard activeBorrow != nil else { return }
        executeRestore(reason: reason)
    }

    private func executeRestore(reason: String) {
        guard let borrow = activeBorrow else { return }
        activeBorrow = nil
        restoreWorkItem = nil

        let currentDefault = defaultInputDevice()
        let decision = VoiceKeyDefaultInputPolicy.evaluateRestore(
            activeBorrow: borrow,
            currentDefaultUID: currentDefault?.uid
        )

        switch decision {
        case let .restoreInput(_, toUID):
            let inputs = availableInputDevices()
            guard let originalDevice = inputs.first(where: { $0.uid == toUID }) else {
                log("VOICE_KEY DEFAULT_INPUT restore_failed reason=original_device_missing target=\(toUID)")
                return
            }
            let status = setDefaultInputDevice(originalDevice)
            if status == noErr {
                log("VOICE_KEY DEFAULT_INPUT restored_to_original to=\(toUID) reason=\(reason)")
            } else {
                log("VOICE_KEY DEFAULT_INPUT restore_failed status=\(status) to=\(toUID) reason=\(reason)")
            }
        case .clearWithoutRestore:
            log("VOICE_KEY DEFAULT_INPUT clear_without_restore current=\(currentDefault?.uid ?? "none") reason=\(reason)")
        case .noChange, .switchInput:
            break
        }
    }
}
