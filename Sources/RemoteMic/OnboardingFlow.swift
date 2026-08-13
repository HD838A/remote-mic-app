import Foundation

enum OnboardingStep: String, CaseIterable, Codable {
    case welcome
    case voiceTool
    case permissions
    case remote
    case audio
    case voiceTest
    case controls
    case complete

    var requiresRuntime: Bool {
        switch self {
        case .welcome, .voiceTool:
            return false
        case .permissions, .remote, .audio, .voiceTest, .controls, .complete:
            return true
        }
    }

    var previous: OnboardingStep? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }

    var next: OnboardingStep? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else {
            return nil
        }
        return Self.allCases[index + 1]
    }

    var progress: Double {
        guard let index = Self.allCases.firstIndex(of: self), Self.allCases.count > 1 else { return 0 }
        return Double(index) / Double(Self.allCases.count - 1)
    }
}

enum OnboardingPhase: String, CaseIterable {
    case prepare
    case setup
    case tryIt = "try_it"

    var localizationKey: String {
        "onboarding.phase.\(rawValue)"
    }

    static func phase(for step: OnboardingStep) -> OnboardingPhase {
        switch step {
        case .welcome, .voiceTool:
            return .prepare
        case .permissions, .remote, .audio:
            return .setup
        case .voiceTest, .controls, .complete:
            return .tryIt
        }
    }
}

enum OnboardingVoiceTool: String, CaseIterable, Codable, Identifiable {
    case unselected
    case doubao
    case typeless
    case other

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.voice_tool.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.voice_tool.\(rawValue).detail"
    }
}

struct OnboardingCapabilities: Equatable {
    var bluetoothGranted = false
    var inputMonitoringGranted = false
    var accessibilityGranted = false
    var remoteConnected = false
    var remoteButtonObserved = false
    var audioReady = false
    var audioOutputSelected = false
    var voiceSessionStarted = false
    var voiceSamplesReceived = false
    var voiceSessionEnded = false
    var transcriptionAppeared = false
    var testedRemoteButtonCount = 0
}

enum OnboardingAudioSelectionPolicy {
    static func isSelectedDeviceAvailable(
        selectedUID: String,
        availableUIDs: some Sequence<String>
    ) -> Bool {
        !selectedUID.isEmpty && availableUIDs.contains(selectedUID)
    }
}

enum OnboardingFlowPolicy {
    static func shouldRequestRemoteReconnect(
        remoteConnected: Bool,
        remoteButtonObserved: Bool,
        recoveryRequested: Bool
    ) -> Bool {
        !remoteConnected && remoteButtonObserved && !recoveryRequested
    }

    static func canContinue(
        from step: OnboardingStep,
        voiceTool: OnboardingVoiceTool,
        capabilities: OnboardingCapabilities
    ) -> Bool {
        switch step {
        case .welcome:
            return true
        case .voiceTool:
            return voiceTool != .unselected
        case .permissions:
            return capabilities.bluetoothGranted &&
                capabilities.inputMonitoringGranted &&
                capabilities.accessibilityGranted
        case .remote:
            return capabilities.remoteConnected && capabilities.remoteButtonObserved
        case .audio:
            return capabilities.audioReady && capabilities.audioOutputSelected
        case .voiceTest:
            return capabilities.voiceSessionStarted &&
                capabilities.voiceSamplesReceived &&
                capabilities.voiceSessionEnded &&
                capabilities.transcriptionAppeared
        case .controls:
            return capabilities.testedRemoteButtonCount >= 3
        case .complete:
            return capabilities.bluetoothGranted &&
                capabilities.inputMonitoringGranted &&
                capabilities.accessibilityGranted &&
                capabilities.remoteConnected &&
                capabilities.audioReady &&
                capabilities.audioOutputSelected
        }
    }

    static func recoveryStep(
        from step: OnboardingStep,
        voiceTool: OnboardingVoiceTool,
        capabilities: OnboardingCapabilities,
        hasSelectedAudioUID: Bool
    ) -> OnboardingStep? {
        let context = FirstUseDiagnosticContext(
            step: step,
            capabilities: capabilities,
            hasSelectedAudioUID: hasSelectedAudioUID
        )
        guard let failure = context.failureReason else { return nil }
        if step == .complete, failure == .completeRuntimeRegressed {
            if !capabilities.bluetoothGranted ||
                !capabilities.inputMonitoringGranted ||
                !capabilities.accessibilityGranted {
                return .permissions
            }
            if !capabilities.remoteConnected { return .remote }
            return .audio
        }
        return failure.recoveryStep
    }
}

enum OnboardingLaunchPolicy {
    static func shouldStartRuntime(isComplete: Bool, step: OnboardingStep) -> Bool {
        isComplete || step.requiresRuntime
    }

    static func shouldShowMainWindow(
        isComplete: Bool,
        completedUpdate: Bool,
        openMainWindowAtLaunch: Bool
    ) -> Bool {
        !isComplete || completedUpdate || openMainWindowAtLaunch
    }
}
