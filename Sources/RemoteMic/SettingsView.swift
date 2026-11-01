import AppKit
import Charts
import Combine
import CoreBluetooth
import CoreText
import SayAllMacRemoteCore
import SayAllMacRemoteUI
#if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
import SayAllChromecast
#endif
#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
import SayAllSiriRemote
#endif
import SwiftUI
import UniformTypeIdentifiers

struct SettingsSection: RawRepresentable, Hashable, CaseIterable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let connection = SettingsSection(rawValue: "connection")
    static let privateFeature = SettingsSection(rawValue: "privateFeature")
    static let macros = SettingsSection(rawValue: "macros")
    static let buttonProfiles = SettingsSection(rawValue: "buttonProfiles")
    static let membership = SettingsSection(rawValue: "membership")
    static let mapping = SettingsSection(rawValue: "mapping")
    /// 「APP 适配」：输入框聚焦与翻页滚动按 APP 单独配置，和按键页的按键绑定互不影响。
    static let applications = SettingsSection(rawValue: "applications")
    static let statistics = SettingsSection(rawValue: "statistics")
    static let transcripts = SettingsSection(rawValue: "transcripts")
    static let commonPhrases = SettingsSection(rawValue: "commonPhrases")
    static let permissions = SettingsSection(rawValue: "permissions")
    static let about = SettingsSection(rawValue: "about")
    static let allCases: [SettingsSection] = [.connection, .privateFeature, .macros, .buttonProfiles, .membership, .mapping, .applications, .statistics, .transcripts, .commonPhrases, .permissions, .about]
    static func supplemental(_ id: String) -> SettingsSection { SettingsSection(rawValue: "supplemental:" + id) }
    var supplementalID: String? { rawValue.hasPrefix("supplemental:") ? String(rawValue.dropFirst(13)) : nil }
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .connection: return "settings.section.connection"
        case .privateFeature: return ""
        case .macros: return ""
        case .buttonProfiles: return ""
        case .membership: return ""
        case .mapping: return "settings.section.buttons"
        case .applications: return "settings.section.applications"
        case .statistics: return "settings.section.statistics"
        case .commonPhrases: return "common_phrases.title"
        case .transcripts: return "settings.section.transcripts"
        case .permissions: return "settings.section.permissions"
        case .about: return "settings.section.settings"
        default: return ""
        }
    }

    var title: LocalizedStringKey {
        LocalizedStringKey(titleKey)
    }

    var systemImage: String {
        switch self {
        case .connection: return "link"
        case .privateFeature: return "sparkles"
        case .macros: return "command.square"
        case .buttonProfiles: return "rectangle.3.group"
        case .membership: return "crown.fill"
        case .mapping: return "keyboard"
        case .applications: return "square.grid.2x2"
        case .statistics: return "person.crop.circle"
        case .commonPhrases: return "text.quote"
        case .transcripts: return "text.bubble.fill"
        case .permissions: return "shield.lefthalf.filled"
        case .about: return "gearshape"
        default: return "square"
        }
    }
}

enum SettingsPermissionKind {
    case bluetooth
    case inputMonitoring
    case accessibility
}

enum SettingsPermissionAction: Equatable {
    case request
    case openSystemSettings(String)

    var titleKey: String {
        switch self {
        case .request:
            "permission.action.request"
        case .openSystemSettings:
            "permission.action.open_settings"
        }
    }
}

struct SettingsDiagnosticSnapshot: Equatable {
    let appVersion: String
    let bluetoothGranted: Bool
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let runtimeLogAvailable: Bool
    var remoteSessionError: HostRemoteSessionError? = nil

    var summary: String {
        [
            "SayAll settings diagnostics",
            "app_version=\(appVersion)",
            "permission_bluetooth=\(bluetoothGranted)",
            "permission_input_monitoring=\(inputMonitoringGranted)",
            "permission_accessibility=\(accessibilityGranted)",
            "runtime_log_available=\(runtimeLogAvailable)",
        ].joined(separator: "\n") + (remoteSessionError.map {
            "\nremote_session " + $0.diagnosticFields
        } ?? "")
    }

    var auditLog: String {
        "SETTINGS DIAGNOSTICS copied permission_bluetooth=\(bluetoothGranted) " +
            "permission_input_monitoring=\(inputMonitoringGranted) " +
            "permission_accessibility=\(accessibilityGranted)"
    }
}

enum RemoteBatteryPresentationPolicy {
    static func shouldShowBattery(
        model: XiaomiRemoteModel,
        level: Int?,
        powerState: RemotePowerState?
    ) -> Bool {
        // Chromecast 不宣告电池能力，界面不得显示永远是「未知」的电量位。
        guard !model.isChromecastRemote else { return false }
        guard model.isAppleSiriRemote else { return true }
        guard level == nil else { return true }
        return powerState == .charging || powerState == .externalPower
    }
}

enum SettingsPageBehavior {
    static let sidebarTopDragHeight: CGFloat = 5

    /// 侧边栏宽度按内容量出来：文字到左边界和到右边界都保持 `sidebarRowInset`，
    /// 不再用固定宽度把多余空白全部堆在文字右侧。
    static let sidebarRowInset: CGFloat = 15
    static let sidebarRowIconWidth: CGFloat = 18
    static let sidebarRowIconSpacing: CGFloat = 8
    static let sidebarRowFontSize: CGFloat = 13
    static let sidebarHeaderIconWidth: CGFloat = 44
    static let sidebarHeaderIconSpacing: CGFloat = 8
    static let sidebarHeaderTitleFontSize: CGFloat = 16
    static let sidebarHeaderVersionFontSize: CGFloat = 12
    static let sidebarWidthBounds: ClosedRange<CGFloat> = 104...136

    static func sidebarWidth(
        headerTitleWidth: CGFloat,
        headerVersionWidth: CGFloat,
        rowLabelWidths: [CGFloat]
    ) -> CGFloat {
        let headerTextWidth = max(headerTitleWidth, headerVersionWidth)
        let headerWidth = sidebarRowInset * 2
            + sidebarHeaderIconWidth
            + sidebarHeaderIconSpacing
            + headerTextWidth
        let rowWidth = (rowLabelWidths.max() ?? 0)
            + sidebarRowInset * 2
            + sidebarRowIconWidth
            + sidebarRowIconSpacing
        let natural = max(headerWidth, rowWidth).rounded(.up)
        return min(max(natural, sidebarWidthBounds.lowerBound), sidebarWidthBounds.upperBound)
    }

    /// 与 `SettingsSidebarRow`、侧边栏页头一致的字重，用于预估文字宽度。
    static func sidebarTextWidth(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .semibold
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    /// 侧边栏页头使用品牌字体（Oxanium），宽度必须按同一字体测量，否则会低估。
    static func sidebarHeaderTextWidth(_ text: String) -> CGFloat {
        let font = NSFont(name: "Oxanium-SemiBold", size: sidebarHeaderTitleFontSize)
            ?? NSFont.systemFont(ofSize: sidebarHeaderTitleFontSize, weight: .semibold)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    static let sidebarSectionOrder: [SettingsSection] = [
        .mapping,
        .applications,
        .macros,
        .buttonProfiles,
        .membership,
        .connection,
        .transcripts,
        .privateFeature,
        .about,
        .statistics,
    ]

    static func sidebarSections(
        privateFeatureVisible: Bool,
        macroFeatureVisible: Bool,
        buttonProfilesVisible: Bool,
        membershipVisible: Bool,
        supplementalPageIDs: [String] = []
    ) -> [SettingsSection] {
        // 补充页插在固定入口之后；「按键 / APP 适配」属于最前面的固定入口。
        let sections = Array(sidebarSectionOrder.prefix(5)) + supplementalPageIDs.map(SettingsSection.supplemental) + Array(sidebarSectionOrder.dropFirst(5))
        return sections.filter {
            switch $0 {
            case .privateFeature: privateFeatureVisible
            case .macros: macroFeatureVisible
            case .buttonProfiles: buttonProfilesVisible
            case .membership: membershipVisible
            default: true
            }
        }
    }

    static func initialSection(
        requestedSection: SettingsSection?,
        privateFeatureVisible: Bool,
        macroFeatureVisible: Bool,
        buttonProfilesVisible: Bool,
        membershipVisible: Bool
    ) -> SettingsSection {
        requestedSection ?? sidebarSections(
            privateFeatureVisible: privateFeatureVisible,
            macroFeatureVisible: macroFeatureVisible,
            buttonProfilesVisible: buttonProfilesVisible,
            membershipVisible: membershipVisible
        ).first ?? .about
    }

    static func visibleSection(for requestedSection: SettingsSection) -> SettingsSection {
        requestedSection == .permissions ? .about : requestedSection
    }

    static func showsUpdateBadge(
        for section: SettingsSection,
        hasUnseenUpdate: Bool
    ) -> Bool {
        section == .about && hasUnseenUpdate
    }

    static func marksUpdateAsSeen(whenSelecting section: SettingsSection) -> Bool {
        section == .about
    }

    static func sidebarAccountTitle(accountDisplayName: String?, loginTitle: String) -> String {
        guard let accountDisplayName else { return loginTitle }
        let title = accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? loginTitle : title
    }

    static func permissionAction(
        for permission: SettingsPermissionKind,
        isGranted: Bool
    ) -> SettingsPermissionAction {
        switch permission {
        case .bluetooth:
            .openSystemSettings("x-apple.systempreferences:com.apple.BluetoothSettings")
        case .inputMonitoring:
            isGranted
                ? .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                )
                : .request
        case .accessibility:
            isGranted
                ? .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                : .request
        }
    }

    static func perform(
        _ action: SettingsPermissionAction,
        requestPermission: () -> Void,
        openSystemSettings: (String) -> Void
    ) {
        switch action {
        case .request:
            requestPermission()
        case let .openSystemSettings(url):
            openSystemSettings(url)
        }
    }

    static func copyDiagnosticSummary(
        _ snapshot: SettingsDiagnosticSnapshot,
        writeToPasteboard: (String) -> Void,
        writeAuditLog: (String) -> Void
    ) {
        writeToPasteboard(snapshot.summary)
        writeAuditLog(snapshot.auditLog)
    }
}

private enum BrandFont {
    static func sidebarTitleFont(size: CGFloat) -> Font {
        _ = font
        return NSFont(name: "Oxanium-SemiBold", size: size).map(Font.init)
            ?? .system(size: size, weight: .semibold)
    }

    static let font: Font = {
        if let url = RemoteMicResourceBundle.mainOrDevelopment.url(
            forResource: "oxanium-semibold",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: "Oxanium-SemiBold", size: 18).map(Font.init)
            ?? .system(size: 18, weight: .semibold)
    }()
}

extension BridgeAppModel: WebRemoteSessionModel {}

private enum PermissionVisualState {
    case granted
    case pending

    func title(using localization: LocalizationStore) -> String {
        switch self {
        case .granted: return localization.text("permission.status.enabled")
        case .pending: return localization.text("permission.status.pending")
        }
    }

    var tint: Color {
        switch self {
        case .granted: return .green
        case .pending: return .orange
        }
    }
}

private final class ScrollRegionLearningSession {
    var point: CGPoint?
    var monitor: Any?

    static func finish(_ session: ScrollRegionLearningSession) {
        if let monitor = session.monitor { NSEvent.removeMonitor(monitor) }
        session.monitor = nil
    }
}

private struct ShortcutEditingTarget: Identifiable, Equatable {
    let button: RemoteButton
    let trigger: ButtonTrigger

    var id: String { "\(button.rawValue)-\(trigger.rawValue)" }
}

private struct ShortcutCaptureFeedback: Equatable {
    enum Result: Equatable {
        case succeeded
        case failed(ShortcutCaptureStartFailure)
    }

    let contextID: String
    let result: Result
}

private enum CustomApplicationLearningState: Equatable {
    case recording
    case succeeded
    case failed
    case applicationMissing
    case openFailed

    var messageKey: String {
        switch self {
        case .recording: return "custom_application.accessibility.learning"
        case .succeeded: return "custom_application.accessibility.learn_succeeded"
        case .failed: return "custom_application.accessibility.learn_failed"
        case .applicationMissing: return "custom_application.error.not_installed"
        case .openFailed: return "custom_application.error.open_failed"
        }
    }

