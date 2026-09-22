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
    case vokie
    case chatterFly = "chatterfly"
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
        case .unselected, .typeless, .vokie, .chatterFly, .other:
            return nil
        }
    }

    var publicLaunchURL: URL? {
        switch self {
        case .vokie:
            return URL(string: "vokie://launch")
        case .unselected, .doubao, .weixin, .typeless, .chatterFly, .other:
            return nil
        }
    }

    var applicationBundleIdentifier: String? {
        switch self {
        case .typeless:
            return "now.typeless.desktop"
        case .unselected, .doubao, .weixin, .vokie, .chatterFly, .other:
            return nil
        }
    }

    var requiresFunctionKeySetup: Bool {
        preferredInputSourceID != nil
    }
}

enum VoiceGestureMode: String, CaseIterable, Codable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }
}

enum VoiceToolBindingSource: String, Codable {
    case documentedDefault = "documented_default"
    case userLearned = "user_learned"
    case deepLinkConfigured = "deeplink_configured"
    case manuallyConfirmed = "manually_confirmed"
}

enum VoiceToolBindingValidationState: String, Codable {
    case staged
    case verified
    case failed
}

enum VoiceToolEvidenceState: String, Codable {
    case verified
    case pending
    case stale
    case unknown
}

enum VoiceToolInstallationProbe: String, Codable {
    case inputSource
    case applicationBundle
    case publicURLScheme
    case none
}

struct VoiceToolAdapterProfile: Equatable {
    let tool: OnboardingVoiceTool
    let supportedModes: Set<VoiceGestureMode>
    let defaultShortcutByMode: [VoiceGestureMode: VoiceKeyMode]
    let recommendedMode: VoiceGestureMode?
    let installationProbe: VoiceToolInstallationProbe
    let evidenceState: VoiceToolEvidenceState

    static func profile(for tool: OnboardingVoiceTool) -> Self {
        switch tool {
        case .doubao:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .function, .toggle: .rightCommand],
                recommendedMode: .hold,
                installationProbe: .inputSource,
                evidenceState: .verified
            )
        case .weixin:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .function, .toggle: .rightCommand],
                recommendedMode: .hold,
                installationProbe: .inputSource,
                evidenceState: .pending
            )
        case .typeless:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .applicationBundle,
                evidenceState: .verified
            )
        case .vokie:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .publicURLScheme,
                evidenceState: .pending
            )
        case .chatterFly:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .publicURLScheme,
                evidenceState: .pending
            )
        case .other:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [:],
                recommendedMode: nil,
                installationProbe: .none,
                evidenceState: .unknown
            )
        case .unselected:
            return Self(
                tool: tool,
                supportedModes: [],
                defaultShortcutByMode: [:],
                recommendedMode: nil,
                installationProbe: .none,
                evidenceState: .unknown
            )
        }
    }
}

struct VoiceToolUserBinding: Codable, Equatable {
    let tool: OnboardingVoiceTool
    let shortcut: VoiceKeyMode
    let gestureMode: VoiceGestureMode
    let source: VoiceToolBindingSource
    var validationState: VoiceToolBindingValidationState
    var verifiedToolVersion: String?
    var verifiedAt: Date?

    func verified(at date: Date = Date()) -> Self {
        var copy = self
        copy.validationState = .verified
        copy.verifiedAt = date
        return copy
    }
}

enum OnboardingVoiceBindingPreference: String, Codable {
    case documentedDefault = "documented_default"
    case learnCurrent = "learn_current"
}

enum OnboardingControlSource: String, CaseIterable, Codable, Identifiable {
    case unselected
    case xiaomiRemote = "xiaomi_remote"
    case siriRemote = "siri_remote"
    case chromecastRemote = "chromecast_remote"
    case appleCompanion = "apple_companion"
    case webRemote = "web_remote"

    var id: String { rawValue }

    var titleKey: String { "onboarding.control_source.\(rawValue).title" }
    var detailKey: String { "onboarding.control_source.\(rawValue).detail" }

