import Foundation

enum OnboardingStep: String, CaseIterable, Codable {
    case welcome
    case voiceTool
    case remoteAvailability
    case controlMethod
    case permissions
    case remote
    case audio
    case voiceTest
    case controls
    case complete

    var requiresRuntime: Bool {
        switch self {
        case .welcome, .voiceTool, .remoteAvailability, .controlMethod:
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
        case .welcome, .voiceTool, .remoteAvailability, .controlMethod:
            return .prepare
        case .permissions, .remote, .audio:
            return .setup
        case .voiceTest, .controls, .complete:
            return .tryIt
        }
    }
}

enum OnboardingRemoteAvailability: String, CaseIterable, Codable, Identifiable {
    case unselected
    case hasRemote = "has_remote"
    case noRemote = "no_remote"

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.remote_availability.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.remote_availability.\(rawValue).detail"
    }
}

enum OnboardingControlMethod: String, CaseIterable, Codable, Identifiable {
    case unselected
    case physicalRemote = "physical_remote"
    case iPhoneApp = "iphone_app"
    case webRemote = "web_remote"

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.control_method.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.control_method.\(rawValue).detail"
    }

    var requiresBluetoothPermission: Bool {
        self != .unselected
    }

    var requiresInputMonitoringPermission: Bool {
        self != .unselected
    }

    var usesOnDemandAudioOutput: Bool {
        self == .iPhoneApp || self == .webRemote
    }
}

enum OnboardingVoiceTool: String, CaseIterable, Codable, Identifiable {
    case unselected
    case doubao
    case weixin
    case typeless
    case other

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.voice_tool.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.voice_tool.\(rawValue).detail"
    }

    var preferredInputSourceID: String? {
        switch self {
        case .doubao:
            return "com.bytedance.inputmethod.doubaoime.pinyin"
        case .weixin:
            return "com.tencent.inputmethod.wetype.pinyin"
        case .unselected, .typeless, .other:
            return nil
        }
    }

    var requiresFunctionKeySetup: Bool {
        preferredInputSourceID != nil
    }
}

struct OnboardingCapabilities: Equatable {
    var systemFunctionKeyAvailable = false
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
    var manualTranscriptInputObserved = false
    var testedRemoteButtonCount = 0
}

enum OnboardingAudioSelectionPolicy {
    private static let supportedUIDs = ["MiRemoteV2ch_UID", "BlackHole2ch_UID"]
    private static let supportedNames = ["MiRemoteV 2ch", "BlackHole 2ch"]

    static func isSupportedDevice(uid: String, name: String) -> Bool {
        supportedUIDs.contains(uid) || supportedNames.contains(name)
    }

    static func isSupportedDeviceSelected(
        selectedUID: String,
        availableSupportedUIDs: some Sequence<String>
    ) -> Bool {
        !selectedUID.isEmpty && availableSupportedUIDs.contains(selectedUID)
    }
}

enum OnboardingTranscriptInputPolicy {
    private static let keyDownEventTypeRawValue: UInt = 10
    private static let hidSystemStateRawValue: Int64 = 1

    static func isConfirmedPhysicalKeyboardInput(
        eventTypeRawValue: UInt?,
        sourceStateID: Int64?,
        sourceUnixProcessID: Int64?
    ) -> Bool {
        guard eventTypeRawValue == keyDownEventTypeRawValue,
              sourceStateID == hidSystemStateRawValue,
              let sourceUnixProcessID,
              sourceUnixProcessID <= 0 else {
            return false
        }
        return true
    }
}

enum OnboardingFlowPolicy {
    static func shouldAutoSelectPhysicalRemote(
        at step: OnboardingStep,
        remoteConnected: Bool
    ) -> Bool {
        step == .remoteAvailability && remoteConnected
    }

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
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        capabilities: OnboardingCapabilities
    ) -> Bool {
        switch step {
        case .welcome:
            return true
        case .voiceTool:
            return voiceTool != .unselected &&
                (!voiceTool.requiresFunctionKeySetup || capabilities.systemFunctionKeyAvailable)
        case .remoteAvailability:
            return remoteAvailability != .unselected
        case .controlMethod:
            return remoteAvailability == .noRemote &&
                (controlMethod == .iPhoneApp || controlMethod == .webRemote)
        case .permissions:
            return isControlSelectionValid(
                remoteAvailability: remoteAvailability,
                controlMethod: controlMethod
            ) &&
                (!controlMethod.requiresBluetoothPermission || capabilities.bluetoothGranted) &&
                (!controlMethod.requiresInputMonitoringPermission ||
                    capabilities.inputMonitoringGranted) &&
                capabilities.accessibilityGranted
        case .remote:
            return capabilities.remoteConnected && capabilities.remoteButtonObserved
        case .audio:
            return capabilities.audioOutputSelected &&
                (controlMethod.usesOnDemandAudioOutput || capabilities.audioReady)
        case .voiceTest:
            return capabilities.voiceSessionStarted &&
                capabilities.voiceSamplesReceived &&
                capabilities.voiceSessionEnded &&
                capabilities.transcriptionAppeared &&
                !capabilities.manualTranscriptInputObserved
        case .controls:
            return capabilities.testedRemoteButtonCount >= 3
        case .complete:
            return isControlSelectionValid(
                remoteAvailability: remoteAvailability,
                controlMethod: controlMethod
            ) &&
                (!controlMethod.requiresBluetoothPermission || capabilities.bluetoothGranted) &&
                (!controlMethod.requiresInputMonitoringPermission ||
                    capabilities.inputMonitoringGranted) &&
                capabilities.accessibilityGranted &&
                capabilities.remoteConnected &&
                capabilities.audioOutputSelected &&
                (controlMethod.usesOnDemandAudioOutput || capabilities.audioReady)
        }
    }

    static func recoveryStep(
        from step: OnboardingStep,
        voiceTool: OnboardingVoiceTool,
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        capabilities: OnboardingCapabilities,
        hasSelectedAudioUID: Bool
    ) -> OnboardingStep? {
        let context = FirstUseDiagnosticContext(
            step: step,
            remoteAvailability: remoteAvailability,
            controlMethod: controlMethod,
            capabilities: capabilities,
            hasSelectedAudioUID: hasSelectedAudioUID
        )
        guard let failure = context.failureReason else { return nil }
        if step == .complete, failure == .completeRuntimeRegressed {
            if !isControlSelectionValid(
                remoteAvailability: remoteAvailability,
                controlMethod: controlMethod
            ) {
                return remoteAvailability == .noRemote ? .controlMethod : .remoteAvailability
            }
            if (controlMethod.requiresBluetoothPermission && !capabilities.bluetoothGranted) ||
                (controlMethod.requiresInputMonitoringPermission &&
                    !capabilities.inputMonitoringGranted) ||
                !capabilities.accessibilityGranted {
                return .permissions
            }
            if !capabilities.remoteConnected { return .remote }
            return .audio
        }
        return failure.recoveryStep
    }

    static func isControlSelectionValid(
        remoteAvailability: OnboardingRemoteAvailability,
        controlMethod: OnboardingControlMethod
    ) -> Bool {
        switch remoteAvailability {
        case .hasRemote:
            return controlMethod == .physicalRemote
        case .noRemote:
            return controlMethod == .iPhoneApp || controlMethod == .webRemote
        case .unselected:
            return false
        }
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