    var tint: Color {
        switch self {
        case .recording: return .orange
        case .succeeded: return .green
        case .failed, .applicationMissing, .openFailed: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .recording: return "timer"
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .applicationMissing, .openFailed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct ConfigurationStatus {
    let message: LocalizedMessage
    let tint: Color
    let systemImage: String
}

private enum MappingActionFilter: String, CaseIterable, Identifiable {
    case all
    case basicKeys
    case systemAndMedia
    case custom
    case commonPhrases
    case applications

    var id: String { rawValue }

    static var visibleCases: [Self] {
        [.basicKeys, .systemAndMedia, .custom, .commonPhrases, .applications]
    }

    var localizationKey: String {
        switch self {
        case .all: return "button_mapping.action_filter.all"
        case .basicKeys: return ButtonActionCategory.basicKeys.localizationKey
        case .systemAndMedia: return ButtonActionCategory.systemAndMedia.localizationKey
        case .custom: return ButtonActionCategory.custom.localizationKey
        case .commonPhrases: return ButtonActionCategory.commonPhrases.localizationKey
        case .applications: return ButtonActionCategory.applications.localizationKey
        }
    }

    func includes(_ category: ButtonActionCategory) -> Bool {
        switch self {
        case .all:
            return true
        case .basicKeys:
            return category == .basicKeys
        case .systemAndMedia:
            return category == .systemAndMedia
        case .custom:
            return category == .custom
        case .commonPhrases:
            return category == .commonPhrases
        case .applications:
            return category == .applications
        }
    }
}

enum MappingPermissionPolicy {
    static func requiresPrompt(
        enabled: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        enabled && (!inputMonitoringGranted || !accessibilityGranted)
    }
}

struct VersionTapRevealCounter {
    private(set) var tapCount = 0
    let requiredTaps: Int

    init(requiredTaps: Int = 5) {
        self.requiredTaps = max(1, requiredTaps)
    }

    mutating func registerTap() -> Bool {
        tapCount += 1
        guard tapCount >= requiredTaps else { return false }
        tapCount = 0
        return true
    }
}

private struct StatisticsColumnsLayout: Layout {
    private let spacing: CGFloat = 14

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }

        let width = proposal.width ?? 0
        let availableWidth = max(0, width - spacing)
        let rankingWidth = max(360, availableWidth * 0.42)
        let rightWidth = max(0, availableWidth - rankingWidth)
        let leftSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: rankingWidth, height: nil)
        )
        let rightSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: rightWidth, height: nil)
        )
        return CGSize(width: width, height: max(leftSize.height, rightSize.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        let availableWidth = max(0, bounds.width - spacing)
        let rankingWidth = max(360, availableWidth * 0.42)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: rankingWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + rankingWidth + spacing, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: max(0, availableWidth - rankingWidth),
                height: bounds.height
            )
        )
    }
}

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var privateFeature: PrivateFeatureIntegration
    @State private var preservesMappingContextOnNavigation = false
    @State private var editingMappingProfileID: UUID?
    /// 选中方案只是**浏览**：方案行右侧的「编辑」才是进入可写态的开关。
    @State private var isEditingMappingProfile = false
    /// 点「编辑」但会员未开通时，把唯一的会员入口（私有模块那个「会员功能，点击开通」）
    /// 挂在方案行下方，而不是在仓库里另画一个开通按钮。
    @State private var showsProfileMembershipNotice = false
    @State private var isSavingMappingProfile = false
    @State private var savingMappingProfileName = ""
    @State private var savingMappingProfileSwitches = true
    @State private var savingMappingProfileError: String?
    @State private var mappingMacroSearch = ""
    @State private var mappingVoiceSettingsRequest = 0
    /// 语音键不属于可映射的普通按键：它的设置面板只在用户点击画布上的语音键之后出现，
    /// 并且与普通按键的编辑器互斥，页面上任何时刻只留一份正在编辑的设置。
    @State private var isMappingVoiceSettingsPresented = false

    @ObservedObject private var macroFeature: MacroFeatureIntegration
    @ObservedObject private var buttonProfileImportRequests: ButtonProfileImportRequestStore
    @ObservedObject private var membershipFeature: MembershipFeatureIntegration
    @ObservedObject private var loginItemService: LoginItemService
    @ObservedObject private var updateInformation: UpdateInformationStore
    @ObservedObject private var hardwareAnnouncements: HardwareAnnouncementStore
    @EnvironmentObject private var localization: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme

    private let checkForUpdates: () -> Void
    private let refreshUpdateInformation: () -> Void
    private let setDockIconVisible: (Bool) -> Void
    private let setStatusBarIconVisible: (Bool) -> Void
    private let syncEntryPointVisibility: () -> Void
    private let appIconCatalog: AppIconCatalog
    private let minimumContentSize: CGSize
    private let initialShortcutPickerShowsKeyboard: Bool
    private let initialMappingScrollsToGestureTiming: Bool
    private let sidebarAccountDisplayName: String?

    @State private var supplementalSettings = SupplementalSettingsIntegration()
    @State private var selectedSection: SettingsSection
    @State private var selectedRemoteButton: RemoteButton = .ok
    @State private var selectedSiriRemoteControlID = "select"
    @State private var selectedChromecastControlID = "select"
    @State private var selectedStatisticsDate: Date?
    @State private var mappingEditingTarget: ShortcutEditingTarget?
    @State private var mappingHoldEditingButton: RemoteButton?
    /// Clicking the same hold entry twice must still bring the editor into view, so the
    /// scroll is driven by a request token instead of the selection identity.
    @State private var mappingEditorScrollTarget = "mapping-action-editor"
    /// 按键页内容滚动后，方案行下边缘要有一条阴影提示「下面还有内容」。
    @State private var mappingContentIsScrolled = false
    @State private var mappingEditorScrollRequest = 0
    @State private var mappingActionFilter: MappingActionFilter = .all
    @State private var gestureTimingDraft = RemoteButtonGestureTiming()
    @State private var gestureTimingDraftModel: XiaomiRemoteModel?
    @State private var gestureTimingSaveConfirmed = false
    @State private var isCapturingMacMicrophoneShortcut = false
    @State private var isHoveringMacMicrophoneButton = false
    @State private var shortcutCaptureTarget: ShortcutEditingTarget?
    @State private var applicationShortcutCaptureProfileID: UUID?
    /// 「App 输入框和滚动」里正在配置哪个 App。它只决定编辑对象，不写按键绑定：
    /// 聚焦与翻页滚动按 App 生效，App 在前台即可使用，和「打开具体 APP」动作无关。
    /// 「APP 适配」页当前展开的 APP；与按键页的编辑对象完全分开。
    @State private var applicationDetailProfileID: UUID?
    @State private var shortcutCaptureFeedback: ShortcutCaptureFeedback?
    @State private var customApplicationLearningStates: [UUID: CustomApplicationLearningState] = [:]
    @State private var scrollRegionCountdowns: [UUID: Int] = [:]
    @State private var scrollRegionMessages: [UUID: String] = [:]
    @State private var bluetoothAuthorization = CBManager.authorization
    @State private var inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
    @State private var accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    @State private var configurationExportSequence = 0
    @State private var configurationImportSequence = 0
    @State private var configurationStatus: ConfigurationStatus?
    @State private var isClearTrustedPhonesConfirmationPresented = false
    @State private var isWebRemoteSessionPresented = false
    @State private var isAppStoreLinkCopied = false
    @State private var isMappingPermissionAlertPresented = false
    @State private var isWaitingForMappingPermissions = false
    @State private var expandedShareSection: SettingsSection?
    @State private var versionTapRevealCounter = VersionTapRevealCounter()

    init(
        model: BridgeAppModel,
        buttonProfileImportRequests: ButtonProfileImportRequestStore = ButtonProfileImportRequestStore(),
        updateInformation: UpdateInformationStore,
        hardwareAnnouncements: HardwareAnnouncementStore = HardwareAnnouncementStore(),
        checkForUpdates: @escaping () -> Void = {},
        refreshUpdateInformation: @escaping () -> Void = {},
        setDockIconVisible: @escaping (Bool) -> Void = { _ in },
        setStatusBarIconVisible: @escaping (Bool) -> Void = { _ in },
        syncEntryPointVisibility: @escaping () -> Void = {},
        appIconCatalog: AppIconCatalog? = nil,
        initialSection: SettingsSection? = nil,
        initialShareSection: SettingsSection? = nil,
        initialMappingEditingButton: RemoteButton? = nil,
        initialMappingHoldEditingButton: RemoteButton? = nil,
        initialMappingEditingTrigger: ButtonTrigger = .singleClick,
        initialShortcutPickerShowsKeyboard: Bool = false,
        initialMappingScrollsToGestureTiming: Bool = false,
        initialMappingVoiceSettingsPresented: Bool = false,
        supplementalSettings: SupplementalSettingsIntegration? = nil,
        sidebarAccountDisplayName: String? = nil,
        minimumContentSize: CGSize = CGSize(width: 980, height: 732)
    ) {
        self.model = model
        self.buttonProfileImportRequests = buttonProfileImportRequests
        settings = model.settings
        privateFeature = model.privateFeature
        macroFeature = model.macroFeature
        membershipFeature = model.membershipFeature
        loginItemService = model.loginItemService
        self.updateInformation = updateInformation
        self.hardwareAnnouncements = hardwareAnnouncements
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.setStatusBarIconVisible = setStatusBarIconVisible
        self.syncEntryPointVisibility = syncEntryPointVisibility
        self.appIconCatalog = appIconCatalog ?? .live()
        self.minimumContentSize = minimumContentSize
        self.initialShortcutPickerShowsKeyboard = initialShortcutPickerShowsKeyboard
        self.initialMappingScrollsToGestureTiming = initialMappingScrollsToGestureTiming
        self.sidebarAccountDisplayName = sidebarAccountDisplayName
        _supplementalSettings = State(initialValue: supplementalSettings ?? SupplementalSettingsIntegration())
        _selectedSection = State(initialValue: SettingsPageBehavior.initialSection(
            requestedSection: initialSection,
            privateFeatureVisible: model.privateFeature.isFeatureVisible,
            macroFeatureVisible: model.macroFeature.isFeatureVisible,
            buttonProfilesVisible: model.macroFeature.isButtonProfilesVisible,
            membershipVisible: model.membershipFeature.isFeatureVisible
        ))
        _expandedShareSection = State(initialValue: initialShareSection)
        _selectedRemoteButton = State(
            initialValue: initialMappingHoldEditingButton ?? initialMappingEditingButton ?? .ok
        )
        _mappingEditingTarget = State(
            initialValue: initialMappingHoldEditingButton == nil ? initialMappingEditingButton.map {
                ShortcutEditingTarget(button: $0, trigger: initialMappingEditingTrigger)
            } : nil
        )
        _mappingHoldEditingButton = State(initialValue: initialMappingHoldEditingButton)
        _isMappingVoiceSettingsPresented = State(initialValue: initialMappingVoiceSettingsPresented)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Color(nsColor: .separatorColor)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            selectedPage
        }
        .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea())
        .environment(\.locale, localization.locale)
        .environment(\.openURL, OpenURLAction { url in
            guard url == URL(string: "sayall://membership") else { return .systemAction }
            guard membershipFeature.isFeatureVisible else { return .discarded }
            selectedSection = .membership
            membershipFeature.refreshIfNeeded()
            return .handled
        })
        .frame(
            minWidth: minimumContentSize.width,
            minHeight: minimumContentSize.height
        )
        .onAppear {
            model.setMappingPageVisible(selectedSection == .mapping)
            if selectedSection == .mapping {
                model.selectDefaultMappingRemoteIfAvailable()
            }
            model.refreshRemoteDeviceNames(reason: .page)
            refreshPermissionStates()
            loginItemService.refresh()
            macroFeature.setEditorActive(false)
            membershipFeature.refreshIfNeeded()
            routePendingButtonProfileImportIfNeeded()
        }
        .onChange(of: selectedSection) { section in
            model.setMappingPageVisible(section == .mapping)
            if isCapturingMacMicrophoneShortcut { endMacMicrophoneShortcutCapture() }
            if section != .mapping {
                model.cancelButtonGestureLearning(reason: "left_mapping_page")
            }
            if section == .mapping {
                if preservesMappingContextOnNavigation { preservesMappingContextOnNavigation = false }
                else { model.selectDefaultMappingRemoteIfAvailable() }
            }
            if section == .connection || section == .mapping {
                model.refreshRemoteDeviceNames(reason: .page)
            }
            if section != .macros, section != .buttonProfiles {
                macroFeature.setEditorActive(false)
            }
        }
        .onDisappear {
            model.setMappingPageVisible(false)
            endMacMicrophoneShortcutCapture()
            model.cancelButtonGestureLearning(reason: "settings_closed")
            macroFeature.setEditorActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            loginItemService.refresh()
            resumeCustomMappingIfPermissionsGranted()
            membershipFeature.refreshIfNeeded()
        }
        .onReceive(privateFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible, selectedSection == .privateFeature {
                selectedSection = .about
            }
        }
        .onReceive(macroFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible,
               (selectedSection == .macros ||
                (selectedSection == .buttonProfiles && !macroFeature.isButtonProfilesVisible)) {
                selectedSection = .about
            }
        }
        .onReceive(membershipFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible, selectedSection == .membership {
                selectedSection = .about
            }
        }
        // Finder requests are events. Receive them after @Published has stored
        // the value, even when SwiftUI coalesces the first page updates.
        .onReceive(buttonProfileImportRequests.$pendingRequest.receive(on: RunLoop.main)) { _ in
            routePendingButtonProfileImportIfNeeded()
        }
        .sheet(isPresented: $isWebRemoteSessionPresented) {
            webRemoteSessionView
        }
        .alert(
            localization.text("connection.trusted_devices.clear_confirm.title"),
            isPresented: $isClearTrustedPhonesConfirmationPresented
        ) {
            Button(
                localization.text("connection.trusted_devices.clear"),
                role: .destructive
            ) {
                settings.clearTrustedPhoneIdentities()
            }
            Button(localization.text("common.action.cancel"), role: .cancel) {}
        } message: {
            Text("connection.trusted_devices.clear_confirm.message")
        }
        .alert(
            localization.text("button_mapping.permission_prompt.title"),
            isPresented: $isMappingPermissionAlertPresented
        ) {
            Button("button_mapping.permission_prompt.open") {
                isWaitingForMappingPermissions = true
                selectedSection = .permissions
                model.applyHIDSettings()
            }
            Button("common.action.cancel", role: .cancel) {
                settings.customMappingEnabled = false
                model.applyHIDSettings()
            }
        } message: {
            Text("button_mapping.permission_prompt.message")
        }
    }

    private var webRemoteSessionView: some View {
        WebRemoteSessionView(
            model: model,
            localization: WebRemoteSessionLocalization(
                locale: localization.locale,
                text: localization.text
            ),
            membershipRequiredView: membershipFeature.membershipRequiredView(remoteAuthorizationDenied: true) {
                isWebRemoteSessionPresented = false
                selectedSection = .membership
                membershipFeature.refreshIfNeeded()
            },
            onDiagnostic: { AppLogger.shared.write($0) }
        )
    }

    /// 侧边栏宽度只由最宽的一行（或页头）决定，文字左右留白保持相等。
    private var sidebarWidth: CGFloat {
        let rowLabelWidths = visibleSections.map { section in
            SettingsPageBehavior.sidebarTextWidth(
                sidebarTitleString(section),
                size: SettingsPageBehavior.sidebarRowFontSize
            ) + (SettingsPageBehavior.showsUpdateBadge(
                for: section,
                hasUnseenUpdate: updateInformation.hasUnseenUpdate
            ) ? 12 : 0)
        }
        return SettingsPageBehavior.sidebarWidth(
            headerTitleWidth: SettingsPageBehavior.sidebarHeaderTextWidth("SayAll"),
            headerVersionWidth: SettingsPageBehavior.sidebarTextWidth(
                currentVersion,
                size: SettingsPageBehavior.sidebarHeaderVersionFontSize,
                weight: .regular
            ),
            rowLabelWidths: rowLabelWidths
        )
    }

    private func sidebarTitleString(_ section: SettingsSection) -> String {
        if section == .statistics {
            return SettingsPageBehavior.sidebarAccountTitle(
                accountDisplayName: membershipFeature.accountDisplayName ?? sidebarAccountDisplayName,
                loginTitle: localization.text("settings.section.login")
            )
        }
        if section == .privateFeature || section == .macros || section == .buttonProfiles
            || section == .membership || section.supplementalID != nil {
            return sectionTitle(section)
        }
        return localization.text(section.titleKey)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: SettingsPageBehavior.sidebarTopDragHeight)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: SettingsPageBehavior.sidebarHeaderIconSpacing) {
                Image(nsImage: appIconCatalog.image(for: settings.appIconIdentifier))
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: SettingsPageBehavior.sidebarHeaderIconWidth,
                        height: SettingsPageBehavior.sidebarHeaderIconWidth
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: -2) {
                    Text(verbatim: "SayAll")
                        .font(BrandFont.sidebarTitleFont(size: SettingsPageBehavior.sidebarHeaderTitleFontSize))
                    Text(currentVersion)
                        .font(.system(size: SettingsPageBehavior.sidebarHeaderVersionFontSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, SettingsPageBehavior.sidebarRowInset)
            .padding(.top, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 75, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(visibleSections.filter { $0 != .statistics }) { section in
                        sidebarButton(section)
                    }
                }
            }
            if visibleSections.contains(.statistics) {
                sidebarButton(.statistics)
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) {
                        Color(nsColor: .separatorColor)
                            .frame(height: 0.5)
                            .padding(.horizontal, 12)
                    }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var supplementalPages: [SupplementalSettingsPage] {
        supplementalSettings.pages(localeIdentifier: localization.locale.identifier)
    }

    private var visibleSections: [SettingsSection] {
        SettingsPageBehavior.sidebarSections(
            privateFeatureVisible: privateFeature.isFeatureVisible,
            macroFeatureVisible: macroFeature.isFeatureVisible,
            buttonProfilesVisible: macroFeature.isButtonProfilesVisible,
            membershipVisible: membershipFeature.isFeatureVisible,
            supplementalPageIDs: supplementalPages.map(\.id)
        )
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        let isSelected = (selectedSection == .commonPhrases ? .mapping : selectedSection) == section
        return Button {
            selectSidebarSection(section)
        } label: {
            SettingsSidebarRow(
                title: sidebarTitle(section),
                systemImage: sectionSystemImage(section),
                showsUpdateBadge: SettingsPageBehavior.showsUpdateBadge(
                    for: section,
                    hasUnseenUpdate: updateInformation.hasUnseenUpdate
                )
            )
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .compatibilityFocusEffectDisabled()
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(
            SettingsPageBehavior.showsUpdateBadge(
                for: section,
                hasUnseenUpdate: updateInformation.hasUnseenUpdate
            ) ? Text("settings.update_badge.accessibility_value") : Text("")
        )
    }

    private func sidebarTitle(_ section: SettingsSection) -> Text {
        if section == .statistics {
            return Text(SettingsPageBehavior.sidebarAccountTitle(
                accountDisplayName: membershipFeature.accountDisplayName ?? sidebarAccountDisplayName,
                loginTitle: localization.text("settings.section.login")
            ))
        }
        if section == .privateFeature || section == .macros || section == .buttonProfiles
            || section == .membership || section.supplementalID != nil {
            return Text(sectionTitle(section))
        }
        return Text(section.title)
    }

    private func selectSidebarSection(_ section: SettingsSection) {
        selectedSection = section
        if SettingsPageBehavior.marksUpdateAsSeen(whenSelecting: section) {
            updateInformation.markAvailableUpdateSeen()
        }
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch SettingsPageBehavior.visibleSection(for: selectedSection) {
        case .connection:
            connectionPage
        case .privateFeature:
            if privateFeature.isFeatureVisible {
                privateFeature.settingsView()
            } else {
                aboutPage
            }
        case .macros:
            if macroFeature.isFeatureVisible {
                VStack(spacing: 0) {
                    macroFeature.settingsView(
                        selectedRemoteProfileID: settings.selectedRemoteProfileID,
                        remoteModel: settings.selectedRemoteProfile?.model,
                        configuredActionTitle: { buttonValue, triggerValue in
                            guard let button = RemoteButton(rawValue: buttonValue),
                                  let trigger = ButtonTrigger(rawValue: triggerValue)
                            else { return nil }
                            return mappingActionSummary(for: button, trigger: trigger)
                        },
                        settings: settings,
                        onEditBinding: { device, profile, button, trigger in
                            preservesMappingContextOnNavigation = true
                            if let device { settings.selectRemoteProfile(device) }
                            // 从组合动作页点进来的同样是「编辑这份方案」的意图：走同一个解锁入口，
                            // 会员没通过时停在只读预览，不会借这条路绕过限制。
                            if let profile {
                                openMappingProfileForEditing(profile)
                            } else {
                                selectMappingProfile(nil)
                            }
                            mappingHoldEditingButton = button
                            mappingEditingTarget = ShortcutEditingTarget(button: button, trigger: trigger)
                            selectedSection = .mapping
                        },
                        onBindToButton: {
                            preservesMappingContextOnNavigation = true
                            mappingEditingTarget = nil
                            mappingHoldEditingButton = nil
                            mappingActionFilter = .custom
                            mappingMacroSearch = ""
                            selectedSection = .mapping
                        }
                    )
                }
            } else {
                aboutPage
            }
        case .buttonProfiles:
            Group {
                if macroFeature.isButtonProfilesVisible {
                    VStack(spacing: 0) {
                        macroFeature.buttonProfilesView(
                            selectedRemoteProfileID: settings.selectedRemoteProfileID,
                            remoteModel: settings.selectedRemoteProfile?.model,
                            hostActionSections: buttonProfileHostActionSections,
                            settings: settings,
                            onEditKeys: { profile in
                                preservesMappingContextOnNavigation = true
                                openMappingProfileForEditing(profile)
                                selectedSection = .mapping
                            },
                            onChooseCustomApplication: { completion in
                                chooseCustomApplicationForButtonProfile { id, displayName, payload in
                                    completion(id, displayName, payload)
                                }
                            },
                            chromecastReservedControlIDs: buttonProfilesChromecastReservedControls,
                            membershipNotice: membershipFeature.membershipRequiredView(forButtonProfiles: true) {
                                selectedSection = .membership
                                membershipFeature.refreshIfNeeded()
                            }
                        )
                    }
                } else {
                    aboutPage
                }
            }
            .task(id: buttonProfileImportRequests.pendingRequest?.operationID) {
                // Submit only after this page has mounted its import observer.
                consumePendingButtonProfileImportIfNeeded()
            }
        case .applications:
            applicationsPage
        case .membership:
            if membershipFeature.isFeatureVisible {
                membershipFeature.settingsView()
            } else {
                aboutPage
            }
        case .mapping:
            if settings.selectedRemoteProfile?.model.isAppleSiriRemote == true {
                #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
                siriRemoteMappingPage
                #else
                mappingPage
                #endif
            } else if settings.selectedRemoteProfile?.model.isChromecastRemote == true {
                #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
                chromecastMappingPage
                #else
                mappingPage
                #endif
            } else {
                mappingPage
            }
        case .statistics:
            statisticsPage
        case .commonPhrases:
            if membershipFeature.canUseCommonPhrases {
                membershipFeature.commonPhrasesSettingsView(
                    onOpenMembership: {
                        selectedSection = .membership
                        membershipFeature.refreshIfNeeded()
                    },
                    onReturn: { selectedSection = .mapping }
                )
            } else {
                membershipFeature.membershipRequiredView {
                    selectedSection = .membership
                    membershipFeature.refreshIfNeeded()
                }
            }
        case .transcripts:
            transcriptHistoryPage
        case .permissions:
            aboutPage
        case .about:
            aboutPage
                .task(id: buttonProfileImportRequests.pendingRequest?.operationID) {
                    consumePendingButtonProfileImportIfNeeded()
                }
        default:
            if let pageID = selectedSection.supplementalID,
               let content = supplementalSettings.view(pageID: pageID, localeIdentifier: localization.locale.identifier) {
                content
            } else { aboutPage }

        }
    }

    private func settingsPage<Header: View, Content: View>(
        contentPadding: CGFloat = 22,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .padding(contentPadding)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .compatibilityScrollEdgeEffect()
        }
    }

    private var connectionPage: some View {
        settingsPage {
            PageHeader(title: localization.text("connection.page.title"))
        } content: {
            if let warning = model.voiceKeyCompatibilityWarning {
                voiceKeyCompatibilityWarningPanel(warning)
            }
            CompatibilityGlassContainer(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    connectionDevicePanel
                        .frame(width: 230)
                    VStack(spacing: 14) {
                        phoneConnectionsPanel
                        audioSettingsPanel
                        audioCompatibilityPanel
                        // Chromecast 连接卡片已按产品要求移除：启用开关默认常开，
                        // 语音键模式在按键页底部，状态见侧边栏「连接」的设备列表。
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear {
            model.refreshVoiceKeyCompatibilityWarning()
        }
    }

    private func voiceKeyCompatibilityWarningPanel(
        _ warning: VoiceKeyCompatibilityWarning
    ) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("connection.voice_key_compatibility.title")
                        .font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text(LocalizedMessage(warning.messageKey).text(using: localization))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("connection.voice_key_compatibility.recheck") {
                    model.recheckRemoteInput()
                }
                .compatibilityButtonStyle(.standard)
            }
        }
    }

    #if SAYALL_CHROMECAST_ENABLED
    /// 语音键模式选择器。挂在按键页靠下的位置（仅 Chromecast 档案的按键页显示）；
    /// 从连接设置页迁移过来，避免同一控件出现在两处。
    private var chromecastVoiceModeSection: some View {
        // 选项只列设备**自报**支持的模式：自报不支持「按一次说话」时，这个选项根本不出现。
        let capabilities = model.selectedRemoteVoiceCapabilities
        let offeredModes = ChromecastVoiceMode.allCases.filter { mode in
            mode != .toggle || capabilities.supportsToggleVoiceRecording
        }
        return VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("chromecast.mode.title")
                .font(.system(size: 13, weight: .medium))

            Picker("", selection: Binding(
                get: { model.effectiveChromecastVoiceMode },
                set: { newValue in
                    settings.chromecastVoiceMode = newValue
                    model.applyChromecastSettings()
                }
            )) {
                ForEach(offeredModes) { mode in
                    Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!settings.chromecastEnabled)

            Text(LocalizedStringKey(model.effectiveChromecastVoiceMode.detailLocalizationKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    #endif

    private var connectionMembershipRequiredView: some View {
        membershipFeature.membershipRequiredView {
            selectedSection = .membership
            membershipFeature.refreshIfNeeded()
        }
    }

    private var phoneConnectionsPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("connection.phone.section_title")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("connection.phone.ios_title")
                                .font(.subheadline.weight(.semibold))
                            Text("connection.phone.ios_help")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                Link(destination: AppLinks.iOSAppStore(for: localization.locale)) {
                                    Label("connection.phone.app_store_open", systemImage: "arrow.up.right.square")
                                }
                                .compatibilityButtonStyle(.standard)

                                Button {
                                    copyIOSAppStoreLink()
                                } label: {
                                    Label(
                                        localization.text(
                                            isAppStoreLinkCopied
                                                ? "common.status.copied"
                                                : "common.action.copy_link"
                                        ),
                                        systemImage: isAppStoreLinkCopied ? "checkmark" : "doc.on.doc"
                                    )
                                }
                                .compatibilityButtonStyle(.standard)
                            }
                        }

                        Spacer(minLength: 8)

                        Text(localization.text(
                            model.isPhoneRemoteConnected
                                ? "connection.phone.connected"
                                : model.isPhoneRemoteConnectionEnabled
                                    ? "connection.phone.enabled"
                                    : "connection.phone.not_enabled"
                        ))
                        .font(.caption)
                        .foregroundStyle(model.isPhoneRemoteConnected
                            ? Color.green
                            : model.isPhoneRemoteConnectionEnabled ? .orange : .secondary)
                        .lineLimit(1)

                        if membershipFeature.canStartCompanionConnection {
                            Button(
                                model.isPhoneRemoteConnected
                                    ? "connection.phone.disconnect"
                                    : model.isPhoneRemoteConnectionEnabled
                                        ? "connection.phone.cancel_waiting"
                                        : "connection.phone.connect"
                            ) {
                                model.togglePhoneRemoteConnection()
                            }
                            .compatibilityButtonStyle(.standard)
                            .controlSize(.regular)
                        } else {
                            connectionMembershipRequiredView
                        }
                    }

                    if membershipFeature.canStartCompanionConnection, let invitation = model.phoneRemoteInvitation {
                        Divider()
                        PhoneRemoteInvitationCard(invitation: invitation)
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("connection.watch.title")
                            .font(.subheadline.weight(.semibold))
                        Text("connection.watch.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Text(localization.text(
                        model.isWatchRemoteConnected
                            ? "connection.watch.connected"
                            : model.isWatchRemoteConnectionEnabled
                                ? "connection.watch.enabled"
                                : "connection.phone.not_enabled"
                    ))
                    .font(.caption)
                    .foregroundStyle(model.isWatchRemoteConnected
                        ? Color.green
                        : model.isWatchRemoteConnectionEnabled ? .orange : .secondary)
                    .lineLimit(1)

                    if membershipFeature.canStartCompanionConnection {
                        Button(
                            model.isWatchRemoteConnected
                                ? "connection.watch.disconnect"
                                : model.isWatchRemoteConnectionEnabled
                                    ? "connection.watch.cancel_waiting"
                                    : "connection.watch.connect"
                        ) {
                            model.toggleWatchRemoteConnection()
                        }
                        .compatibilityButtonStyle(.standard)
                        .controlSize(.regular)
                    } else {
                        connectionMembershipRequiredView
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("connection.web.title")
                            .font(.subheadline.weight(.semibold))
                        Text("connection.web.help_short")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                    Text(webRemoteStatusText)
                        .font(.caption)
                        .foregroundStyle(webRemoteStatusTint)
                        .lineLimit(1)
                    if membershipFeature.canStartCompanionConnection || model.webRemoteState.isEnabled {
                        Button(
                            model.webRemoteState.isEnabled
                                ? "connection.web.show_qr"
                                : "connection.web.connect"
                        ) {
                            requestWebRemoteSession()
                        }
                        .compatibilityButtonStyle(.standard)
                        .controlSize(.regular)
                    } else {
                        connectionMembershipRequiredView
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Label(
                        LocalizedMessage(
                            "connection.trusted_devices.count_long",
                            arguments: [String(settings.trustedPhoneIdentityFingerprints.count)]
                        ).text(using: localization),
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("connection.trusted_devices.clear") {
                        isClearTrustedPhonesConfirmationPresented = true
                    }
                    .compatibilityButtonStyle(.standard)
                    .disabled(settings.trustedPhoneIdentityFingerprints.isEmpty)
                }
            }
        }
    }

    private var connectionDevicePanel: some View {
        GlassPanel {
            VStack(spacing: 16) {
                remoteDeviceSelector(vertical: true)

                connectionRemotePhoto

                VStack(alignment: .leading, spacing: 9) {
                    connectionStatusLine(
                        symbol: "antenna.radiowaves.left.and.right",
                        text: model.connectionStatus.text(using: localization),
                        tint: connectionTint
                    )
                    connectionStatusLine(
                        symbol: "waveform",
                        text: localization.text(
                            model.isStreaming
                                ? "connection.status.voice_streaming"
                                : "connection.status.voice_ready"
                        ),
                        tint: model.isStreaming ? .orange : .blue
                    )
                    connectionStatusLine(
                        symbol: "mic.fill",
                        text: model.voiceShortcutStatus.text(using: localization),
                        tint: .blue
                    )
                }

                Button {
                    model.reconnect()
                } label: {
                    Text("connection.action.reconnect")
                        .foregroundStyle(.white)
                }
                    .compatibilityButtonStyle(.prominent)
                    .compatibilityRoundedButtonBorderShape(radius: 10)
                    .frame(maxWidth: .infinity)

            }
        }
    }

    @ViewBuilder
    private var connectionRemotePhoto: some View {
        if settings.selectedRemoteProfile?.model.isAppleSiriRemote == true {
            #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
            SiriRemoteConnectionPhoto()
            #else
            UnrecognizedRemotePhoto()
                .frame(width: 82, height: 166)
            #endif
        } else if settings.selectedRemoteProfile?.model.isChromecastRemote == true {
            #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
            ChromecastConnectionPhoto()
            #else
            UnrecognizedRemotePhoto()
                .frame(width: 82, height: 166)
            #endif
        } else if let model = settings.selectedRemoteProfile?.model,
                  let resource = VoiceRemoteCatalog.photoResource(for: model) {
            // 型号在目录里 → 用目录指定的那张真机图。
            RemoteCatalogPhoto(resourceName: resource)
                .frame(width: 82, height: 166)
        } else {
            // 型号目录里没有这个型号（.unknown、或还没选设备）：**不套用任何一款真机图**。
            // App 里每张图都对应一个验证过的型号，给未识别设备画上 RC003 等于界面声称
            // 支持一台从未验证过的遥控器。
            UnrecognizedRemotePhoto()
                .frame(width: 82, height: 166)
        }
    }

    private func connectionStatusLine(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioSettingsPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 13) {
                Text("audio.voice_output.section_title")
                    .font(.headline)

                macMicrophoneControls
                Divider()

                HStack(spacing: 14) {
                    Text("audio.output.title")
                        .frame(width: 92, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { settings.selectedAudioDeviceUID },
                        set: { value in
                            settings.selectedAudioDeviceUID = value
                            model.applyAudioSettings()
                        }
                    )) {
                        Text("audio.output.disabled").tag("")
                        ForEach(model.audioDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 270)
                    .disabled(model.macMicrophoneState.isActive)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 14) {
                        Text("audio.gain.title")
                            .frame(width: 92, alignment: .leading)
                        Slider(value: Binding(
                            get: { settings.gainDB },
                            set: { settings.gainDB = $0 }
                        ), in: 0...24, step: 1)
                        Text("\(Int(settings.gainDB)) dB")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 54, alignment: .trailing)
                    }

                    Text("audio.gain.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 106)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("audio.status.title")
                        .frame(width: 92, alignment: .leading)
                    Spacer(minLength: 10)
                    Text(model.audioStatus.text(using: localization))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 10) {
                    Button {
                        model.refreshAudioDevices()
                    } label: {
                        Text("audio.action.refresh_devices")
                    }
                        .compatibilityButtonStyle(.standard)
                }

                Text("audio.output.privacy_help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var macMicrophoneControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                Text("audio.mac_microphone.input").frame(width: 92, alignment: .leading)
                Group {
                    if model.macMicrophoneDevices.count > 1 ||
                        !model.macMicrophoneDevices.contains(where: { $0.uid == settings.macMicrophoneInputUID }) {
                        Picker("audio.mac_microphone.input", selection: $settings.macMicrophoneInputUID) {
                            Text("audio.mac_microphone.choose").tag("")
                            ForEach(model.macMicrophoneDevices, id: \.uid) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.macMicrophoneState.isActive)
                    } else {
                        Text(model.macMicrophoneDevices.first?.name ?? "")
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 50, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                .help(model.macMicrophoneDevices.first(where: { $0.uid == settings.macMicrophoneInputUID })?.name ?? "")
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.macMicrophoneState == .recording ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(LocalizedStringKey(model.macMicrophoneState == .armed || model.macMicrophoneState.isActive
                        ? model.macMicrophoneState.statusKey : "audio.mac_microphone.idle"))
                        .font(.system(size: 12))
                        .foregroundStyle(model.macMicrophoneState == .recording ? Color.green : Color.secondary)
                }
                .fixedSize()
                Button {
                    endMacMicrophoneShortcutCapture()
                    model.toggleMacMicrophone(from: .connectionPage)
                } label: {
                    Text(LocalizedStringKey(model.macMicrophoneButtonKey))
                }
                .compatibilityButtonStyle(.standard)
                .accessibilityHint(Text("audio.mac_microphone.help"))
                .onHover { isHoveringMacMicrophoneButton = $0 }
                .overlay(alignment: .bottom) {
                    if isHoveringMacMicrophoneButton {
                        Text("audio.mac_microphone.help")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                            )
                            .fixedSize()
                            .offset(y: -34)
                            .allowsHitTesting(false)
                            .zIndex(1)
                    }
                }
                .disabled(model.macMicrophoneState == .stopping)
                .fixedSize()
            }
            if case .failed = model.macMicrophoneState {
                Text(LocalizedStringKey(model.macMicrophoneState.statusKey))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.macMicrophoneState == .failed(.permission) || model.macMicrophoneState == .failed(.accessibility) || model.macMicrophoneState == .failed(.inputMonitoring) {
                Button("permission.action.open_settings") {
                    let pane = model.macMicrophoneState == .failed(.permission) ? "Privacy_Microphone" :
                        (model.macMicrophoneState == .failed(.inputMonitoring) ? "Privacy_ListenEvent" : "Privacy_Accessibility")
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }.compatibilityButtonStyle(.standard)
            }
            HStack(spacing: 14) {
                Text("audio.mac_microphone.shortcut")
                    .font(.system(size: 12))
                    .frame(width: 92, alignment: .leading)
                Button {
                    shortcutCaptureFeedback = nil
                    isCapturingMacMicrophoneShortcut.toggle()
                    model.suspendMacMicrophoneShortcutCapture(isCapturingMacMicrophoneShortcut)
                } label: {
                    Text(isCapturingMacMicrophoneShortcut
                        ? localization.text("common.action.cancel")
                        : settings.macMicrophoneShortcut?.displayName(using: localization)
                            ?? localization.text("audio.mac_microphone.shortcut_set"))
                }
                .compatibilityButtonStyle(.standard)
                .disabled(model.macMicrophoneState.isActive)
                if settings.macMicrophoneShortcut != nil {
                    Button("common.action.clear") {
                        endMacMicrophoneShortcutCapture()
                        model.setMacMicrophoneShortcut(nil)
                    }
                    .compatibilityButtonStyle(.standard)
                    .disabled(model.macMicrophoneState.isActive)
                }
            }
            HStack(spacing: 14) {
                Text("audio.mac_microphone.voice_key").font(.system(size: 12))
                    .frame(width: 92, alignment: .leading)
                Text(LocalizedStringKey(settings.voiceKeyMode.localizationKey)).font(.system(size: 12))
                Text(model.macMicrophoneVoiceGesture == .hold
                    ? "audio.mac_microphone.voice_hold" : "audio.mac_microphone.voice_toggle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if isCapturingMacMicrophoneShortcut {
                Text("audio.mac_microphone.shortcut_prompt").font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ShortcutCaptureView(onCapture: { shortcut in
                    endMacMicrophoneShortcutCapture()
                    model.setMacMicrophoneShortcut(shortcut)
                }, onFailure: { failure in
                    endMacMicrophoneShortcutCapture()
                    shortcutCaptureFeedback = ShortcutCaptureFeedback(contextID: "mac-microphone", result: .failed(failure))
                    AppLogger.shared.write("MAC MICROPHONE SHORTCUT phase=failed reason=\(failure)")
                }).frame(height: 1)
            }
            shortcutCaptureFeedbackView(contextID: "mac-microphone")
            if !model.macMicrophoneShortcutAvailable {
                Text("audio.mac_microphone.shortcut_unavailable")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func endMacMicrophoneShortcutCapture() {
        guard isCapturingMacMicrophoneShortcut else { return }
        isCapturingMacMicrophoneShortcut = false
        model.suspendMacMicrophoneShortcutCapture(false)
    }

    private var audioCompatibilityPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("audio.compatibility.section_title")
                            .font(.headline)
                        Text("audio.compatibility.microphone_label")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Text(model.doubaoAudioStatus.text(using: localization))
                        .font(.caption)
                        .foregroundStyle(model.hasDoubaoAudioDevice ? .green : .orange)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 10) {
                    Button(LocalizedMessage(
                        "audio.compatibility.select_microphone", arguments: [
                            DoubaoAudioDevicePolicy.device(in: model.audioDevices)?.name ?? DoubaoAudioDevicePolicy.deviceName
                        ]
                    ).text(using: localization)) { model.selectDoubaoAudioDevice() }
                        .compatibilityButtonStyle(.prominent)
                        .disabled(!model.hasDoubaoAudioDevice)
                    Button("audio.compatibility.open_install_guide") {
                        model.openDoubaoDriverInstructions(using: localization)
                    }
                    .compatibilityButtonStyle(.standard)
                }

                Text("audio.compatibility.help_plain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
    private var siriRemoteMappingPage: some View {
        hardwareMappingPage(includeSiriScrollArrow: true) {
            SiriRemoteMappingCanvas(
                selectedControlID: $selectedSiriRemoteControlID,
                activeControlIDs: model.activeAppleRemoteControlIDs,
                voiceActive: model.activeAppleRemoteControlIDs.contains("siri"),
                labels: SiriRemoteMappingCanvas.Labels(
                    voiceTitle: localization.text("siri_remote.mapping.voice.title"),
                    voiceFixed: localization.text("siri_remote.mapping.voice.fixed"),
                    voiceDetail: localization.text("siri_remote.mapping.voice.detail"),
                    missingPhoto: localization.text("siri_remote.mapping.photo.missing")
                ),
                buttonTitle: { controlID in
                    siriRemoteButton(for: controlID)?.displayName(using: localization)
                        ?? controlID
                },
                triggerTitle: { triggerID in
                    ButtonTrigger(rawValue: triggerID)?.displayName(using: localization)
                        ?? triggerID
                },
                actionSummary: { controlID, triggerID in
                    guard let button = siriRemoteButton(for: controlID),
                          let trigger = ButtonTrigger(rawValue: triggerID)
                    else { return localization.text("action.disabled") }
                    return mappingActionSummary(for: button, trigger: trigger)
                },
                holdSummary: { controlID in
                    guard let button = siriRemoteButton(for: controlID) else {
                        return localization.text("button_mapping.hold.entry")
                    }
                    return mappingHoldSummary(for: button)
                },
                reservedControlIDs: profileScopeReservedSiriControlIDs,
                onEdit: { controlID, triggerID in
                    guard let button = siriRemoteButton(for: controlID),
                          let trigger = ButtonTrigger(rawValue: triggerID)
                    else { return }
                    selectedSiriRemoteControlID = controlID
                    selectedRemoteButton = button
                    mappingActionFilter = .all
                    mappingHoldEditingButton = button
                    mappingEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: trigger
                    )
                },
                onEditHold: { controlID in
                    guard let button = siriRemoteButton(for: controlID) else { return }
                    selectedSiriRemoteControlID = controlID
                    selectedRemoteButton = button
                    mappingEditingTarget = nil
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                    mappingHoldEditingButton = button
                    requestMappingEditorScroll(focusHold: true)
                },
                onVoiceSettings: presentMappingVoiceSettings
            )
        }
    }

    private func siriRemoteButton(for controlID: String) -> RemoteButton? {
        switch controlID {
        case "power": return .power
        case "up": return .up
        case "left": return .left
        case "select": return .ok
        case "right": return .right
        case "down": return .down
        case "back": return .back
        case "tv": return .tv
        case "play_pause": return .playPause
        case "volume_up": return .volumeUp
        case "mute": return .mute
        case "volume_down": return .volumeDown
        default: return nil
        }
    }
    #endif

    #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
    /// Chromecast 按键页。
    ///
    /// 与小米/苹果按键页共用同一个页面框架（页头、设备选择器、动作编辑器、页脚），
    /// 只有中间的遥控器画布由私有包提供，因此三种遥控器的页面功能完全一致。
    private var chromecastMappingPage: some View {
        hardwareMappingPage {
            ChromecastMappingCanvas(
                selectedControlID: $selectedChromecastControlID,
                activeControlIDs: model.activeChromecastControlIDs,
                voiceActive: model.isChromecastVoiceActive,
                labels: ChromecastMappingCanvas.Labels(
                    voiceTitle: localization.text("chromecast.mapping.voice.title"),
                    voiceFixed: localization.text("chromecast.mapping.voice.fixed"),
                    voiceDetail: localization.text("chromecast.mapping.voice.detail"),
                    missingPhoto: localization.text("chromecast.mapping.photo.missing")
                ),
                buttonTitle: { controlID in
                    chromecastButton(for: controlID)?.displayName(using: localization)
                        ?? controlID
                },
                triggerTitle: { triggerID in
                    ButtonTrigger(rawValue: triggerID)?.displayName(using: localization)
                        ?? triggerID
                },
                actionSummary: { controlID, triggerID in
                    guard let button = chromecastButton(for: controlID),
                          let trigger = ButtonTrigger(rawValue: triggerID)
                    else { return localization.text("action.disabled") }
                    // 系统占用键（left/right/select）不在本 App 的映射范围内：单击槽位展示该键
                    // 在系统侧的实际行为，其余槽位无动作。行为由 macOS 配件服务（BT-AACP）产生，
                    // 详见 Testing/ChromecastVoicePitfalls.md。
                    if let control = ChromecastRemoteControl(rawValue: controlID),
                       ChromecastRemoteControl.isSystemManaged(
                           control,
                           allowSystemReservedKeys: settings.chromecastAllowSystemReservedKeys,
                           exceptions: settings.chromecastSystemReservedExceptions
                       ) {
                        guard trigger == .singleClick else { return "—" }
                        return localization.text("chromecast.mapping.system.\(controlID)")
                    }
                    return mappingActionSummary(for: button, trigger: trigger)
                },
                holdSummary: { controlID in
                    guard let button = chromecastButton(for: controlID) else {
                        return localization.text("button_mapping.hold.entry")
                    }
                    return mappingHoldSummary(for: button)
                },
                onEdit: { controlID, triggerID in
                    guard let button = chromecastButton(for: controlID),
                          let trigger = ButtonTrigger(rawValue: triggerID)
                    else { return }
                    selectedChromecastControlID = controlID
                    selectedRemoteButton = button
                    mappingActionFilter = .all
                    mappingHoldEditingButton = button
                    mappingEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: trigger
                    )
                },
                onEditHold: { controlID in
                    guard let button = chromecastButton(for: controlID) else { return }
                    selectedChromecastControlID = controlID
                    selectedRemoteButton = button
                    mappingEditingTarget = nil
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                    mappingHoldEditingButton = button
                    requestMappingEditorScroll(focusHold: true)
                },
                // 置灰表 = 默认表去掉已放开的键（主开关全放开 / 按键级豁免）；方案作用域再并入非 10 键。
                systemReservedControlIDs: ChromecastRemoteControl.canvasReservedControlIDs(
                    allowSystemReservedKeys: settings.chromecastAllowSystemReservedKeys,
                    exceptions: settings.chromecastSystemReservedExceptions
                ).union(profileScopeReservedChromecastControlIDs),
                onVoiceSettings: presentMappingVoiceSettings
            )
        }
    }

    private func chromecastButton(for controlID: String) -> RemoteButton? {
        ChromecastRemoteControl(rawValue: controlID)?.remoteButton
    }
    #endif

    private var buttonProfilesChromecastReservedControls: Set<String> {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        ChromecastRemoteControl.canvasReservedControlIDs(
            allowSystemReservedKeys: settings.chromecastAllowSystemReservedKeys,
            exceptions: settings.chromecastSystemReservedExceptions)
        #else
        ["left", "right", "select"]
        #endif
    }

    /// Asks the mapping scroll view to bring the hold editor into view. The token makes a
    /// repeated click on the same button still scroll, instead of looking like a dead control.
    private func requestMappingEditorScroll(focusHold: Bool) {
        mappingEditorScrollTarget = focusHold ? "mapping-hold-editor" : "mapping-action-editor"
        mappingEditorScrollRequest &+= 1
    }

    /// 语音键卡片：只展开语音键自己的设置面板。
    ///
    /// 语音键没有可配置的单击/双击/长按动作，所以它不打开普通按键的编辑器；反之，打开普通按键
    /// 或按住编辑器时也会收起本面板（见 `hardwareMappingPage` 的 onChange），保证点击之后页面上
    /// 只有这一份与语音键有关的设置。再点一次语音键卡片收起。
    private func presentMappingVoiceSettings() {
        mappingEditingTarget = nil
        mappingHoldEditingButton = nil
        shortcutCaptureTarget = nil
        applicationShortcutCaptureProfileID = nil
        guard !isMappingVoiceSettingsPresented else {
            isMappingVoiceSettingsPresented = false
            return
        }
        isMappingVoiceSettingsPresented = true
        mappingVoiceSettingsRequest &+= 1
    }

    private func mappingConfiguration(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction {
        if let profile = editingMappingProfileID {
            return (macroFeature.profileBinding(device: settings.selectedRemoteProfileID, profile: profile,
                button: button, trigger: trigger)
                ?? settings.configuredBaseAction(for: button, trigger: trigger))
                .normalizedForExecution
        }
        return settings.configuredBaseAction(for: button, trigger: trigger).normalizedForExecution
    }

    private func saveMappingBinding(_ configured: ConfiguredButtonAction, button: RemoteButton, trigger: ButtonTrigger) {
        // 只读预览下任何写入都必须被挡住：编辑器已经整体禁用，这里再兜一层，
        // 防止快捷键录制、恢复默认之类的旁路把数据写进别人的方案。
        guard !isMappingProfilePreviewOnly else { return }
        let operationID = UUID().uuidString
        if configured.action == .combinationAction {
            AppLogger.shared.write("BUTTON CONFIGURATION operation_id=\(operationID) action=select_combination phase=started result=requested")
        }
        if let profile = editingMappingProfileID {
            macroFeature.setProfileBinding(configured, profile: profile, button: button, trigger: trigger,
                displayName: configured.action == .customShortcut
                    ? configured.shortcut?.visualDisplayName(using: localization) ?? configured.action.displayName(using: localization)
                    : configured.action.displayName(using: localization))
        } else {
            settings.setBaseBinding(configured, for: button, trigger: trigger, profileID: settings.selectedRemoteProfileID)
        }
        if configured.action == .combinationAction {
            let matches = mappingConfiguration(for: button, trigger: trigger) == configured
            AppLogger.shared.write("BUTTON CONFIGURATION operation_id=\(operationID) action=select_combination phase=completed result=\(matches ? "stored" : "not_stored") scope=\(editingMappingProfileID == nil ? "base" : "profile")")
        }
        reconcileMappingHoldMode(afterChanging: button)
    }

    private func setMappingAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.action = action
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    private func setMappingShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.shortcut = shortcut
        if shortcut != nil {
            // A recorded shortcut is an executable action in its own right.
            // Keeping the previous preset action (for example arrowRight or
            // volumeDown) would make runtime dispatch ignore this shortcut.
            configured.action = .customShortcut
        } else if configured.action == .customShortcut {
            configured.action = .disabled
        }
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    private func setMappingApplicationProfileID(_ id: UUID?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.applicationProfileID = id
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    /// 方案作用域只覆盖 10 个普通按键，其余控制项置灰且不可点。
    private var profileScopeReservedButtons: Set<RemoteButton> {
        guard editingMappingProfileID != nil else { return [] }
        return Set(RemoteButton.allCases.filter { !macroFeature.supportsProfileButton($0.rawValue) })
    }

    /// 键位方案实际覆盖的按键名单，按固定顺序排列，方向键四颗合并成「方向键」。
    ///
    /// 名单来自私有组件的白名单（`supportsProfileButton`），换遥控器型号就会变；
    /// 因此界面上的「10 个普通按键」既不能写死数量，也不能只报数量——用户无从知道是哪 10 个。
    private var profileScopeItems: [ButtonProfileScopeItem] {
        RemoteButton.profileScopeItems(
            for: RemoteButton.allCases.filter { macroFeature.supportsProfileButton($0.rawValue) }
        )
    }

    /// 纯文本形式的同一份名单，供作用域提示这类只能塞一句话的位置使用。
    private var profileScopedButtonNames: String {
        profileScopeItems
            .map { $0.displayName(using: localization) }
            .joined(separator: localization.text("common.list.separator"))
    }

    #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
    private var profileScopeReservedSiriControlIDs: Set<String> {
        guard editingMappingProfileID != nil else { return [] }
        return Set(SiriRemoteControl.allCases.map(\.rawValue).filter { controlID in
            guard let button = siriRemoteButton(for: controlID) else { return true }
            return !macroFeature.supportsProfileButton(button.rawValue)
        })
    }
    #endif

    #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
    private var profileScopeReservedChromecastControlIDs: Set<String> {
        guard editingMappingProfileID != nil else { return [] }
        return Set(ChromecastRemoteControl.allCases.map(\.rawValue).filter { controlID in
            guard let button = chromecastButton(for: controlID) else { return true }
            return !macroFeature.supportsProfileButton(button.rawValue)
        })
    }
    #endif

    private var mappingSaveAsProfileSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.text("button_mapping.save_as_profile"))
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(localization.text("button_mapping.save_as_profile.name"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(localization.text("button_mapping.save_as_profile.name"), text: $savingMappingProfileName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(localization.text("button_mapping.save_as_profile.note"))
                    .fixedSize(horizontal: false, vertical: true)
                if !profileScopeItems.isEmpty {
                    Text(localization.text("button_mapping.save_as_profile.scope"))
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 82), spacing: 6, alignment: .leading),
                        ],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(profileScopeItems, id: \.self) { item in
                            HStack(spacing: 4) {
                                Image(systemName: item.systemImage)
                                    .frame(width: 12)
                                Text(item.displayName(using: localization))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Toggle(localization.text("button_mapping.save_as_profile.switch"),
                   isOn: $savingMappingProfileSwitches)
                .toggleStyle(.switch)
            if let savingMappingProfileError {
                Text(savingMappingProfileError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(localization.text("common.action.cancel")) {
                    isSavingMappingProfile = false
                }
                Button(localization.text("common.action.save")) {
                    saveMappingAsProfile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(savingMappingProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func beginSavingMappingProfile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        savingMappingProfileName = localization.text("button_mapping.save_as_profile.default_name")
            + " " + formatter.string(from: Date())
        savingMappingProfileSwitches = true
        savingMappingProfileError = nil
        isSavingMappingProfile = true
    }

    /// 基础作用域下没有“差异”可言，保存即把 10 个按键的当前动作与按住抄成一份方案。
    private func saveMappingAsProfile() {
        let name = savingMappingProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let profileID = macroFeature.createMappingProfile(named: name) else {
            savingMappingProfileError = localization.text("button_mapping.save_as_profile.failed")
            return
        }
        var written = 0
        for button in RemoteButton.allCases where macroFeature.supportsProfileButton(button.rawValue) {
            for trigger in ButtonTrigger.allCases {
                let configured = settings.configuredBaseAction(for: button, trigger: trigger)
                guard configured.action != .disabled else { continue }
                macroFeature.setProfileBinding(
                    configured,
                    profile: profileID,
                    button: button,
                    trigger: trigger,
                    displayName: configured.action.displayName(using: localization)
                )
                written += 1
            }
            if let mode = settings.interactionSettings.mode(for: button) {
                macroFeature.setProfileHoldMode(mode, profile: profileID, button: button)
            }
        }
        guard written > 0 else {
            macroFeature.deleteMappingProfile(profileID)
            savingMappingProfileError = localization.text("button_mapping.save_as_profile.empty")
            return
        }
        if savingMappingProfileSwitches {
            editingMappingProfileID = profileID
            // 刚建出来的方案同样先给只读预览：写权限只由「编辑」这一步放行。
            isEditingMappingProfile = false
        }
        isSavingMappingProfile = false
    }

    /// 方案行（固定带）：上面一行是方案胶囊 + 右侧唯一的动作入口（保存 / 编辑 / 完成）；
    /// 会员没开通时，全 App 唯一的会员入口紧贴在它下面，位置关系与按键方案页保持一致。
    private var mappingProfileToolbar: some View {
        VStack(spacing: 0) {
            mappingProfileSelector
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 5)
            if showsProfileMembershipNotice {
                membershipFeature.membershipRequiredView(forButtonProfiles: true) {
                    selectedSection = .membership
                    membershipFeature.refreshIfNeeded()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // 内容滚到工具行下面后，只在下边缘投影，明确「上面这条是固定的」。
        // 直接给整行加 .shadow 会四条边一起投；这里用一条只向下的渐变代替。
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [
                    // 深色背景上同样的黑色阴影几乎看不见，按外观加重一档。
                    .black.opacity(colorScheme == .dark ? 0.22 : 0.06),
                    .black.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 10)
            .offset(y: 10)
            .opacity(mappingContentIsScrolled ? 1 : 0)
            .allowsHitTesting(false)
        }
        // 不抬高层级时阴影会被后绘制的滚动内容盖住。
        .zIndex(1)
        .onChange(of: membershipFeature.buttonProfilesAccessDecision) { _ in
            reconcileMappingProfileMembership()
        }
    }

    /// 键位方案编辑是会员功能，判定沿用按键方案页那一套（同一个私有模块、同一份凭据）。
    ///
    /// 两把锁都要过：先看方案组件自己的访问判定（方案列表就是按它过滤的，本地测试构建还会
    /// 用测试开关把它放开），再看宿主会员模块（它决定有没有「点击开通」可点）。
    /// 只看会员模块会漏掉测试构建里「列表看得见、编辑被拦」的死按钮；只看组件那份则会漏掉
    /// 会员刚过期、组件还没收到新判定的那一小段时间。
    private var canEditMappingProfiles: Bool {
        guard macroFeature.canUseMappingProfiles else { return false }
        // 会员模块整个不在的构建里没有可点开通的入口，不拦。
        guard membershipFeature.isFeatureVisible else { return true }
        switch membershipFeature.buttonProfilesAccessDecision {
        case .allowed, .temporarilyOffline, .authorized:
            return true
        case .requiresPlus, .unavailable:
            return false
        }
    }

    /// 只有「选中了一份可编辑的方案」才谈得上解锁；私有的「默认」方案继承基础映射并拒绝写入。
    private var selectedMappingProfileIsEditable: Bool {
        guard let profile = editingMappingProfileID else { return false }
        return macroFeature.isMappingProfileEditable(profile)
    }

    /// 可写：选中了可编辑方案，且用户点过「编辑」（会员通过后才允许点上）。
    private var isMappingProfileUnlocked: Bool {
        selectedMappingProfileIsEditable && isEditingMappingProfile
    }

    /// 只读预览：选中了方案但没解锁。编辑器整体禁用，写入路径再兜一层 guard。
    private var isMappingProfilePreviewOnly: Bool {
        editingMappingProfileID != nil && !isMappingProfileUnlocked
    }

    /// 切换方案一律回到只读预览：「刚解锁过」不能被带到另一份方案上。
    private func selectMappingProfile(_ profile: UUID?) {
        editingMappingProfileID = profile
        isEditingMappingProfile = false
        showsProfileMembershipNotice = false
        shortcutCaptureTarget = nil
    }

    /// 从别的页面带过来的「编辑按键」意图：选中方案后立刻尝试解锁，行为与按下「编辑」一致。
    private func openMappingProfileForEditing(_ profile: UUID) {
        selectMappingProfile(profile)
        beginEditingMappingProfile()
    }

    /// 「编辑」入口：会员通过就解锁；没通过只把唯一的会员入口摆出来，不跳页、不写任何数据。
    private func beginEditingMappingProfile() {
        guard selectedMappingProfileIsEditable else { return }
        guard canEditMappingProfiles else {
            isEditingMappingProfile = false
            showsProfileMembershipNotice = true
            AppLogger.shared.write("BUTTON PROFILE edit phase=blocked reason=membership")
            return
        }
        showsProfileMembershipNotice = false
        isEditingMappingProfile = true
    }

    private func endEditingMappingProfile() {
        isEditingMappingProfile = false
        shortcutCaptureTarget = nil
        applicationShortcutCaptureProfileID = nil
    }

    /// 会员状态会随登录、续费、离线变化，编辑态必须跟着走：
    /// 刚开通就顺势解锁用户刚点的那个「编辑」；掉权限就退回只读，并把原因重新摆出来。
    private func reconcileMappingProfileMembership() {
        if canEditMappingProfiles {
            guard showsProfileMembershipNotice else { return }
            showsProfileMembershipNotice = false
            if selectedMappingProfileIsEditable {
                isEditingMappingProfile = true
            }
        } else {
            guard isEditingMappingProfile || showsProfileMembershipNotice else { return }
            endEditingMappingProfile()
            showsProfileMembershipNotice = selectedMappingProfileIsEditable
        }
    }

    /// 方案切换与「保存为键位方案」共处一行。
    ///
    /// 方案数量不固定，因此只有方案一侧横向滚动；右侧动作入口留在滚动区域之外、固定在行右端，
    /// 不会随方案数量左右漂移，也不再是小号按钮挤在方案后面。
    private var mappingProfileSelector: some View {
        let profiles = macroFeature.mappingProfiles(device: settings.selectedRemoteProfileID)
        let baseProfile = baseMappingProfile(in: profiles)
        let listedProfiles = baseProfile.map { base in profiles.filter { $0.id != base.id } } ?? profiles
        return HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    mappingProfileChip(
                        // 私有的「默认」方案就是基础映射，有它时直接用它的名字，不再重复一项「基础映射」。
                        baseProfile?.name ?? localization.text("button_mapping.base_profile"),
                        selected: editingMappingProfileID == nil
                    ) {
                        selectMappingProfile(nil)
                    }
                    ForEach(listedProfiles) { profile in
                        mappingProfileChip(
                            profile.name,
                            selected: editingMappingProfileID == profile.id
                        ) {
                            selectMappingProfile(profile.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            // 右端只放一个动作：基础映射下是「保存为键位方案」，选中方案后是「编辑 / 完成」。
            if editingMappingProfileID == nil {
                if macroFeature.isFeatureVisible {
                    mappingSaveAsProfileButton
                }
            } else if isMappingProfileUnlocked {
                mappingProfileRowButton(
                    localization.text("button_mapping.profile.edit_done"),
                    help: localization.text("button_mapping.profile.edit_done.help")
                ) {
                    endEditingMappingProfile()
                }
            } else if selectedMappingProfileIsEditable {
                mappingProfileRowButton(
                    localization.text("button_mapping.profile.edit"),
                    help: canEditMappingProfiles
                        ? localization.text("button_mapping.profile.edit.help")
                        : localization.text("button_mapping.profile.edit.help_locked")
                ) {
                    beginEditingMappingProfile()
                }
            }
        }
        .sheet(isPresented: $isSavingMappingProfile) { mappingSaveAsProfileSheet }
        .onAppear { macroFeature.prepareMappingDevice(settings.selectedRemoteProfileID) }
        .onChange(of: macroFeature.mappingProfiles(device: settings.selectedRemoteProfileID).map(\.id)) { ids in
            if let profile = editingMappingProfileID, !ids.contains(profile) {
                selectMappingProfile(nil)
            }
        }
        .onChange(of: settings.selectedRemoteProfileID) { _ in
            macroFeature.prepareMappingDevice(settings.selectedRemoteProfileID)
            if let profile = editingMappingProfileID,
               !macroFeature.mappingProfiles(device: settings.selectedRemoteProfileID).contains(where: { $0.id == profile }) {
                selectMappingProfile(nil)
            }
        }
    }

    /// 私有「默认」方案继承基础映射且拒绝写入，因此它本身就是基础映射，不该再单独出现一项「基础映射」。
    ///
    /// 组件若无法区分可编辑性，会把全部方案都报成不可编辑；这时保留原来的「基础映射 + 全部方案」，
    /// 宁可多一项，也不隐藏用户已有的方案。
    private func baseMappingProfile(in profiles: [ButtonMappingProfile]) -> ButtonMappingProfile? {
        guard let candidate = profiles.first(where: { !macroFeature.isMappingProfileEditable($0.id) }),
              profiles.count == 1 || profiles.contains(where: { macroFeature.isMappingProfileEditable($0.id) })
        else { return nil }
        return candidate
    }

    /// 基础映射与所有键位方案共用同一尺寸的胶囊：选中只改变配色，不改变大小与描边宽度。
    private func mappingProfileChip(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(
                            selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22),
                            lineWidth: 1
                        )
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    /// 方案行右端的动作入口，与方案胶囊同高同字号，靠稍重的描边区分为动作而非状态。
    ///
    /// 保存、编辑、完成共用这一份样式：切换方案时右侧只换文字，尺寸与描边不变。
    private func mappingProfileRowButton(
        _ title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    /// 「保存为键位方案」：只在基础映射作用域下出现。
    private var mappingSaveAsProfileButton: some View {
        mappingProfileRowButton(
            localization.text("button_mapping.save_as_profile"),
            help: localization.text("button_mapping.save_as_profile.note")
        ) {
            beginSavingMappingProfile()
        }
    }

    @ViewBuilder
    private func mappingInheritanceControl(button: RemoteButton, trigger: ButtonTrigger) -> some View {
            if let profile = editingMappingProfileID {
                Button(localization.text("button_mapping.inherit_base")) {
                    macroFeature.setProfileBinding(nil, profile: profile, button: button, trigger: trigger)
                }.buttonStyle(.bordered)
                if macroFeature.profileBinding(device: settings.selectedRemoteProfileID, profile: profile,
                    button: button, trigger: trigger) == nil {
                    Text(localization.text("button_mapping.inherited") + "：" + mappingActionSummary(for: button, trigger: trigger))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
    }

    private func mappingMacroChoices(button: RemoteButton, trigger: ButtonTrigger,
                                     configured: ConfiguredButtonAction) -> some View {
        let searchQuery = mappingMacroSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingActions = macroFeature.libraryActions.filter {
            searchQuery.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                $0.id.localizedCaseInsensitiveContains(searchQuery)
        }
        let visibleActions = searchQuery.isEmpty ? Array(matchingActions.prefix(10)) : matchingActions
        return VStack(alignment: .leading, spacing: 10) {
            Text(localization.text("action.combination_action")).font(.system(size: 14, weight: .semibold))
            TextField(localization.text("button_mapping.search_macros"), text: $mappingMacroSearch)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .frame(maxWidth: 280)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(visibleActions) { action in
                        Button {
                            var binding = configured
                            binding.action = .combinationAction
                            binding.macroID = action.id
                            saveMappingBinding(binding, button: button, trigger: trigger)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.stack.3d.up")
                                    Text(action.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if configured.action == .combinationAction && configured.macroID == action.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(String(format: localization.text("button_mapping.macro_step_count"), action.stepCount))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: 180, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(configured.action == .combinationAction && configured.macroID == action.id
                                ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if configured.action == .combinationAction,
               !macroFeature.libraryActions.contains(where: { $0.id == configured.macroID }) {
                Text(localization.text("button_mapping.macro_unavailable")).font(.system(size: 13)).foregroundStyle(.orange)
            }
            Button(localization.text("button_mapping.manage_macros")) {
                mappingActionFilter = .custom
                mappingMacroSearch = ""
                selectedSection = .macros
            }
                .buttonStyle(.bordered)
        }
    }

    private var mappingPageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            PageHeader(title: localization.text("button_mapping.page.title"))
            Text(localization.text("button_mapping.page.subtitle"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            mappingHeaderToggle
        }
    }

    private var mappingPage: some View {
        hardwareMappingPage {
            RemoteMappingCanvas(
                selectedButton: $selectedRemoteButton,
                activeButtons: model.activeRemoteButtons,
                voiceActive: model.isStreaming,
                actionSummary: { button, trigger in mappingActionSummary(for: button, trigger: trigger) },
                holdSummary: { button in mappingHoldSummary(for: button) },
                onEdit: { button, trigger in
                    selectedRemoteButton = button
                    mappingActionFilter = .all
                    mappingHoldEditingButton = button
                    mappingEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: trigger
                    )
                },
                onEditHold: { button in
                    selectedRemoteButton = button
                    mappingEditingTarget = nil
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                    mappingHoldEditingButton = button
                    requestMappingEditorScroll(focusHold: true)
                },
                onVoiceSettings: presentMappingVoiceSettings,
                reservedButtons: profileScopeReservedButtons
            )
            // 按下实体遥控器时只让对应卡片显示按下态（橙色），不移动选中项：
            // 选中项决定高亮和编辑落点，跟着按键跳会把手里的编辑顶掉。
            // 这个“锁定”以前是一个开关，现在固定生效，不再占页面位置。
        }
    }

    private func hardwareMappingPage<HardwareCanvas: View>(
        includeSiriScrollArrow: Bool = false,
        @ViewBuilder hardwareCanvas: @escaping () -> HardwareCanvas
    ) -> some View {
        VStack(spacing: 0) {
            // 控制器卡片按底边与页头对齐：卡片高度随控制器和连接状态变化，
            // 只有底边固定在分隔线上，卡片到下方工具行的间距才不会跟着控制器变。
            HStack(alignment: .bottom, spacing: 14) {
                mappingPageHeader
                    .fixedSize(horizontal: true, vertical: false)
                remoteDeviceSelector()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // 方案切换与右侧动作入口固定在页头下方的横带里：它不随内容滚动，宽度等于页面可视宽度，
            // 因此「保存为键位方案 / 编辑」能稳定贴住右边缘，也不会被画布撑出的溢出宽度带出屏幕。
            // 上下留白都在滚动区域之外，滚动时不会塌掉。
            // 画布第一张卡片自带约 6.5pt 内部留白，所以静止时下侧会比纯 padding 多这一段：
            // 上 8pt、下 5pt 是让「静止」和「滚动中」两种状态都尽量接近 10pt 的取值。
            mappingProfileToolbar

            ScrollViewReader { proxy in
                Group {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            if editingMappingProfileID != nil, !profileScopedButtonNames.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(
                                        format: localization.text("button_mapping.profile_scope_hint"),
                                        profileScopedButtonNames
                                    ))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    if isMappingProfilePreviewOnly {
                                        // 选中方案只是浏览：说清「为什么现在改不了」，别让禁用看起来像故障。
                                        Text(localization.text(selectedMappingProfileIsEditable
                                                ? "button_mapping.profile.preview_hint"
                                                : "button_mapping.profile.inherited_hint"))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            configurationImportBanner
                            corruptedSettingsBanner

                            hardwareCanvas()

                            if let target = mappingEditingTarget {
                                mappingEditorPanel(target)
                                    .id("mapping-action-editor")
                                if let holdButton = mappingHoldEditingButton, holdButton == target.button {
                                    mappingHoldEditorPanel(holdButton)
                                        .id("mapping-hold-editor")
                                        .disabled(isMappingProfilePreviewOnly)
                                }
                            } else if let button = mappingHoldEditingButton {
                                mappingHoldEditorPanel(button)
                                    .id("mapping-hold-editor")
                                    .disabled(isMappingProfilePreviewOnly)
                            }

                            // 语音键的设置只在点击语音键之后出现，而且是页面上唯一的编辑面板：
                            // 选普通按键会收起它，点它会收起普通按键的编辑器。
                            if isMappingVoiceSettingsPresented {
                                mappingVoiceSettingsPanel(includeSiriScrollArrow: includeSiriScrollArrow)
                                    .id("mapping-voice-settings")
                            }

                            #if SAYALL_CHROMECAST_ENABLED
                            // 语音键模式仅 Chromecast 遥控器有（该遥控器是唯一支持「按一次说话」的），
                            // 放在按键页靠下的位置，方便随时切换手感。
                            if settings.selectedRemoteProfile?.model.isChromecastRemote == true {
                                chromecastVoiceModeSection
                            }
                            #endif

                            mappingGestureTimingSection
                            Color.clear.frame(height: 1).id("mapping-page-bottom")
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 22)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // 锚点直接落在内容本身：再放一个零高度占位会在它与首行之间多出一段会滚走的间距。
                        .id("mapping-page-top")
                        .background {
                            // 只读取滚动偏移，用来决定工具行下边缘是否显示阴影。
                            GeometryReader { geometry in
                                let offset = geometry.frame(in: .named("mapping-scroll")).minY
                                Color.clear
                                    .onAppear { mappingContentIsScrolled = offset < -0.5 }
                                    .onChange(of: offset) { value in
                                        mappingContentIsScrolled = value < -0.5
                                    }
                            }
                        }
                    }
                    .coordinateSpace(name: "mapping-scroll")
                    .id(settings.selectedRemoteProfileID)
                    .compatibilityScrollEdgeEffect()
                }
                .onChange(of: settings.selectedRemoteProfileID) { _ in
                    model.cancelButtonGestureLearning(reason: "remote_changed")
                    loadGestureTimingDraft()
                    // 编辑器属于上一只遥控器；切换设备后不得把旧编辑区带到新页面。
                    mappingEditingTarget = nil
                    mappingHoldEditingButton = nil
                    isMappingVoiceSettingsPresented = false
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                    DispatchQueue.main.async {
                        proxy.scrollTo("mapping-page-top", anchor: .top)
                    }
                }
                .onChange(of: settings.selectedRemoteProfile?.model) { _ in
                    model.cancelButtonGestureLearning(reason: "remote_model_changed")
                    loadGestureTimingDraft()
                }
                .onAppear {
                    loadGestureTimingDraft()
                    if initialMappingScrollsToGestureTiming {
                        DispatchQueue.main.async {
                            proxy.scrollTo("mapping-gesture-timing", anchor: .top)
                        }
                    }
                    guard mappingEditingTarget != nil
                        || mappingHoldEditingButton != nil
                        || isMappingVoiceSettingsPresented
                    else { return }
                    // The hold editor has its own anchor; scrolling to the action editor
                    // would land on the page top when only the hold editor is open.
                    let anchor = isMappingVoiceSettingsPresented
                        ? "mapping-voice-settings"
                        : (mappingEditingTarget == nil ? "mapping-hold-editor" : "mapping-action-editor")
                    DispatchQueue.main.async {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
                .onChange(of: mappingEditingTarget?.id) { targetID in
                    guard targetID != nil else { return }
                    isMappingVoiceSettingsPresented = false
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("mapping-action-editor", anchor: .top)
                        }
                    }
                }
                .onChange(of: mappingHoldEditingButton?.rawValue) { buttonID in
                    guard buttonID != nil else { return }
                    isMappingVoiceSettingsPresented = false
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("mapping-hold-editor", anchor: .top)
                        }
                    }
                }
                .onChange(of: mappingEditorScrollRequest) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(mappingEditorScrollTarget, anchor: .top)
                        }
                    }
                }
                .onChange(of: mappingVoiceSettingsRequest) { _ in
                    // 面板是这一刻才插进视图树的，锚点要等下一轮布局完成才可滚动。
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("mapping-voice-settings", anchor: .top)
                        }
                    }
                }
                .onChange(of: model.buttonGestureLearningResult) { result in
                    guard let result,
                          model.buttonGestureLearningStatus.model == gestureTimingDraftModel
                    else { return }
                    gestureTimingDraft = result.suggestedTiming
                    gestureTimingSaveConfirmed = false
                }
            }
        }
    }

    /// Inline on purpose: an import that quietly dropped an entry must leave a trace the user
    /// can still read afterwards, and the repository's interface rules keep page-level notices
    /// flat inside the page rather than behind a sheet. Renders nothing when the last import
    /// adopted everything, so a clean import keeps the page's layout.
    @ViewBuilder
    private var configurationImportBanner: some View {
        if let notice = settings.configurationImportNotice {
            let rejected = ConfigurationImportNoticeText.rejectedSummary(
                for: notice.rejectedEntryStorageKeys,
                localize: localization.text
            )
            let missing = ConfigurationImportNoticeText.missingApplicationSummary(
                for: notice.applicationsMissingOnThisMac,
                localize: localization.text
            )
            GlassPanel {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localization.text(ConfigurationImportNoticeText.titleKey))
                            .font(.system(size: 12, weight: .semibold))
                        if let rejected {
                            Text(rejected)
                                .font(.system(size: 12))
                        }
                        if let missing {
                            Text(missing)
                                .font(.system(size: 12))
                        }
                        Text(localization.text(ConfigurationImportNoticeText.nextStepKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Inline on purpose: a sheet or alert here would be dismissed once and never seen again,
    /// and the repository's interface rules keep page-level notices flat inside the page.
    /// Renders nothing at all when no key failed to decode, so a healthy launch keeps its layout.
    @ViewBuilder
    private var corruptedSettingsBanner: some View {
        if let summary = CorruptedSettingsNotice.summary(
            for: settings.corruptedSettingKeys,
            localize: localization.text
        ) {
            GlassPanel {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localization.text(CorruptedSettingsNotice.titleKey))
                            .font(.system(size: 12, weight: .semibold))
                        Text(summary)
                            .font(.system(size: 12))
                        Text(localization.text(CorruptedSettingsNotice.recoveryKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(localization.text(CorruptedSettingsNotice.nextStepKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var mappingHeaderToggle: some View {
        Toggle("button_mapping.toggle.enabled", isOn: Binding(
            get: { settings.customMappingEnabled },
            set: setCustomMappingEnabled
        ))
        .font(.system(size: 14, weight: .medium))
        .toggleStyle(.switch)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func mappingEditorPanel(_ target: ShortcutEditingTarget) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(target.button.displayName(using: localization))
                        .font(.system(size: 18, weight: .semibold))
                    Text(target.trigger.displayName(using: localization))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Spacer()
                    Toggle(
                        "button_mapping.action.disable_switch",
                        isOn: Binding(
                            get: {
                                mappingConfiguration(
                                    for: target.button,
                                    trigger: target.trigger
                                ).action == .disabled
                            },
                            set: { disabled in
                                setMappingAction(
                                    disabled ? .disabled : .escape,
                                    for: target.button,
                                    trigger: target.trigger
                                )
                                shortcutCaptureTarget = nil
                                applicationShortcutCaptureProfileID = nil
                            }
                        )
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .tint(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(
                        isMappingProfilePreviewOnly ||
                            (target.button == .power &&
                                target.trigger == .singleClick &&
                                settings.experimentalContinuousRecordingEnabled)
                    )
                    Button("common.action.close") {
                        mappingEditingTarget = nil
                        shortcutCaptureTarget = nil
                        applicationShortcutCaptureProfileID = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }

                // 只读预览下只禁用会写入的部分，「关闭」仍然可点，否则面板变成关不掉的窗口。
                mappingTriggerEditor(target.button, trigger: target.trigger)
                    .disabled(isMappingProfilePreviewOnly)
            }
        }
    }

    /// 语音键设置面板：用户点击画布上的语音键之后才出现，内容只包含这一块。
    /// 语音键没有普通按键的单击/双击/长按动作，所以这里放的是触发方式、兼容开关和恢复默认。
    private func mappingVoiceSettingsPanel(includeSiriScrollArrow: Bool = false) -> some View {
        // 能力一律取自「链路自报优先、型号默认兜底」的判定结果（见 RemoteVoiceCapabilities）。
        let capabilities = model.selectedRemoteVoiceCapabilities
        return GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                mappingHIDStatus
                Divider()
                mappingVoiceKeyModeControl
                // 「语音键模拟 Fn 点按」只对「不会按一次收音」的遥控器有意义：
                // 它把按住模拟成点按，用来驱动只认点按的工具。Chromecast 自己能按一次收音，
                // 驱动方式由语音模式直接决定，页面不出现该开关（见能力矩阵文档）。
                if VoiceFunctionKeyTapApplicability.isApplicable(capabilities: capabilities) {
                    Divider()
                    mappingVoiceFnTapControl
                }
                // 触摸面（滑动箭头/光标）只有具备触摸面的遥控器才显示，页面请求之外再加一道能力门禁。
                if TouchSurfaceControlApplicability.isApplicable(
                    capabilities: capabilities,
                    pageRequestsControl: includeSiriScrollArrow
                ) {
                    Divider()
                    siriRemoteScrollArrowControl
                }
                HStack {
                    Spacer(minLength: 0)
                    mappingRestoreDefaultsButton
                }
            }
        }
    }

    private var siriRemoteScrollArrowControl: some View {
        Toggle(isOn: $settings.siriRemoteScrollArrowReversed) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localization.text("siri_remote.scroll_arrow.reverse.title"))
                    .font(.system(size: 13, weight: .medium))
                Text(localization.text("siri_remote.scroll_arrow.reverse.detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .help(localization.text("siri_remote.scroll_arrow.reverse.help"))
    }

    private var mappingHIDStatus: some View {
        Label(
            model.hidStatus.text(using: localization),
            systemImage: "keyboard"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private var mappingVoiceKeyModeControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("connection.voice_key_mode.title")
                .font(.system(size: 12, weight: .medium))
            Picker("connection.voice_key_mode.title", selection: Binding(
                get: { settings.voiceKeyMode },
                set: { model.setVoiceKeyMode($0) }
            )) {
                ForEach(VoiceKeyMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .tint(Color.accentColor)
            Text("connection.voice_key_mode.help")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if settings.voiceKeyMode != .function {
                Text("connection.voice_key_mode.unverified_detail")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(localization.text("connection.voice_key_mode.help"))
    }

    private var mappingVoiceFnTapControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("connection.voice_fn_tap.enabled", isOn: Binding(
                get: { settings.voiceFnTapModeEnabled },
                set: { model.setVoiceFnTapModeEnabled($0) }
            ))
            .font(.system(size: 12, weight: .medium))
            .toggleStyle(.switch)
            Text("connection.voice_fn_tap.hint_short")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .help(localization.text("connection.voice_fn_tap.hint"))
        .opacity(settings.voiceKeyMode == .function ? 1 : 0.55)
        .disabled(settings.voiceKeyMode != .function)
    }

    private var mappingRestoreDefaultsButton: some View {
        Button("common.action.restore_defaults") {
            if let profile = editingMappingProfileID {
                for button in RemoteButton.allCases {
                    for trigger in ButtonTrigger.allCases {
                        macroFeature.setProfileBinding(nil, profile: profile, button: button, trigger: trigger)
                    }
                }
            } else { settings.resetBindings() }
            selectedRemoteButton = .ok
        }
        .compatibilityButtonStyle(.standard)
        // 方案只读预览时「恢复默认」也是写入：和编辑器一起禁用。
        .disabled(isMappingProfilePreviewOnly)
    }

    @ViewBuilder
    private func remoteDeviceSelector(vertical: Bool = false) -> some View {
        let visibleProfiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles.filter { profile in
                #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
                // Keep the activation entry available while the Apple adapter is stopped.
                model.isRemoteConnected(profile.id) || profile.model.isAppleSiriRemote
                #else
                model.isRemoteConnected(profile.id)
                #endif
            },
            modelName: remoteModelName,
            systemName: { model.systemDeviceName(for: $0) }
        )
        if visibleProfiles.isEmpty {
            remoteDeviceEmptyState(vertical: vertical)
        } else if vertical {
            VStack(spacing: 8) {
                ForEach(visibleProfiles) { profile in
                    remoteDeviceCard(profile, fillsWidth: true)
                }
            }
        } else {
            let cards = HStack(spacing: 8) {
                ForEach(visibleProfiles) { profile in
                    remoteDeviceCard(profile)
                        .id(profile.id)
                }
            }
            ViewThatFits(in: .horizontal) {
                cards.fixedSize(horizontal: true, vertical: false)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        cards
                    }
                    // 三款遥控器同时在线时卡片行放不下：选中的那张可能在视口之外（Chromecast
                    // 排最后，最容易被完全挡住），用户看到的画布就和顶部高亮对不上。卡片行
                    // 必须自己把当前选中的那张滚进视野。
                    .onAppear { revealSelectedRemoteCard(using: proxy) }
                    .onChange(of: settings.selectedRemoteProfileID) { _ in
                        revealSelectedRemoteCard(using: proxy, animated: true)
                    }
                    .onChange(of: visibleProfiles.map(\.id)) { _ in
                        revealSelectedRemoteCard(using: proxy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// 把当前选中的遥控器卡片滚进设备选择器的可见范围。
    private func revealSelectedRemoteCard(
        using proxy: ScrollViewProxy,
        animated: Bool = false
    ) {
        guard let selectedProfileID = settings.selectedRemoteProfileID,
              settings.remoteDeviceProfiles.contains(where: { $0.id == selectedProfileID })
        else { return }
        // 首帧的布局还没完成，立刻 scrollTo 会被丢弃；等一次主队列再滚。
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(selectedProfileID, anchor: .center)
                }
            } else {
                proxy.scrollTo(selectedProfileID, anchor: .center)
            }
        }
    }

    private func remoteDeviceEmptyState(vertical: Bool) -> some View {
        VStack(alignment: vertical ? .leading : .center, spacing: 8) {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: vertical ? 24 : 18, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(model.connectionStatus.text(using: localization))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(vertical ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)

            if !vertical {
                Button("connection.action.reconnect") {
                    model.reconnect()
                }
                .compatibilityButtonStyle(.standard)
            }
        }
        .frame(maxWidth: .infinity, alignment: vertical ? .leading : .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        }
    }

    private func remoteDeviceCard(
        _ profile: RemoteDeviceProfile,
        fillsWidth: Bool = false
    ) -> some View {
        let selected = settings.selectedRemoteProfileID == profile.id
        let connected = model.isRemoteConnected(profile.id)
        let batteryLevel = model.batteryLevel(for: profile.id)
        let powerState = model.powerState(for: profile.id)
        let modelName = remoteModelName(profile)
        let systemName = remoteSystemName(profile)
        let showsBattery = RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: profile.model,
            level: batteryLevel,
            powerState: powerState
        )
        let siriRemoteMembershipRequired = requiresSiriRemoteMembership(for: profile)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    model.noteManualRemoteProfileSelection()
                    model.selectRemoteProfile(profile.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(modelName)
                            .help(modelName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(systemName)
                            .help(systemName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(modelName), \(systemName)"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                HStack(spacing: 7) {
                    remoteConnectionLabel(connected: connected)
                    if showsBattery {
                        remoteBatteryLabel(level: batteryLevel, powerState: powerState)
                    }
                    #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
                    if profile.model.isAppleSiriRemote {
                        // 会员入口与启用/停用都排在这一行里，卡片不额外开一列。
                        siriRemoteCardActions(
                            profile,
                            showsVoiceMembershipHint: siriRemoteMembershipRequired
                        )
                        .fixedSize()
                    }
                    #endif
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: fillsWidth ? nil : 232, alignment: .leading)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background {
            // The background handles padding; foreground buttons keep their own actions.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture {
                    model.noteManualRemoteProfileSelection()
                    model.selectRemoteProfile(profile.id)
                }
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18))
                .allowsHitTesting(false)
        }
    }

    /// 苹果遥控器只有**语音**需要会员；这里只决定是否给出「开通会员」提示，
    /// 不再用来隐藏启用/停用，因为连接、按键与触摸都不看会员。
    private func requiresSiriRemoteMembership(for profile: RemoteDeviceProfile) -> Bool {
        guard profile.model.isAppleSiriRemote else { return false }
        switch membershipFeature.buttonProfilesAccessDecision {
        case .allowed, .temporarilyOffline, .authorized:
            return false
        case .requiresPlus, .unavailable:
            return true
        }
    }

    #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
    /// 第三行内联的紧凑操作：语音会员入口 + 启用/重试/准备中。
    ///
    /// 卡片正文固定三行（型号、系统名称、连接状态与电量），所以这些操作不再单独占一列，
    /// 而是紧跟在连接状态与电量后面同一行显示。
    private func siriRemoteCardActions(
        _ profile: RemoteDeviceProfile,
        showsVoiceMembershipHint: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsVoiceMembershipHint {
                Button(localization.text("siri_remote.activation.open_membership")) {
                    model.selectRemoteProfile(profile.id)
                    selectedSection = .membership
                    membershipFeature.refreshIfNeeded()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help(localization.text("siri_remote.mapping.voice.detail"))
            }
            if !settings.siriRemoteEnabled {
                Button(localization.text("siri_remote.activation.enable")) {
                    model.selectRemoteProfile(profile.id)
                    model.setSiriRemoteEnabled(true)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(model.isStreaming || model.activePhysicalVoiceControlSource == .siriRemote)
            } else if model.siriRemoteAudioStatus.hasPrefix("unavailable:") {
                Button(localization.text("siri_remote.activation.retry")) {
                    model.selectRemoteProfile(profile.id)
                    model.prepareSiriRemoteFromUserAction()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(model.isStreaming || model.activePhysicalVoiceControlSource == .siriRemote)
            } else if model.siriRemoteAudioStatus != "ready" {
                Button(localization.text("siri_remote.activation.preparing")) {}
                    .buttonStyle(.borderless)
                    .disabled(true)
            }
        }
        .lineLimit(1)
    }
    #endif

    private func remoteConnectionLabel(connected: Bool) -> some View {
        Label(
            localization.text(connected ? "common.status.connected" : "remote.device.disconnected"),
            systemImage: "circle.fill"
        )
        .foregroundStyle(connected ? Color.green : Color.secondary)
    }

    private func remoteBatteryLabel(
        level: Int?,
        powerState: RemotePowerState?
    ) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: batterySymbol(for: level))
                    .font(.system(size: 13, weight: .medium))
                if powerState == .charging || powerState == .externalPower {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.green)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 20)

            Text(level.map { "\($0)%" } ?? "—")
        }
        .foregroundStyle(batteryColor(for: level))
        .help(remoteBatteryHelp(level: level, powerState: powerState))
    }

    private func batterySymbol(for level: Int?) -> String {
        guard let level else { return "battery.0percent" }
        switch level {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryColor(for level: Int?) -> Color {
        guard let level else { return .secondary }
        if level <= 10 { return .red }
        if level <= 25 { return .orange }
        return .secondary
    }

    private func remoteBatteryHelp(
        level: Int?,
        powerState: RemotePowerState?
    ) -> String {
        switch powerState {
        case .charging:
            return localization.text("remote.device.power.charging")
        case .externalPower:
            return localization.text("remote.device.power.external")
        case .onBattery:
            return level == nil
                ? localization.text("remote.device.battery_unavailable")
                : localization.text("remote.device.power.battery")
        case .unknown:
            return localization.text("remote.device.power.unknown")
        case nil:
            return level == nil
                ? localization.text("remote.device.battery_unavailable")
                : localization.text("remote.device.power.battery")
        }
    }

    private func remoteModelName(_ profile: RemoteDeviceProfile) -> String {
        localization.text(profile.displayNameFallbackKey)
    }

    private func remoteSystemName(_ profile: RemoteDeviceProfile) -> String {
        model.systemDeviceName(for: profile)
            ?? localization.text("remote.device.system_name_unknown")
    }

    private func mappingTriggerEditor(
        _ button: RemoteButton,
        trigger: ButtonTrigger
    ) -> some View {
        let configured = mappingConfiguration(for: button, trigger: trigger)
        let installedBundleIdentifiers = PresetApplication.installedBundleIdentifiers
        let actions = ButtonAction.pickerActions(
            installedBundleIdentifiers: installedBundleIdentifiers,
            current: configured.action,
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ).filter { $0 != .disabled && $0 != .combinationAction }
        let isManagedPowerAction = button == .power &&
            trigger == .singleClick &&
            settings.experimentalContinuousRecordingEnabled
        return VStack(alignment: .leading, spacing: 16) {
            mappingInheritanceControl(button: button, trigger: trigger)
            mappingActionFilterControl

            ForEach(ButtonActionCategory.allCases.filter(mappingActionFilter.includes)) { category in
                    let groupedActions = actions.filter { $0.category == category }
                    if !groupedActions.isEmpty {
                        mappingActionGroup(
                            category: category,
                            actions: groupedActions,
                            selectedAction: configured.action,
                            installedBundleIdentifiers: installedBundleIdentifiers,
                            isManagedPowerAction: isManagedPowerAction,
                            onSelect: { action in
                                applicationShortcutCaptureProfileID = nil
                                guard action != .customShortcut else {
                                    // Choosing the action starts recording; an unrecorded shortcut
                                    // must never become a saved binding.
                                    shortcutCaptureTarget = ShortcutEditingTarget(
                                        button: button,
                                        trigger: trigger
                                    )
                                    return
                                }
                                setMappingAction(action, for: button, trigger: trigger)
                                shortcutCaptureTarget = nil
                            }
                        )
                    }
                }

                if mappingActionFilter.includes(.custom), macroFeature.isFeatureVisible {
                    mappingMacroChoices(button: button, trigger: trigger, configured: configured)
                }
                if configured.action == .customShortcut ||
                    shortcutCaptureTarget == ShortcutEditingTarget(button: button, trigger: trigger) {
                    inlineShortcutEditor(
                        button: button,
                        trigger: trigger,
                        configured: configured
                    )
                }

                if configured.action == .openCustomApplication {
                    customApplicationTargetPicker(
                        button: button,
                        trigger: trigger,
                        configured: configured
                    )
                }

                if button == .power && trigger == .singleClick && settings.experimentalContinuousRecordingEnabled {
                    Text("button_mapping.continuous_recording_experiment.power_managed")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                } else if trigger == .doubleClick && configured.action != .disabled {
                    Text("button_mapping.double_click.effect")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                } else if trigger == .longPress && configured.action != .disabled {
                    Text("button_mapping.long_press.effect")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                } else if trigger == .singleClick,
                          configured.action == .disabled || configured.action.allowsRepeat {
                    Text("button_mapping.single_click.help")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var mappingActionFilterControl: some View {
        HStack(spacing: 8) {
            ForEach(MappingActionFilter.visibleCases) { filter in
                let isSelected = mappingActionFilter == filter
                Button {
                    guard mappingActionFilter != filter else { return }
                    mappingActionFilter = filter
                } label: {
                    Text(localization.text(filter.localizationKey))
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(
                            isSelected
                                ? Color(nsColor: .alternateSelectedControlTextColor)
                                : Color.secondary
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            isSelected ? Color.accentColor : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    isSelected ? Color.clear : Color.secondary.opacity(0.22),
                                    lineWidth: 1
                                )
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func mappingHoldMode(for button: RemoteButton) -> RemoteButtonHoldMode {
        if let profile = editingMappingProfileID,
           let rawValue = macroFeature.profileHoldMode(profile: profile, button: button),
           let mode = RemoteButtonHoldMode(rawValue: rawValue) {
            return mode
        }
        return settings.interactionSettings.mode(for: button) ?? .once
    }

    private func mappingHoldSummary(for button: RemoteButton) -> String {
        let mode = mappingHoldSnapshot(for: button).mode
        guard let mode, mode != .once else {
            return localization.text("button_mapping.hold.entry")
        }
        let trigger: ButtonTrigger = mode == .repeatLong ? .longPress : .singleClick
        return localization.text("button_mapping.hold.repeat_prefix") +
            mappingActionSummary(for: button, trigger: trigger)
    }

    private func setMappingHoldMode(_ mode: RemoteButtonHoldMode, for button: RemoteButton) {
        if let profile = editingMappingProfileID {
            settings.onInteractionModeChanged?(settings.selectedRemoteProfileID)
            macroFeature.setProfileHoldMode(mode, profile: profile, button: button)
        } else {
            settings.setHoldMode(mode, for: button)
        }
    }

    private func reconcileMappingHoldMode(afterChanging button: RemoteButton) {
        let explicitMode: RemoteButtonHoldMode? = if let profile = editingMappingProfileID {
            macroFeature.profileHoldMode(profile: profile, button: button)
                .flatMap(RemoteButtonHoldMode.init(rawValue:))
        } else {
            settings.interactionSettings.modes[button.rawValue]
                .flatMap(RemoteButtonHoldMode.init(rawValue:))
        }
        let snapshot = mappingHoldSnapshot(for: button)
        // The action just changed. If the saved hold choice can no longer run, drop it back to
        // "unset" so the button always has a truthful state and the user can choose again.
        if let explicitMode, !snapshot.blockers(for: explicitMode).isEmpty {
            setMappingHoldMode(.once, for: button)
            return
        }
        guard let mode = RemoteButtonHoldModeDefault.storedMode(explicit: explicitMode, snapshot: snapshot)
        else { return }
        setMappingHoldMode(mode, for: button)
    }

    private func mappingHoldSnapshot(for button: RemoteButton) -> RemoteButtonInteractionSnapshot {
        let currentInteractionSettings = settings.buttonInteractionSettings()
        var snapshot = RemoteButtonInteractionSnapshot(settings: currentInteractionSettings,
            mode: mappingHoldMode(for: button),
            single: mappingConfiguration(for: button, trigger: .singleClick),
            double: mappingConfiguration(for: button, trigger: .doubleClick),
            long: mappingConfiguration(for: button, trigger: .longPress))
        // The editor mirrors runtime: a choice the actions cannot run is simply unset.
        if let mode = snapshot.mode, !snapshot.blockers(for: mode).isEmpty {
            snapshot.mode = .once
        }
        return snapshot
    }

    private func holdBlockerText(_ blocker: RemoteButtonHoldBlocker) -> String {
        switch blocker {
        case .timingInvalid:
            return localization.text("button_mapping.hold.blocker.timing_invalid")
        case .profileOwned:
            return localization.text("button_mapping.hold.blocker.profile_owned")
        case .actionUnset:
            return localization.text("button_mapping.hold.blocker.action_unset")
        case let .actionNotRepeatable(configured):
            return String(
                format: localization.text("button_mapping.hold.blocker.action_not_repeatable"),
                actionSummary(configured)
            )
        case let .longPressConfigured(configured):
            return String(
                format: localization.text("button_mapping.hold.blocker.long_configured"),
                actionSummary(configured)
            )
        case .longPressOwnedByProfile:
            return localization.text("button_mapping.hold.blocker.long_owned_by_profile")
        }
    }

    private func mappingHoldEditorPanel(_ button: RemoteButton) -> some View {
        let snapshot = mappingHoldSnapshot(for: button)
        let profileUnsupported = editingMappingProfileID != nil && !macroFeature.supportsProfileHoldModes
        return GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(button.displayName(using: localization))
                        .font(.system(size: 18, weight: .semibold))
                    Text("button_mapping.hold.entry")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Spacer()
                    if snapshot.mode != .once {
                        Button("button_mapping.hold.clear") {
                            setMappingHoldMode(.once, for: button)
                        }
                        .compatibilityButtonStyle(.standard)
                        .disabled(profileUnsupported)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("button_mapping.hold.target")
                        .font(.system(size: 13, weight: .semibold))
                    Text("button_mapping.hold.description")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 8) {
                    ForEach(RemoteButtonHoldMode.selectableCases) { mode in
                        mappingHoldOptionColumn(mode, button: button, snapshot: snapshot,
                                                profileUnsupported: profileUnsupported)
                    }
                }

                if profileUnsupported {
                    Text("button_mapping.hold_profile_unavailable")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = snapshot.unavailableReason {
                    Text(localization.text(reason))
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if snapshot.single.action != .disabled, !snapshot.single.action.allowsRepeat {
                    Divider().padding(.top, 2)
                    mappingRapidPressControl(button: button)
                } else if snapshot.single.action != .disabled {
                    Divider().padding(.top, 2)
                    Text("button_mapping.single_click.help")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One hold target. The card keeps a single height across both columns and its reason
    /// sits directly underneath, so the pair always lines up.
    private func mappingHoldOptionColumn(
        _ mode: RemoteButtonHoldMode,
        button: RemoteButton,
        snapshot: RemoteButtonInteractionSnapshot,
        profileUnsupported: Bool
    ) -> some View {
        let blockers = snapshot.blockers(for: mode)
        let selected = snapshot.mode == mode
        let subtitle = mode == .repeatSingle
            ? localization.text("button_mapping.hold.repeat_single.action_prefix") +
                mappingActionSummary(for: button, trigger: .singleClick)
            : localization.text("button_mapping.hold.repeat_long.action_prefix") +
                mappingActionSummary(for: button, trigger: .longPress)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                setMappingHoldMode(mode, for: button)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        Text(localization.text(mode.localizationKey))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 13))
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear)
                }
            }
            .buttonStyle(.plain)
            .disabled(profileUnsupported || !blockers.isEmpty)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if !blockers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                        Text(holdBlockerText(blocker))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if mode == .repeatSingle, blockers == [.longPressConfigured(snapshot.long)] {
                        Button("button_mapping.hold.clear_long_to_enable") {
                            setMappingAction(.disabled, for: button, trigger: .longPress)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var mappingGestureTimingSection: some View {
        let selectedModel = settings.selectedRemoteProfile?.model
        let selectedProfileID = settings.selectedRemoteProfileID
        let learningStatus = model.buttonGestureLearningStatus
        let learningMatchesModel = learningStatus.model == selectedModel
        let availability = RemoteButtonGestureLearningAvailability(
            model: selectedModel,
            isConnected: selectedProfileID.map(model.isRemoteConnected) ?? false
        )
        let persistedTiming = selectedModel.map { settings.buttonGestureTiming(for: $0) }
            ?? RemoteButtonGestureTiming()
        return GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("button_mapping.gesture.title")
                        .font(.system(size: 20, weight: .bold))
                    Text("button_mapping.gesture.subtitle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("button_mapping.learning.title")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(learningStatusText(
                            status: learningStatus,
                            matchesModel: learningMatchesModel
                        ))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                    Text("button_mapping.learning.subtitle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 8) {
                        learningMeasurementCard(
                            number: 1,
                            total: 3,
                            titleKey: "button_mapping.learning.single",
                            detailKey: "button_mapping.learning.single_hint",
                            value: learningMatchesModel ? learningStatus.singleClickMilliseconds : nil,
                            isCurrent: learningMatchesModel && learningStatus.step == .singleClick
                        )
                        learningMeasurementCard(
                            number: 2,
                            total: 3,
                            titleKey: "button_mapping.learning.double",
                            detailKey: "button_mapping.learning.double_hint",
                            value: learningMatchesModel ? learningStatus.doubleClickMilliseconds : nil,
                            isCurrent: learningMatchesModel && learningStatus.step == .doubleClick
                        )
                        learningMeasurementCard(
                            number: 3,
                            total: 3,
                            titleKey: "button_mapping.learning.long",
                            detailKey: "button_mapping.learning.long_hint",
                            value: learningMatchesModel ? learningStatus.longPressMilliseconds : nil,
                            isCurrent: learningMatchesModel && learningStatus.step == .longPress
                        )
                    }

                    if !availability.canLearn {
                        Text(localization.text(availability.canSaveTiming
                            ? "button_mapping.learning.disconnected"
                            : "button_mapping.learning.unavailable"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        Button("button_mapping.learning.restart") {
                            gestureTimingSaveConfirmed = false
                            _ = model.startButtonGestureLearning()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!availability.canLearn ||
                            (!learningMatchesModel || learningStatus.step == .idle))
                        Button("button_mapping.learning.start") {
                            gestureTimingSaveConfirmed = false
                            _ = model.startButtonGestureLearning()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!availability.canLearn ||
                            (learningMatchesModel && learningStatus.isActive))
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("button_mapping.timing_title")
                        .font(.system(size: 16, weight: .semibold))
                    HStack(alignment: .top, spacing: 18) {
                        gestureTimingSlider(
                            titleKey: "button_mapping.timing_double",
                            value: Binding(
                                get: { gestureTimingDraft.doubleClickMilliseconds },
                                set: {
                                    gestureTimingDraft.doubleClickMilliseconds = $0
                                    gestureTimingSaveConfirmed = false
                                }
                            ),
                            range: 50...500
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        gestureTimingSlider(
                            titleKey: "button_mapping.timing_long",
                            value: Binding(
                                get: { gestureTimingDraft.longPressMilliseconds },
                                set: {
                                    gestureTimingDraft.longPressMilliseconds = $0
                                    gestureTimingSaveConfirmed = false
                                }
                            ),
                            range: 300...1000
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Text(gestureTimingSaveConfirmed
                            ? localization.text("button_mapping.timing_saved")
                            : localization.text("button_mapping.timing_save_hint"))
                            .font(.system(size: 12))
                            .foregroundStyle(gestureTimingSaveConfirmed ? Color.green : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("common.action.save") {
                            guard let selectedModel, selectedModel != .unknown else { return }
                            settings.setButtonGestureTiming(gestureTimingDraft, for: selectedModel)
                            gestureTimingSaveConfirmed = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!availability.canSaveTiming || !gestureTimingDraft.isValid ||
                            (gestureTimingDraft == persistedTiming &&
                                (model.buttonGestureLearningResult == nil || gestureTimingSaveConfirmed)))
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .id("mapping-gesture-timing")
    }

    private func gestureTimingSlider(
        titleKey: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(localization.text(titleKey))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(value.wrappedValue) ms")
                    .font(.system(size: 14, design: .monospaced))
            }
            HStack(spacing: 10) {
                Text("\(range.lowerBound)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(value.wrappedValue) },
                        set: { value.wrappedValue = Int($0.rounded()) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 50
                )
                Text("\(range.upperBound)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func learningMeasurementCard(
        number: Int,
        total: Int,
        titleKey: String,
        detailKey: String,
        value: Int?,
        isCurrent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number)/\(total) · \(localization.text(titleKey))")
                .font(.system(size: 13, weight: .semibold))
            Text(localization.text(detailKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value.map { "\($0) ms" } ?? localization.text("button_mapping.learning.waiting"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isCurrent ? 2 : 1)
        }
    }

    private func learningStatusText(
        status: RemoteButtonGestureLearningStatus,
        matchesModel: Bool
    ) -> String {
        guard matchesModel else { return localization.text("button_mapping.learning.not_started") }
        switch status.step {
        case .idle: return localization.text("button_mapping.learning.not_started")
        case .complete: return localization.text("button_mapping.learning.complete")
        case .singleClick, .doubleClick, .longPress:
            let step: Int = switch status.step {
            case .doubleClick: 2
            case .longPress: 3
            default: 1
            }
            return String(
                format: localization.text("button_mapping.learning.progress"),
                step,
                3
            )
        }
    }

    private func loadGestureTimingDraft() {
        guard let selectedModel = settings.selectedRemoteProfile?.model else {
            gestureTimingDraftModel = nil
            gestureTimingDraft = RemoteButtonGestureTiming()
            gestureTimingSaveConfirmed = false
            return
        }
        gestureTimingDraftModel = selectedModel
        gestureTimingDraft = settings.buttonGestureTiming(for: selectedModel)
        gestureTimingSaveConfirmed = false
    }

    private func mappingRapidPressControl(button: RemoteButton) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text("button_mapping.rapid_press")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.allowsRapidPress(for: button) },
                    set: { settings.setAllowsRapidPress($0, for: button) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Text("button_mapping.hold.rapid_press_description")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(localization.text("button_mapping.rapid_press_help"))
    }

    @ViewBuilder
    private func mappingActionGroup(
        category: ButtonActionCategory,
        actions: [ButtonAction],
        selectedAction: ButtonAction,
        installedBundleIdentifiers: Set<String>,
        isManagedPowerAction: Bool,
        onSelect: @escaping (ButtonAction) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.text(category.localizationKey))
                .font(.system(size: 14, weight: .semibold))

            mappingActionGrid(
                actions: actions,
                selectedAction: selectedAction,
                installedBundleIdentifiers: installedBundleIdentifiers,
                isManagedPowerAction: isManagedPowerAction,
                onSelect: onSelect
            )
        }
    }

    private func mappingActionGrid(
        actions: [ButtonAction],
        selectedAction: ButtonAction,
        installedBundleIdentifiers: Set<String>,
        isManagedPowerAction: Bool,
        onSelect: @escaping (ButtonAction) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(actions.filter { $0 != .openCommonPhrases }) { action in
                    let unavailableApplication = action.presetApplication.map {
                        !installedBundleIdentifiers.contains($0.bundleIdentifier)
                    } ?? false
                    let unavailableExperiment = action == .toggleLongRecording &&
                        !settings.experimentalContinuousRecordingEnabled
                    Button {
                        onSelect(action)
                    } label: {
                        mappingActionLabel(
                            title: action.visualDisplayName(using: localization) +
                                (unavailableApplication
                                    ? localization.text("common.suffix.not_installed")
                                    : unavailableExperiment
                                        ? localization.text("common.suffix.experimental_disabled")
                                        : ""),
                            isSelected: selectedAction == action,
                            systemImage: selectedAction == action ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .help(action.detailedDisplayName(using: localization))
                    .accessibilityLabel(Text(action.detailedDisplayName(using: localization)))
                    .disabled(isManagedPowerAction || unavailableApplication || unavailableExperiment)
                }
            }
            if actions.contains(.openCommonPhrases) {
                commonPhrasesActionControls(
                    selectedAction: selectedAction,
                    isManagedPowerAction: isManagedPowerAction,
                    onSelect: onSelect
                )
            }
        }
    }

    private func commonPhrasesActionControls(
        selectedAction: ButtonAction,
        isManagedPowerAction: Bool,
        onSelect: @escaping (ButtonAction) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                guard membershipFeature.canUseCommonPhrases else { return }
                onSelect(.openCommonPhrases)
            } label: {
                mappingActionLabel(
                    title: localization.text("action.open_common_phrases"),
                    isSelected: selectedAction == .openCommonPhrases,
                    systemImage: selectedAction == .openCommonPhrases
                        ? "checkmark.circle.fill"
                        : "circle",
                    badge: membershipFeature.canUseCommonPhrases
                        ? localization.text("membership.badge")
                        : nil
                )
            }
            .buttonStyle(.plain)
            .disabled(isManagedPowerAction || !membershipFeature.canUseCommonPhrases)
            .accessibilityIdentifier("common-phrases-open")

            if !membershipFeature.canUseCommonPhrases {
                membershipFeature.membershipRequiredView {
                    selectedSection = .membership
                    membershipFeature.refreshIfNeeded()
                }
                .frame(minWidth: 170)
                .accessibilityIdentifier("common-phrases-membership")
            }

            Button {
                if membershipFeature.canUseCommonPhrases {
                    selectedSection = .commonPhrases
                } else {
                    selectedSection = .membership
                    membershipFeature.refreshIfNeeded()
                }
            } label: {
                mappingActionLabel(
                    title: localization.text("common_phrases.adjust"),
                    isSelected: false,
                    systemImage: "slider.horizontal.3"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("common-phrases-adjust")

            Button {
                _ = membershipFeature.canUseCommonPhrases
                    ? membershipFeature.openCommonPhrases(source: "settings_example")
                    : membershipFeature.openCommonPhrasesPreview(source: "settings_preview")
            } label: {
                mappingActionLabel(
                    title: localization.text("common_phrases.example"),
                    isSelected: false,
                    systemImage: "text.quote"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("common-phrases-example")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mappingActionLabel(
        title: String,
        isSelected: Bool,
        systemImage: String,
        badge: String? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(title).lineLimit(1).truncationMode(.tail)
            if let badge {
                Text(badge)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func inlineShortcutEditor(
        button: RemoteButton,
        trigger: ButtonTrigger,
        configured: ConfiguredButtonAction
    ) -> some View {
        let target = ShortcutEditingTarget(button: button, trigger: trigger)
        let contextID = target.id
        VStack(alignment: .leading, spacing: 10) {
            Text("shortcut.editor.click_first_help")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if shortcutCaptureTarget == target {
                HStack(spacing: 10) {
                    Label("shortcut.editor.recording_prompt", systemImage: "keyboard.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    Button("common.action.cancel") {
                        shortcutCaptureTarget = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                ShortcutCaptureView(
                    onCapture: { shortcut in
                        setMappingShortcut(shortcut, for: button, trigger: trigger)
                        AppLogger.shared.write("SHORTCUT CAPTURE completed target=button")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .succeeded
                        )
                        shortcutCaptureTarget = nil
                    },
                    onFailure: { failure in
                        AppLogger.shared.write("SHORTCUT CAPTURE failed reason=\(failure)")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .failed(failure)
                        )
                        shortcutCaptureTarget = nil
                        if failure == .accessibilityPermissionRequired {
                            _ = KeyboardInjector.requestAccessibilityAccess()
                        }
                    }
                )
                .frame(height: 1)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Label {
                                Text(
                                configured.shortcut?.visualDisplayName(using: localization) ??
                                    localization.text("shortcut.editor.not_recorded")
                                )
                        } icon: {
                            Image(systemName: configured.shortcut == nil ? "keyboard" : "keyboard.badge.checkmark")
                                .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.green)
                        }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        .help(configured.shortcut?.detailedDisplayName(using: localization) ?? "")

                        Button(configured.shortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again") {
                            applicationShortcutCaptureProfileID = nil
                            shortcutCaptureFeedback = nil
                            shortcutCaptureTarget = target
                        }
                        .compatibilityButtonStyle(.standard)

                        Button("common.action.clear") {
                            setMappingShortcut(nil, for: button, trigger: trigger)
                            shortcutCaptureFeedback = nil
                        }
                        .compatibilityButtonStyle(.standard)
                        .disabled(configured.shortcut == nil)
                    }

                    shortcutCaptureFeedbackView(contextID: contextID)

                    KeyboardShortcutPicker(
                        shortcut: configured.shortcut,
                        showsStandardKeyboardInitially: initialShortcutPickerShowsKeyboard,
                        onSelect: { shortcut in
                            setMappingShortcut(shortcut, for: button, trigger: trigger)
                            shortcutCaptureFeedback = nil
                        }
                    )
                    .id("mapping-shortcut-editor-\(contextID)")
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 「打开具体 APP」动作组里只负责挑目标 App；输入框聚焦与滚动区域不是打开 App 的一部分，
    /// 它们按 App 生效、App 在前台就能用，统一放在平级的「App 输入框和滚动」里配置。
    @ViewBuilder
    private func customApplicationTargetPicker(
        button: RemoteButton,
        trigger: ButtonTrigger,
        configured: ConfiguredButtonAction
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("custom_application.target")
                .font(.system(size: 14, weight: .semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(settings.customApplicationProfiles) { profile in
                    profileSelectionButton(
                        profile,
                        selected: configured.applicationProfileID == profile.id
                    ) {
                        setMappingApplicationProfileID(profile.id, for: button, trigger: trigger)
                    }
                }

                Button {
                    guard let id = pickCustomApplicationProfile() else { return }
                    setMappingApplicationProfileID(id, for: button, trigger: trigger)
                } label: {
                    Label("custom_application.add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .compatibilityButtonStyle(.standard)
            }

            if let profile = settings.customApplicationProfile(id: configured.applicationProfileID) {
                // 聚焦与翻页属于 APP 档案，这里只报状态并给出跳转，不复制可写控件。
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(applicationStatusSummary(profile))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("custom_application.go_configure") {
                        applicationDetailProfileID = profile.id
                        selectedSection = .applications
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
            } else {
                Text("custom_application.not_configured")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var applicationsPage: some View {
        settingsPage {
            VStack(alignment: .leading, spacing: 6) {
                PageHeader(title: localization.text("settings.section.applications"))
                Text("custom_application.page.subtitle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            if settings.customApplicationProfiles.isEmpty {
                applicationEmptyPanel
            } else {
                HStack(alignment: .top, spacing: 14) {
                    applicationListPanel
                        .frame(width: 246)
                    applicationDetailPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var resolvedApplicationProfileID: UUID? {
        applicationDetailProfileID ?? settings.customApplicationProfiles.first?.id
    }

    private var applicationListPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("custom_application.list.title")
                    .font(.system(size: 20, weight: .bold))

                VStack(spacing: 6) {
                    ForEach(settings.customApplicationProfiles) { profile in
                        applicationListRow(profile)
                    }
                }

                Button {
                    guard let id = pickCustomApplicationProfile() else { return }
                    applicationDetailProfileID = id
                    applicationShortcutCaptureProfileID = nil
                } label: {
                    Label("custom_application.add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .compatibilityButtonStyle(.standard)
            }
        }
    }

    /// 左侧列表的一行：图标、名称、聚焦与翻页状态，选中项用任务里既有的强调底色。
    private func applicationListRow(_ profile: CustomApplicationProfile) -> some View {
        let isSelected = resolvedApplicationProfileID == profile.id
        return Button {
            applicationDetailProfileID = profile.id
            applicationShortcutCaptureProfileID = nil
        } label: {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: profile.applicationPath))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(applicationCompactStatus(profile))
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.accentColor.opacity(0.75) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    private var applicationEmptyPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("custom_application.empty_title")
                    .font(.system(size: 20, weight: .bold))
                Text("custom_application.empty_hint")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    guard let id = pickCustomApplicationProfile() else { return }
                    applicationDetailProfileID = id
                    applicationShortcutCaptureProfileID = nil
                } label: {
                    Label("custom_application.add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .compatibilityButtonStyle(.prominent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var applicationDetailPanel: some View {
        if let profile = settings.customApplicationProfile(id: resolvedApplicationProfileID) {
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(profile.displayName)
                            .font(.system(size: 18, weight: .semibold))
                        Text(profile.applicationPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }

                    Text("custom_application.focus.scope_note")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    applicationSectionCard {
                        Text("custom_application.focus_strategy")
                            .font(.system(size: 14, weight: .semibold))

                        // 顺序固定：① 只打开 APP ② 打开后自动聚焦；快捷键是兜底，不再并列。
                        HStack(spacing: 8) {
                            applicationFocusOption(profile, .none, key: "custom_application.focus.none")
                            applicationFocusOption(
                                profile,
                                .recordedAccessibility,
                                key: "custom_application.focus.recorded"
                            )
                        }

                        if profile.focusStrategy == .recordedAccessibility {
                            accessibilityLearningEditor(profile)
                            if profile.accessibilityTarget == nil {
                                Text("custom_application.focus.learn_hint")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if profile.focusStrategy == .keyboardShortcut {
                            inlineApplicationShortcutEditor(profile)
                            HStack(spacing: 8) {
                                Spacer()
                                Button("custom_application.focus.shortcut_back") {
                                    var updated = profile
                                    updated.focusStrategy = .recordedAccessibility
                                    settings.updateCustomApplicationProfile(updated)
                                    applicationShortcutCaptureProfileID = nil
                                }
                                .compatibilityButtonStyle(.standard)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("custom_application.focus.shortcut_hint")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("custom_application.focus.shortcut_use") {
                                    var updated = profile
                                    updated.focusStrategy = .keyboardShortcut
                                    settings.updateCustomApplicationProfile(updated)
                                }
                                .compatibilityButtonStyle(.standard)
                            }
                            .padding(.top, 2)
                        }

                        HStack {
                            Spacer()
                            Button("custom_application.test") {
                                _ = KeyboardInjector.send(
                                    .openCustomApplication,
                                    applicationProfile: profile
                                )
                            }
                            .compatibilityButtonStyle(.prominent)
                        }
                    }

                    applicationSectionCard { scrollRegionEditor(profile) }

                    applicationSectionCard { applicationBindingSection(profile) }
                }
            }
        } else {
            GlassPanel {
                Text("custom_application.not_configured")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// 详情里的三个分区用同一张内嵌卡片，避免只有一条细分隔线导致下面被发现不了。
    private func applicationSectionCard<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        // 必须先收进一个 VStack：直接把修饰符挂在多子视图的 @ViewBuilder 上会被摊到每个子视图，
        // 结果是每个控件各自一张卡片，而不是整块一张。
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14))
        }
    }

    private func applicationFocusOption(
        _ profile: CustomApplicationProfile,
        _ strategy: CustomApplicationFocusStrategy,
        key: String
    ) -> some View {
        let isSelected = profile.focusStrategy == strategy
        return Button {
            var updated = profile
            updated.focusStrategy = strategy
            settings.updateCustomApplicationProfile(updated)
            applicationShortcutCaptureProfileID = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(LocalizedStringKey(key))
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16))
        }
    }

    private func applicationStatusSummary(_ profile: CustomApplicationProfile) -> String {
        String(
            format: localization.text("custom_application.status.line"),
            profile.focusStrategy.displayName(using: localization),
            applicationScrollStatusText(profile)
        )
    }

    /// 列表一行的状态很短，用短标签；详情与按键页仍用全名。
    private func applicationCompactStatus(_ profile: CustomApplicationProfile) -> String {
        let focusKey: String
        switch profile.focusStrategy {
        case .none: focusKey = "custom_application.focus.short.none"
        case .keyboardShortcut: focusKey = "custom_application.focus.short.shortcut"
        case .recordedAccessibility: focusKey = "custom_application.focus.short.recorded"
        }
        return String(
            format: localization.text("custom_application.status.compact"),
            localization.text(focusKey),
            applicationScrollStatusText(profile)
        )
    }

    private func applicationScrollStatusText(_ profile: CustomApplicationProfile) -> String {
        if profile.scrollRegionTarget != nil {
            return localization.text("scroll_region.status_learned")
        }
        if ScrollRegionPreset.rule(for: profile.bundleIdentifier) != nil {
            return localization.text("scroll_region.status_preset")
        }
        return localization.text("scroll_region.status_needs_calibration")
    }

    private struct ApplicationBindingRef: Identifiable {
        let button: RemoteButton
        let trigger: ButtonTrigger
        /// 来自哪个键位方案；nil 表示当前按键配置。
        let profile: ButtonMappingProfile?
        var id: String {
            "\(profile?.id.uuidString ?? "base")-\(button.rawValue)-\(trigger.rawValue)"
        }
    }

    /// 反查范围限定当前遥控器与当前键位方案生效后的绑定，不混入其它遥控器。
    private func applicationBindings(for profile: CustomApplicationProfile) -> [ApplicationBindingRef] {
        var result: [ApplicationBindingRef] = []
        for button in RemoteButton.allCases {
            for trigger in ButtonTrigger.allCases {
                let configured = mappingConfiguration(for: button, trigger: trigger)
                guard configured.action == .openCustomApplication,
                      configured.applicationProfileID == profile.id
                else { continue }
                result.append(ApplicationBindingRef(button: button, trigger: trigger, profile: nil))
            }
        }
        // 键位方案里的绑定同样要出现在这里，否则「他到底被谁用着」只能看到一半。
        let device = settings.selectedRemoteProfileID
        for mappingProfile in macroFeature.mappingProfiles(device: device) {
            for button in RemoteButton.allCases {
                for trigger in ButtonTrigger.allCases {
                    guard let bound = macroFeature.profileBinding(
                        device: device,
                        profile: mappingProfile.id,
                        button: button,
                        trigger: trigger
                    ) else { continue }
                    let configured = bound.normalizedForExecution
                    guard configured.action == .openCustomApplication,
                          configured.applicationProfileID == profile.id
                    else { continue }
                    result.append(ApplicationBindingRef(
                        button: button,
                        trigger: trigger,
                        profile: mappingProfile
                    ))
                }
            }
        }
        return result
    }

    @ViewBuilder
    private func applicationBindingSection(_ profile: CustomApplicationProfile) -> some View {
        let bindings = applicationBindings(for: profile)
        VStack(alignment: .leading, spacing: 8) {
            Text("custom_application.bindings.title")
                .font(.system(size: 14, weight: .semibold))

            if bindings.isEmpty {
                Text("custom_application.bindings.empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(bindings) { binding in
                    Button {
                        preservesMappingContextOnNavigation = true
                        mappingHoldEditingButton = nil
                        mappingActionFilter = .all
                        if let mappingProfile = binding.profile {
                            openMappingProfileForEditing(mappingProfile.id)
                        } else {
                            selectMappingProfile(nil)
                        }
                        mappingEditingTarget = ShortcutEditingTarget(
                            button: binding.button,
                            trigger: binding.trigger
                        )
                        selectedSection = .mapping
                    } label: {
                        HStack(spacing: 8) {
                            if let mappingProfile = binding.profile {
                                Text(mappingProfile.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(Color.accentColor)
                                    .background(
                                        Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                            }
                            Text("\(binding.button.displayName(using: localization)) · " +
                                 binding.trigger.displayName(using: localization))
                                .font(.system(size: 12, weight: .semibold))
                            Text("action.open_custom_application")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("custom_application.bindings.go_mapping")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func profileSelectionButton(
        _ profile: CustomApplicationProfile,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "app")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(profile.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inlineApplicationShortcutEditor(_ profile: CustomApplicationProfile) -> some View {
        let contextID = "application-\(profile.id.uuidString)"
        VStack(alignment: .leading, spacing: 10) {
            Text("custom_application.shortcut.editor_instructions")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if applicationShortcutCaptureProfileID == profile.id {
                HStack(spacing: 10) {
                    Label("shortcut.editor.recording_prompt", systemImage: "keyboard.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    Button("common.action.cancel") {
                        applicationShortcutCaptureProfileID = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                ShortcutCaptureView(
                    onCapture: { shortcut in
                        guard var updated = settings.customApplicationProfile(id: profile.id) else { return }
                        updated.focusShortcut = shortcut
                        settings.updateCustomApplicationProfile(updated)
                        AppLogger.shared.write("SHORTCUT CAPTURE completed target=application_focus")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .succeeded
                        )
                        applicationShortcutCaptureProfileID = nil
                    },
                    onFailure: { failure in
                        AppLogger.shared.write("SHORTCUT CAPTURE failed reason=\(failure)")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .failed(failure)
                        )
                        applicationShortcutCaptureProfileID = nil
                        if failure == .accessibilityPermissionRequired {
                            _ = KeyboardInjector.requestAccessibilityAccess()
                        }
                    }
                )
                .frame(height: 1)
            } else {
                HStack(spacing: 10) {
                    Label {
                        Text(
                            profile.focusShortcut?.displayName(using: localization) ??
                                localization.text("shortcut.editor.not_recorded")
                        )
                    } icon: {
                        Image(systemName: profile.focusShortcut == nil ? "keyboard" : "keyboard.badge.checkmark")
                            .foregroundStyle(profile.focusShortcut == nil ? Color.secondary : Color.green)
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(profile.focusShortcut == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                    Button(profile.focusShortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again") {
                        shortcutCaptureTarget = nil
                        shortcutCaptureFeedback = nil
                        applicationShortcutCaptureProfileID = profile.id
                    }
                    .compatibilityButtonStyle(.prominent)

                    Button("common.action.clear") {
                        var updated = profile
                        updated.focusShortcut = nil
                        settings.updateCustomApplicationProfile(updated)
                        shortcutCaptureFeedback = nil
                    }
                    .compatibilityButtonStyle(.standard)
                    .disabled(profile.focusShortcut == nil)
                }

                shortcutCaptureFeedbackView(contextID: contextID)
            }
        }
    }

    @ViewBuilder
    private func shortcutCaptureFeedbackView(contextID: String) -> some View {
        if shortcutCaptureFeedback?.contextID == contextID,
           let result = shortcutCaptureFeedback?.result {
            switch result {
            case .succeeded:
                Label("shortcut.editor.success", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            case .failed(.accessibilityPermissionRequired):
                Label("shortcut.editor.permission_required", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(.eventTapUnavailable):
                Label("shortcut.editor.capture_unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func accessibilityLearningEditor(_ profile: CustomApplicationProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("custom_application.accessibility.learn_help")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("custom_application.accessibility.learn") {
                    recordCustomApplicationInput(profileID: profile.id)
                }
                .compatibilityButtonStyle(.prominent)
                .disabled(customApplicationLearningStates[profile.id] == .recording)

                Button(localization.text("custom_application.accessibility.test")) {
                    KeyboardInjector.testCustomApplicationInput(profile) { success in
                        DispatchQueue.main.async {
                            if success { settings.markPortableApplicationVerified(profile.id) }
                            customApplicationLearningStates[profile.id] = success ? .succeeded : .failed
                        }
                    }
                }
                .compatibilityButtonStyle(.standard)
                .disabled(profile.accessibilityTarget == nil)
                Text(
                    settings.portablePendingApplications.contains(profile.id.uuidString)
                        ? localization.text("custom_application.accessibility.needs_verification")
                        : profile.accessibilityTarget == nil
                        ? localization.text("custom_application.accessibility.not_recorded")
                        : localization.text("custom_application.accessibility.recorded")
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(profile.accessibilityTarget == nil ? Color.orange : Color.green)
            }

            if let learningState = customApplicationLearningStates[profile.id] {
                Label(
                    localization.text(learningState.messageKey),
                    systemImage: learningState.systemImage
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(learningState.tint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func scrollRegionEditor(_ profile: CustomApplicationProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("scroll_region.title")
                    .font(.system(size: 14, weight: .semibold))
                Text(scrollRegionStatusKey(profile))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(scrollRegionStatusTint(profile))
                Spacer()
            }

            Text("scroll_region.help")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("scroll_region.learn") {
                    learnScrollRegion(profile)
                }
                .compatibilityButtonStyle(.prominent)
                .disabled(scrollRegionCountdowns[profile.id] != nil)

                if let remaining = scrollRegionCountdowns[profile.id] {
                    Text(String(format: localization.text("scroll_region.countdown"), remaining))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("scroll_region.test_up") {
                    testScrollRegion(profile, direction: .up)
                }
                .compatibilityButtonStyle(.standard)

                Button("scroll_region.test_down") {
                    testScrollRegion(profile, direction: .down)
                }
                .compatibilityButtonStyle(.standard)

                if profile.scrollRegionTarget != nil {
                    Button("scroll_region.reset") {
                        resetScrollRegion(profile)
                    }
                    .compatibilityButtonStyle(.standard)
                }
            }

            if let messageKey = scrollRegionMessages[profile.id] {
                Text(LocalizedStringKey(messageKey))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        messageKey.hasSuffix("failed") ||
                            messageKey.hasSuffix("unconfirmed") ||
                            messageKey.hasSuffix("needs_calibration")
                            ? Color.orange : Color.green
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scrollRegionStatusKey(_ profile: CustomApplicationProfile) -> LocalizedStringKey {
        if profile.scrollRegionTarget != nil { return "scroll_region.status_learned" }
        if ScrollRegionPreset.rule(for: profile.bundleIdentifier) != nil {
            return "scroll_region.status_preset"
        }
        return "scroll_region.status_needs_calibration"
    }

    private func scrollRegionStatusTint(_ profile: CustomApplicationProfile) -> Color {
        profile.scrollRegionTarget != nil ||
            ScrollRegionPreset.rule(for: profile.bundleIdentifier) != nil ? .green : .orange
    }

    private func learnScrollRegion(_ profile: CustomApplicationProfile) {
        guard KeyboardInjector.isAccessibilityTrusted else {
            model.requestAccessibilityPermission()
            return
        }
        let savedURL = URL(fileURLWithPath: profile.applicationPath)
        let applicationURL = Bundle(url: savedURL)?.bundleIdentifier == profile.bundleIdentifier
            ? savedURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier)
        guard let applicationURL else {
            scrollRegionMessages[profile.id] = "scroll_region.learn_failed"
            return
        }

        scrollRegionMessages[profile.id] = nil
        let session = ScrollRegionLearningSession()
        session.monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            if session.point == nil { session.point = CGEvent(source: nil)?.location }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                guard error == nil else {
                    ScrollRegionLearningSession.finish(session)
                    scrollRegionCountdowns[profile.id] = nil
                    scrollRegionMessages[profile.id] = "scroll_region.learn_failed"
                    return
                }
                startScrollRegionCountdown(profile: profile, session: session)
            }
        }
    }

    private func startScrollRegionCountdown(
        profile: CustomApplicationProfile,
        session: ScrollRegionLearningSession
    ) {
        Task { @MainActor in
            for remaining in stride(from: 3, through: 1, by: -1) {
                scrollRegionCountdowns[profile.id] = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if session.point != nil { break }
            }
            ScrollRegionLearningSession.finish(session)
            scrollRegionCountdowns[profile.id] = nil

            let point = session.point ?? CGEvent(source: nil)?.location
            guard let point,
                  let target = ScrollRegionInjector.captureTarget(
                      bundleIdentifier: profile.bundleIdentifier,
                      point: point
                  ),
                  var updated = settings.customApplicationProfile(id: profile.id)
            else {
                scrollRegionMessages[profile.id] = "scroll_region.learn_failed"
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            updated.scrollRegionTarget = target
            settings.updateCustomApplicationProfile(updated)
            scrollRegionMessages[profile.id] = "scroll_region.learn_succeeded"
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func testScrollRegion(_ profile: CustomApplicationProfile, direction: ScrollPageDirection) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: profile.bundleIdentifier
        ) else {
            scrollRegionMessages[profile.id] = "scroll_region.test_failed"
            return
        }
        let learned = profile.scrollRegionTarget
        scrollRegionMessages[profile.id] = nil

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            guard error == nil else {
                DispatchQueue.main.async {
                    scrollRegionMessages[profile.id] = "scroll_region.test_failed"
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
                let result = ScrollRegionInjector.scrollPage(
                    direction: direction,
                    learnedTarget: learned,
                    verifyMovement: true
                )
                DispatchQueue.main.async {
                    scrollRegionMessages[profile.id] = scrollRegionTestMessage(for: result)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func scrollRegionTestMessage(for result: ScrollPageResult) -> String {
        switch result.outcome {
        case .scrolledByPageAction, .scrolledByPixelWheel:
            switch result.verifiedMovement {
            case true: return "scroll_region.test_moved"
            case false: return "scroll_region.test_unconfirmed"
            case nil: return "scroll_region.test_sent"
            }
        case .queued:
            return "scroll_region.test_sent"
        case .needsCalibration:
            return "scroll_region.test_needs_calibration"
        default:
            return "scroll_region.test_failed"
        }
    }

    private func resetScrollRegion(_ profile: CustomApplicationProfile) {
        guard var updated = settings.customApplicationProfile(id: profile.id) else { return }
        updated.scrollRegionTarget = nil
        settings.updateCustomApplicationProfile(updated)
        scrollRegionMessages[profile.id] = nil
    }

    /// 让用户挑一个 `.app`，返回（或复用）它的配置 ID；是否把它写进按键绑定由调用方决定——
    /// 「打开具体 APP」组里写绑定，「App 输入框和滚动」里只切换正在配置的 App。
    private func pickCustomApplicationProfile() -> UUID? {
        let panel = NSOpenPanel()
        panel.title = localization.text("custom_application.picker.title")
        panel.prompt = localization.text("common.action.choose")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return nil }

        let existing = settings.customApplicationProfiles.first {
            $0.bundleIdentifier == bundleIdentifier
        }
        let profileID: UUID
        if let existing {
            var updated = existing
            updated.applicationPath = url.path
            settings.updateCustomApplicationProfile(updated)
            profileID = existing.id
        } else {
            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            profileID = settings.addCustomApplicationProfile(
                CustomApplicationProfile(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    applicationPath: url.path
                )
            )
        }
        return profileID
    }

    private func chooseCustomApplicationForButtonProfile(
        _ completion: @escaping (String, String, Data) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = localization.text("custom_application.picker.title")
        panel.prompt = localization.text("common.action.choose")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return }

        let existing = settings.customApplicationProfiles.first {
            $0.bundleIdentifier == bundleIdentifier
        }
        let profileID: UUID
        let displayName: String
        if let existing {
            var updated = existing
            updated.applicationPath = url.path
            settings.updateCustomApplicationProfile(updated)
            profileID = existing.id
            displayName = existing.displayName
        } else {
            displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            profileID = settings.addCustomApplicationProfile(
                CustomApplicationProfile(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    applicationPath: url.path
                )
            )
        }

        guard let payload = try? JSONEncoder().encode(
            ConfiguredButtonAction(
                action: .openCustomApplication,
                shortcut: nil,
                applicationProfileID: profileID
            )
        ) else { return }

        completion(
            "host.customApplication.\(profileID.uuidString.lowercased())",
            displayName,
            payload
        )
    }

    private func recordCustomApplicationInput(profileID: UUID) {
        guard KeyboardInjector.isAccessibilityTrusted else {
            model.requestAccessibilityPermission()
            return
        }
        guard let profile = settings.customApplicationProfile(id: profileID) else { return }
        customApplicationLearningStates[profileID] = .recording
        let savedURL = URL(fileURLWithPath: profile.applicationPath)
        let applicationURL = Bundle(url: savedURL)?.bundleIdentifier == profile.bundleIdentifier
            ? savedURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier)
        guard let applicationURL else {
            customApplicationLearningStates[profileID] = .applicationMissing
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            guard error == nil else {
                DispatchQueue.main.async {
                    customApplicationLearningStates[profileID] = .openFailed
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let target = KeyboardInjector.captureFocusedAccessibilityTarget(
                    bundleIdentifier: profile.bundleIdentifier
                )
                if let target, var updated = settings.customApplicationProfile(id: profileID) {
                    updated.accessibilityTarget = target
                    updated.focusStrategy = .recordedAccessibility
                    settings.updateCustomApplicationProfile(updated)
                    settings.markPortableApplicationVerified(updated.id)
                }
                customApplicationLearningStates[profileID] = target == nil ? .failed : .succeeded
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func mappingActionSummary(for button: RemoteButton, trigger: ButtonTrigger,
                                      configuredAction: ConfiguredButtonAction? = nil) -> String {
        actionSummary(configuredAction ?? mappingConfiguration(for: button, trigger: trigger))
    }

    /// The user-visible name of one configured action. An unrecorded custom shortcut must not
    /// read as if it already performed something.
    private func actionSummary(_ configured: ConfiguredButtonAction) -> String {
        guard configured.action != .disabled else {
            return localization.text("button_mapping.action.not_set")
        }
        if configured.action == .combinationAction {
            return macroFeature.libraryActions.first { $0.id == configured.macroID }?.name
                ?? localization.text("button_mapping.macro_unavailable")
        }
        if configured.action == .customShortcut {
            guard let shortcut = configured.shortcut else {
                return localization.text("button_mapping.action.not_set")
            }
            return shortcut.visualDisplayName(using: localization)
        }
        if configured.action == .openCustomApplication {
            return settings.customApplicationProfile(id: configured.applicationProfileID)?.displayName
                ?? localization.text("custom_application.not_configured")
        }
        switch configured.action {
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .deleteBackward: return "⌫"
        case .volumeUp: return localization.text("action.system_volume_up_short")
        case .volumeDown: return localization.text("action.system_volume_down_short")
        case .volumeMute: return "Mute"
        default: break
        }
        return configured.action.displayName(using: localization)
    }

    private var buttonProfileHostActionSections: [ButtonProfileHostActionSection] {
        let availableActions = ButtonAction.pickerActions(
            installedBundleIdentifiers: PresetApplication.installedBundleIdentifiers,
            current: .disabled,
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ).filter {
            $0 != .disabled && $0 != .customShortcut && $0 != .openCustomApplication && $0 != .combinationAction
        }
        return ButtonActionCategory.allCases.compactMap { category in
            let actions: [ButtonProfileHostAction] = availableActions
                .filter { $0.category == category }
                .compactMap { action in
                guard let payload = try? JSONEncoder().encode(ConfiguredButtonAction(
                    action: action,
                    shortcut: nil
                )) else { return nil }
                return ButtonProfileHostAction(
                    id: "host.action.\(action.rawValue)",
                    title: action.displayName(using: localization),
                    detail: nil,
                    systemImage: buttonProfileSystemImage(for: action),
                    payload: payload,
                    isAvailable: true
                )
                }
            guard !actions.isEmpty else { return nil }
            return ButtonProfileHostActionSection(
                id: "host.section.\(category.rawValue)",
                title: localization.text(category.localizationKey),
                actions: actions
            )
        }
    }

    private func buttonProfileSystemImage(for action: ButtonAction) -> String {
        if action.presetApplication != nil { return "app" }
        switch action {
        case .openCommonPhrases: return "text.quote"
        case .focusInput: return "scope"
        case .showDesktop: return "macwindow"
        case .appSwitcher: return "command"
        case .volumeUp, .volumeDown, .volumeMute: return "speaker.wave.2"
        case .playPause, .previousCommandLeft, .nextCommandRight: return "play.circle"
        case .toggleLongRecording: return "record.circle"
        default: return "keyboard"
        }
    }

    // Legacy entry point retained for callers that still ask for the old route.
    // The visible navigation now renders permissions and diagnostics inline in Settings.
    private var permissionsPage: some View {
        aboutPage
    }

    private var statisticsPage: some View {
        settingsPage {
            PageHeader(title: localization.text("statistics.page.title"))
        } content: {
            VStack(spacing: 14) {
                sharePanel(for: .statistics)
                statisticsSummaryGrid
                StatisticsColumnsLayout {
                    statisticsRankingPanel
                    VStack(spacing: 14) {
                        statisticsCalendarPanel
                        statisticsVoiceSessionRankingPanel
                    }
                }
            }
        }
    }

    private var statisticsSummaryGrid: some View {
        // Keep the approved layout as one row at the default width; only the narrowest windows wrap.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(statisticsMetrics) { metric in
                    ProfileMetricCard(metric: metric)
                        .frame(minWidth: 170, maxWidth: .infinity)
                }
            }
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(statisticsMetrics) { metric in
                    ProfileMetricCard(metric: metric)
                }
            }
        }
    }

    private var statisticsMetrics: [ProfileMetric] {
        [
            ProfileMetric(
                id: "total-buttons",
                systemImage: "keyboard",
                title: localization.text("statistics.metric.total_button_count"),
                value: localizedNumber(settings.usageStatistics(for: .total).buttonPressCount),
                unit: countUnit
            ),
            ProfileMetric(
                id: "total-voice",
                systemImage: "waveform",
                title: localization.text("statistics.metric.total_voice_duration"),
                value: voiceDurationText(for: .total),
                unit: nil
            ),
            ProfileMetric(
                id: "week-buttons",
                systemImage: "chart.line.uptrend.xyaxis",
                title: localization.text("statistics.metric.week_button_count"),
                value: localizedNumber(settings.usageStatistics(for: .thisWeek).buttonPressCount),
                unit: countUnit
            ),
            ProfileMetric(
                id: "longest-voice",
                systemImage: "clock",
                title: localization.text("statistics.metric.longest_voice"),
                value: chartDurationText(
                    seconds: UsageStatisticsPresentation.wholeSeconds(
                        settings.usageMetadata(for: .total).longestVoiceSessionDuration
                    )
                ),
                unit: nil
            ),
        ]
    }

    /// Counter word such as “次”. English reads counts without one, so the key may be empty
    /// and the surrounding rows skip the label entirely.
    private var countUnit: String? {
        let unit = localization.text("statistics.metric.count_unit")
        return unit.isEmpty ? nil : unit
    }

    private var statisticsRankingPanel: some View {
        ProfilePanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("statistics.ranking.title")
                    .font(.title3.weight(.semibold))

                statisticsRankingSection(
                    title: localization.text("statistics.ranking.actions"),
                    systemImage: "keyboard",
                    entries: statisticsActionRanking
                ) { entry in
                    HStack(spacing: 8) {
                        Text(entry.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(localizedNumber(entry.count))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let countUnit {
                            Text(countUnit)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                statisticsRankingSection(
                    title: localization.text("statistics.ranking.buttons"),
                    systemImage: "rectangle.grid.1x2",
                    entries: statisticsButtonRanking
                ) { entry in
                    HStack(spacing: 8) {
                        Text(entry.title)
                        Spacer(minLength: 4)
                        Text(localizedNumber(entry.count))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let countUnit {
                            Text(countUnit)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            }
        }
    }

    private func statisticsRankingSection<Row: View>(
        title: String,
        systemImage: String,
        entries: [StatisticsRankingEntry],
        @ViewBuilder row: @escaping (StatisticsRankingEntry) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            if entries.isEmpty {
                Text("statistics.ranking.empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.prefix(10).enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                            .frame(width: 18, alignment: .leading)
                        row(entry)
                    }
                    .padding(.vertical, 3)
                    if index < min(entries.count, 10) - 1 { Divider() }
                }
            }
        }
    }

    private var statisticsCalendarPanel: some View {
        ProfilePanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("statistics.calendar.title")
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("statistics.calendar.hint")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 160, alignment: .trailing)
                }

                TimelineView(.everyMinute) { context in
                    StatisticsHeatmap(
                        days: statisticsCalendarDays(endingAt: context.date),
                        selectedDate: $selectedStatisticsDate,
                        localization: localization
                    )
                }

                if let selectedStatisticsDate {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(calendarDateText(selectedStatisticsDate))
                                .font(.subheadline.weight(.semibold))
                            Button {
                                selectedSection = .transcripts
                            } label: {
                                Label(
                                    "statistics.calendar.open_reflections",
                                    systemImage: "arrow.up.right"
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        .padding(10)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { model.refreshTranscriptRecords() }
    }

    private var statisticsVoiceSessionRankingPanel: some View {
        ProfilePanel {
            VStack(alignment: .leading, spacing: 7) {
                Label(
                    localization.text("statistics.ranking.voice_sessions"),
                    systemImage: "waveform"
                )
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)

                if settings.voiceSessionRanking.isEmpty {
                    Text("statistics.voice_ranking.empty")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(settings.voiceSessionRanking.prefix(10).enumerated()), id: \.element.id) {
                        index, record in
                        Button {
                            selectedSection = .transcripts
                        } label: {
                            HStack(spacing: 7) {
                                Text("\(index + 1)")
                                    .foregroundStyle(.orange)
                                    .frame(width: 18, alignment: .leading)
                                Text(chartDurationText(
                                    seconds: UsageStatisticsPresentation.wholeSeconds(record.duration)
                                ))
                                .monospacedDigit()
                                Text("·").foregroundStyle(.secondary)
                                Text(record.applicationName ?? localization.text(
                                    "statistics.ranking.unknown_app"
                                )).lineLimit(1)
                                Spacer(minLength: 3)
                                Text(voiceSessionDateText(record.endedAt))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)
                        if index < min(settings.voiceSessionRanking.count, 10) - 1 {
                            Divider()
                        }
                    }
                }

                Button {
                    selectedSection = .transcripts
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("statistics.ranking.view_all")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private var transcriptHistoryPage: some View {
        settingsPage {
            HStack(alignment: .center, spacing: 14) {
                PageHeader(title: localization.text("statistics.transcripts.title"))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                Text(localization.text("statistics.transcripts.privacy"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 16)
                Toggle(
                    "statistics.transcripts.enable",
                    isOn: $settings.localTranscriptHistoryEnabled
                )
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
                Toggle(
                    "statistics.transcripts.recording_enable",
                    isOn: $settings.localOriginalAudioRecordingEnabled
                )
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
            }
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                TranscriptHistorySection(model: model, settings: settings)
            }
        }
    }

    // Kept as a source boundary for existing regression checks; the ranking now lives inline above.
    private var voiceSessionRankingCard: some View {
        EmptyView()
    }

    private var inlinePermissionsSection: some View {
        let bluetoothAction = SettingsPageBehavior.permissionAction(
            for: .bluetooth,
            isGranted: bluetoothPermissionState == .granted
        )
        let inputMonitoringAction = SettingsPageBehavior.permissionAction(
            for: .inputMonitoring,
            isGranted: inputMonitoringGranted
        )
        let accessibilityAction = SettingsPageBehavior.permissionAction(
            for: .accessibility,
            isGranted: accessibilityGranted
        )

        return VStack(alignment: .leading, spacing: 0) {
            Text("settings.permissions.title")
                .font(.title3.weight(.semibold))

            permissionRow(
                symbol: "antenna.radiowaves.left.and.right",
                title: localization.text("permission.bluetooth.title"),
                detail: localization.text("permission.bluetooth.description"),
                state: bluetoothPermissionState,
                actionTitle: localization.text("permission.bluetooth.open_settings")
            ) {
                performPermissionAction(bluetoothAction) {}
            }

            Divider().padding(.leading, 48)

            permissionRow(
                symbol: "keyboard",
                title: localization.text("permission.input_monitoring.title"),
                detail: localization.text("permission.input_monitoring.description"),
                state: inputMonitoringGranted ? .granted : .pending,
                actionTitle: localization.text(inputMonitoringAction.titleKey)
            ) {
                performPermissionAction(inputMonitoringAction) {
                    model.requestInputMonitoringPermission()
                }
            }

            Divider().padding(.leading, 48)

            permissionRow(
                symbol: "accessibility",
                title: localization.text("permission.accessibility.title"),
                detail: localization.text("permission.accessibility.description"),
                state: accessibilityGranted ? .granted : .pending,
                actionTitle: localization.text(accessibilityAction.titleKey)
            ) {
                performPermissionAction(accessibilityAction) {
                    model.requestAccessibilityPermission()
                }
            }

            if settings.isOnboardingComplete,
               !inputMonitoringGranted || !accessibilityGranted {
                Divider().padding(.leading, 48)
                Label("permissions.upgrade_identity_help", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var inlineDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.diagnostics.title")
                .font(.title3.weight(.semibold))
            Text("diagnostics.logs.privacy")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("diagnostics.logs.title")
                        .font(.subheadline.weight(.semibold))
                    Text("diagnostics.logs.last_entry")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(model.diagnosticUploadStatus.text(using: localization))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button("diagnostics.logs.send") { model.sendDiagnosticLogs() }
                        .compatibilityButtonStyle(.prominent)
                        .disabled(model.isSendingDiagnosticLogs)
                    Button("diagnostics.logs.show_in_finder") { model.openLogFolder() }
                        .compatibilityButtonStyle(.standard)
                    Button("diagnostics.logs.copy_summary") { copySettingsDiagnosticSummary() }
                        .compatibilityButtonStyle(.standard)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var appIconPreferenceRow: some View {
        let selectedIdentifier = appIconCatalog.resolvedIdentifier(
            for: settings.appIconIdentifier
        )

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "app.badge")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("about.preferences.app_icon")
                    .font(.subheadline.weight(.semibold))
                Text("about.preferences.app_icon_help")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                ForEach(appIconCatalog.options) { option in
                    Button {
                        settings.appIconIdentifier = option.id
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: option.image)
                                .resizable()
                                .frame(width: 38, height: 38)
                            if selectedIdentifier == option.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .background(Circle().fill(.background))
                            }
                        }
                        .padding(7)
                        .background(
                            selectedIdentifier == option.id
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    selectedIdentifier == option.id
                                        ? Color.accentColor.opacity(0.55)
                                        : Color.secondary.opacity(0.18),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey(option.titleKey)))
                    .accessibilityAddTraits(
                        selectedIdentifier == option.id ? .isSelected : []
                    )
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var aboutPage: some View {
        settingsPage(contentPadding: 28) {
            PageHeader(title: localization.text("settings.page.title"))
        } content: {
            CompatibilityGlassContainer(spacing: 0) {
                VStack(spacing: 0) {
                    Group {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(nsImage: appIconCatalog.image(
                                    for: settings.appIconIdentifier
                                ))
                                    .resizable()
                                    .frame(width: 72, height: 72)
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                                Text("app.name")
                                    .font(BrandFont.font)
                                Text("settings.application.tagline")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(minWidth: 190, maxWidth: 230, alignment: .leading)

                            Divider()

                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Text("about.version.current")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Button(action: revealPrivateEnrollmentIfNeeded) {
                                        Text(currentVersionWithBuild)
                                            .font(.system(size: 13, weight: .medium))
                                            .monospacedDigit()
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                    if case .available = updateInformation.state {
                                        StatusPill(
                                            text: localization.text("about.version.available"),
                                            tint: .green
                                        )
                                    }
                                    Spacer(minLength: 8)
                                }

                                HStack(spacing: 12) {
                                    Button(action: checkForUpdates) {
                                        Label(
                                            "menu.check_for_updates",
                                            systemImage: "arrow.triangle.2.circlepath"
                                        )
                                    }
                                    .compatibilityButtonStyle(.standard)
                                    .fixedSize(horizontal: true, vertical: false)

                                    Spacer(minLength: 12)

                                    Toggle(
                                        "about.version.check_prerelease",
                                        isOn: $settings.checksForPreReleaseUpdates
                                    )
                                    .toggleStyle(.switch)
                                    .font(.system(size: 12))
                                }

                                Divider()

                                updateInformationContent
                                if case let .available(update) = updateInformation.state {
                                    HStack {
                                        Spacer()
                                        Button(action: checkForUpdates) {
                                            Text(String(
                                                format: localization.text("about.version.update_to"),
                                                locale: localization.locale,
                                                arguments: [update.displayVersion]
                                            ))
                                        }
                                        .compatibilityButtonStyle(.prominent)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                        .overlay(alignment: .bottom) { Divider() }
                    }

                    hardwareAnnouncementPanel

                    inlinePermissionsSection

                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.general.title")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if membershipFeature.isEnvironmentSettingsVisible {
                            membershipFeature.serviceEnvironmentSettingsView()
                                .padding(.vertical, 8)
                        }

                        Group {
                            VStack(spacing: 0) {
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.configuration.title")
                                        .font(.subheadline.weight(.semibold))
                                    Text(LocalizedStringKey(macroFeature.isFeatureVisible
                                        ? "about.configuration.backup_description"
                                        : "about.configuration.export_description"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 16)
                                Button("about.configuration.export", action: exportConfiguration)
                                    .compatibilityButtonStyle(.standard)
                                    .frame(width: 92)
                                Button("about.configuration.import", action: importConfiguration)
                                    .compatibilityButtonStyle(.standard)
                                    .frame(width: 92)
                            }
                            .padding(.vertical, 8)
                            if macroFeature.isFeatureVisible {
                                macroFeature.configurationTransferView(profileID: settings.selectedRemoteProfileID,
                                    model: settings.selectedRemoteProfile?.model)
                            }

                            if let configurationStatus {
                                Divider()
                                Label(
                                    configurationStatus.message.text(using: localization),
                                    systemImage: configurationStatus.systemImage
                                )
                                .font(.caption)
                                .foregroundStyle(configurationStatus.tint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            }

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "dock.rectangle")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.preferences.show_dock_icon")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.preferences.show_dock_icon_help")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { settings.showDockIcon },
                                    set: { setDockIconVisible($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                            .padding(.vertical, 8)

                            Divider()

                            appIconPreferenceRow

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "menubar.rectangle")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.preferences.show_status_bar_icon")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.preferences.show_status_bar_icon_help")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { settings.showStatusBarIcon },
                                    set: { setStatusBarIconVisible($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                            .padding(.vertical, 8)

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "power")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("settings.general.launch_behavior")
                                        .font(.subheadline.weight(.semibold))
                                    Text("settings.general.launch_behavior_help")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                HStack(spacing: 10) {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("about.preferences.launch_at_login")
                                            .font(.system(size: 12, weight: .medium))
                                        Toggle("", isOn: Binding(
                                            get: { loginItemService.isEnabled },
                                            set: { loginItemService.setEnabled($0) }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                    }

                                    Divider()
                                        .frame(height: 34)

                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("about.preferences.open_main_window_at_launch")
                                            .font(.system(size: 12, weight: .medium))
                                        Toggle("", isOn: $settings.openMainWindowAtLaunch)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                    }
                                }
                            }
                            .padding(.vertical, 8)

                            if loginItemService.requiresApproval {
                                Text("about.preferences.launch_at_login_requires_approval")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.bottom, 8)
                                Button(
                                    "about.preferences.launch_at_login_open_system_settings",
                                    action: loginItemService.openLoginItemsSettings
                                )
                                .compatibilityButtonStyle(.standard)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            } else if loginItemService.didFailToUpdate {
                                Text("about.preferences.launch_at_login_update_failed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.bottom, 8)
                            }

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.preferences.language")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.preferences.language_description")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 20)
                                Picker("about.preferences.language", selection: Binding(
                                    get: { localization.language },
                                    set: { localization.select($0) }
                                )) {
                                    ForEach(AppLanguage.allCases) { language in
                                        Text(languageTitle(language)).tag(language)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 300)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.preferences.restart_onboarding")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.preferences.restart_onboarding_help")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 20)
                                Button("about.preferences.restart_onboarding_action") {
                                    settings.restartOnboarding()
                                }
                                .compatibilityButtonStyle(.standard)
                            }
                            .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider() }

                    if privateFeature.shouldShowEnrollment {
                        privateFeature.enrollmentView()
                    }

                    if macroFeature.shouldShowEnrollment {
                        macroFeature.enrollmentView()
                    }

                    inlineDiagnosticsSection

                    if model.isRC003VoiceExtensionTestEnabled {
                        Text("测试长时间语音功能")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }

                    settingsSupportSection
                }
            }
        }
        .onAppear {
            hardwareAnnouncements.refresh()
            guard !SettingsVisualRenderingPolicy.isScreenshotHarness else { return }
            guard UpdateCheckPolicy(
                checksForPreReleaseUpdates: settings.checksForPreReleaseUpdates
            ).refreshesAboutInformationOnAppear else { return }
            refreshUpdateInformation()
        }
    }

    private var settingsSupportSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("about.support.feedback")
                    .font(.subheadline.weight(.semibold))
                Text("about.support.feedback_description")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Link(destination: localization.localizedWebsiteURL) {
                Label("about.support.website", systemImage: "globe")
            }
            .compatibilityButtonStyle(.standard)
            Link(destination: AppLinks.githubRepository) {
                Label("about.support.github", systemImage: "link")
            }
            .compatibilityButtonStyle(.standard)
            Link(destination: AppLinks.feedback) {
                Label("about.support.feedback_action", systemImage: "arrow.up.right")
            }
            .compatibilityButtonStyle(.standard)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var hardwareAnnouncementPanel: some View {
        ForEach(hardwareAnnouncements.announcements) { announcement in
            GlassPanel {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(announcement.title(for: localization.locale))
                            .font(.subheadline.weight(.semibold))
                        Text(announcement.message(for: localization.locale))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Link(destination: announcement.downloadURL) {
                        Label("about.hardware.download", systemImage: "arrow.down.circle")
                    }
                    .compatibilityButtonStyle(.prominent)
                }
            }
        }
    }

    private func sharePanel(for section: SettingsSection) -> some View {
        let isExpanded = expandedShareSection == section
        let shareURL = AppShareLink.url(for: localization.locale)

        return ProfilePanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("share.title")
                            .font(.subheadline.weight(.semibold))
                        Text("share.description")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Button {
                        expandedShareSection = isExpanded ? nil : section
                    } label: {
                        Label(
                            isExpanded ? "share.hide_action" : "share.show_action",
                            systemImage: isExpanded ? "chevron.up" : "qrcode"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                if isExpanded {
                    Divider()
                    ShareCard(url: shareURL)
                        .id(shareURL)
                }
            }
        }
    }

    private func sectionTitle(_ section: SettingsSection) -> String {
        switch section {
        case .privateFeature: privateFeature.sectionTitle
        case .macros: macroFeature.sectionTitle
        case .buttonProfiles: macroFeature.buttonProfilesSectionTitle
        case .membership: membershipFeature.sectionTitle
        default: supplementalPages.first { SettingsSection.supplemental($0.id) == section }?.title ?? ""
        }
    }

    private func sectionSystemImage(_ section: SettingsSection) -> String {
        switch section {
        case .privateFeature: privateFeature.sectionSystemImage
        case .macros: macroFeature.sectionSystemImage
        case .buttonProfiles: macroFeature.buttonProfilesSectionSystemImage
        case .membership: membershipFeature.sectionSystemImage
        default: supplementalPages.first { SettingsSection.supplemental($0.id) == section }?.systemImage ?? section.systemImage
        }
    }

    @ViewBuilder
    private var updateInformationContent: some View {
        switch updateInformation.state {
        case .idle:
            Text("about.version.information_title")
                .font(.headline)
            Text("about.version.information_idle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .checking:
            Text("about.version.information_title")
                .font(.headline)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("about.version.checking")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("about.version.up_to_date", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("about.version.up_to_date_description")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("about.version.information_unavailable", systemImage: "wifi.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("about.version.information_unavailable_description")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case let .available(update):
            Text(String(
                format: localization.text("about.version.release_notes_title"),
                locale: localization.locale,
                arguments: [update.displayVersion]
            ))
            .font(.headline)

            if update.releaseNotes.isEmpty {
                Text("about.version.release_notes_unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(update.releaseNotes.enumerated()), id: \.offset) { index, note in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(note)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
    }

    private var currentVersionWithBuild: String {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else {
            return currentVersion
        }
        return String(
            format: localization.text("about.version.current_with_build"),
            locale: localization.locale,
            arguments: [currentVersion, build]
        )
    }

    private func revealPrivateEnrollmentIfNeeded() {
        guard versionTapRevealCounter.registerTap() else { return }
        privateFeature.revealEnrollment()
        macroFeature.revealEnrollment()
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        language == .system ? localization.text("language.system") : language.nativeDisplayName
    }

    private func buttonPressCountText(for period: UsageStatisticsPeriod) -> String {
        localizedNumber(settings.usageStatistics(for: period).buttonPressCount)
    }

    private func voiceDurationText(for period: UsageStatisticsPeriod) -> String {
        let statistics = settings.usageStatistics(for: period)
        let totalSeconds = max(
            0,
            Int(min(statistics.voiceDuration.rounded(), Double(Int.max)))
        )
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        // The four KPI cards share one row, so hour-scale totals must use the compact
        // wording to stay complete inside the narrowest card.
        if hours > 0 {
            return String(
                format: localization.text("usage.duration.compact_hours_minutes"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(hours)), localizedNumber(UInt64(minutes))]
            )
        }
        if minutes > 0 {
            return String(
                format: localization.text("usage.duration.compact_minutes_seconds"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(minutes)), localizedNumber(UInt64(seconds))]
            )
        }
        return String(
            format: localization.text("usage.duration.seconds"),
            locale: localization.locale,
            arguments: [localizedNumber(UInt64(seconds))]
        )
    }

    private var dailyUsageChartPoints: [UsageChartPoint] {
        usageChartPoints(
            from: settings.dailyUsageStatistics(days: 7),
            dateFormatTemplate: "EEE"
        )
    }

    private var weeklyUsageChartPoints: [UsageChartPoint] {
        let series = settings.weeklyUsageStatisticsSeries(recentWeeks: 7)
        let hasEarlierStatistics = series.earlierStatistics.buttonPressCount > 0 ||
            series.earlierStatistics.voiceDuration > 0
        let statistics = (hasEarlierStatistics ? [series.earlierStatistics] : []) +
            series.weeklyBuckets.map(\.statistics)
        let visibleVoiceDuration = statistics.reduce(0) { result, statistics in
            result + max(0, statistics.voiceDuration)
        }
        let displayedVoiceSeconds = UsageStatisticsPresentation.apportionedWholeSeconds(
            statistics.map(\.voiceDuration),
            totalDuration: visibleVoiceDuration
        )
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.setLocalizedDateFormatFromTemplate("Md")
        let dates = (hasEarlierStatistics ? [Date.distantPast] : []) +
            series.weeklyBuckets.map(\.startDate)
        let labels = (hasEarlierStatistics
            ? [localization.text("statistics.chart.earlier")]
            : []) + series.weeklyBuckets.map { formatter.string(from: $0.startDate) }
        return statistics.indices.map { index in
            usageChartPoint(
                date: dates[index],
                label: labels[index],
                statistics: statistics[index],
                displayedVoiceSeconds: displayedVoiceSeconds[index]
            )
        }
    }

    private func usageChartPoint(
        date: Date,
        label: String,
        statistics: UsageStatistics,
        displayedVoiceSeconds: Int? = nil
    ) -> UsageChartPoint {
        UsageChartPoint(
            date: date,
            label: label,
            buttonPressCount: Double(statistics.buttonPressCount),
            buttonPressCountLabel: localizedNumber(statistics.buttonPressCount),
            voiceDuration: max(0, statistics.voiceDuration),
            voiceDurationLabel: chartDurationText(
                seconds: displayedVoiceSeconds ?? UsageStatisticsPresentation.wholeSeconds(
                    statistics.voiceDuration
                )
            )
        )
    }

    private func usageChartPoints(
        from buckets: [UsageStatisticsBucket],
        dateFormatTemplate: String
    ) -> [UsageChartPoint] {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.setLocalizedDateFormatFromTemplate(dateFormatTemplate)
        return buckets.map { bucket in
            usageChartPoint(
                date: bucket.startDate,
                label: formatter.string(from: bucket.startDate),
                statistics: bucket.statistics
            )
        }
    }

    private func chartDurationText(seconds totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                locale: localization.locale,
                hours,
                minutes,
                seconds
            )
        }
        return String(
            format: "%d:%02d",
            locale: localization.locale,
            minutes,
            seconds
        )
    }

    private func voiceSessionDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func calendarDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    private var statisticsActionRanking: [StatisticsRankingEntry] {
        let metadata = settings.usageMetadata(for: .total)
        var counts: [String: UInt64] = [:]
        for button in RemoteButton.allCases {
            let count = metadata.buttonPressCountByControl["button.\(button.rawValue)"] ?? 0
            guard count > 0 else { continue }
            let action = settings.configuredAction(for: button, trigger: .singleClick)
            guard action.action != .disabled else { continue }
            let title = mappingActionSummary(for: button, trigger: .singleClick, configuredAction: action)
            counts[title, default: 0] += count
        }
        return counts.map { StatisticsRankingEntry(title: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
    }

    private var statisticsButtonRanking: [StatisticsRankingEntry] {
        let metadata = settings.usageMetadata(for: .total)
        return RemoteButton.allCases.compactMap { button in
            let count = metadata.buttonPressCountByControl["button.\(button.rawValue)"] ?? 0
            guard count > 0 else { return nil }
            return StatisticsRankingEntry(
                title: button.displayName(using: localization),
                count: count
            )
        }
        .sorted { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
    }

    private func statisticsCalendarDays(endingAt date: Date) -> [StatisticsCalendarDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.locale = localization.locale
        return StatisticsCalendarDay.recentDays(
            settings: settings, endingAt: date, calendar: calendar,
            records: model.transcriptRecords, assets: model.recordingAssets
        )
    }

    private func usagePeriodLocalizationKey(_ period: UsageStatisticsPeriod) -> String {
        switch period {
        case .today: return "statistics.period.today"
        case .thisWeek: return "statistics.period.this_week"
        case .total: return "statistics.period.total"
        }
    }

    private func localizedNumber(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = localization.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func exportConfiguration() {
        configurationStatus = nil
        configurationExportSequence += 1
        let operationID = configurationExportSequence
        var phase = "prepare"
        AppLogger.shared.write("CONFIGURATION EXPORT operation_id=\(operationID) phase=requested")
        do {
            let data = try macroFeature.exportedCompleteConfigurationData(settings: settings)
            phase = "file_panel"
            guard let url = ConfigurationFilePanel.exportURL(
                title: localization.text("configuration.export.panel_title"),
                prompt: localization.text("configuration.export.prompt"),
                includesPortableConfiguration: true
            ) else {
                AppLogger.shared.write("CONFIGURATION EXPORT operation_id=\(operationID) phase=cancelled result=no_write")
                return
            }
            phase = "write"
            try data.write(to: url, options: .atomic)
            AppLogger.shared.write("CONFIGURATION EXPORT operation_id=\(operationID) phase=completed result=file_saved")
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.export.success"),
                tint: .green,
                systemImage: "checkmark.circle.fill"
            )
        } catch {
            AppLogger.shared.write("CONFIGURATION EXPORT operation_id=\(operationID) phase=failed stage=\(phase) result=no_file_saved")
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.export.write_failed"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private func importConfiguration() {
        configurationStatus = nil
        guard let url = ConfigurationFilePanel.importURL(
            title: localization.text("configuration.import.panel_title"),
            prompt: localization.text("configuration.import.prompt"),
            includesPortableConfiguration: true
        ) else { return }
        importConfiguration(from: url)
    }

    private func importConfiguration(from url: URL) {
        configurationImportSequence += 1
        let operationID = configurationImportSequence
        AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=requested source=settings_or_finder")
        do {
            let data = try MacConfigurationBackup.read(url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["format"] as? String == MacConfigurationBackup.format {
                let backup = try MacConfigurationBackup.decode(data, version: currentVersion)
                _ = try settings.validatedCompleteConfigurationSnapshot(backup.host)
                try macroFeature.validateConfigurationArchive(backup.components)
                let alert = NSAlert()
                alert.messageText = localization.text("configuration.import.restore_title")
                alert.informativeText = localization.text("configuration.import.restore_detail")
                alert.addButton(withTitle: localization.text("configuration.import.prompt"))
                alert.addButton(withTitle: localization.text("configuration.import.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=cancelled result=no_write")
                    return
                }
                try model.restoreCompleteConfiguration(backup)
            } else if object?["format"] as? String == "sayall-transfer" {
                guard macroFeature.requestConfigurationImport(from: url) else { throw AppConfigurationError.unsupportedVersion }
                AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=submitted result=awaiting_review")
                return
            } else {
                try model.importConfiguration(from: data)
            }
            AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=completed result=stored")
            localization.select(settings.applicationLanguage)
            syncEntryPointVisibility()
            if settings.configurationImportNotice != nil {
                configurationStatus = ConfigurationStatus(
                    message: LocalizedMessage("configuration.import.partial"),
                    tint: .orange,
                    systemImage: "exclamationmark.triangle.fill"
                )
            } else {
                configurationStatus = ConfigurationStatus(
                    message: LocalizedMessage("configuration.import.success"),
                    tint: .green,
                    systemImage: "checkmark.circle.fill"
                )
            }
        } catch AppConfigurationError.unsupportedVersion {
            AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=failed result=no_write reason=unsupported_format_or_platform")
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.unsupported_version"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch AppConfigurationError.unsafeVoiceKeyChange {
            AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=failed result=no_write reason=voice_busy")
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.voice_key_busy"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch {
            AppLogger.shared.write("CONFIGURATION IMPORT operation_id=\(operationID) phase=failed result=not_completed reason=invalid_or_storage_failure")
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.invalid_file"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private func routePendingButtonProfileImportIfNeeded() {
        guard let request = buttonProfileImportRequests.pendingRequest else { return }
        do {
            let destination = try ConfigurationImportDestination.detect(MacConfigurationBackup.read(request.url))
            let section: SettingsSection = destination == .buttonProfiles && macroFeature.isButtonProfilesVisible
                ? .buttonProfiles : .about
            let alreadyMounted = selectedSection == section
            selectedSection = section
            if alreadyMounted || !macroFeature.isFeatureVisible {
                consumePendingButtonProfileImportIfNeeded()
            }
        } catch {
            selectedSection = .about
            buttonProfileImportRequests.clear()
            configurationStatus = ConfigurationStatus(message: LocalizedMessage("configuration.import.invalid_file"),
                tint: .red, systemImage: "exclamationmark.triangle.fill")
            AppLogger.shared.write("CONFIGURATION IMPORT phase=failed result=no_write reason=unreadable_or_unknown_type")
        }
    }

    private func consumePendingButtonProfileImportIfNeeded() {
        guard let request = buttonProfileImportRequests.pendingRequest else { return }
        do {
            let destination = try ConfigurationImportDestination.detect(MacConfigurationBackup.read(request.url))
            buttonProfileImportRequests.clear()
            if destination == .settings {
                importConfiguration(from: request.url)
            } else if macroFeature.requestButtonProfileImport(from: request.url) {
                AppLogger.shared.write("BUTTON_PROFILE_IMPORT phase=started result=accepted source=finder_file operation_id=button_profile_import_\(request.operationID)")
            } else {
                configurationStatus = ConfigurationStatus(message: LocalizedMessage("configuration.import.feature_unavailable"),
                    tint: .red, systemImage: "exclamationmark.triangle.fill")
                AppLogger.shared.write("BUTTON_PROFILE_IMPORT phase=completed result=rejected source=finder_file reason=feature_unavailable operation_id=button_profile_import_\(request.operationID)")
            }
        } catch {
            buttonProfileImportRequests.clear()
            configurationStatus = ConfigurationStatus(message: LocalizedMessage("configuration.import.invalid_file"),
                tint: .red, systemImage: "exclamationmark.triangle.fill")
            AppLogger.shared.write("CONFIGURATION IMPORT phase=failed result=no_write reason=unreadable_or_unknown_type")
        }
    }

    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        state: PermissionVisualState,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            HStack(spacing: 7) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 8, height: 8)
                Text(state.title(using: localization))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 78, alignment: .leading)
            Button(actionTitle, action: action)
                .compatibilityButtonStyle(.standard)
                .frame(width: 126)
        }
        .padding(.vertical, 8)
    }

    private func openSettingsURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func performPermissionAction(
        _ action: SettingsPermissionAction,
        requestPermission: () -> Void
    ) {
        SettingsPageBehavior.perform(
            action,
            requestPermission: requestPermission,
            openSystemSettings: openSettingsURL
        )
    }

    private func copySettingsDiagnosticSummary() {
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: currentVersion,
            bluetoothGranted: bluetoothPermissionState == .granted,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            runtimeLogAvailable: FileManager.default.fileExists(atPath: AppLogger.shared.logURL.path),
            remoteSessionError: model.lastRemoteSessionError
        )
        SettingsPageBehavior.copyDiagnosticSummary(
            snapshot,
            writeToPasteboard: { summary in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
            },
            writeAuditLog: AppLogger.shared.write
        )
    }

    private var connectionBadge: String {
        localization.text(model.isConnected ? "common.status.connected" : "common.status.connecting")
    }

    private var webRemoteStatusText: String {
        switch model.webRemoteState {
        case .disabled:
            return localization.text("connection.web.disabled")
        case .unavailable:
            return localization.text("connection.web.unavailable")
        case .connecting:
            return localization.text("connection.web.connecting")
        case .waitingForPhone:
            return localization.text("connection.web.waiting_scan")
        case .membershipRequired:
            // 权益已经放开、只差建一次会话时，不要再写「此连接需要 Plus 会员」——
            // 刚开完会员的人会以为没生效，而且旁边的按钮已经变成「连接」。
            return localization.text(
                membershipFeature.canStartCompanionConnection
                    ? "connection.web.disabled"
                    : "connection.web.plus_required_title"
            )
        case .plusRequired:
            return localization.text("connection.web.plus_required_title")
        case .awaitingApproval:
            return localization.text("connection.web.waiting_approval")
        case .connected:
            return localization.text("connection.web.connected")
        case .failed:
            return localization.text("connection.web.failed")
        }
    }

    private var webRemoteStatusTint: Color {
        switch model.webRemoteState {
        case .connected:
            return .green
        case .failed, .unavailable, .plusRequired:
            return .orange
        case .membershipRequired:
            // 权益可用时这只是「还没建会话」，不是错误，别涂成橙色。
            return membershipFeature.canStartCompanionConnection ? .secondary : .orange
        default:
            return .secondary
        }
    }

    private func requestWebRemoteSession() {
        openWebRemoteSession()
    }

    private func copyIOSAppStoreLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        isAppStoreLinkCopied = pasteboard.writeObjects([
            AppLinks.iOSAppStore(for: localization.locale).absoluteString as NSString
        ])
    }

    private func openWebRemoteSession() {
        if !model.webRemoteState.isEnabled {
            model.enableWebRemoteConnection()
        }
        guard model.webRemoteState.isEnabled else { return }
        isWebRemoteSessionPresented = true
    }

    private var connectionTint: Color {
        model.isConnected ? .green : .orange
    }

    private var voiceTriggerBadge: String {
        localization.text(model.isVoiceTriggerEnabled ? "common.status.enabled" : "common.status.preparing")
    }

    private var bluetoothPermissionState: PermissionVisualState {
        bluetoothAuthorization == .allowedAlways ? .granted : .pending
    }

    private func refreshPermissionStates() {
        bluetoothAuthorization = CBManager.authorization
        inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
        accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    }

    private func setCustomMappingEnabled(_ enabled: Bool) {
        refreshPermissionStates()
        settings.customMappingEnabled = enabled
        guard MappingPermissionPolicy.requiresPrompt(
            enabled: enabled,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted
        ) else {
            isWaitingForMappingPermissions = false
            model.applyHIDSettings()
            return
        }
        isMappingPermissionAlertPresented = true
    }

    private func resumeCustomMappingIfPermissionsGranted() {
        guard
            isWaitingForMappingPermissions,
            inputMonitoringGranted,
            accessibilityGranted
        else { return }
        isWaitingForMappingPermissions = false
        model.applyHIDSettings()
    }
}

enum UsageStatisticsPresentation {
    static func wholeSeconds(_ duration: TimeInterval) -> Int {
        guard !duration.isNaN, duration > 0 else { return 0 }
        guard duration.isFinite else { return .max }
        let roundedDuration = duration.rounded()
        guard roundedDuration < Double(Int.max) else { return .max }
        return Int(roundedDuration)
    }

    static func apportionedWholeSeconds(
        _ durations: [TimeInterval],
        totalDuration: TimeInterval
    ) -> [Int] {
        guard !durations.isEmpty else { return [] }
        let sanitizedDurations = durations.map { duration in
            duration.isFinite ? max(0, duration) : 0
        }
        var result = sanitizedDurations.map(flooredWholeSeconds)
        let targetTotal = wholeSeconds(totalDuration)
        let currentTotal = result.reduce(0) { partialResult, value in
            let (sum, overflow) = partialResult.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
        let secondsToDistribute = min(
            result.count,
            max(0, targetTotal - currentTotal)
        )
        let indicesByRemainder = sanitizedDurations.indices.sorted { lhs, rhs in
            let lhsRemainder = sanitizedDurations[lhs] - sanitizedDurations[lhs].rounded(.down)
            let rhsRemainder = sanitizedDurations[rhs] - sanitizedDurations[rhs].rounded(.down)
            if lhsRemainder == rhsRemainder { return lhs < rhs }
            return lhsRemainder > rhsRemainder
        }
        for index in indicesByRemainder.prefix(secondsToDistribute) {
            result[index] += 1
        }
        return result
    }

    private static func flooredWholeSeconds(_ duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let roundedDuration = duration.rounded(.down)
        guard roundedDuration < Double(Int.max) else { return .max }
        return Int(roundedDuration)
    }
}

private final class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (CustomKeyboardShortcut) -> Void
    let onFailure: (ShortcutCaptureStartFailure) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onFailure = onFailure
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onCapture: (CustomKeyboardShortcut) -> Void
        var onFailure: (ShortcutCaptureStartFailure) -> Void
        private var monitor: ShortcutCaptureMonitor?

        init(
            onCapture: @escaping (CustomKeyboardShortcut) -> Void,
            onFailure: @escaping (ShortcutCaptureStartFailure) -> Void
        ) {
            self.onCapture = onCapture
            self.onFailure = onFailure
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            let capture = onCapture
            let monitor = ShortcutCaptureMonitor(onCapture: capture)
            self.monitor = monitor
            if case let .failure(failure) = monitor.start() {
                self.monitor = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onFailure(failure)
                }
            }
        }

        func stopMonitoring() {
            monitor?.stop()
            monitor = nil
        }

        deinit {
            stopMonitoring()
        }
    }
}

private enum CompatibilityButtonStyle {
    case standard
    case prominent
}

private enum SettingsVisualRenderingPolicy {
    static let isScreenshotHarness = ProcessInfo.processInfo.environment[
        "REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"
    ] != nil

    static var usesNativeGlass: Bool { !isScreenshotHarness }
}

private struct CompatibilityGlassContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *), SettingsVisualRenderingPolicy.usesNativeGlass {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct CompatibilityButtonStyleModifier: ViewModifier {
    let style: CompatibilityButtonStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), SettingsVisualRenderingPolicy.usesNativeGlass {
            switch style {
            case .standard:
                content.buttonStyle(.glass)
            case .prominent:
                content.buttonStyle(.glassProminent)
            }
        } else {
            switch style {
            case .standard:
                content.buttonStyle(.bordered)
            case .prominent:
                content.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct CompatibilityScrollEdgeEffectModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), SettingsVisualRenderingPolicy.usesNativeGlass {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct CompatibilityFocusEffectDisabledModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

private struct CompatibilityRoundedButtonBorderShapeModifier: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.buttonBorderShape(.roundedRectangle(radius: radius))
        } else {
            content
        }
    }
}

private struct CompatibilityTintedGlassModifier<GlassShape: Shape>: ViewModifier {
    let tint: Color
    let shape: GlassShape
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), SettingsVisualRenderingPolicy.usesNativeGlass {
            if interactive {
                content.glassEffect(.clear.tint(tint).interactive(), in: shape)
            } else {
                content.glassEffect(.clear.tint(tint), in: shape)
            }
        } else {
            content
                .background(tint, in: shape)
                .overlay(
                    shape.stroke(
                        Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 1
                    )
                )
        }
    }
}

private extension View {
    func compatibilityButtonStyle(_ style: CompatibilityButtonStyle) -> some View {
        modifier(CompatibilityButtonStyleModifier(style: style))
    }

    func compatibilityScrollEdgeEffect() -> some View {
        modifier(CompatibilityScrollEdgeEffectModifier())
    }

    func compatibilityFocusEffectDisabled() -> some View {
        modifier(CompatibilityFocusEffectDisabledModifier())
    }

    func compatibilityRoundedButtonBorderShape(radius: CGFloat) -> some View {
        modifier(CompatibilityRoundedButtonBorderShapeModifier(radius: radius))
    }

    func compatibilityTintedGlass<GlassShape: Shape>(
        tint: Color,
        in shape: GlassShape,
        interactive: Bool = false
    ) -> some View {
        modifier(
            CompatibilityTintedGlassModifier(
                tint: tint,
                shape: shape,
                interactive: interactive
            )
        )
    }
}

private struct PageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 25, weight: .semibold))
    }
}

struct GlassPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *), SettingsVisualRenderingPolicy.usesNativeGlass {
            content
                .padding(16)
                .glassEffect(.regular, in: shape)
        } else if SettingsVisualRenderingPolicy.isScreenshotHarness {
            content
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(
                    shape.stroke(
                        Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 1
                    )
                )
        } else {
            content
                .padding(16)
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape.stroke(
                        Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 1
                    )
                )
        }
    }
}

private struct ProfilePanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18))
            }
    }
}

private struct ShareCard: View {
    let url: URL
    @State private var copySucceeded: Bool?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Group {
                if let image = AppShareQRCode.image(for: url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "qrcode")
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 144, height: 144)
            .padding(8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(Text("share.qr.accessibility_label"))

            VStack(alignment: .leading, spacing: 12) {
                Text("share.card.title")
                    .font(.headline)
                Text("share.card.description")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button {
                    copySucceeded = AppShareClipboard.copyToGeneralPasteboard(url)
                } label: {
                    Label("share.copy_action", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Text("share.copy.accessibility_hint"))

                if let copySucceeded {
                    Label(
                        copySucceeded ? "share.copy_succeeded" : "share.copy_failed",
                        systemImage: copySucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copySucceeded ? Color.green : Color.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatisticsRankingEntry: Identifiable {
    let title: String
    let count: UInt64

    var id: String { "\(title)-\(count)" }
}

struct StatisticsCalendarDay: Identifiable {
    let date: Date?
    let buttonPressCount: UInt64
    let voiceDuration: TimeInterval
    let reflectionCount: Int

    static func recentDays(
        settings: AppSettings,
        endingAt date: Date = Date(),
        calendar: Calendar,
        records: [TranscriptRecord] = [],
        assets: [RecordingAssetManifest] = []
    ) -> [StatisticsCalendarDay] {
        // Use the same saved date keys and session deduplication as Reflections.
        let transcriptSessions = Set(records.map(\.sessionID))
        let entries = records.map(TranscriptHistoryEntry.transcript)
            + assets.filter { !transcriptSessions.contains($0.sessionID) }
                .map(TranscriptHistoryEntry.recording)
        let counts = Dictionary(grouping: entries, by: \.localDateKey).mapValues(\.count)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Keep the heatmap to the latest 26 weeks so each day remains readable.
        let buckets = settings.dailyUsageStatistics(endingAt: date, days: 26 * 7, calendar: calendar)
        return buckets.map {
            StatisticsCalendarDay(
                date: $0.startDate,
                buttonPressCount: $0.statistics.buttonPressCount,
                voiceDuration: $0.statistics.voiceDuration,
                reflectionCount: counts[formatter.string(from: $0.startDate), default: 0]
            )
        }
    }

    static func weekdaySymbols(firstDate: Date?, calendar: Calendar, locale: Locale) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let symbols = formatter.shortWeekdaySymbols ?? []
        guard let firstDate, symbols.count == 7 else { return symbols }
        let firstWeekday = calendar.component(.weekday, from: firstDate) - 1
        return (0..<7).map { symbols[(firstWeekday + $0) % 7] }
    }

    var id: String {
        date.map { String($0.timeIntervalSinceReferenceDate) } ?? UUID().uuidString
    }

    var intensity: Double {
        let buttonIntensity = min(Double(buttonPressCount) / 40, 1)
        let voiceIntensity = min(max(voiceDuration, 0) / 300, 1)
        return min(1, max(buttonIntensity, voiceIntensity))
    }
}

private struct ProfileMetricCard: View {
    let systemImage: String
    let title: String
    let value: String
    let unit: String?
    let tint: Color

    init(metric: ProfileMetric) {
        systemImage = metric.systemImage
        title = metric.title
        value = metric.value
        unit = metric.unit
        tint = .accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                    if let unit, !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        }
    }
}

private struct ProfileMetric: Identifiable {
    let id: String
    let systemImage: String
    let title: String
    let value: String
    let unit: String?
}

struct StatisticsHeatmapMetrics {
    static let spacing: CGFloat = 3
    static let weekdayLabelWidth: CGFloat = 30
    let cellSize: CGFloat
    let gridWidth: CGFloat
    let height: CGFloat

    init(width: CGFloat, columns: Int) {
        let columnCount = max(1, columns)
        let gaps = CGFloat(columnCount - 1) * Self.spacing
        let availableWidth = max(0, width - Self.weekdayLabelWidth - 8 - 6)
        cellSize = max(14, min(28, (availableWidth - gaps) / CGFloat(columnCount)))
        gridWidth = CGFloat(columnCount) * cellSize + gaps
        height = 18 + 8 + 7 * cellSize + 6 * Self.spacing
    }
}

private struct StatisticsHeatmapLayout: Layout {
    let columns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        return CGSize(width: width, height: StatisticsHeatmapMetrics(width: width, columns: columns).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(bounds.size))
    }
}

private struct StatisticsHeatmap: View {
    let days: [StatisticsCalendarDay]
    @Binding var selectedDate: Date?
    let localization: LocalizationStore

    private let cellSpacing = StatisticsHeatmapMetrics.spacing
    private let weekdayLabelWidth = StatisticsHeatmapMetrics.weekdayLabelWidth

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.locale = localization.locale
        return calendar
    }

    private var monthMarkers: [(column: Int, label: String)] {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        var markers: [(column: Int, label: String)] = []
        var seen = Set<String>()
        var nextAvailableColumn = 0
        for column in 0..<max(1, days.count / 7) {
            let columnDays = days.dropFirst(column * 7).prefix(7)
            guard let date = columnDays.compactMap(\.date).first else { continue }
            let key = formatter.string(from: date)
            guard seen.insert(key).inserted else { continue }
            let displayColumn = max(column, nextAvailableColumn)
            markers.append((displayColumn, key))
            nextAvailableColumn = displayColumn + 2
        }
        return markers
    }

    private var weekdayLabels: [String] {
        return StatisticsCalendarDay.weekdaySymbols(
            firstDate: days.first?.date, calendar: calendar, locale: localization.locale
        )
    }

    var body: some View {
        StatisticsHeatmapLayout(columns: max(1, days.count / 7)) {
            GeometryReader { proxy in
                let columnCount = max(1, days.count / 7)
                let metrics = StatisticsHeatmapMetrics(width: proxy.size.width, columns: columnCount)
                let cellSize = metrics.cellSize

                HStack(alignment: .top, spacing: 8) {
                    // Keep weekday labels visible when earlier columns scroll offscreen.
                    VStack(alignment: .leading, spacing: cellSpacing) {
                        ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: weekdayLabelWidth, height: cellSize, alignment: .leading)
                        }
                    }
                    .padding(.top, 26)

                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .topLeading) {
                                    ForEach(Array(monthMarkers.enumerated()), id: \.offset) { _, marker in
                                        Text(marker.label)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: 36, alignment: .leading)
                                            .offset(x: min(
                                                CGFloat(marker.column) * (cellSize + cellSpacing),
                                                metrics.gridWidth - 36
                                            ))
                                    }
                                }
                                .frame(width: metrics.gridWidth, height: 18, alignment: .leading)

                                VStack(alignment: .leading, spacing: cellSpacing) {
                                    ForEach(0..<7, id: \.self) { row in
                                        HStack(spacing: cellSpacing) {
                                            ForEach(0..<columnCount, id: \.self) { column in
                                                let index = column * 7 + row
                                                let day = days[index]
                                                Button {
                                                    guard let date = day.date else { return }
                                                    selectedDate = date
                                                } label: {
                                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                        .fill(fillColor(for: day))
                                                        .overlay {
                                                            if let date = day.date,
                                                               calendar.isDateInToday(date) {
                                                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                                    .stroke(Color.accentColor, lineWidth: 1)
                                                            }
                                                        }
                                                        .frame(width: cellSize, height: cellSize)
                                                }
                                                .buttonStyle(.plain)
                                                .help(summary(for: day))
                                                .accessibilityLabel(summary(for: day))
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.trailing, 6)
                            .id("calendar-trailing")
                        }
                        .onAppear {
                            scrollProxy.scrollTo("calendar-trailing", anchor: .trailing)
                        }
                        .onChange(of: proxy.size.width) { _ in
                            scrollProxy.scrollTo("calendar-trailing", anchor: .trailing)
                        }
                        .onChange(of: days.last?.id) { _ in
                            scrollProxy.scrollTo("calendar-trailing", anchor: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func summary(for day: StatisticsCalendarDay) -> String {
        guard let date = day.date else { return "" }
        let seconds = UsageStatisticsPresentation.wholeSeconds(day.voiceDuration)
        let duration = String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        return String(
            format: localization.text("statistics.calendar.summary"),
            dateText(date), String(day.reflectionCount), String(day.buttonPressCount), duration
        )
    }

    private func fillColor(for day: StatisticsCalendarDay) -> Color {
        guard day.date != nil else { return .clear }
        if day.intensity == 0 { return Color(nsColor: .separatorColor).opacity(0.28) }
        return Color.accentColor.opacity(0.22 + day.intensity * 0.78)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

private struct UsageStatisticCard: View {
    let systemImage: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .compatibilityTintedGlass(tint: tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatibilityTintedGlass(
            tint: tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct UsageChartPoint: Identifiable {
    let date: Date
    let label: String
    let buttonPressCount: Double
    let buttonPressCountLabel: String
    let voiceDuration: Double
    let voiceDurationLabel: String

    var id: Date { date }
}

private enum UsageChartMetric {
    case buttonPressCount
    case voiceDuration

    func value(for point: UsageChartPoint) -> Double {
        switch self {
        case .buttonPressCount: return point.buttonPressCount
        case .voiceDuration: return point.voiceDuration
        }
    }

    func label(for point: UsageChartPoint) -> String {
        switch self {
        case .buttonPressCount: return point.buttonPressCountLabel
        case .voiceDuration: return point.voiceDurationLabel
        }
    }
}

private struct UsageBarChart: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let points: [UsageChartPoint]
    let metric: UsageChartMetric
    let tint: Color

    private var maximumValue: Double {
        max(1, points.map { metric.value(for: $0) }.max() ?? 0) * 1.25
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(tint)
                        .frame(width: 32, height: 32)
                        .compatibilityTintedGlass(tint: tint.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Chart(points) { point in
                    BarMark(
                        x: .value(subtitle, point.label),
                        y: .value(title, metric.value(for: point))
                    )
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(5)
                    .annotation(position: .top, spacing: 4) {
                        Text(metric.label(for: point))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .chartYScale(domain: 0...maximumValue)
                .chartYAxis(.hidden)
                .frame(height: 250)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

@MainActor
private enum ConfigurationFilePanel {
    static func exportURL(title: String, prompt: String, includesPortableConfiguration: Bool) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        if includesPortableConfiguration {
            panel.allowedFileTypes = ["sayall"]
            panel.nameFieldStringValue = "sayall-configurations.sayall"
        } else {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Remote-Mic-Settings.json"
        }
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func importURL(title: String, prompt: String, includesPortableConfiguration: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedFileTypes = ["sayall", "json"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .compatibilityTintedGlass(tint: tint.opacity(0.14), in: Capsule())
    }
}

private struct DeviceStatusStep: View {
    let symbol: String
    let title: String
    let detail: String
    let badge: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .compatibilityTintedGlass(tint: tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    StatusPill(text: badge, tint: tint)
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 按型号目录给出的资源名加载真机图。资源名来自 `VoiceRemoteCatalog`，不在这里硬编码。
private struct RemoteCatalogPhoto: View {
    let resourceName: String

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
               let photo = NSImage(contentsOf: url) {
                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Text("remote.photo.missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}

/// 型号目录里没有这个型号时的占位。
///
/// 关键：这里**不显示任何真机图**。App 内置每款遥控器的真机图与按键页，给未识别设备套上
/// 别款的图，界面就等于声称一台从未验证过的设备「已连接、能用」。
private struct UnrecognizedRemotePhoto: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.quaternary)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("remote.device.model.unrecognized")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
            }
    }
}

/// Turns the storage keys and application names in a `ConfigurationImportReport` into the
/// warning the button mapping page shows. Storage keys are an implementation detail, so they
/// are collapsed onto the settings a user recognizes; an unrecognized key still surfaces under
/// a generic item so a future importable key cannot be dropped silently — silence about dropped
/// entries is the exact defect this notice exists to close.
enum ConfigurationImportNoticeText {
    static let titleKey = "settings.import_notice.title"
    static let rejectedKey = "settings.import_notice.rejected"
    static let missingApplicationKey = "settings.import_notice.missing_app"
    static let nextStepKey = "settings.import_notice.next_step"
    static let separatorKey = "settings.import_notice.separator"
    static let buttonMappingItemKey = "settings.import_notice.item.button_mapping"
    static let customApplicationItemKey = "settings.import_notice.item.custom_application"
    static let audioDeviceItemKey = "settings.import_notice.item.audio_device"
    static let otherItemKey = "settings.import_notice.item.other"

    /// Fixed display order, so the sentence reads the same no matter which order the import
    /// happened to reject entries in.
    private static let itemKeyOrder = [
        buttonMappingItemKey,
        customApplicationItemKey,
        audioDeviceItemKey,
        otherItemKey,
    ]

    private static let itemKeysByStorageKey: [String: String] = [
        "buttonBindings": buttonMappingItemKey,
        "buttonShortcuts": buttonMappingItemKey,
        "buttonApplicationProfileIDs": buttonMappingItemKey,
        "secondaryButtonBindings": buttonMappingItemKey,
        "buttonRapidPressEnabled": buttonMappingItemKey,
        "continuousRecordingPowerBindingBackup": buttonMappingItemKey,
        "customApplicationProfiles": customApplicationItemKey,
        "selectedAudioDeviceUID": audioDeviceItemKey,
    ]

    /// Deduplicated, order-stable localization keys naming what was skipped.
    static func affectedItemKeys(for storageKeys: [String]) -> [String] {
        let matched = Set(storageKeys.map { itemKeysByStorageKey[$0] ?? otherItemKey })
        return itemKeyOrder.filter(matched.contains)
    }

    static func rejectedSummary(
        for storageKeys: [String],
        localize: (String) -> String
    ) -> String? {
        let itemKeys = affectedItemKeys(for: storageKeys)
        guard !itemKeys.isEmpty else { return nil }
        let list = itemKeys.map(localize).joined(separator: localize(separatorKey))
        return String(format: localize(rejectedKey), list)
    }

    /// Names come from the imported file, so they are only ever displayed, never resolved.
    static func missingApplicationSummary(
        for applicationNames: [String],
        localize: (String) -> String
    ) -> String? {
        guard !applicationNames.isEmpty else { return nil }
        return String(
            format: localize(missingApplicationKey),
            applicationNames.joined(separator: localize(separatorKey))
        )
    }
}

/// Turns the storage keys published by `AppSettings.corruptedSettingKeys` into the warning the
/// button mapping page shows. Storage keys are an implementation detail, so they are collapsed
/// onto the settings a user recognizes. An unrecognized key still surfaces under a generic item
/// so that adding a decoded key later cannot silently drop the warning again.
enum CorruptedSettingsNotice {
    static let titleKey = "settings.corrupted.title"
    static let summaryKey = "settings.corrupted.summary"
    static let recoveryKey = "settings.corrupted.recovery"
    static let nextStepKey = "settings.corrupted.next_step"
    static let separatorKey = "settings.corrupted.separator"
    static let buttonMappingItemKey = "settings.corrupted.item.button_mapping"
    static let customApplicationItemKey = "settings.corrupted.item.custom_application"
    static let remoteDeviceItemKey = "settings.corrupted.item.remote_device"
    static let statisticsItemKey = "settings.corrupted.item.statistics"
    static let otherItemKey = "settings.corrupted.item.other"

    private static let itemKeyOrder = [
        buttonMappingItemKey,
        customApplicationItemKey,
        remoteDeviceItemKey,
        statisticsItemKey,
        otherItemKey,
    ]

    private static let itemKeysByStorageKey: [String: String] = [
        "buttonBindings": buttonMappingItemKey,
        "buttonShortcuts": buttonMappingItemKey,
        "buttonApplicationProfileIDs": buttonMappingItemKey,
        "secondaryButtonBindings": buttonMappingItemKey,
        "buttonRapidPressEnabled": buttonMappingItemKey,
        "continuousRecordingPowerBindingBackup": buttonMappingItemKey,
        "customApplicationProfiles": customApplicationItemKey,
        "remoteDeviceProfiles": remoteDeviceItemKey,
        "usage.dailyStatistics": statisticsItemKey,
        "usage.voiceSessionRanking": statisticsItemKey,
    ]

    static func affectedItemKeys(for storageKeys: [String]) -> [String] {
        let matched = Set(storageKeys.map { itemKeysByStorageKey[$0] ?? otherItemKey })
        return itemKeyOrder.filter(matched.contains)
    }

    static func summary(
        for storageKeys: [String],
        localize: (String) -> String
    ) -> String? {
        let itemKeys = affectedItemKeys(for: storageKeys)
        guard !itemKeys.isEmpty else { return nil }
        let list = itemKeys.map(localize).joined(separator: localize(separatorKey))
        return String(format: localize(summaryKey), list)
    }
}
