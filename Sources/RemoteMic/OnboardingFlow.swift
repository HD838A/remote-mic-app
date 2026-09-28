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

    /// The public flow keeps the control-device decision immediately after the welcome page.
    /// The legacy control-method case remains decodable so an interrupted older flow can resume.
    static let visibleCases: [Self] = [
        .welcome, .remoteAvailability, .permissions, .remote, .audio, .voiceTool,
        .voiceTest, .controls, .complete,
    ]

    var normalized: Self {
        self == .controlMethod ? .remoteAvailability : self
    }

    var requiresRuntime: Bool {
        switch self {
        case .welcome, .remoteAvailability, .controlMethod:
            return false
        case .permissions, .remote, .audio, .voiceTool, .voiceTest, .controls, .complete:
            return true
        }
    }

    var previous: OnboardingStep? {
        let step = normalized
        guard let index = Self.visibleCases.firstIndex(of: step), index > 0 else { return nil }
        return Self.visibleCases[index - 1]
    }

    var next: OnboardingStep? {
        let step = normalized
        guard let index = Self.visibleCases.firstIndex(of: step), index + 1 < Self.visibleCases.count else {
            return nil
        }
        return Self.visibleCases[index + 1]
    }

    var progress: Double {
        let step = normalized
        guard let index = Self.visibleCases.firstIndex(of: step), Self.visibleCases.count > 1 else {
            return 0
        }
        return Double(index) / Double(Self.visibleCases.count - 1)
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
        case .welcome, .remoteAvailability, .controlMethod:
            return .prepare
        case .permissions, .remote, .audio, .voiceTool:
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
        case .unselected, .typeless, .vokie, .other:
            return nil
        }
    }

    var publicLaunchURL: URL? {
        switch self {
        case .vokie:
            return URL(string: "vokie://launch")
        case .unselected, .doubao, .weixin, .typeless, .other:
            return nil
        }
    }

    var applicationBundleIdentifier: String? {
        switch self {
        case .typeless:
            return "now.typeless.desktop"
        case .unselected, .doubao, .weixin, .vokie, .other:
            return nil
        }
    }

    var requiresFunctionKeySetup: Bool {
        preferredInputSourceID != nil
    }
}

enum OnboardingAIAssistantPrompt {
    static let chinese = """
    请在这台 Mac 上直接完成“无线麦SayAll.app”的配置。我的遥控器已经通过蓝牙连接。

    不要操作屏幕、不要点击窗口，也不要只给我操作建议。请使用无线麦提供的本机配置命令，通过终端完成配置并验证结果：

    1. 先在终端定位已安装的无线麦SayAll.app：
       APP_PATH="$(mdfind 'kMDItemCFBundleIdentifier == \"com.hd838a.RemoteMic\"' | head -n 1)"; [ -n "$APP_PATH" ] || APP_PATH="/Applications/SayAll.app"
       [ -x "$APP_PATH/Contents/MacOS/RemoteMic" ] || APP_PATH="/Applications/无线麦SayAll.app"
       "$APP_PATH/Contents/MacOS/RemoteMic" --agent-configure --auto --json
    2. 自动选择当前已连接的遥控器；如果有多个候选且无法判断，只向我询问一次。
    3. 自动选择已安装且可用的语音工具：豆包、微信输入法、Vokie、Typeless 或其他工具；如果有多个候选且无法判断，只询问我一次。
    4. 让本次 Onboarding 使用 Fn，并按控制设备与语音工具匹配的“按住”或“按一次”方式配置。
    5. 选择可用的无线麦音频设备作为语音输入路线，并保留当前增益；如果需要，可把增益调整到适合小声或气声的范围。
    6. 只修改无线麦自己的配置，不读取或修改第三方语音工具的私有文件、数据库、沙盒或未公开协议。
    7. 配置成功后，将无线麦向导停在真实语音测试步骤，不要跳过语音、音频、按键和文字上屏验证，也不要把写入配置当成验证成功。
    8. 如果需要 macOS 权限、用户选择或真实说话测试，明确告诉我还缺哪一步；否则告诉我配置已准备完成。

    请使用命令返回的 JSON 结果判断成功或失败，并在失败时说明具体原因。不要伪造完成状态。
    """

    static let english = """
    Configure “SayAll” directly on this Mac. My remote is already connected over Bluetooth.

    Do not operate the screen, click windows, or only give instructions. Use the app’s local headless configuration command from the terminal, then verify its result:

    1. Locate the installed SayAll app without opening a window, then run:
       APP_PATH="$(mdfind 'kMDItemCFBundleIdentifier == \"com.hd838a.RemoteMic\"' | head -n 1)"; [ -n "$APP_PATH" ] || APP_PATH="/Applications/SayAll.app"
       [ -x "$APP_PATH/Contents/MacOS/RemoteMic" ] || APP_PATH="/Applications/无线麦SayAll.app"
       "$APP_PATH/Contents/MacOS/RemoteMic" --agent-configure --auto --json
    2. Select the currently connected remote automatically; ask me at most once if multiple candidates cannot be distinguished.
    3. Select an installed and available voice tool: Doubao, WeChat Input, Vokie, Typeless, or Other; ask me at most once if multiple candidates cannot be distinguished.
    4. Use Fn for this onboarding run and apply the hold-or-toggle behavior matched to the selected remote and voice tool.
    5. Select an available SayAll audio device for voice input and keep the current gain; adjust it only if needed for a quiet or breathy voice.
    6. Modify only SayAll’s own configuration. Do not read or modify private files, databases, sandboxes, or undocumented protocols of third-party voice tools.
    7. After configuration, leave SayAll at the real voice-test step. Do not skip voice, audio, button, or text-on-screen verification, and do not treat a written configuration as proof of success.
    8. If macOS permissions, a user choice, or a real spoken test is still required, tell me exactly what remains; otherwise report that configuration is prepared.

    Use the command’s JSON result to determine success or failure, and explain the concrete reason if it fails. Never fabricate completion.
    """

