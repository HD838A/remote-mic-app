import AppKit
import Charts
import Combine
import CoreBluetooth
import SayAllMacRemoteCore
import SayAllMacRemoteUI
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case connection
    case privateFeature
    case macros
    case mapping
    case statistics
    case transcripts
    case permissions
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .connection: return "settings.section.connection"
        case .privateFeature: return ""
        case .macros: return ""
        case .mapping: return "settings.section.buttons"
        case .statistics: return "settings.section.statistics"
        case .transcripts: return "settings.section.transcripts"
        case .permissions: return "settings.section.permissions"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "link"
        case .privateFeature: return "sparkles"
        case .macros: return "command.square"
        case .mapping: return "keyboard"
        case .statistics: return "chart.bar.xaxis"
        case .transcripts: return "text.bubble.fill"
        case .permissions: return "shield.lefthalf.filled"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsSidebarIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.gradient)
            }
            .shadow(color: .black.opacity(0.16), radius: 0.75, y: 0.5)
            .accessibilityHidden(true)
    }
}

private struct SettingsSidebarRow: View {
    let title: Text
    let systemName: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            SettingsSidebarIcon(systemName: systemName, color: color)
            title
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSearchItem: Identifiable {
    let id: String
    let section: SettingsSection
    let title: String
    let anchor: String
    let keywords: [String]

    init(
        _ id: String,
        section: SettingsSection,
        title: String,
        anchor: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.anchor = anchor
        self.keywords = keywords
    }
}

private struct SettingsSearchNavigationRequest: Equatable {
    let id = UUID()
    let section: SettingsSection
    let anchor: String
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

enum MappingSelectionPolicy {
    static func selection(
        current: RemoteButton,
        activeButtons: Set<RemoteButton>,
        isLocked: Bool
    ) -> RemoteButton {
        guard !isLocked else { return current }
        return RemoteButton.allCases.first(where: activeButtons.contains) ?? current
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

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var privateFeature: PrivateFeatureIntegration
    @ObservedObject private var macroFeature: MacroFeatureIntegration
    @ObservedObject private var loginItemService: LoginItemService
    @ObservedObject private var updateInformation: UpdateInformationStore
    @EnvironmentObject private var localization: LocalizationStore

    private let checkForUpdates: () -> Void
    private let refreshUpdateInformation: () -> Void
    private let setDockIconVisible: (Bool) -> Void
    private let minimumContentSize: CGSize
    private let initialShortcutPickerShowsKeyboard: Bool
    private let navigationCoordinator: SettingsNavigationCoordinator
    private static let sidebarSectionOrder: [SettingsSection] = [
        .mapping,
        .macros,
        .statistics,
        .transcripts,
        .connection,
        .privateFeature,
        .permissions,
        .about,
    ]

    @State private var selectedSection: SettingsSection
    @State private var sidebarSearchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedSearchResultID: String?
    @State private var highlightedSearchAnchor: String?
    @State private var navigationHistory: [SettingsSection]
    @State private var navigationHistoryIndex: Int
    @State private var searchNavigationRequest: SettingsSearchNavigationRequest?
    @State private var selectedRemoteButton: RemoteButton = .ok
    @State private var isMappingSelectionLocked = true
    @State private var selectedUsagePeriod: UsageStatisticsPeriod = .today
    @State private var mappingEditingTarget: ShortcutEditingTarget?
    @State private var isPresetApplicationActionsExpanded = false
    @State private var shortcutCaptureTarget: ShortcutEditingTarget?
    @State private var applicationShortcutCaptureProfileID: UUID?
    @State private var shortcutCaptureFeedback: ShortcutCaptureFeedback?
    @State private var customApplicationLearningStates: [UUID: CustomApplicationLearningState] = [:]
    @State private var bluetoothAuthorization = CBManager.authorization
    @State private var inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
    @State private var accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    @State private var configurationStatus: ConfigurationStatus?
    @State private var isClearTrustedPhonesConfirmationPresented = false
    @State private var isWebRemoteSessionPresented = false
    @State private var isWebRemoteInvitePresented = false
    @State private var isWebRemoteInviteInvalidPresented = false
    @State private var isWebRemoteInviteAuthorized = false
    @State private var isTestFlightLinkCopied = false
    @State private var isMappingPermissionAlertPresented = false
    @State private var isWaitingForMappingPermissions = false
    @State private var isAboutShareExpanded: Bool
    @State private var webRemoteInviteCode = ""
    @State private var versionTapRevealCounter = VersionTapRevealCounter()
    private static let requiredWebRemoteInviteCode = "8586"

    init(
        model: BridgeAppModel,
        updateInformation: UpdateInformationStore,
        checkForUpdates: @escaping () -> Void = {},
        refreshUpdateInformation: @escaping () -> Void = {},
        setDockIconVisible: @escaping (Bool) -> Void = { _ in },
        initialSection: SettingsSection = .connection,
        initialShareExpanded: Bool = false,
        initialMappingEditingButton: RemoteButton? = nil,
        initialMappingEditingTrigger: ButtonTrigger = .singleClick,
        initialShortcutPickerShowsKeyboard: Bool = false,
        minimumContentSize: CGSize = .zero,
        navigationCoordinator: SettingsNavigationCoordinator = SettingsNavigationCoordinator()
    ) {
        self.model = model
        settings = model.settings
        privateFeature = model.privateFeature
        macroFeature = model.macroFeature
        loginItemService = model.loginItemService
        self.updateInformation = updateInformation
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.minimumContentSize = minimumContentSize
        self.initialShortcutPickerShowsKeyboard = initialShortcutPickerShowsKeyboard
        self.navigationCoordinator = navigationCoordinator
        _selectedSection = State(initialValue: initialSection)
        _navigationHistory = State(initialValue: [initialSection])
        _navigationHistoryIndex = State(initialValue: 0)
        _isAboutShareExpanded = State(initialValue: initialShareExpanded)
        _selectedRemoteButton = State(initialValue: initialMappingEditingButton ?? .ok)
        _mappingEditingTarget = State(
            initialValue: initialMappingEditingButton.map {
                ShortcutEditingTarget(button: $0, trigger: initialMappingEditingTrigger)
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .searchable(
                    text: $sidebarSearchText,
                    placement: .sidebar,
                    prompt: Text(localization.text("settings.search.placeholder"))
                )
                .searchFocusedWhenAvailable($isSearchFocused)
                .onSubmit(of: .search) {
                    if let first = searchResults.first {
                        activateSearchResult(first)
                    }
                }
                .controlSize(.large)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)
        } detail: {
            selectedPage
                .navigationTitle(sectionTitle(selectedSection))
                .controlSize(.regular)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                navigationControlGroup
            }
        }
        .navigationSplitViewStyle(.balanced)
        .controlSize(.regular)
        .environment(\.locale, localization.locale)
        .frame(
            minWidth: minimumContentSize.width,
            minHeight: minimumContentSize.height
        )
        .onAppear {
            refreshPermissionStates()
            loginItemService.refresh()
            macroFeature.setEditorActive(false)
            syncNavigationStateWithCoordinator()
        }
        .onChange(of: selectedSection) { section in
            if section != .macros {
                macroFeature.setEditorActive(false)
            }
        }
        .onDisappear {
            macroFeature.setEditorActive(false)
        }
        .onReceive(navigationCoordinator.commands) { command in
            switch command {
            case .goBack:
                goBack()
            case .goForward:
                goForward()
            case .focusSearch:
                isSearchFocused = true
            case .selectSection(let section):
                navigate(to: section)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            loginItemService.refresh()
            resumeCustomMappingIfPermissionsGranted()
        }
        .onReceive(privateFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible, selectedSection == .privateFeature {
                navigate(to: .about)
            }
        }
        .onReceive(macroFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible, selectedSection == .macros {
                navigate(to: .about)
            }
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
        .sheet(isPresented: $isWebRemoteInvitePresented) {
            if isWebRemoteInviteAuthorized {
                webRemoteSessionView
            } else {
                webRemoteInviteSheet
            }
        }
        .alert(
            localization.text("connection.web.invite.invalid_title"),
            isPresented: $isWebRemoteInviteInvalidPresented
        ) {
            Button(localization.text("common.action.ok")) {}
        } message: {
            Text("connection.web.invite.invalid_message")
        }
        .alert(
            localization.text("button_mapping.permission_prompt.title"),
            isPresented: $isMappingPermissionAlertPresented
        ) {
            Button("button_mapping.permission_prompt.open") {
                isWaitingForMappingPermissions = true
                navigate(to: .permissions)
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

    private var webRemoteInviteSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "iphone")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.14), in: Circle())

                    VStack(alignment: .leading, spacing: 5) {
                        Text("connection.web.invite.ios_eyebrow")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text("connection.web.invite.ios_title")
                            .font(.title3.weight(.semibold))
                        Text("connection.web.invite.ios_description")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Link(destination: AppLinks.testFlightPublicBeta) {
                        Label("connection.web.invite.testflight_open", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        copyTestFlightPublicBetaLink()
                    } label: {
                        Label(
                            localization.text(
                                isTestFlightLinkCopied
                                    ? "common.status.copied"
                                    : "common.action.copy_link"
                            ),
                            systemImage: isTestFlightLinkCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
            .background(
                Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("connection.web.invite.title")
                    .font(.headline)
                Text("connection.web.invite.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField(
                localization.text("connection.web.invite.placeholder"),
                text: $webRemoteInviteCode
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("common.action.cancel") {
                    webRemoteInviteCode = ""
                    isWebRemoteInvitePresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("connection.web.invite.unlock") {
                    validateWebRemoteInviteCode()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var webRemoteSessionView: some View {
        WebRemoteSessionView(
            model: model,
            localization: WebRemoteSessionLocalization(
                locale: localization.locale,
                text: localization.text
            )
        )
    }

    @ViewBuilder
    private var sidebar: some View {
        if trimmedSidebarSearchText.isEmpty {
            settingsSectionList
        } else if searchResults.isEmpty {
            ContentUnavailableView.search(text: trimmedSidebarSearchText)
        } else {
            searchResultList
        }
    }

    private var settingsSectionList: some View {
        List(selection: Binding(
            get: { Optional(selectedSection) },
            set: { section in
                guard let section else { return }
                navigate(to: section)
            }
        )) {
            Section {
                ForEach(visibleSections) { section in
                    SettingsSidebarRow(
                        title: Text(sectionTitle(section)),
                        systemName: sectionSystemImage(section),
                        color: sectionIconColor(section)
                    )
                    .tag(section)
                    .listRowInsets(sidebarRowInsets)
                }
            }

        }
        .listStyle(.sidebar)
    }

    private var searchResultList: some View {
        List(searchResults, selection: $selectedSearchResultID) { item in
            Button {
                activateSearchResult(item)
            } label: {
                HStack(spacing: 7) {
                    SettingsSidebarIcon(
                        systemName: sectionSystemImage(item.section),
                        color: sectionIconColor(item.section)
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(sectionTitle(item.section))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 8))
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            guard let selectedSearchResultID,
                  let item = searchResults.first(where: { $0.id == selectedSearchResultID })
            else { return .ignored }
            activateSearchResult(item)
            return .handled
        }
    }

    private var sidebarRowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 8)
    }

    private var visibleSections: [SettingsSection] {
        Self.sidebarSectionOrder.filter(isSectionVisible)
    }

    private func isSectionVisible(_ section: SettingsSection) -> Bool {
        switch section {
        case .privateFeature: return privateFeature.isFeatureVisible
        case .macros: return macroFeature.isFeatureVisible
        default: return true
        }
    }

    private var trimmedSidebarSearchText: String {
        sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [SettingsSearchItem] {
        let query = trimmedSidebarSearchText
        guard !query.isEmpty else { return [] }
        return settingsSearchItems.filter { item in
            ([item.title, sectionTitle(item.section)] + item.keywords).contains { text in
                text.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var settingsSearchItems: [SettingsSearchItem] {
        var items: [SettingsSearchItem] = []

        for section in visibleSections {
            items.append(SettingsSearchItem(
                "page.\(section.rawValue)",
                section: section,
                title: sectionTitle(section),
                anchor: pageTopAnchor(for: section)
            ))
        }

        items.append(contentsOf: [
            searchItem(
                "connection.remote",
                section: .connection,
                titleKey: "remote.device.selector",
                anchor: "connection-remote"
            ),
            searchItem(
                "connection.audio-output",
                section: .connection,
                titleKey: "audio.voice_output.section_title",
                anchor: "connection-audio-output",
                keywordKeys: ["audio.output.title", "audio.gain.title", "audio.status.title"]
            ),
            searchItem(
                "connection.gain",
                section: .connection,
                titleKey: "audio.gain.title",
                anchor: "connection-audio-output",
                keywordKeys: ["audio.gain.help"]
            ),
            searchItem(
                "connection.audio-status",
                section: .connection,
                titleKey: "audio.status.title",
                anchor: "connection-audio-output"
            ),
            searchItem(
                "connection.compatibility",
                section: .connection,
                titleKey: "audio.compatibility.section_title",
                anchor: "connection-compatibility",
                keywordKeys: [
                    "audio.compatibility.microphone_label",
                    "audio.compatibility.select_microphone",
                ]
            ),
            searchItem(
                "connection.iphone",
                section: .connection,
                titleKey: "connection.phone.ios_title",
                anchor: "connection-mobile"
            ),
            searchItem(
                "connection.watch",
                section: .connection,
                titleKey: "connection.watch.title",
                anchor: "connection-mobile"
            ),
            searchItem(
                "connection.web",
                section: .connection,
                titleKey: "connection.web.title",
                anchor: "connection-mobile"
            ),
            searchItem(
                "mapping.enable",
                section: .mapping,
                titleKey: "button_mapping.toggle.enabled",
                anchor: "mapping-controls"
            ),
            searchItem(
                "mapping.remote",
                section: .mapping,
                titleKey: "remote.device.selector",
                anchor: "mapping-controls"
            ),
            searchItem(
                "mapping.actions",
                section: .mapping,
                titleKey: "button_mapping.actions.title",
                anchor: "mapping-actions"
            ),
            searchItem(
                "mapping.all-buttons",
                section: .mapping,
                titleKey: "button_mapping.all_buttons.title",
                anchor: "mapping-actions"
            ),
            searchItem(
                "mapping.selection-lock",
                section: .mapping,
                titleKey: "button_mapping.selection_lock",
                anchor: "mapping-footer"
            ),
            searchItem(
                "mapping.voice-button",
                section: .mapping,
                titleKey: "button_mapping.voice_button.title",
                anchor: "mapping-footer"
            ),
            searchItem(
                "mapping.voice-fn",
                section: .mapping,
                titleKey: "connection.voice_fn_tap.enabled",
                anchor: "mapping-footer"
            ),
            searchItem(
                "mapping.restore-defaults",
                section: .mapping,
                titleKey: "common.action.restore_defaults",
                anchor: "mapping-footer"
            ),
            searchItem(
                "statistics.button-count",
                section: .statistics,
                titleKey: "statistics.metric.button_count",
                anchor: "statistics-charts"
            ),
            searchItem(
                "statistics.voice-duration",
                section: .statistics,
                titleKey: "statistics.metric.voice_duration",
                anchor: "statistics-charts"
            ),
            searchItem(
                "statistics.voice-ranking",
                section: .statistics,
                titleKey: "statistics.voice_ranking.title",
                anchor: "statistics-ranking"
            ),
            searchItem(
                "transcripts.enable",
                section: .transcripts,
                titleKey: "statistics.transcripts.enable",
                anchor: "transcripts-enable"
            ),
            searchItem(
                "transcripts.records",
                section: .transcripts,
                titleKey: "statistics.transcripts.all_records",
                anchor: "transcripts-records",
                keywordKeys: ["statistics.transcripts.applications"]
            ),
            searchItem(
                "transcripts.delete-all",
                section: .transcripts,
                titleKey: "statistics.transcripts.delete_all",
                anchor: "transcripts-records"
            ),
            searchItem(
                "transcripts.agent-access",
                section: .transcripts,
                titleKey: "statistics.transcripts.agent_access.title",
                anchor: "transcripts-records",
                keywordKeys: ["statistics.transcripts.agent_access.quick_connect"]
            ),
            searchItem(
                "permissions.bluetooth",
                section: .permissions,
                titleKey: "permission.bluetooth.title",
                anchor: "permissions-required"
            ),
            searchItem(
                "permissions.input-monitoring",
                section: .permissions,
                titleKey: "permission.input_monitoring.title",
                anchor: "permissions-required"
            ),
            searchItem(
                "permissions.accessibility",
                section: .permissions,
                titleKey: "permission.accessibility.title",
                anchor: "permissions-required"
            ),
            searchItem(
                "permissions.logs",
                section: .permissions,
                titleKey: "diagnostics.logs.title",
                anchor: "permissions-diagnostics"
            ),
            searchItem(
                "about.feedback",
                section: .about,
                titleKey: "about.support.feedback",
                anchor: "about-support"
            ),
            searchItem(
                "about.share",
                section: .about,
                titleKey: "share.action",
                anchor: "about-support"
            ),
            searchItem(
                "about.website",
                section: .about,
                titleKey: "about.support.website",
                anchor: "about-support"
            ),
            searchItem(
                "about.github",
                section: .about,
                titleKey: "about.support.github",
                anchor: "about-support"
            ),
            searchItem(
                "about.version",
                section: .about,
                titleKey: "about.version.title",
                anchor: "about-version",
                keywordKeys: ["about.version.current", "about.version.latest"]
            ),
            searchItem(
                "about.prerelease",
                section: .about,
                titleKey: "about.version.check_prerelease",
                anchor: "about-version"
            ),
            searchItem(
                "about.configuration",
                section: .about,
                titleKey: "about.configuration.title",
                anchor: "about-configuration",
                keywordKeys: ["about.configuration.export", "about.configuration.import"]
            ),
            searchItem(
                "about.dock",
                section: .about,
                titleKey: "about.preferences.show_dock_icon",
                anchor: "about-preferences"
            ),
            searchItem(
                "about.login-item",
                section: .about,
                titleKey: "about.preferences.launch_at_login",
                anchor: "about-preferences"
            ),
            searchItem(
                "about.main-window",
                section: .about,
                titleKey: "about.preferences.open_main_window_at_launch",
                anchor: "about-preferences"
            ),
            searchItem(
                "about.language",
                section: .about,
                titleKey: "about.preferences.language",
                anchor: "about-preferences"
            ),
            searchItem(
                "about.onboarding",
                section: .about,
                titleKey: "about.preferences.restart_onboarding",
                anchor: "about-preferences"
            ),
        ])

        return items.filter { isSectionVisible($0.section) }
    }

    private func searchItem(
        _ id: String,
        section: SettingsSection,
        titleKey: String,
        anchor: String,
        keywordKeys: [String] = []
    ) -> SettingsSearchItem {
        SettingsSearchItem(
            id,
            section: section,
            title: localization.text(titleKey),
            anchor: anchor,
            keywords: keywordKeys.map(localization.text)
        )
    }

    private func pageTopAnchor(for section: SettingsSection) -> String {
        switch section {
        case .connection: return "connection-remote"
        case .mapping: return "mapping-controls"
        case .statistics: return "statistics-period"
        case .transcripts: return "transcripts-enable"
        case .permissions: return "permissions-required"
        case .about: return "about-summary"
        case .privateFeature, .macros: return "page-top"
        }
    }

    @ViewBuilder
    private var navigationControlGroup: some View {
        if #available(macOS 26.0, *) {
            nativeNavigationControlGroup
                .controlSize(.extraLarge)
                .buttonStyle(.glass)
        } else {
            nativeNavigationControlGroup
                .controlSize(.large)
        }
    }

    private var nativeNavigationControlGroup: some View {
        ControlGroup {
            Menu {
                ForEach(backwardHistoryIndices, id: \.self) { index in
                    Button(sectionTitle(navigationHistory[index])) {
                        moveInHistory(to: index)
                    }
                }
            } label: {
                Image(systemName: "chevron.backward")
            } primaryAction: {
                goBack()
            }
            .disabled(previousHistoryIndex == nil)
            .menuIndicator(.hidden)
            .help(localization.text("settings.navigation.back"))

            Menu {
                ForEach(forwardHistoryIndices, id: \.self) { index in
                    Button(sectionTitle(navigationHistory[index])) {
                        moveInHistory(to: index)
                    }
                }
            } label: {
                Image(systemName: "chevron.forward")
            } primaryAction: {
                goForward()
            }
            .disabled(nextHistoryIndex == nil)
            .menuIndicator(.hidden)
            .help(localization.text("settings.navigation.forward"))
        }
        .controlGroupStyle(.navigation)
    }

    private var backwardHistoryIndices: [Int] {
        guard navigationHistoryIndex > 0 else { return [] }
        return stride(from: navigationHistoryIndex - 1, through: 0, by: -1)
            .filter { isSectionVisible(navigationHistory[$0]) }
    }

    private var previousHistoryIndex: Int? {
        guard navigationHistoryIndex > 0 else { return nil }
        return stride(from: navigationHistoryIndex - 1, through: 0, by: -1)
            .first { isSectionVisible(navigationHistory[$0]) }
    }

    private var nextHistoryIndex: Int? {
        guard navigationHistoryIndex < navigationHistory.count - 1 else { return nil }
        return (navigationHistoryIndex + 1..<navigationHistory.count)
            .first { isSectionVisible(navigationHistory[$0]) }
    }

    private var forwardHistoryIndices: [Int] {
        guard navigationHistoryIndex < navigationHistory.count - 1 else { return [] }
        return (navigationHistoryIndex + 1..<navigationHistory.count)
            .filter { isSectionVisible(navigationHistory[$0]) }
    }

    private func navigate(to section: SettingsSection, searchAnchor: String? = nil) {
        if let searchAnchor {
            searchNavigationRequest = SettingsSearchNavigationRequest(
                section: section,
                anchor: searchAnchor
            )
        } else {
            searchNavigationRequest = nil
        }

        guard selectedSection != section else { return }
        navigationHistory = Array(navigationHistory.prefix(navigationHistoryIndex + 1)) + [section]
        navigationHistoryIndex = navigationHistory.count - 1
        selectedSection = section
        syncNavigationStateWithCoordinator()
    }

    private func activateSearchResult(_ item: SettingsSearchItem) {
        navigate(to: item.section, searchAnchor: item.anchor)
    }

    private func goBack() {
        guard let previousHistoryIndex else { return }
        moveInHistory(to: previousHistoryIndex)
    }

    private func goForward() {
        guard let nextHistoryIndex else { return }
        moveInHistory(to: nextHistoryIndex)
    }

    private func moveInHistory(to index: Int) {
        guard navigationHistory.indices.contains(index) else { return }
        navigationHistoryIndex = index
        searchNavigationRequest = nil
        selectedSection = navigationHistory[index]
        syncNavigationStateWithCoordinator()
    }

    private func syncNavigationStateWithCoordinator() {
        navigationCoordinator.canGoBack = previousHistoryIndex != nil
        navigationCoordinator.canGoForward = nextHistoryIndex != nil
    }

    private func scrollToSearchResult(
        in section: SettingsSection,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let request = searchNavigationRequest, request.section == section else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(request.anchor, anchor: .top)
                }
            } else {
                proxy.scrollTo(request.anchor, anchor: .top)
            }
            flashSearchResultHighlight(request.anchor)
        }
    }

    private func flashSearchResultHighlight(_ anchor: String) {
        highlightedSearchAnchor = anchor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard highlightedSearchAnchor == anchor else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                highlightedSearchAnchor = nil
            }
        }
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selectedSection {
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
                        configuredActionTitle: { buttonValue, triggerValue in
                            guard let button = RemoteButton(rawValue: buttonValue),
                                  let trigger = ButtonTrigger(rawValue: triggerValue)
                            else { return nil }
                            return mappingActionSummary(for: button, trigger: trigger)
                        }
                    )
                    Divider()
                    Label(
                        localization.text("macro.integration.focus_mcp_boundary"),
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                }
            } else {
                aboutPage
            }
        case .mapping:
            mappingPage
        case .statistics:
            statisticsPage
        case .transcripts:
            transcriptHistoryPage
        case .permissions:
            permissionsPage
        case .about:
            aboutPage
        }
    }

    private var connectionPage: some View {
        ScrollViewReader { proxy in
            Form {
                Section("remote.device.selector") {
                    connectionDevicePanel
                }
                .searchAnchor("connection-remote", highlighted: highlightedSearchAnchor)

                Section {
                    audioSettingsPanel
                } footer: {
                    Text("audio.output.privacy_help")
                }
                .searchAnchor("connection-audio-output", highlighted: highlightedSearchAnchor)

                Section {
                    audioCompatibilityPanel
                } header: {
                    Text("audio.compatibility.section_title")
                } footer: {
                    Text("audio.compatibility.help_plain")
                }
                .searchAnchor("connection-compatibility", highlighted: highlightedSearchAnchor)

                Section {
                    phoneConnectionsPanel
                } header: {
                    Text("connection.phone.section_title")
                } footer: {
                    Text("connection.trusted_devices.help")
                }
                .searchAnchor("connection-mobile", highlighted: highlightedSearchAnchor)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToSearchResult(in: .connection, using: proxy, animated: false)
            }
            .onChange(of: searchNavigationRequest?.id) {
                scrollToSearchResult(in: .connection, using: proxy, animated: true)
            }
        }
    }

    private var phoneConnectionsPanel: some View {
        Group {
            connectionOptionRow(
                systemImage: "iphone",
                title: "connection.phone.ios_title",
                detail: "connection.phone.ios_help",
                status: localization.text(
                    model.isPhoneRemoteConnected
                        ? "connection.phone.connected"
                        : model.isPhoneRemoteConnectionEnabled
                            ? "connection.phone.enabled"
                            : "connection.phone.not_enabled"
                ),
                statusTint: model.isPhoneRemoteConnected
                    ? .green
                    : model.isPhoneRemoteConnectionEnabled ? .orange : .secondary,
                isWaiting: model.isPhoneRemoteConnectionEnabled && !model.isPhoneRemoteConnected,
                auxiliaryActions: {
                    HStack(spacing: 8) {
                        Link(destination: AppLinks.testFlightPublicBeta) {
                            Label(
                                "connection.web.invite.testflight_open",
                                systemImage: "arrow.up.right.square"
                            )
                        }
                        .buttonStyle(.bordered)

                        Button {
                            copyTestFlightPublicBetaLink()
                        } label: {
                            Label(
                                localization.text(
                                    isTestFlightLinkCopied
                                        ? "common.status.copied"
                                        : "common.action.copy_link"
                                ),
                                systemImage: isTestFlightLinkCopied ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
            ) {
                Button(
                    model.isPhoneRemoteConnected
                        ? "connection.phone.disconnect"
                        : model.isPhoneRemoteConnectionEnabled
                            ? "connection.phone.cancel_waiting"
                            : "connection.phone.connect"
                ) {
                    model.togglePhoneRemoteConnection()
                }
                .buttonStyle(.bordered)
            }

            if let invitation = model.phoneRemoteInvitation {
                PhoneRemoteInvitationCard(invitation: invitation)
            }

            connectionOptionRow(
                systemImage: "applewatch",
                title: "connection.watch.title",
                detail: "connection.watch.help",
                status: localization.text(
                    model.isWatchRemoteConnected
                        ? "connection.watch.connected"
                        : model.isWatchRemoteConnectionEnabled
                            ? "connection.watch.enabled"
                            : "connection.phone.not_enabled"
                ),
                statusTint: model.isWatchRemoteConnected
                    ? .green
                    : model.isWatchRemoteConnectionEnabled ? .orange : .secondary,
                isWaiting: model.isWatchRemoteConnectionEnabled && !model.isWatchRemoteConnected
            ) {
                Button(
                    model.isWatchRemoteConnected
                        ? "connection.watch.disconnect"
                        : model.isWatchRemoteConnectionEnabled
                            ? "connection.watch.cancel_waiting"
                            : "connection.watch.connect"
                ) {
                    model.toggleWatchRemoteConnection()
                }
                .buttonStyle(.bordered)
            }

            connectionOptionRow(
                systemImage: "globe",
                title: "connection.web.title",
                detail: "connection.web.help_short",
                status: webRemoteStatusText,
                statusTint: webRemoteStatusTint,
                isWaiting: isWebRemoteWaiting
            ) {
                Button(
                    model.webRemoteState.isEnabled
                        ? "connection.web.show_qr"
                        : "connection.web.connect"
                ) {
                    requestWebRemoteSession()
                }
                .buttonStyle(.bordered)
            }

            LabeledContent {
                Button("connection.trusted_devices.clear") {
                    isClearTrustedPhonesConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .disabled(settings.trustedPhoneIdentityFingerprints.isEmpty)
            } label: {
                Label(
                    LocalizedMessage(
                        "connection.trusted_devices.count_long",
                        arguments: [String(settings.trustedPhoneIdentityFingerprints.count)]
                    ).text(using: localization),
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private func connectionOptionRow<Actions: View>(
        systemImage: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        status: String,
        statusTint: Color,
        isWaiting: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        LabeledContent {
            connectionOptionControls(
                status: status,
                statusTint: statusTint,
                isWaiting: isWaiting,
                actions: actions
            )
        } label: {
            connectionOptionLabel(systemImage: systemImage, title: title, detail: detail)
        }
    }

    private func connectionOptionRow<Actions: View, AuxiliaryActions: View>(
        systemImage: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        status: String,
        statusTint: Color,
        isWaiting: Bool = false,
        @ViewBuilder auxiliaryActions: () -> AuxiliaryActions,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                connectionOptionControls(
                    status: status,
                    statusTint: statusTint,
                    isWaiting: isWaiting,
                    actions: actions
                )
            } label: {
                connectionOptionLabel(systemImage: systemImage, title: title, detail: detail)
            }

            HStack(spacing: 8) {
                Spacer()
                auxiliaryActions()
            }
        }
    }

    private func connectionOptionControls<Actions: View>(
        status: String,
        statusTint: Color,
        isWaiting: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                connectionStatusLabel(status, tint: statusTint, isWaiting: isWaiting)
                actions()
            }
            VStack(alignment: .trailing, spacing: 8) {
                connectionStatusLabel(status, tint: statusTint, isWaiting: isWaiting)
                actions()
            }
        }
    }

    private func connectionOptionLabel(
        systemImage: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
        } icon: {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
    }

    private func connectionStatusLabel(_ text: String, tint: Color, isWaiting: Bool) -> some View {
        HStack(spacing: 6) {
            if isWaiting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    private var connectionDevicePanel: some View {
        Group {
            HStack(alignment: .top, spacing: 20) {
                connectionRemotePicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                RC003Photo()
                    .frame(width: 48, height: 98)
                    .accessibilityHidden(true)
            }

            LabeledContent("connection.status.bluetooth_title") {
                Label(
                    model.connectionStatus.text(using: localization),
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .foregroundStyle(connectionTint)
            }

            LabeledContent("connection.status.voice_title") {
                Label(
                    localization.text(
                        model.isStreaming
                            ? "connection.status.voice_streaming"
                            : "connection.status.voice_ready"
                    ),
                    systemImage: "waveform"
                )
                .foregroundStyle(model.isStreaming ? Color.orange : Color.secondary)
            }

            LabeledContent("connection.status.voice_trigger") {
                Label(
                    model.voiceShortcutStatus.text(using: localization),
                    systemImage: "mic.fill"
                )
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("connection.action.reconnect") {
                    model.reconnect()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var connectionRemotePicker: some View {
        let connectedProfiles = settings.remoteDeviceProfiles.filter {
            model.isRemoteConnected($0.id)
        }
        if connectedProfiles.isEmpty {
            Label(
                model.connectionStatus.text(using: localization),
                systemImage: "appletvremote.gen4.fill"
            )
            .foregroundStyle(.secondary)
        } else {
            Picker("remote.device.current", selection: Binding(
                get: { settings.selectedRemoteProfileID },
                set: { profileID in
                    guard let profileID else { return }
                    model.selectRemoteProfile(profileID)
                }
            )) {
                ForEach(connectedProfiles) { profile in
                    Text(remoteDisplayName(profile))
                        .tag(Optional(profile.id))
                }
            }
            .pickerStyle(.radioGroup)

            if let selectedProfile = connectedProfiles.first(where: {
                $0.id == settings.selectedRemoteProfileID
            }) {
                HStack(spacing: 10) {
                    remoteConnectionLabel(connected: true)
                    remoteBatteryLabel(
                        level: model.batteryLevel(for: selectedProfile.id),
                        powerState: model.powerState(for: selectedProfile.id)
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var audioSettingsPanel: some View {
        let audioStatusText = model.audioStatus.text(using: localization)
        let testToneStatusText = model.testToneStatus.text(using: localization)
        let shouldShowTestToneStatus = !testToneStatusText.isEmpty
            && model.testToneStatus.key != "audio.test_tone.ready"
            && (
                model.audioStatus.key == "audio.output.current_format"
                    || testToneStatusText != audioStatusText
            )

        return Group {
            Picker("audio.output.title", selection: Binding(
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

            audioGainSettingsRow

            if model.audioStatus.key != "audio.output.current_format" {
                LabeledContent("audio.status.title") {
                    Text(audioStatusText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Spacer()
                    Button("audio.action.refresh_devices") {
                        model.refreshAudioDevices()
                    }
                    .buttonStyle(.bordered)
                    Link(
                        "audio.action.learn_virtual_microphones",
                        destination: URL(string: "https://existential.audio/blackhole/")!
                    )
                    .buttonStyle(.bordered)
                    Button("audio.action.send_test_tone") {
                        model.sendTestTone()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canSendTestTone)
                }

                if shouldShowTestToneStatus {
                    Text(testToneStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var audioGainSettingsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("audio.gain.title") {
                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { settings.gainDB },
                        set: { settings.gainDB = $0 }
                    ), in: 0...24, step: 1)
                    .frame(minWidth: 220)
                    Text("\(Int(settings.gainDB)) dB")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 54, alignment: .trailing)
                }
            }

            Text("audio.gain.help")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var audioCompatibilityPanel: some View {
        Group {
            LabeledContent("audio.compatibility.microphone_label") {
                Label(
                    model.doubaoAudioStatus.text(using: localization),
                    systemImage: model.hasDoubaoAudioDevice
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.hasDoubaoAudioDevice ? .green : .orange)
                .multilineTextAlignment(.trailing)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("audio.compatibility.select_microphone") {
                    model.selectDoubaoAudioDevice()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasDoubaoAudioDevice)
                Button("audio.compatibility.open_install_guide") {
                    model.openDoubaoDriverInstructions(using: localization)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var mappingPage: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Toggle("button_mapping.toggle.enabled", isOn: Binding(
                        get: { settings.customMappingEnabled },
                        set: setCustomMappingEnabled
                    ))
                    .toggleStyle(.switch)

                    mappingRemoteDeviceBlock
                }
                .searchAnchor("mapping-controls", highlighted: highlightedSearchAnchor)

                Section {
                    RemoteMappingCanvas(
                        selectedButton: $selectedRemoteButton,
                        activeButtons: model.activeRemoteButtons,
                        voiceActive: model.isStreaming,
                        actionSummary: mappingActionSummary,
                        onEdit: { button, trigger in
                            selectedRemoteButton = button
                            isPresetApplicationActionsExpanded = false
                            mappingEditingTarget = ShortcutEditingTarget(
                                button: button,
                                trigger: trigger
                            )
                        }
                    )
                    .onReceive(model.$activeRemoteButtons) { buttons in
                        selectedRemoteButton = MappingSelectionPolicy.selection(
                            current: selectedRemoteButton,
                            activeButtons: buttons,
                            isLocked: isMappingSelectionLocked
                        )
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .searchAnchor("mapping-actions", highlighted: highlightedSearchAnchor)

                if let target = mappingEditingTarget {
                    Section {
                        mappingEditorPanel(target)
                            .id("mapping-action-editor")
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
                }

                Section {
                    mappingFooter
                }
                .searchAnchor("mapping-footer", highlighted: highlightedSearchAnchor)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .animation(.easeInOut(duration: 0.2), value: mappingEditingTarget == nil)
            .onAppear {
                guard let target = mappingEditingTarget else { return }
                let scrollTarget = settings.configuredAction(
                    for: target.button,
                    trigger: target.trigger
                ).action == .customShortcut
                    ? "mapping-shortcut-editor-\(target.id)"
                    : "mapping-action-editor"
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
            .onChange(of: mappingEditingTarget?.id) { _, targetID in
                guard targetID != nil else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("mapping-action-editor", anchor: .top)
                    }
                }
            }
            .onAppear {
                scrollToSearchResult(in: .mapping, using: proxy, animated: false)
            }
            .onChange(of: searchNavigationRequest?.id) {
                scrollToSearchResult(in: .mapping, using: proxy, animated: true)
            }
        }
    }

    private var mappingRemoteDeviceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("remote.device.selector")
            mappingHeaderDeviceContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var mappingHeaderDeviceContent: some View {
        remoteDeviceSelector(vertical: true)
    }

    private func mappingEditorPanel(_ target: ShortcutEditingTarget) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(target.button.displayName(using: localization))
                    .font(.headline)
                Text(target.trigger.displayName(using: localization))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Spacer()
                Toggle(
                    "button_mapping.action.disable_switch",
                    isOn: Binding(
                        get: {
                            settings.configuredAction(
                                for: target.button,
                                trigger: target.trigger
                            ).action == .disabled
                        },
                        set: { disabled in
                            settings.setAction(
                                disabled ? .disabled : .escape,
                                for: target.button,
                                trigger: target.trigger
                            )
                            shortcutCaptureTarget = nil
                            applicationShortcutCaptureProfileID = nil
                        }
                    )
                )
                .font(.body.weight(.semibold))
                .toggleStyle(.switch)
                .controlSize(.regular)
                .disabled(
                    target.button == .power &&
                        target.trigger == .singleClick &&
                        settings.experimentalContinuousRecordingEnabled
                )
                Button("common.action.close") {
                    mappingEditingTarget = nil
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                }
                .buttonStyle(.bordered)
            }

            mappingTriggerEditor(target.button, trigger: target.trigger)
        }
    }

    private var mappingFooter: some View {
        VStack(spacing: 0) {
            Label(
                model.hidStatus.text(using: localization),
                systemImage: "keyboard"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 10)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("button_mapping.selection_lock")
                        .font(.body.weight(.medium))
                    Text("button_mapping.selection_lock_hint_short")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Toggle(
                    "button_mapping.selection_lock",
                    isOn: $isMappingSelectionLocked
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
            }
            .help(localization.text("button_mapping.selection_lock_help"))

            Divider()
                .padding(.vertical, 10)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("connection.voice_key_mode.title")
                        .font(.body.weight(.medium))
                    Text("connection.voice_key_mode.help")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

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
                .fixedSize()
            }
            .help(localization.text("connection.voice_key_mode.help"))

            Divider()
                .padding(.vertical, 10)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("connection.voice_fn_tap.enabled")
                        .font(.body.weight(.medium))
                    Text("connection.voice_fn_tap.hint_short")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Toggle(
                    "connection.voice_fn_tap.enabled",
                    isOn: Binding(
                        get: { settings.voiceFnTapModeEnabled },
                        set: { model.setVoiceFnTapModeEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
            }
            .help(localization.text("connection.voice_fn_tap.hint"))
            .opacity(settings.voiceKeyMode == .function ? 1 : 0.55)
            .disabled(settings.voiceKeyMode != .function)

            Divider()
                .padding(.vertical, 10)

            HStack {
                Spacer()
                Button("common.action.restore_defaults") {
                    settings.resetBindings()
                    selectedRemoteButton = .ok
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func remoteDeviceSelector(vertical: Bool = false) -> some View {
        let connectedProfiles = settings.remoteDeviceProfiles.filter {
            model.isRemoteConnected($0.id)
        }
        if connectedProfiles.isEmpty {
            remoteDeviceEmptyState(vertical: vertical)
        } else if vertical {
            VStack(spacing: 8) {
                ForEach(connectedProfiles) { profile in
                    remoteDeviceCard(profile, fillsWidth: true)
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(connectedProfiles) { profile in
                    remoteDeviceCard(profile)
                }
            }
        }
    }

    private func remoteDeviceEmptyState(vertical: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Label(
                    model.connectionStatus.text(using: localization),
                    systemImage: "appletvremote.gen4.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Button("connection.action.reconnect") {
                    model.reconnect()
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: vertical ? .trailing : .leading, spacing: 8) {
                Label(
                    model.connectionStatus.text(using: localization),
                    systemImage: "appletvremote.gen4.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("connection.action.reconnect") {
                    model.reconnect()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func remoteDeviceCard(
        _ profile: RemoteDeviceProfile,
        fillsWidth: Bool = false
    ) -> some View {
        let selected = settings.selectedRemoteProfileID == profile.id
        let connected = model.isRemoteConnected(profile.id)
        let batteryLevel = model.batteryLevel(for: profile.id)
        return SelectableCardButton(isSelected: selected, cornerRadius: 10) {
            model.selectRemoteProfile(profile.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(remoteDisplayName(profile))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .help(localization.text("remote.device.current"))
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        remoteConnectionLabel(connected: connected)
                        remoteBatteryLabel(
                            level: batteryLevel,
                            powerState: model.powerState(for: profile.id)
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            remoteConnectionLabel(connected: connected)
                            remoteBatteryLabel(
                                level: batteryLevel,
                                powerState: model.powerState(for: profile.id)
                            )
                        }
                    }
                }
                .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: fillsWidth ? nil : 232, alignment: .leading)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        }
    }

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
                    .font(.body.weight(.medium))
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

    private func remoteDisplayName(_ profile: RemoteDeviceProfile) -> String {
        let base = localization.text(profile.displayNameFallbackKey)
        let peers = settings.remoteDeviceProfiles.filter { $0.model == profile.model }
        guard peers.count > 1,
              let index = peers.firstIndex(where: { $0.id == profile.id })
        else { return base }
        return "\(base) \(index + 1)"
    }

    private func mappingTriggerEditor(
        _ button: RemoteButton,
        trigger: ButtonTrigger
    ) -> some View {
        let configured = settings.configuredAction(for: button, trigger: trigger)
        let installedBundleIdentifiers = PresetApplication.installedBundleIdentifiers
        let actions = ButtonAction.pickerActions(
            installedBundleIdentifiers: installedBundleIdentifiers,
            current: configured.action,
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ).filter { $0 != .disabled }
        let isManagedPowerAction = button == .power &&
            trigger == .singleClick &&
            settings.experimentalContinuousRecordingEnabled
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(ButtonActionCategory.allCases) { category in
                let groupedActions = actions.filter { $0.category == category }
                if !groupedActions.isEmpty {
                    mappingActionGroup(
                        category: category,
                        actions: groupedActions,
                        selectedAction: configured.action,
                        installedBundleIdentifiers: installedBundleIdentifiers,
                        isManagedPowerAction: isManagedPowerAction,
                        onSelect: { action in
                            settings.setAction(action, for: button, trigger: trigger)
                            shortcutCaptureTarget = nil
                            applicationShortcutCaptureProfileID = nil
                        }
                    )
                }
            }

            if configured.action == .customShortcut {
                inlineShortcutEditor(
                    button: button,
                    trigger: trigger,
                    configured: configured
                )
            }

            if configured.action == .openCustomApplication {
                customApplicationEditor(
                    button: button,
                    trigger: trigger,
                    configured: configured
                )
            }

            if trigger == .singleClick,
               configured.action != .disabled,
               !configured.action.allowsRepeat {
                mappingRapidPressControl(button: button)
            }

            if button == .power && trigger == .singleClick && settings.experimentalContinuousRecordingEnabled {
                Text("button_mapping.continuous_recording_experiment.power_managed")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if trigger == .doubleClick && configured.action != .disabled {
                Text("button_mapping.double_click.effect")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if trigger == .longPress && configured.action != .disabled {
                Text("button_mapping.long_press.effect")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if trigger == .singleClick {
                Text("button_mapping.single_click.help")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mappingRapidPressControl(button: RemoteButton) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("button_mapping.rapid_press", isOn: Binding(
                get: { settings.allowsRapidPress(for: button) },
                set: { settings.setAllowsRapidPress($0, for: button) }
            ))
            .font(.system(size: 13, weight: .medium))
            .toggleStyle(.switch)
            Text("button_mapping.rapid_press_hint_short")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
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
        if category == .applications {
            DisclosureGroup(isExpanded: $isPresetApplicationActionsExpanded) {
                mappingActionGrid(
                    actions: actions,
                    selectedAction: selectedAction,
                    installedBundleIdentifiers: installedBundleIdentifiers,
                    isManagedPowerAction: isManagedPowerAction,
                    onSelect: onSelect
                )
                .padding(.top, 8)
            } label: {
                Text(localization.text(category.localizationKey))
                    .font(.body.weight(.semibold))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(localization.text(category.localizationKey))
                    .font(.body.weight(.semibold))

                mappingActionGrid(
                    actions: actions,
                    selectedAction: selectedAction,
                    installedBundleIdentifiers: installedBundleIdentifiers,
                    isManagedPowerAction: isManagedPowerAction,
                    onSelect: onSelect
                )
            }
        }
    }

    private func mappingActionGrid(
        actions: [ButtonAction],
        selectedAction: ButtonAction,
        installedBundleIdentifiers: Set<String>,
        isManagedPowerAction: Bool,
        onSelect: @escaping (ButtonAction) -> Void
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 148), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(actions) { action in
                let unavailableApplication = action.presetApplication.map {
                    !installedBundleIdentifiers.contains($0.bundleIdentifier)
                } ?? false
                let unavailableExperiment = action == .toggleLongRecording &&
                    !settings.experimentalContinuousRecordingEnabled
                SelectableCardButton(isSelected: selectedAction == action, cornerRadius: 8) {
                    onSelect(action)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: selectedAction == action ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedAction == action ? Color.accentColor : Color.secondary)
                        Text(
                            action.displayName(using: localization) +
                                (unavailableApplication
                                    ? localization.text("common.suffix.not_installed")
                                    : unavailableExperiment
                                        ? localization.text("common.suffix.experimental_disabled")
                                        : "")
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.body.weight(selectedAction == action ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
                .disabled(isManagedPowerAction || unavailableApplication || unavailableExperiment)
            }
        }
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
                .font(.callout)
                .foregroundStyle(.secondary)

            if shortcutCaptureTarget == target {
                HStack(spacing: 10) {
                    Label("shortcut.editor.recording_prompt", systemImage: "keyboard.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    Button("common.action.cancel") {
                        shortcutCaptureTarget = nil
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                ShortcutCaptureView(
                    onCapture: { shortcut in
                        settings.setShortcut(shortcut, for: button, trigger: trigger)
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
                                configured.shortcut?.displayName(using: localization) ??
                                    localization.text("shortcut.editor.not_recorded")
                            )
                        } icon: {
                            Image(systemName: configured.shortcut == nil ? "keyboard" : "keyboard.badge.checkmark")
                                .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.green)
                        }
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                        Button(configured.shortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again") {
                            applicationShortcutCaptureProfileID = nil
                            shortcutCaptureFeedback = nil
                            shortcutCaptureTarget = target
                        }
                        .buttonStyle(.bordered)

                        Button("common.action.clear") {
                            settings.setShortcut(nil, for: button, trigger: trigger)
                            shortcutCaptureFeedback = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(configured.shortcut == nil)
                    }

                    shortcutCaptureFeedbackView(contextID: contextID)

                    KeyboardShortcutPicker(
                        shortcut: configured.shortcut,
                        showsStandardKeyboardInitially: initialShortcutPickerShowsKeyboard,
                        onSelect: { shortcut in
                            settings.setShortcut(shortcut, for: button, trigger: trigger)
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

    @ViewBuilder
    private func customApplicationEditor(
        button: RemoteButton,
        trigger: ButtonTrigger,
        configured: ConfiguredButtonAction
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("custom_application.target")
                .font(.body.weight(.semibold))

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
                        settings.setApplicationProfileID(profile.id, for: button, trigger: trigger)
                    }
                }

                Button {
                    chooseCustomApplication(for: button, trigger: trigger)
                } label: {
                    Label("custom_application.add", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }

            if let profile = settings.customApplicationProfile(id: configured.applicationProfileID) {
                Divider()

                Text("custom_application.focus_strategy")
                    .font(.body.weight(.semibold))

                HStack(spacing: 8) {
                    ForEach(CustomApplicationFocusStrategy.allCases) { strategy in
                        SelectableCardButton(
                            isSelected: profile.focusStrategy == strategy,
                            cornerRadius: 8
                        ) {
                            var updated = profile
                            updated.focusStrategy = strategy
                            settings.updateCustomApplicationProfile(updated)
                            applicationShortcutCaptureProfileID = nil
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: profile.focusStrategy == strategy ? "checkmark.circle.fill" : "circle")
                                Text(strategy.displayName(using: localization))
                                    .lineLimit(1)
                            }
                            .font(.body.weight(profile.focusStrategy == strategy ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .foregroundStyle(profile.focusStrategy == strategy ? Color.accentColor : Color.primary)
                    }
                }

                if profile.focusStrategy == .keyboardShortcut {
                    inlineApplicationShortcutEditor(profile)
                }

                if profile.focusStrategy == .recordedAccessibility {
                    accessibilityLearningEditor(profile)
                }

                HStack {
                    Spacer()
                    Button("custom_application.test") {
                        _ = KeyboardInjector.send(
                            .openCustomApplication,
                            applicationProfile: profile
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("custom_application.not_configured")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func profileSelectionButton(
        _ profile: CustomApplicationProfile,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SelectableCardButton(isSelected: selected, cornerRadius: 8, action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "app")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(profile.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.body.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
    }

    @ViewBuilder
    private func inlineApplicationShortcutEditor(_ profile: CustomApplicationProfile) -> some View {
        let contextID = "application-\(profile.id.uuidString)"
        VStack(alignment: .leading, spacing: 10) {
            Text("custom_application.shortcut.editor_instructions")
                .font(.callout)
                .foregroundStyle(.secondary)

            if applicationShortcutCaptureProfileID == profile.id {
                HStack(spacing: 10) {
                    Label("shortcut.editor.recording_prompt", systemImage: "keyboard.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    Button("common.action.cancel") {
                        applicationShortcutCaptureProfileID = nil
                    }
                    .buttonStyle(.bordered)
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
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(profile.focusShortcut == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                    Button(profile.focusShortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again") {
                        shortcutCaptureTarget = nil
                        shortcutCaptureFeedback = nil
                        applicationShortcutCaptureProfileID = profile.id
                    }
                    .buttonStyle(.borderedProminent)

                    Button("common.action.clear") {
                        var updated = profile
                        updated.focusShortcut = nil
                        settings.updateCustomApplicationProfile(updated)
                        shortcutCaptureFeedback = nil
                    }
                    .buttonStyle(.bordered)
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
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            case .failed(.accessibilityPermissionRequired):
                Label("shortcut.editor.permission_required", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(.eventTapUnavailable):
                Label("shortcut.editor.capture_unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func accessibilityLearningEditor(_ profile: CustomApplicationProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("custom_application.accessibility.learn_help")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("custom_application.accessibility.learn") {
                    recordCustomApplicationInput(profileID: profile.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(customApplicationLearningStates[profile.id] == .recording)

                Text(
                    profile.accessibilityTarget == nil
                        ? localization.text("custom_application.accessibility.not_recorded")
                        : localization.text("custom_application.accessibility.recorded")
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(profile.accessibilityTarget == nil ? Color.orange : Color.green)
            }

            if let learningState = customApplicationLearningStates[profile.id] {
                Label(
                    localization.text(learningState.messageKey),
                    systemImage: learningState.systemImage
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(learningState.tint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseCustomApplication(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
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
        else { return }

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
        settings.setApplicationProfileID(profileID, for: button, trigger: trigger)
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
                }
                customApplicationLearningStates[profileID] = target == nil ? .failed : .succeeded
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func mappingActionSummary(for button: RemoteButton, trigger: ButtonTrigger) -> String {
        let configured = settings.configuredAction(for: button, trigger: trigger)
        guard configured.action != .disabled else {
            return localization.text("button_mapping.action.not_set")
        }
        if configured.action == .customShortcut, let shortcut = configured.shortcut {
            return shortcut.displayName(using: localization)
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
        case .volumeUp: return "+"
        case .volumeDown: return "−"
        case .volumeMute: return "Mute"
        default: break
        }
        return configured.action.displayName(using: localization)
    }

    private var permissionsPage: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    permissionRow(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: localization.text("permission.bluetooth.title"),
                    detail: localization.text("permission.bluetooth.description"),
                    state: bluetoothPermissionState,
                    actionTitle: localization.text("permission.bluetooth.open_settings")
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }

                    permissionRow(
                    symbol: "keyboard",
                    title: localization.text("permission.input_monitoring.title"),
                    detail: localization.text("permission.input_monitoring.description"),
                    state: inputMonitoringGranted ? .granted : .pending,
                    actionTitle: localization.text("permission.action.request")
                ) {
                    model.requestInputMonitoringPermission()
                }

                    permissionRow(
                    symbol: "accessibility",
                    title: localization.text("permission.accessibility.title"),
                    detail: localization.text("permission.accessibility.description"),
                    state: accessibilityGranted ? .granted : .pending,
                    actionTitle: localization.text("permission.action.request")
                ) {
                    model.requestAccessibilityPermission()
                }

                } header: {
                    Text("permissions.required.title")
                } footer: {
                    if settings.isOnboardingComplete,
                       !inputMonitoringGranted || !accessibilityGranted {
                        Text("permissions.upgrade_identity_help")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .searchAnchor("permissions-required", highlighted: highlightedSearchAnchor)

                Section("diagnostics.title") {
                    LabeledContent {
                        Button("diagnostics.logs.show_in_finder") { model.openLogFolder() }
                            .buttonStyle(.bordered)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("diagnostics.logs.title")
                                    .font(.body.weight(.medium))
                                Text("diagnostics.logs.privacy")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                        }
                    }
                }
                .searchAnchor("permissions-diagnostics", highlighted: highlightedSearchAnchor)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToSearchResult(in: .permissions, using: proxy, animated: false)
            }
            .onChange(of: searchNavigationRequest?.id) {
                scrollToSearchResult(in: .permissions, using: proxy, animated: true)
            }
        }
    }

    private var statisticsPage: some View {
        ScrollViewReader { proxy in
            statisticsForm
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
            .onAppear {
                scrollToSearchResult(in: .statistics, using: proxy, animated: false)
            }
            .onChange(of: searchNavigationRequest?.id) {
                scrollToSearchResult(in: .statistics, using: proxy, animated: true)
            }
        }
    }

    private var statisticsForm: some View {
        Form {
            Section {
                statisticsPeriodContent
            } header: {
                VStack(alignment: .leading, spacing: 16) {
                    statisticsPeriodPicker
                        .searchAnchor(
                            "statistics-period",
                            highlighted: highlightedSearchAnchor
                        )
                    statisticsPrivacyLabel
                }
            }
            .searchAnchor("statistics-charts", highlighted: highlightedSearchAnchor)

            Section {
                voiceSessionRankingCard
            }
            .searchAnchor("statistics-ranking", highlighted: highlightedSearchAnchor)

        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var statisticsPeriodPicker: some View {
        if #available(macOS 26.0, *) {
            nativeStatisticsPeriodPicker
                .controlSize(.extraLarge)
        } else {
            nativeStatisticsPeriodPicker
                .controlSize(.large)
        }
    }

    private var nativeStatisticsPeriodPicker: some View {
        Picker(
            localization.text("statistics.page.title"),
            selection: $selectedUsagePeriod
        ) {
            ForEach(UsageStatisticsPeriod.allCases) { period in
                Text(localization.text(usagePeriodLocalizationKey(period)))
                    .tag(period)
            }
        }
        .labelsHidden()
        .frame(width: 480)
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }

    private var statisticsPrivacyLabel: some View {
        Label(
            localization.text("about.privacy.local_only"),
            systemImage: "lock.fill"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var transcriptHistoryPage: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Toggle(
                        "statistics.transcripts.enable",
                        isOn: $settings.localTranscriptHistoryEnabled
                    )
                    .toggleStyle(.switch)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("statistics.transcripts.description")
                        Text("statistics.transcripts.privacy")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .searchAnchor("transcripts-enable", highlighted: highlightedSearchAnchor)

                TranscriptHistorySection(model: model, settings: settings)
                    .searchAnchor("transcripts-records", highlighted: highlightedSearchAnchor)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToSearchResult(in: .transcripts, using: proxy, animated: false)
            }
            .onChange(of: searchNavigationRequest?.id) {
                scrollToSearchResult(in: .transcripts, using: proxy, animated: true)
            }
        }
    }

    private var voiceSessionRankingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.body)
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .semanticTintedBackground(tint: Color.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.text("statistics.voice_ranking.title"))
                        .font(.headline)
                    Text(localization.text("statistics.voice_ranking.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.voiceSessionRanking.isEmpty {
                Text(localization.text("statistics.voice_ranking.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(settings.voiceSessionRanking.enumerated()), id: \.element.id) {
                        index, record in
                        HStack(spacing: 12) {
                            Text("#\(index + 1)")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(index < 3 ? Color.orange : Color.secondary)
                                .monospacedDigit()
                                .frame(width: 36, alignment: .leading)

                            Text(chartDurationText(
                                seconds: UsageStatisticsPresentation.wholeSeconds(
                                    record.duration
                                )
                            ))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .monospacedDigit()

                            Spacer(minLength: 12)

                            Text(voiceSessionDateText(record.endedAt))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 9)

                        if index < settings.voiceSessionRanking.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statisticsPeriodContent: some View {
        switch selectedUsagePeriod {
        case .today:
            HStack(alignment: .top, spacing: 14) {
                UsageBarChart(
                    title: localization.text("statistics.metric.button_count"),
                    subtitle: localization.text("statistics.chart.last_seven_days"),
                    systemImage: "button.programmable",
                    points: dailyUsageChartPoints,
                    metric: .buttonPressCount,
                    tint: .blue
                )
                UsageBarChart(
                    title: localization.text("statistics.metric.voice_duration"),
                    subtitle: localization.text("statistics.chart.last_seven_days"),
                    systemImage: "waveform",
                    points: dailyUsageChartPoints,
                    metric: .voiceDuration,
                    tint: .orange
                )
            }

        case .thisWeek:
            HStack(alignment: .top, spacing: 14) {
                UsageBarChart(
                    title: localization.text("statistics.metric.button_count"),
                    subtitle: localization.text("statistics.chart.weekly_history"),
                    systemImage: "button.programmable",
                    points: weeklyUsageChartPoints,
                    metric: .buttonPressCount,
                    tint: .blue
                )
                UsageBarChart(
                    title: localization.text("statistics.metric.voice_duration"),
                    subtitle: localization.text("statistics.chart.weekly_history"),
                    systemImage: "waveform",
                    points: weeklyUsageChartPoints,
                    metric: .voiceDuration,
                    tint: .orange
                )
            }

        case .total:
            HStack(spacing: 14) {
                UsageStatisticCard(
                    systemImage: "button.programmable",
                    title: localization.text("statistics.metric.button_count"),
                    value: buttonPressCountText(for: .total),
                    tint: .blue
                )
                UsageStatisticCard(
                    systemImage: "waveform",
                    title: localization.text("statistics.metric.voice_duration"),
                    value: voiceDurationText(for: .total),
                    tint: .orange
                )
            }
            .frame(minHeight: 330, alignment: .top)
        }
    }

    private var aboutPage: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("app.name")
                            .font(.title2.weight(.semibold))
                        Text("about.page.hero_description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Link(destination: localization.localizedWebsiteURL) {
                        Label("about.support.website", systemImage: "globe")
                    }
                    .buttonStyle(.bordered)

                    Link(destination: AppLinks.githubRepository) {
                        Label("about.support.github", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                }
                }
                .searchAnchor("about-summary", highlighted: highlightedSearchAnchor)

                Section("about.support.title") {
                LabeledContent {
                    Link(destination: AppLinks.feedback) {
                        Text("about.support.feedback_action")
                    }
                    .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.support.feedback")
                            .font(.body.weight(.medium))
                        Text("about.support.feedback_description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                aboutShareSectionContent
                }
                .searchAnchor("about-support", highlighted: highlightedSearchAnchor)

                Section("about.version.title") {
                aboutCurrentVersionRow
                aboutReleaseNotesRow

                LabeledContent {
                    Toggle(
                        "about.version.check_prerelease",
                        isOn: $settings.checksForPreReleaseUpdates
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.version.check_prerelease")
                            .font(.body.weight(.medium))
                        Text("about.version.check_prerelease_help_short")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                }
                .searchAnchor("about-version", highlighted: highlightedSearchAnchor)

            if privateFeature.shouldShowEnrollment {
                Section {
                    privateFeature.enrollmentView()
                }
            }

            if macroFeature.shouldShowEnrollment {
                Section {
                    macroFeature.enrollmentView()
                }
            }

                Section {
                LabeledContent {
                    Button("about.configuration.export", action: exportConfiguration)
                        .buttonStyle(.bordered)
                } label: {
                    Text("about.configuration.export_description")
                        .font(.body)
                }

                LabeledContent {
                    Button("about.configuration.import", action: importConfiguration)
                        .buttonStyle(.bordered)
                } label: {
                    Text("about.configuration.import_description")
                        .font(.body)
                }

                if let configurationStatus {
                    Label(
                        configurationStatus.message.text(using: localization),
                        systemImage: configurationStatus.systemImage
                    )
                    .font(.callout)
                    .foregroundStyle(configurationStatus.tint)
                }
                } header: {
                    Text("about.configuration.title")
                } footer: {
                    Text("about.configuration.description")
                }
                .searchAnchor("about-configuration", highlighted: highlightedSearchAnchor)

                Section("about.preferences.title") {
                LabeledContent {
                    Toggle("", isOn: Binding(
                        get: { settings.showDockIcon },
                        set: { setDockIconVisible($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.preferences.show_dock_icon")
                            .font(.body.weight(.medium))
                        Text("about.preferences.show_dock_icon_help")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    VStack(alignment: .trailing, spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { loginItemService.isEnabled },
                            set: { loginItemService.setEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)

                        if loginItemService.requiresApproval {
                            Button(
                                "about.preferences.launch_at_login_open_system_settings",
                                action: loginItemService.openLoginItemsSettings
                            )
                            .buttonStyle(.bordered)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("about.preferences.launch_at_login")
                            .font(.body.weight(.medium))
                        Text("about.preferences.launch_at_login_help")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if loginItemService.requiresApproval {
                            Text("about.preferences.launch_at_login_requires_approval")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        } else if loginItemService.didFailToUpdate {
                            Text("about.preferences.launch_at_login_update_failed")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                }

                LabeledContent {
                    Toggle("", isOn: $settings.openMainWindowAtLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.preferences.open_main_window_at_launch")
                            .font(.body.weight(.medium))
                        Text("about.preferences.open_main_window_help")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
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
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.preferences.language")
                            .font(.body.weight(.medium))
                        Text("about.preferences.language_description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("about.preferences.restart_onboarding_action") {
                        settings.restartOnboarding()
                    }
                    .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.preferences.restart_onboarding")
                            .font(.body.weight(.medium))
                        Text("about.preferences.restart_onboarding_help")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                }
                .searchAnchor("about-preferences", highlighted: highlightedSearchAnchor)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .onAppear {
                if UpdateCheckPolicy(
                    checksForPreReleaseUpdates: settings.checksForPreReleaseUpdates
                ).refreshesAboutInformationOnAppear {
                    refreshUpdateInformation()
                }
                scrollToSearchResult(in: .about, using: proxy, animated: false)
            }
            .onChange(of: searchNavigationRequest?.id) {
                scrollToSearchResult(in: .about, using: proxy, animated: true)
            }
        }
    }

    @ViewBuilder
    private var aboutUpdateStatusView: some View {
        switch updateInformation.state {
        case .idle:
            Text("about.version.information_idle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("about.version.checking")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label {
                Text("about.version.up_to_date")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.callout)
        case .unavailable:
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    "about.version.information_unavailable",
                    systemImage: "wifi.exclamationmark"
                )
                .font(.body.weight(.medium))
                .foregroundStyle(.orange)
                Text("about.version.information_unavailable_description")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .available(update):
            HStack(spacing: 8) {
                Label("about.version.available", systemImage: "arrow.down.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.green)
                Text("about.version.latest")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(update.displayVersion)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = updateInformation.state { return true }
        return false
    }

    private var aboutCurrentVersionRow: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Button(action: revealPrivateEnrollmentIfNeeded) {
                    Text(currentVersion)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Button {
                    if case .available = updateInformation.state {
                        checkForUpdates()
                    } else {
                        refreshUpdateInformation()
                    }
                } label: {
                    switch updateInformation.state {
                    case let .available(update):
                        Text(String(
                            format: localization.text("about.version.update_to"),
                            locale: localization.locale,
                            arguments: [update.displayVersion]
                        ))
                    case .idle:
                        Label(
                            "menu.check_for_updates",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    case .checking:
                        Label(
                            "about.version.checking",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    case .upToDate, .unavailable:
                        Label(
                            "about.version.recheck",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingForUpdates)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("about.version.current")
                    .font(.body.weight(.medium))
                aboutUpdateStatusView
            }
        }
    }

    @ViewBuilder
    private var aboutReleaseNotesRow: some View {
        if case .available = updateInformation.state {
            LabeledContent("about.version.information_title") {
                aboutReleaseNotesView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var aboutReleaseNotesView: some View {
        if case let .available(update) = updateInformation.state {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(
                    format: localization.text("about.version.release_notes_title"),
                    locale: localization.locale,
                    arguments: [update.displayVersion]
                ))
                .font(.body.weight(.medium))

                if update.releaseNotes.isEmpty {
                    Text("about.version.release_notes_unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(update.releaseNotes.enumerated()), id: \.offset) { index, note in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                            Text(note)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if model.isRC003VoiceExtensionTestEnabled {
                        Text("测试长时间语音功能")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var aboutShareSectionContent: some View {
        let shareURL = AppShareLink.url(for: localization.locale)

        return VStack(alignment: .leading, spacing: 14) {
            LabeledContent {
                Button {
                    isAboutShareExpanded.toggle()
                } label: {
                    Label(
                        isAboutShareExpanded ? "share.hide_action" : "share.show_action",
                        systemImage: isAboutShareExpanded ? "chevron.up" : "qrcode"
                    )
                }
                .buttonStyle(.bordered)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("share.title")
                        .font(.body.weight(.medium))
                    Text("share.description")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isAboutShareExpanded {
                Divider()
                ShareCard(url: shareURL)
                    .id(shareURL)
            }
        }
    }

    private func sectionTitle(_ section: SettingsSection) -> String {
        switch section {
        case .privateFeature: privateFeature.sectionTitle
        case .macros: macroFeature.sectionTitle
        default: localization.text(section.titleKey)
        }
    }

    private func sectionSystemImage(_ section: SettingsSection) -> String {
        switch section {
        case .privateFeature: privateFeature.sectionSystemImage
        case .macros: macroFeature.sectionSystemImage
        default: section.systemImage
        }
    }

    private func sectionIconColor(_ section: SettingsSection) -> Color {
        switch section {
        case .connection:
            return Color(nsColor: .systemBlue)
        case .privateFeature:
            return Color(nsColor: .systemPurple)
        case .macros:
            return Color(nsColor: .systemIndigo)
        case .mapping:
            return Color(nsColor: .systemGray)
        case .statistics:
            return Color(nsColor: .systemCyan)
        case .transcripts:
            return Color(nsColor: .systemTeal)
        case .permissions:
            return Color(nsColor: .systemIndigo)
        case .about:
            return Color(nsColor: .systemGray)
        }
    }

    private var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
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
        if hours > 0 {
            return String(
                format: localization.text("usage.duration.hours_minutes"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(hours)), localizedNumber(UInt64(minutes))]
            )
        }
        if minutes > 0 {
            return String(
                format: localization.text("usage.duration.minutes_seconds"),
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
        guard let url = ConfigurationFilePanel.exportURL(
            title: localization.text("configuration.export.panel_title"),
            prompt: localization.text("configuration.export.prompt")
        ) else { return }
        do {
            let data = try settings.exportedConfigurationData()
            try data.write(to: url, options: .atomic)
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.export.success"),
                tint: .green,
                systemImage: "checkmark.circle.fill"
            )
        } catch {
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
            prompt: localization.text("configuration.import.prompt")
        ) else { return }
        do {
            try model.importConfiguration(from: Data(contentsOf: url))
            localization.select(settings.applicationLanguage)
            setDockIconVisible(settings.showDockIcon)
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.success"),
                tint: .green,
                systemImage: "checkmark.circle.fill"
            )
        } catch AppConfigurationError.unsupportedVersion {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.unsupported_version"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch AppConfigurationError.unsafeVoiceKeyChange {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.voice_key_busy"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.invalid_file"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
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
        LabeledContent {
            HStack(spacing: 10) {
                Text(state.title(using: localization))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(state.tint)
                if state != .granted {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
        }
        .padding(.vertical, 4)
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
        case .failed, .unavailable:
            return .orange
        default:
            return .secondary
        }
    }

    private var isWebRemoteWaiting: Bool {
        switch model.webRemoteState {
        case .connecting, .waitingForPhone, .awaitingApproval:
            return true
        case .disabled, .unavailable, .connected, .failed:
            return false
        }
    }

    private func requestWebRemoteSession() {
        guard isWebRemoteInviteAuthorized else {
            webRemoteInviteCode = ""
            isTestFlightLinkCopied = false
            isWebRemoteInvitePresented = true
            return
        }
        openWebRemoteSession()
    }

    private func validateWebRemoteInviteCode() {
        guard webRemoteInviteCode.trimmingCharacters(in: .whitespacesAndNewlines) ==
                Self.requiredWebRemoteInviteCode
        else {
            webRemoteInviteCode = ""
            isWebRemoteInvitePresented = false
            DispatchQueue.main.async {
                isWebRemoteInviteInvalidPresented = true
            }
            return
        }
        webRemoteInviteCode = ""
        if !model.webRemoteState.isEnabled {
            model.enableWebRemoteConnection()
        }
        guard model.webRemoteState.isEnabled else {
            isWebRemoteInvitePresented = false
            return
        }
        isWebRemoteInviteAuthorized = true
    }

    private func copyTestFlightPublicBetaLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        isTestFlightLinkCopied = pasteboard.writeObjects([
            AppLinks.testFlightPublicBeta.absoluteString as NSString
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

private struct SemanticTintedBackgroundModifier<BackgroundShape: Shape>: ViewModifier {
    let tint: Color
    let shape: BackgroundShape
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .background(tint, in: shape)
            .overlay(
                shape.stroke(
                    Color(nsColor: .separatorColor).opacity(interactive ? 0.55 : 0.35),
                    lineWidth: 0.5
                )
            )
    }
}

private extension View {
    func semanticTintedBackground<BackgroundShape: Shape>(
        tint: Color,
        in shape: BackgroundShape,
        interactive: Bool = false
    ) -> some View {
        modifier(
            SemanticTintedBackgroundModifier(
                tint: tint,
                shape: shape,
                interactive: interactive
            )
        )
    }

    /// `.searchFocused` requires macOS 15; on macOS 14 the search field simply
    /// cannot be focused programmatically, so the menu shortcut is disabled there.
    @ViewBuilder
    func searchFocusedWhenAvailable(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            self.searchFocused(binding)
        } else {
            self
        }
    }

    /// Tags a section with its search anchor and draws a short accent outline
    /// when a search result just navigated to it, like System Settings does.
    func searchAnchor(_ anchor: String, highlighted: String?) -> some View {
        modifier(SearchAnchorModifier(anchor: anchor, isHighlighted: highlighted == anchor))
    }
}

private struct SearchAnchorModifier: ViewModifier {
    let anchor: String
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 2)
                    .opacity(isHighlighted ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

/// Shared look and interaction for card-style selection buttons (device cards,
/// action grid, strategy and profile pickers): low-opacity semantic-blue selection,
/// hover feedback and a system-style keyboard focus ring.
private struct SelectableCardButton<Label: View>: View {
    let isSelected: Bool
    var cornerRadius: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .focusable()
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.13)
                    : Color.primary.opacity(isHovered ? 0.08 : 0.045),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isFocused
                            ? Color.accentColor.opacity(0.65)
                            : isSelected
                                ? Color.accentColor.opacity(0.55)
                                : Color.secondary.opacity(0.16),
                        lineWidth: isFocused ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(url.absoluteString)
                    .font(.system(.callout, design: .monospaced))
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
                    .font(.callout.weight(.medium))
                    .foregroundStyle(copySucceeded ? Color.green : Color.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                .semanticTintedBackground(tint: tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .semanticTintedBackground(
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .semanticTintedBackground(tint: tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
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
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .chartYScale(domain: 0...maximumValue)
            .chartYAxis(.hidden)
            .frame(height: 250)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

@MainActor
private enum ConfigurationFilePanel {
    static func exportURL(title: String, prompt: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Remote-Mic-Settings.json"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func importURL(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private enum RC003ImageResource {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "RC003-remote-photo",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private struct RC003Photo: View {
    var body: some View {
        Group {
            if let photo = RC003ImageResource.image {
                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Text("remote.photo.missing")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}
