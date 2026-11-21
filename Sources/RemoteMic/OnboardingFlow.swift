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

/// 提示词放在本地化资源中；源码只负责按语言读取，避免长文案和产品配置混在一起。
enum OnboardingAIAssistantPrompt {
    private static let resourceName = "OnboardingAIAssistantPrompt"
    private static let resourceExtension = "txt"

    static let chinese = load(localization: "zh-Hans")
    static let english = load(localization: "en")

    static func text(for locale: Locale) -> String {
        locale.identifier.lowercased().hasPrefix("zh") ? chinese : english
    }

    private static func load(localization: String) -> String {
        guard let url = RemoteMicResourceBundle.mainOrDevelopment.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: nil,
            localization: localization
        ),
        let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OnboardingVoiceGesturePrompt {
    static func text(for mode: VoiceGestureMode, locale: Locale) -> String {
        let isChinese = locale.identifier.lowercased().hasPrefix("zh")
        switch (isChinese, mode) {
        case (true, .hold): return "按住语音键说话，说完松开。"
        case (true, .toggle): return "按一下语音键开始说话，再按一下结束。"
        case (false, .hold): return "Hold the voice button while speaking, then release it."
        case (false, .toggle): return "Press the voice button once to start, then once more to finish."
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

    /// 该工具是否有「全局唤起语音」这类开关，需要在测试前单独确认。
    ///
    /// 之前这里是在策略里写死 `voiceTool == .doubao`：行为对，但语音测试页的勾选文案和
    /// 失败提示都跟着把「豆包」和「全局唤起」当成了所有工具的共性。一旦新增一个带该开关
    /// 的工具，或者给无该开关的工具加提示，就得同时改三处。改成能力字段后只改这一张表。
    ///
    /// `nil` 表示未观察到该工具的设置界面（`.other`），此时不追问，避免让用户去找一个
    /// 自己工具里并不存在的开关。
    var globalActivationSupport: Bool? {
        switch tool {
        case .doubao: return true
        case .weixin, .typeless, .vokie: return false
        case .unselected, .other: return nil
        }
    }

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

    /// 语音音频是否只在按下语音键时建立。
    ///
    /// 小米遥控器和 Chromecast 连接成功后蓝牙桥保持 Ready，虚拟音频引擎因此常驻；
    /// Siri Remote 的音频由 HCI 组件在按键时开始采集，连接本身不启动引擎，按需建立。
    /// 两者都归为 `physical_remote`，只能按来源区分，不能按控制方式区分。
    var usesOnDemandAudioOutput: Bool {
        self == .siriRemote
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

enum OnboardingPermissionRefreshPolicy {
    /// 引导页的周期权限查询间隔（秒）。
    ///
    /// 1 Hz 只是兜底：用户从系统设置改完权限回到 App 时，
    /// `NSApplication.didBecomeActiveNotification` 会立即触发一次刷新，
    /// 因此 2 s 已经足够感知权限变化。
    static let permissionRefreshIntervalSeconds: TimeInterval = 2

    /// App 在后台时不做周期权限查询。
    ///
    /// 权限查询要同步访问 tccd，而后台没有任何用户可见收益；
    /// 用户回到前台时由 `didBecomeActive` 立即刷新一次，状态不会漏。
    static func shouldRefreshPermissions(isApplicationActive: Bool) -> Bool {
        isApplicationActive
    }
}

enum OnboardingAppleRemoteGeneration: String, Codable, CaseIterable, Identifiable {
    case generation6 = "generation_6"
    case generation7 = "generation_7"

    /// 页面展示顺序：Type-C 在 Lightning 之前。保留 `allCases` 的声明顺序，
    /// 避免影响只关心集合而非顺序的调用方。
    static let displayOrder: [Self] = [.generation7, .generation6]

    var id: String { rawValue }

    var titleKey: String { "onboarding.control_source.apple_remote.\(rawValue).title" }

    var model: XiaomiRemoteModel {
        switch self {
        case .generation6: return .appleSiriRemoteA2540
        case .generation7: return .appleSiriRemoteA2854
        }
    }
}

/// Onboarding 需要用户明确选择的具体小米型号。
///
/// 持久化只允许这两个已验证型号；Apple、Chromecast 和 `.unknown` 不属于这个选择。
enum OnboardingXiaomiRemoteModel: String, Codable, CaseIterable, Identifiable {
    case rc003
    case rc001

    var id: String { rawValue }

    var model: XiaomiRemoteModel {
        switch self {
        case .rc003: return .rc003
        case .rc001: return .rc001
        }
    }

    var titleKey: String { model.localizationKey }
    var detailKey: String { "onboarding.control_source.xiaomi_remote.detail" }
}

/// 控制设备页实际渲染的实体遥控器卡片。
enum OnboardingPhysicalRemoteCard: Identifiable, Equatable {
    case xiaomi(OnboardingXiaomiRemoteModel)
    case apple(OnboardingAppleRemoteGeneration)

    var id: String {
        switch self {
        case let .xiaomi(model):
            return "xiaomi_remote.\(model.rawValue)"
        case let .apple(generation):
            return "siri_remote.\(generation.rawValue)"
        }
    }

    static func ordered(availableSources: [OnboardingControlSource]) -> [Self] {
        var cards: [Self] = []
        if availableSources.contains(.xiaomiRemote) {
            cards.append(contentsOf: OnboardingXiaomiRemoteModel.allCases.map(Self.xiaomi))
        }
        if availableSources.contains(.siriRemote) {
            cards.append(contentsOf: OnboardingAppleRemoteGeneration.displayOrder.map(Self.apple))
        }
        return cards
    }
}

enum OnboardingControlSourceSelectionPolicy {
    static func isComplete(
        source: OnboardingControlSource,
        xiaomiModel: OnboardingXiaomiRemoteModel?
    ) -> Bool {
        guard source != .unselected else { return false }
        guard source == .xiaomiRemote else { return true }
        return xiaomiModel != nil
    }
}

/// Onboarding 期间如何对待来自某个小米档案的按键或语音事件。
enum OnboardingXiaomiEventDisposition: Equatable {
    /// 事件来自用户选择的型号，可以进入现有门禁。
    case accept
    /// 档案型号尚未识别；可以暂存第一条证据，但型号确认前不能通过。
    case pendingIdentity
    /// 事件来自另一只已识别的小米遥控器；不得改变选择或满足门禁。
    case rejectOtherModel

    var logValue: String {
        switch self {
        case .accept: return "accepted"
        case .pendingIdentity: return "pending_identity"
        case .rejectOtherModel: return "profile_mismatch"
        }
    }
}

enum OnboardingXiaomiEventPolicy {
    static func disposition(
        profileModel: XiaomiRemoteModel?,
        selectedModel: OnboardingXiaomiRemoteModel?,
        controlSource: OnboardingControlSource
    ) -> OnboardingXiaomiEventDisposition {
        guard controlSource == .xiaomiRemote, let selectedModel else { return .accept }
        switch profileModel {
        case .rc001?, .rc003?:
            return profileModel == selectedModel.model ? .accept : .rejectOtherModel
        case .unknown?, .none:
            return .pendingIdentity
        case .appleSiriRemoteA2854?, .appleSiriRemoteA2540?,
             .chromecastVoiceRemote?:
            return .rejectOtherModel
        }
    }

    /// 未识别档案只有在所选型号还没有可用档案时才接管当前选择。
    /// 所选型号已经有档案时，未知档案不能把 HID/语音路由切走。
    static func shouldAdoptSelection(
        profileModel: XiaomiRemoteModel?,
        selectedModel: OnboardingXiaomiRemoteModel?,
        selectedModelProfileExists: Bool,
        controlSource: OnboardingControlSource
    ) -> Bool {
        switch disposition(
            profileModel: profileModel,
            selectedModel: selectedModel,
            controlSource: controlSource
        ) {
        case .accept:
            return true
        case .pendingIdentity:
            return !selectedModelProfileExists
        case .rejectOtherModel:
            return false
        }
    }
}

enum OnboardingBuildCapabilities {
    static var availableControlSources: [OnboardingControlSource] {
        availableControlSources(siriRemotePackageInstalled: isSiriRemotePackageInstalled())
    }

    /// Installer receipts are public installation metadata owned by SayAll.
    static func isSiriRemotePackageInstalled(
        receiptExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        receiptExists("/var/db/receipts/com.hd838a.RemoteMic.siri-remote.plist")
    }

    static func availableControlSources(
        siriRemotePackageInstalled: Bool
    ) -> [OnboardingControlSource] {
        var sources: [OnboardingControlSource] = [.xiaomiRemote]
        #if SAYALL_SIRI_REMOTE_ENABLED
        if siriRemotePackageInstalled { sources.append(.siriRemote) }
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

/// Onboarding may hide a source while keeping its runtime implementation and
/// persisted compatibility values available to the rest of the app.
enum OnboardingControlSourceVisibilityPolicy {
    static func visibleSources(
        _ sources: [OnboardingControlSource]
    ) -> [OnboardingControlSource] {
        sources.filter { $0 != .chromecastRemote }
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
        selectedModel: XiaomiRemoteModel?,
        onboardingXiaomiModel: OnboardingXiaomiRemoteModel? = nil
    ) -> Self {
        switch source {
        case .xiaomiRemote:
            // Only a Xiaomi profile may refine the image. A previously selected
            // Apple/Chromecast profile must never replace the Xiaomi card artwork.
            let preferredModel = onboardingXiaomiModel?.model ?? selectedModel
            if let preferredModel,
               preferredModel == .rc001 || preferredModel == .rc003 {
                guard let resource = VoiceRemoteCatalog.photoResource(for: preferredModel) else {
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

/// 音频页与完成页的音频门禁。
///
/// 语音音频按需建立的来源（iPhone、网页版、Siri Remote）只要选中受支持的设备且该设备仍在
/// 列表里就能继续，真实输出由下一页的会话、PCM、停止和文字验证；其他实体遥控器在连接期间
/// 常驻输出引擎，仍然要求持续 Ready。把 Siri Remote 一起按持续 Ready 要求会让只有一只
/// Siri Remote 的用户永远停在这一页：连接遥控器不会启动引擎，重试也只是重复同一个判断。
enum OnboardingAudioReadinessPolicy {
    static func usesOnDemandAudioOutput(
        controlMethod: OnboardingControlMethod,
        controlSource: OnboardingControlSource
    ) -> Bool {
        controlMethod.usesOnDemandAudioOutput || controlSource.usesOnDemandAudioOutput
    }

    static func isSatisfied(
        controlMethod: OnboardingControlMethod,
        controlSource: OnboardingControlSource,
        audioOutputSelected: Bool,
        audioReady: Bool
    ) -> Bool {
        audioOutputSelected &&
            (usesOnDemandAudioOutput(controlMethod: controlMethod, controlSource: controlSource) ||
                audioReady)
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

enum OnboardingVoiceStreamAction: Equatable {
    case ignore
    case recordRemoteVoiceButtonPress
    case beginVoiceAttempt
    case endVoiceAttempt
}

/// Decides what an `isStreaming` change means for the current onboarding step.
///
/// The end transition deliberately does not require `sourceAccepted`: the model
/// clears `activeVoiceSource` in the same update that publishes `isStreaming = false`,
/// so requiring the source again would drop the release and leave the attempt in
/// `.recording` forever.
enum OnboardingVoiceStreamPolicy {
    static func action(
        isStreaming: Bool,
        step: OnboardingStep,
        voiceSessionStarted: Bool,
        sourceAccepted: Bool
    ) -> OnboardingVoiceStreamAction {
        switch step {
        case .remote where isStreaming:
            return sourceAccepted ? .recordRemoteVoiceButtonPress : .ignore
        case .voiceTest:
            if isStreaming {
                return sourceAccepted ? .beginVoiceAttempt : .ignore
            }
            return voiceSessionStarted ? .endVoiceAttempt : .ignore
        default:
            return .ignore
        }
    }
}

enum OnboardingVoiceTestConfigurationPolicy {
    static func requiresGlobalVoiceConfirmation(for voiceTool: OnboardingVoiceTool) -> Bool {
        VoiceToolAdapterProfile.profile(for: voiceTool).globalActivationSupport == true
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
        controlSource: OnboardingControlSource = .unselected,
        voiceKeyMode: VoiceKeyMode = .function,
        capabilities: OnboardingCapabilities,
        phoneAppInstallConfirmed: Bool = true
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
                // iPhone 路径下「我已安装 iPhone App」是必选项，勾选前不让走。
                // 其他控制方式不显示这一行，也就不该被它拦住——默认值 true 让
                // 不关心这个勾选的调用方（例如 FirstUseDiagnostics）行为不变。
                (controlMethod != .iPhoneApp || phoneAppInstallConfirmed) &&
                (!controlMethod.requiresBluetoothPermission || capabilities.bluetoothGranted) &&
                (!controlMethod.requiresInputMonitoringPermission ||
                    capabilities.inputMonitoringGranted) &&
                capabilities.accessibilityGranted
        case .remote:
            return capabilities.remoteConnected && capabilities.remoteButtonObserved
        case .audio:
            return OnboardingAudioReadinessPolicy.isSatisfied(
                controlMethod: controlMethod,
                controlSource: controlSource,
                audioOutputSelected: capabilities.audioOutputSelected,
                audioReady: capabilities.audioReady
            )
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
                OnboardingAudioReadinessPolicy.isSatisfied(
                    controlMethod: controlMethod,
                    controlSource: controlSource,
                    audioOutputSelected: capabilities.audioOutputSelected,
                    audioReady: capabilities.audioReady
                )
        }
    }

    static func recoveryStep(
        from step: OnboardingStep,
        voiceTool: OnboardingVoiceTool,
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        controlSource: OnboardingControlSource = .unselected,
        capabilities: OnboardingCapabilities,
        hasSelectedAudioUID: Bool
    ) -> OnboardingStep? {
        let context = FirstUseDiagnosticContext(
            step: step,
            remoteAvailability: remoteAvailability,
            controlMethod: controlMethod,
            controlSource: controlSource,
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