    static func text(for locale: Locale) -> String {
        locale.identifier.lowercased().hasPrefix("zh") ? chinese : english
    }
}

enum OnboardingVoiceGesturePrompt {
    static func text(for mode: VoiceGestureMode, locale: Locale) -> String {
        let isChinese = locale.identifier.lowercased().hasPrefix("zh")
        switch (isChinese, mode) {
        case (true, .hold): return "按住语音键说话，说完松开。"
        case (true, .toggle): return "按一下语音键开始说话，再按一下结束。"
        case (false, .hold): return "Hold the voice key while speaking, then release it."
        case (false, .toggle): return "Press the voice key once to start, then once more to finish."
        }
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
        case .other:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                // The third-party tool remains unobserved; Fn is only the
                // temporary Onboarding trigger and still requires the user's
                // real voice-text confirmation before it can be committed.
                defaultShortcutByMode: [.hold: .function, .toggle: .function],
                recommendedMode: .hold,
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

/// During the ordinary-button check, Onboarding observes fresh input events but must
/// never execute mappings that the user configured before starting (or rerunning) the flow.
enum OnboardingControlValidationPolicy {
    static func suppressConfiguredActions(
        at step: OnboardingStep,
        source: OnboardingControlSource
    ) -> Bool {
        guard step == .controls else { return false }
        switch source {
        case .xiaomiRemote, .siriRemote, .chromecastRemote, .appleCompanion, .webRemote:
            return true
        case .unselected:
            return false
        }
    }
}

enum OnboardingSecureInputPolicy {
    static let warningDelay: TimeInterval = 3

    static func shouldMonitor(
        step: OnboardingStep,
        source: OnboardingControlSource
    ) -> Bool {
        guard step == .remote || step == .controls else { return false }
        switch source {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return true
        case .appleCompanion, .webRemote, .unselected:
            return false
        }
    }

    static func shouldShowWarning(
        step: OnboardingStep,
        source: OnboardingControlSource,
        remoteConnected: Bool,
        remoteButtonObserved: Bool,
        secureInputActive: Bool?,
        waitStartedAtUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Bool {
        guard shouldMonitor(step: step, source: source),
              remoteConnected,
              !remoteButtonObserved,
              secureInputActive == true,
              let waitStartedAtUptime
        else { return false }
        return nowUptime - waitStartedAtUptime >= warningDelay
    }
}

enum OnboardingAppleRemoteGeneration: String, Codable, CaseIterable, Identifiable {
    case generation6 = "generation_6"
    case generation7 = "generation_7"

    var id: String { rawValue }

    var titleKey: String { "onboarding.control_source.apple_remote.\(rawValue).title" }

    var model: XiaomiRemoteModel {
        switch self {
        case .generation6: return .appleSiriRemoteA2540
        case .generation7: return .appleSiriRemoteA2854
        }
    }
}

enum OnboardingBuildCapabilities {
    static var availableControlSources: [OnboardingControlSource] {
        var sources: [OnboardingControlSource] = [.xiaomiRemote]
        #if SAYALL_SIRI_REMOTE_ENABLED
        sources.append(.siriRemote)
        #endif
        #if SAYALL_CHROMECAST_ENABLED
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
    let chromecastVoiceMode: ChromecastVoiceMode?
    let evidenceState: VoiceToolEvidenceState

    static func resolve(
        tool: OnboardingVoiceTool,
        controlSource: OnboardingControlSource,
        preferredGesture: VoiceGestureMode? = nil,
        userBinding: VoiceToolUserBinding? = nil,
        forceFunctionKey: Bool = false
    ) -> Self? {
        guard tool != .unselected, controlSource != .unselected else { return nil }
        let profile = VoiceToolAdapterProfile.profile(for: tool)

        if let userBinding {
            var effectiveBinding = userBinding
            if forceFunctionKey {
                effectiveBinding = VoiceToolUserBinding(
                    tool: userBinding.tool,
                    shortcut: .function,
                    gestureMode: userBinding.gestureMode,
                    source: userBinding.source,
                    validationState: userBinding.validationState,
                    verifiedToolVersion: userBinding.verifiedToolVersion,
                    verifiedAt: userBinding.verifiedAt
                )
            }
            guard effectiveBinding.tool == tool,
                  profile.supportedModes.contains(effectiveBinding.gestureMode),
                  canDrive(
                    gesture: effectiveBinding.gestureMode,
                    shortcut: effectiveBinding.shortcut,
                    from: controlSource
                  ) else { return nil }
            return makePlan(
                binding: effectiveBinding,
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
            let shortcut = forceFunctionKey ? VoiceKeyMode.function : profile.defaultShortcutByMode[gesture]
            guard let shortcut,
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
        let chromecastMode: ChromecastVoiceMode? = controlSource == .chromecastRemote
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
            // Only a Xiaomi profile may refine the image. A previously selected
            // Apple/Chromecast profile must never replace the Xiaomi card artwork.
            if let selectedModel,
               selectedModel == .rc001 || selectedModel == .rc003 {
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

enum OnboardingVoiceToolVisibilityPolicy {
    static func visibleTools(
        availability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability]
    ) -> [OnboardingVoiceTool] {
        var tools: [OnboardingVoiceTool] = [.doubao]
        if availability[.weixin] == .available {
            tools.append(.weixin)
        }
        tools.append(.vokie)
        if availability[.typeless] == .available {
            tools.append(.typeless)
        }
        tools.append(.other)
        return tools
    }
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