    var supportedGestureModes: Set<VoiceGestureMode> {
        switch self {
        case .unselected:
            return []
        case .xiaomiRemote, .siriRemote:
            return [.hold]
        case .chromecastRemote, .appleCompanion, .webRemote:
            return [.hold, .toggle]
        }
    }

    var legacyControlMethod: OnboardingControlMethod {
        switch self {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return .physicalRemote
        case .appleCompanion:
            return .iPhoneApp
        case .webRemote:
            return .webRemote
        case .unselected:
            return .unselected
        }
    }

    static func migrated(from method: OnboardingControlMethod) -> Self {
        switch method {
        case .physicalRemote: return .xiaomiRemote
        case .iPhoneApp: return .appleCompanion
        case .webRemote: return .webRemote
        case .unselected: return .unselected
        }
    }
}

enum OnboardingBuildCapabilities {
    static var availableControlSources: [OnboardingControlSource] {
        var sources: [OnboardingControlSource] = [.xiaomiRemote]
        #if SAYALL_SIRI_REMOTE_ENABLED
        sources.append(.siriRemote)
        #endif
        #if SAYALL_CHROMECASE_ENABLED
        sources.append(.chromecastRemote)
        #endif
        #if SAYALL_MAC_REMOTE_ENABLED
        sources.append(contentsOf: [.appleCompanion, .webRemote])
        #endif
        return sources
    }
}

struct OnboardingVoicePairingPlan: Equatable {
    let binding: VoiceToolUserBinding
    let controlSource: OnboardingControlSource
    let fnTapModeEnabled: Bool
    let chromecastVoiceMode: ChromecaseVoiceMode?
    let evidenceState: VoiceToolEvidenceState

    static func resolve(
        tool: OnboardingVoiceTool,
        controlSource: OnboardingControlSource,
        preferredGesture: VoiceGestureMode? = nil,
        userBinding: VoiceToolUserBinding? = nil
    ) -> Self? {
        guard tool != .unselected, controlSource != .unselected else { return nil }
        let profile = VoiceToolAdapterProfile.profile(for: tool)

        if let userBinding {
            guard userBinding.tool == tool,
                  profile.supportedModes.contains(userBinding.gestureMode),
                  canDrive(
                    gesture: userBinding.gestureMode,
                    shortcut: userBinding.shortcut,
                    from: controlSource
                  ) else { return nil }
            return makePlan(
                binding: userBinding,
                controlSource: controlSource,
                evidenceState: profile.evidenceState
            )
        }

        let candidates = gestureCandidates(
            profile: profile,
            controlSource: controlSource,
            preferredGesture: preferredGesture
        )
        for gesture in candidates {
            guard let shortcut = profile.defaultShortcutByMode[gesture],
                  canDrive(gesture: gesture, shortcut: shortcut, from: controlSource)
            else { continue }
            return makePlan(
                binding: VoiceToolUserBinding(
                    tool: tool,
                    shortcut: shortcut,
                    gestureMode: gesture,
                    source: .documentedDefault,
                    validationState: .staged,
                    verifiedToolVersion: nil,
                    verifiedAt: nil
                ),
                controlSource: controlSource,
                evidenceState: profile.evidenceState
            )
        }
        return nil
    }

    private static func gestureCandidates(
        profile: VoiceToolAdapterProfile,
        controlSource: OnboardingControlSource,
        preferredGesture: VoiceGestureMode?
    ) -> [VoiceGestureMode] {
        var result: [VoiceGestureMode] = []
        func append(_ mode: VoiceGestureMode?) {
            guard let mode, profile.supportedModes.contains(mode), !result.contains(mode) else {
                return
            }
            result.append(mode)
        }
        append(preferredGesture)
        if controlSource == .chromecastRemote { append(.toggle) }
        if controlSource == .xiaomiRemote || controlSource == .siriRemote { append(.hold) }
        append(profile.recommendedMode)
        append(.toggle)
        append(.hold)
        return result
    }

    private static func canDrive(
        gesture: VoiceGestureMode,
        shortcut: VoiceKeyMode,
        from source: OnboardingControlSource
    ) -> Bool {
        if source.supportedGestureModes.contains(gesture) { return true }
        return gesture == .toggle &&
            shortcut == .function &&
            source.supportedGestureModes == [.hold]
    }

    private static func makePlan(
        binding: VoiceToolUserBinding,
        controlSource: OnboardingControlSource,
        evidenceState: VoiceToolEvidenceState
    ) -> Self {
        let fnTap = binding.gestureMode == .toggle &&
            binding.shortcut == .function &&
            !controlSource.supportedGestureModes.contains(.toggle)
        let chromecastMode: ChromecaseVoiceMode? = controlSource == .chromecastRemote
            ? (binding.gestureMode == .toggle ? .toggle : .hold)
            : nil
        return Self(
            binding: binding,
            controlSource: controlSource,
            fnTapModeEnabled: fnTap,
            chromecastVoiceMode: chromecastMode,
            evidenceState: evidenceState
        )
    }
}

/// Onboarding 右栏使用的遥控器图片来源。
///
/// 物理遥控器的图片必须跟随用户选择的来源，不能把一张小米图片当成所有硬件的占位图。
enum OnboardingRemotePhotoKind: Equatable {
    case bundled(resourceName: String)
    case siriRemote
    case chromecastRemote
    case placeholder

    static func resolve(
        source: OnboardingControlSource,
        selectedModel: XiaomiRemoteModel?
    ) -> Self {
        switch source {
        case .xiaomiRemote:
            // 尚未识别到具体型号时，来源本身已经限定为公开支持的小米 2/2 Pro，
            // 使用目录中明确声明的共享真机图；一旦识别出未知型号则必须降级占位。
            if let selectedModel, selectedModel != .unknown {
                guard let resource = VoiceRemoteCatalog.photoResource(for: selectedModel) else {
                    return .placeholder
                }
                return .bundled(resourceName: resource)
            }
            return .bundled(resourceName: VoiceRemoteCatalog.photoResource(for: .rc003)
                ?? "RC003-remote-photo")
        case .siriRemote:
            return .siriRemote
        case .chromecastRemote:
            return .chromecastRemote
        case .appleCompanion, .webRemote, .unselected:
            return .placeholder
        }
    }
}

enum OnboardingVoiceToolAvailability: String, Equatable, Hashable {
    case available
    case notInstalled
    case unknown
}

enum OnboardingVoiceToolRuntimeState: String, Equatable, Hashable {
    case running
    case notRunning = "not_running"
    case unknown
    case notApplicable = "not_applicable"
}

enum OnboardingVoiceToolRuntimePolicy {
    static func requiresRunningApplication(for tool: OnboardingVoiceTool) -> Bool {
        switch VoiceToolAdapterProfile.profile(for: tool).installationProbe {
        case .applicationBundle, .publicURLScheme:
            return true
        case .inputSource, .none:
            return false
        }
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

enum OnboardingVoiceTestConfigurationPolicy {
    static func requiresGlobalVoiceConfirmation(for voiceTool: OnboardingVoiceTool) -> Bool {
        voiceTool == .doubao
    }
}

enum OnboardingFlowPolicy {
    static func isPhysicalRemoteRecognized(
        at step: OnboardingStep,
        voiceConnectionReady: Bool,
        validatedHIDButtonObserved: Bool
    ) -> Bool {
        voiceConnectionReady || (step == .remote && validatedHIDButtonObserved)
    }

    static func shouldAutoSelectPhysicalRemote(
        at step: OnboardingStep,
        remoteConnected: Bool,
        suppressForUserBack: Bool = false
    ) -> Bool {
        step == .remoteAvailability && remoteConnected && !suppressForUserBack
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
        voiceKeyMode: VoiceKeyMode = .function,
        capabilities: OnboardingCapabilities
    ) -> Bool {
        switch step {
        case .welcome:
            return true
        case .voiceTool:
            return voiceTool != .unselected
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

enum CompletedUpdatePermissionRepairPolicy {
    static func shouldOpenPermissions(
        isOnboardingComplete: Bool,
        completedUpdate: Bool,
        bluetoothGranted: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        isOnboardingComplete &&
            completedUpdate &&
            (!bluetoothGranted || !inputMonitoringGranted || !accessibilityGranted)
    }
}
