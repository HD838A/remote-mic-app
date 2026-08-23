import AppKit
import Charts
import Combine
import CoreBluetooth
import SayAllMacRemoteCore
import SayAllMacRemoteUI
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let remoteMicSelectSettingsSection = Notification.Name(
        "RemoteMicSelectSettingsSection"
    )
}

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

    var title: LocalizedStringKey {
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
    @ObservedObject private var updateInformation: UpdateInformationStore
    @EnvironmentObject private var localization: LocalizationStore

    private let checkForUpdates: () -> Void
    private let refreshUpdateInformation: () -> Void
    private let setDockIconVisible: (Bool) -> Void
    private let minimumContentSize: CGSize
    private let initialShortcutPickerShowsKeyboard: Bool
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
    @State private var isReleaseHistoryPresented = false
    @State private var isClearTrustedPhonesConfirmationPresented = false
    @State private var isWebRemoteSessionPresented = false
    @State private var isWebRemoteInvitePresented = false
    @State private var isWebRemoteInviteInvalidPresented = false
    @State private var isWebRemoteInviteAuthorized = false
    @State private var isTestFlightLinkCopied = false
    @State private var isMappingPermissionAlertPresented = false
    @State private var isWaitingForMappingPermissions = false
    @State private var expandedShareSection: SettingsSection?
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
        initialShareSection: SettingsSection? = nil,
        initialMappingEditingButton: RemoteButton? = nil,
        initialMappingEditingTrigger: ButtonTrigger = .singleClick,
        initialShortcutPickerShowsKeyboard: Bool = false,
        minimumContentSize: CGSize = CGSize(width: 980, height: 732)
    ) {
        self.model = model
        settings = model.settings
        privateFeature = model.privateFeature
        macroFeature = model.macroFeature
        self.updateInformation = updateInformation
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.minimumContentSize = minimumContentSize
        self.initialShortcutPickerShowsKeyboard = initialShortcutPickerShowsKeyboard
        _selectedSection = State(initialValue: initialSection)
        _expandedShareSection = State(initialValue: initialShareSection)
        _selectedRemoteButton = State(initialValue: initialMappingEditingButton ?? .ok)
        _mappingEditingTarget = State(
            initialValue: initialMappingEditingButton.map {
                ShortcutEditingTarget(button: $0, trigger: initialMappingEditingTrigger)
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 108)
            Color(nsColor: .separatorColor)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            selectedPage
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .environment(\.locale, localization.locale)
        .frame(
            minWidth: minimumContentSize.width,
            minHeight: minimumContentSize.height
        )
        .onAppear {
            refreshPermissionStates()
            macroFeature.setEditorActive(selectedSection == .macros)
        }
        .onChange(of: selectedSection) { section in
            macroFeature.setEditorActive(section == .macros)
        }
        .onDisappear {
            macroFeature.setEditorActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            resumeCustomMappingIfPermissionsGranted()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteMicSelectSettingsSection)) { notification in
            guard let section = notification.object as? SettingsSection else { return }
            selectedSection = section
        }
        .onReceive(privateFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible, selectedSection == .privateFeature {
                selectedSection = .about
            }
        }
        .onReceive(macroFeature.$isFeatureVisible.removeDuplicates()) { isVisible in
            if !isVisible, selectedSection == .macros {
                selectedSection = .about
            }
        }
        .sheet(isPresented: $isReleaseHistoryPresented) {
            ReleaseHistorySheet()
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
                            .font(.caption.weight(.bold))
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
                    .compatibilityButtonStyle(.prominent)

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
                    .compatibilityButtonStyle(.standard)
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
                .compatibilityButtonStyle(.prominent)
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: 56)
                .accessibilityHidden(true)
            ForEach(visibleSections) { section in
                sidebarButton(section)
            }
            Spacer(minLength: 0)
            Button {
                selectedSection = .about
                expandedShareSection = .about
            } label: {
                VStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 21, weight: .semibold))
                    Text("share.action")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .compatibilityFocusEffectDisabled()
            .foregroundStyle(Color.secondary)
            .accessibilityLabel(Text("share.sidebar.accessibility_label"))
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var visibleSections: [SettingsSection] {
        Self.sidebarSectionOrder.filter {
            switch $0 {
            case .privateFeature: privateFeature.isFeatureVisible
            case .macros: macroFeature.isFeatureVisible
            default: true
            }
        }
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            VStack(spacing: 7) {
                Image(systemName: sectionSystemImage(section))
                    .font(.system(size: 21, weight: .semibold))
                if section == .privateFeature || section == .macros {
                    Text(sectionTitle(section))
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatibilityFocusEffectDisabled()
        .foregroundStyle(selectedSection == section ? Color.accentColor : Color.secondary)
        .background(selectedSection == section ? Color.accentColor.opacity(0.10) : Color.clear)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
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
                    .font(.system(size: 12))
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

    private func settingsPage<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
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
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .compatibilityScrollEdgeEffect()
        }
    }

    private var connectionPage: some View {
        settingsPage {
            PageHeader(title: localization.text("connection.page.title"))
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    connectionDevicePanel
                        .frame(width: 230)
                    VStack(spacing: 14) {
                        audioSettingsPanel
                        audioCompatibilityPanel
                        phoneConnectionsPanel
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var phoneConnectionsPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("connection.phone.section_title")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("connection.phone.ios_title")
                                    .font(.subheadline.weight(.semibold))
                                Text("connection.phone.qr_badge")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text("connection.phone.ios_help")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        StatusPill(
                            text: localization.text(
                                model.isPhoneRemoteConnected
                                    ? "connection.phone.connected"
                                    : model.isPhoneRemoteConnectionEnabled
                                        ? "connection.phone.enabled"
                                        : "connection.phone.not_enabled"
                            ),
                            tint: model.isPhoneRemoteConnected
                                ? .green
                                : model.isPhoneRemoteConnectionEnabled ? .orange : .secondary
                        )
                    }

                    HStack(spacing: 8) {
                        Button(
                            model.isPhoneRemoteConnected
                                ? "connection.phone.disconnect"
                                : model.isPhoneRemoteConnectionEnabled
                                    ? "connection.phone.cancel_waiting"
                                    : "connection.phone.connect"
                        ) {
                            model.togglePhoneRemoteConnection()
                        }
                        .compatibilityButtonStyle(
                            model.isPhoneRemoteConnectionEnabled ? .standard : .prominent
                        )

                        Link(destination: AppLinks.testFlightPublicBeta) {
                            Label("connection.web.invite.testflight_open", systemImage: "arrow.up.right.square")
                        }
                        .compatibilityButtonStyle(.standard)

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
                        .compatibilityButtonStyle(.standard)
                    }

                    if let invitation = model.phoneRemoteInvitation {
                        Divider()
                        PhoneRemoteInvitationCard(invitation: invitation)
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
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

                    StatusPill(
                        text: localization.text(
                            model.isWatchRemoteConnected
                                ? "connection.watch.connected"
                                : model.isWatchRemoteConnectionEnabled
                                    ? "connection.watch.enabled"
                                    : "connection.phone.not_enabled"
                        ),
                        tint: model.isWatchRemoteConnected
                            ? .green
                            : model.isWatchRemoteConnectionEnabled ? .orange : .secondary
                    )

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
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.secondary)
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
                    Button(
                        model.webRemoteState.isEnabled
                            ? "connection.web.show_qr"
                            : "connection.web.connect"
                    ) {
                        requestWebRemoteSession()
                    }
                    .compatibilityButtonStyle(.standard)
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

                RC003Photo()
                    .frame(width: 82, height: 166)

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
                    Link("audio.action.learn_virtual_microphones", destination: URL(string: "https://existential.audio/blackhole/")!)
                        .compatibilityButtonStyle(.standard)
                    Button("audio.action.send_test_tone") { model.sendTestTone() }
                        .compatibilityButtonStyle(.standard)
                        .disabled(!model.canSendTestTone)
                }

                Text("audio.output.privacy_help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(model.testToneStatus.text(using: localization))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
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
                    Button("audio.compatibility.select_microphone") { model.selectDoubaoAudioDevice() }
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

    private var mappingPage: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    PageHeader(title: localization.text("button_mapping.page.title"))
                        .fixedSize(horizontal: true, vertical: false)
                    mappingHeaderToggle
                    Spacer()
                    remoteDeviceSelector()
                        .frame(width: 400)
                }

                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        PageHeader(title: localization.text("button_mapping.page.title"))
                            .fixedSize(horizontal: true, vertical: false)
                        mappingHeaderToggle
                    }
                    Spacer(minLength: 14)
                    remoteDeviceSelector()
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
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

                        if let target = mappingEditingTarget {
                            mappingEditorPanel(target)
                                .id("mapping-action-editor")
                        }

                        mappingFooter
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .compatibilityScrollEdgeEffect()
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
                .onChange(of: mappingEditingTarget?.id) { targetID in
                    guard targetID != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("mapping-action-editor", anchor: .top)
                        }
                    }
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
                    .font(.system(size: 15, weight: .semibold))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .tint(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
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
                    .compatibilityButtonStyle(.standard)
                }

                mappingTriggerEditor(target.button, trigger: target.trigger)
            }
        }
    }

    private var mappingFooter: some View {
        GlassPanel {
            HStack(spacing: 16) {
                Label(
                    model.hidStatus.text(using: localization),
                    systemImage: "keyboard"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

                Divider().frame(height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("button_mapping.selection_lock", isOn: $isMappingSelectionLocked)
                        .font(.system(size: 12, weight: .medium))
                        .toggleStyle(.switch)
                    Text("button_mapping.selection_lock_hint_short")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .help(localization.text("button_mapping.selection_lock_help"))

                Divider().frame(height: 28)

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

                Spacer(minLength: 0)

                Button("common.action.restore_defaults") {
                    settings.resetBindings()
                    selectedRemoteButton = .ok
                }
                .compatibilityButtonStyle(.standard)
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
        return Button {
            model.selectRemoteProfile(profile.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(remoteDisplayName(profile))
                        .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: fillsWidth ? nil : 232, alignment: .leading)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private func remoteDisplayName(_ profile: RemoteDeviceProfile) -> String {
        ButtonMappingPresentation.remoteDisplayName(
            profile,
            among: settings.remoteDeviceProfiles,
            using: localization
        )
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

            if button == .power && trigger == .singleClick && settings.experimentalContinuousRecordingEnabled {
                Text("button_mapping.continuous_recording_experiment.power_managed")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if trigger == .doubleClick && configured.action != .disabled {
                Text("button_mapping.double_click.effect")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if trigger == .longPress && configured.action != .disabled {
                Text("button_mapping.long_press.effect")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if trigger == .singleClick {
                Text("button_mapping.single_click.help")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
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
                    .font(.system(size: 14, weight: .semibold))
            }
        } else {
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
                Button {
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
                    .font(.system(size: 13, weight: selectedAction == action ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(
                        selectedAction == action
                            ? Color.accentColor.opacity(0.13)
                            : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                selectedAction == action
                                    ? Color.accentColor.opacity(0.55)
                                    : Color.secondary.opacity(0.16)
                            )
                    }
                }
                .buttonStyle(.plain)
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
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                        Button(configured.shortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again") {
                            applicationShortcutCaptureProfileID = nil
                            shortcutCaptureFeedback = nil
                            shortcutCaptureTarget = target
                        }
                        .compatibilityButtonStyle(.standard)

                        Button("common.action.clear") {
                            settings.setShortcut(nil, for: button, trigger: trigger)
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
                        settings.setApplicationProfileID(profile.id, for: button, trigger: trigger)
                    }
                }

                Button {
                    chooseCustomApplication(for: button, trigger: trigger)
                } label: {
                    Label("custom_application.add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .compatibilityButtonStyle(.standard)
            }

            if let profile = settings.customApplicationProfile(id: configured.applicationProfileID) {
                Divider()

                Text("custom_application.focus_strategy")
                    .font(.system(size: 14, weight: .semibold))

                HStack(spacing: 8) {
                    ForEach(CustomApplicationFocusStrategy.allCases) { strategy in
                        Button {
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
                            .font(.system(size: 13, weight: profile.focusStrategy == strategy ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(profile.focusStrategy == strategy ? Color.accentColor : Color.primary)
                        .background(
                            profile.focusStrategy == strategy
                                ? Color.accentColor.opacity(0.12)
                                : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    profile.focusStrategy == strategy
                                        ? Color.accentColor.opacity(0.5)
                                        : Color.secondary.opacity(0.16)
                                )
                        }
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
                    .compatibilityButtonStyle(.prominent)
                }
            } else {
                Text("custom_application.not_configured")
                    .font(.system(size: 12))
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

                Text(
                    profile.accessibilityTarget == nil
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
        return ButtonMappingPresentation.actionSummary(
            configured: configured,
            customApplicationName: settings.customApplicationProfile(
                id: configured.applicationProfileID
            )?.displayName,
            using: localization
        )
    }

    private var permissionsPage: some View {
        settingsPage {
            PageHeader(title: localization.text("permissions.page.title"))
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("permissions.required.title")
                            .font(.headline)
                            .padding(.bottom, 8)

                        permissionRow(
                            index: 1,
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

                        Divider().padding(.leading, 62)

                        permissionRow(
                            index: 2,
                            symbol: "keyboard",
                            title: localization.text("permission.input_monitoring.title"),
                            detail: localization.text("permission.input_monitoring.description"),
                            state: inputMonitoringGranted ? .granted : .pending,
                            actionTitle: localization.text("permission.action.request")
                        ) {
                            model.requestInputMonitoringPermission()
                        }

                        Divider().padding(.leading, 62)

                        permissionRow(
                            index: 3,
                            symbol: "accessibility",
                            title: localization.text("permission.accessibility.title"),
                            detail: localization.text("permission.accessibility.description"),
                            state: accessibilityGranted ? .granted : .pending,
                            actionTitle: localization.text("permission.action.request")
                        ) {
                            model.requestAccessibilityPermission()
                        }

                        if settings.isOnboardingComplete,
                           !inputMonitoringGranted || !accessibilityGranted {
                            Divider().padding(.leading, 62)
                            Label("permissions.upgrade_identity_help", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 12)
                        }
                    }
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("diagnostics.title")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34, height: 34)
                                .compatibilityTintedGlass(
                                    tint: Color.accentColor.opacity(0.14),
                                    in: Circle()
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("diagnostics.logs.title")
                                Text("diagnostics.logs.privacy")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("diagnostics.logs.show_in_finder") { model.openLogFolder() }
                                .compatibilityButtonStyle(.standard)
                        }
                    }
                }
            }
        }
    }

    private var statisticsPage: some View {
        settingsPage {
            HStack(spacing: 14) {
                PageHeader(title: localization.text("statistics.page.title"))
                Spacer(minLength: 20)
                HStack(spacing: 8) {
                    ForEach(UsageStatisticsPeriod.allCases) { period in
                        Button {
                            selectedUsagePeriod = period
                        } label: {
                            Text(localization.text(usagePeriodLocalizationKey(period)))
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 92, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            selectedUsagePeriod == period ? Color.white : Color.primary
                        )
                        .background(
                            selectedUsagePeriod == period
                                ? Color.accentColor
                                : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    selectedUsagePeriod == period
                                        ? Color.accentColor
                                        : Color(nsColor: .separatorColor).opacity(0.65),
                                    lineWidth: 1
                                )
                        }
                        .accessibilityAddTraits(
                            selectedUsagePeriod == period ? .isSelected : []
                        )
                    }
                }
                StatusPill(
                    text: localization.text("about.privacy.local_only"),
                    tint: .green
                )
            }
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                VStack(spacing: 14) {
                    sharePanel(for: .statistics)
                    statisticsPeriodContent
                    voiceSessionRankingCard
                }
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
            }
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                TranscriptHistorySection(model: model, settings: settings)
            }
        }
    }

    private var voiceSessionRankingCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "trophy.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .frame(width: 32, height: 32)
                        .compatibilityTintedGlass(tint: Color.orange.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("statistics.voice_ranking.title")
                            .font(.headline)
                        Text("statistics.voice_ranking.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.voiceSessionRanking.isEmpty {
                    Text("statistics.voice_ranking.empty")
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
                                    .font(.caption)
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
            GlassPanel {
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
            }
            .frame(minHeight: 330, alignment: .top)
        }
    }

    private var aboutPage: some View {
        settingsPage {
            PageHeader(title: localization.text("menu.about"))
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                VStack(spacing: 14) {
                    HStack(spacing: 18) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 72, height: 72)
                            .shadow(color: .black.opacity(0.14), radius: 10, y: 5)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("app.name")
                                .font(.system(size: 28, weight: .semibold))
                            Text("about.page.hero_description")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 20)

                        Link(destination: localization.localizedWebsiteURL) {
                            Label("about.support.website", systemImage: "globe")
                                .frame(minWidth: 104)
                        }
                        .compatibilityButtonStyle(.prominent)

                        Link(destination: AppLinks.githubRepository) {
                            Label("about.support.github", systemImage: "link")
                                .frame(minWidth: 104)
                        }
                        .compatibilityButtonStyle(.standard)
                    }
                    .padding(.horizontal, 6)

                    GlassPanel {
                        HStack(spacing: 14) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("about.support.feedback")
                                    .font(.subheadline.weight(.semibold))
                                Text("about.support.feedback_description")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 20)
                            Link(destination: AppLinks.feedback) {
                                Label("about.support.feedback_action", systemImage: "arrow.up.right")
                            }
                            .compatibilityButtonStyle(.standard)
                        }
                    }

                    sharePanel(for: .about)

                    GlassPanel {
                        VStack(spacing: 16) {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("about.version.title")
                                        .font(.headline)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("about.version.current")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Button(action: revealPrivateEnrollmentIfNeeded) {
                                            Text(currentVersion)
                                                .font(.system(size: 28, weight: .semibold))
                                                .monospacedDigit()
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                    }

                                    if case let .available(update) = updateInformation.state {
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("about.version.latest")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                Text(update.displayVersion)
                                                    .font(.system(size: 28, weight: .semibold))
                                                    .monospacedDigit()
                                            }
                                            StatusPill(
                                                text: localization.text("about.version.available"),
                                                tint: .green
                                            )
                                        }

                                        HStack(spacing: 10) {
                                            Button(action: checkForUpdates) {
                                                Text(String(
                                                    format: localization.text("about.version.update_to"),
                                                    locale: localization.locale,
                                                    arguments: [update.displayVersion]
                                                ))
                                                .frame(maxWidth: .infinity)
                                            }
                                            .compatibilityButtonStyle(.prominent)

                                            Button(
                                                "about.version.recheck",
                                                action: refreshUpdateInformation
                                            )
                                            .compatibilityButtonStyle(.standard)
                                        }
                                    } else {
                                        HStack(spacing: 10) {
                                            Button(action: checkForUpdates) {
                                                Label(
                                                    "menu.check_for_updates",
                                                    systemImage: "arrow.triangle.2.circlepath"
                                                )
                                                .frame(maxWidth: .infinity)
                                            }
                                            .compatibilityButtonStyle(.prominent)

                                            Button(
                                                "about.version.recheck",
                                                action: refreshUpdateInformation
                                            )
                                            .compatibilityButtonStyle(.standard)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Divider()

                                VStack(alignment: .leading, spacing: 12) {
                                    updateInformationContent
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Divider()

                            HStack(spacing: 20) {
                                Button {
                                    isReleaseHistoryPresented = true
                                } label: {
                                    Label("about.version.history", systemImage: "clock.arrow.circlepath")
                                }
                                .compatibilityButtonStyle(.standard)

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Toggle(
                                        "about.version.check_prerelease",
                                        isOn: $settings.checksForPreReleaseUpdates
                                    )
                                    .toggleStyle(.switch)
                                    Text("about.version.check_prerelease_help_short")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if privateFeature.shouldShowEnrollment {
                        privateFeature.enrollmentView()
                    }

                    if macroFeature.shouldShowEnrollment {
                        macroFeature.enrollmentView()
                    }

                    GlassPanel {
                        VStack(spacing: 0) {
                            HStack(spacing: 14) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.configuration.export")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.configuration.export_description")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("about.configuration.export", action: exportConfiguration)
                                    .compatibilityButtonStyle(.standard)
                                    .frame(width: 92)
                            }
                            .padding(.vertical, 10)

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.configuration.import")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.configuration.import_description")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("about.configuration.import", action: importConfiguration)
                                    .compatibilityButtonStyle(.standard)
                                    .frame(width: 92)
                            }
                            .padding(.vertical, 10)

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
                            .padding(.vertical, 10)

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "macwindow")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("about.preferences.open_main_window_at_launch")
                                        .font(.subheadline.weight(.semibold))
                                    Text("about.preferences.open_main_window_help")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $settings.openMainWindowAtLaunch)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            .padding(.vertical, 10)

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
                                .frame(width: 400)
                            }
                            .padding(.vertical, 10)

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
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard UpdateCheckPolicy(
                checksForPreReleaseUpdates: settings.checksForPreReleaseUpdates
            ).refreshesAboutInformationOnAppear else { return }
            refreshUpdateInformation()
        }
    }

    private func sharePanel(for section: SettingsSection) -> some View {
        let isExpanded = expandedShareSection == section
        let shareURL = AppShareLink.url(for: localization.locale)

        return GlassPanel {
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
                    .compatibilityButtonStyle(.standard)
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
        default: ""
        }
    }

    private func sectionSystemImage(_ section: SettingsSection) -> String {
        switch section {
        case .privateFeature: privateFeature.sectionSystemImage
        case .macros: macroFeature.sectionSystemImage
        default: section.systemImage
        }
    }

    @ViewBuilder
    private var updateInformationContent: some View {
        switch updateInformation.state {
        case .idle:
            Text("about.version.information_title")
                .font(.headline)
            Text("about.version.information_idle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .checking:
            Text("about.version.information_title")
                .font(.headline)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("about.version.checking")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("about.version.up_to_date", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("about.version.up_to_date_description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("about.version.information_unavailable", systemImage: "wifi.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("about.version.information_unavailable_description")
                .font(.subheadline)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(update.releaseNotes.enumerated()), id: \.offset) { index, note in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.13), in: Circle())
                        Text(note)
                            .font(.subheadline)
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
            try settings.importConfiguration(from: Data(contentsOf: url))
            localization.select(settings.applicationLanguage)
            setDockIconVisible(settings.showDockIcon)
            model.applyAudioSettings(reason: "configuration_import")
            model.applyHIDSettings()
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
        } catch {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.invalid_file"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private func permissionRow(
        index: Int,
        symbol: String,
        title: String,
        detail: String,
        state: PermissionVisualState,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())

            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .compatibilityTintedGlass(
                    tint: Color.accentColor.opacity(0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            StatusPill(text: state.title(using: localization), tint: state.tint)
            if state != .granted {
                Button(actionTitle, action: action)
                    .compatibilityButtonStyle(.standard)
                    .frame(width: 112)
            }
        }
        .padding(.vertical, 12)
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

private struct ReleaseHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(localization.text("about.version.history"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(localization.text("common.action.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                if let sections = releaseHistorySections {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.title)
                                    .font(.title3.weight(.semibold).monospacedDigit())

                                ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•")
                                        Text(entry)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(24)
                } else {
                    Text(localization.text("about.version.history_load_failed"))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                }
            }
        }
        .frame(width: 640, height: 520)
    }

    private var releaseHistorySections: [ReleaseHistorySection]? {
        guard let url = localization.localizedURL(
            forResource: "ReleaseHistory",
            withExtension: "md"
        ),
        let markdown = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        var sections: [ReleaseHistorySection] = []
        var title: String?
        var entries: [String] = []

        func appendSection() {
            guard let title, !entries.isEmpty else { return }
            sections.append(ReleaseHistorySection(title: title, entries: entries))
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                appendSection()
                title = String(line.dropFirst(3))
                entries = []
            } else if line.hasPrefix("- "), title != nil {
                entries.append(String(line.dropFirst(2)))
            }
        }
        appendSection()

        return sections.isEmpty ? nil : sections
    }
}

private struct ReleaseHistorySection: Identifiable {
    let title: String
    let entries: [String]

    var id: String { title }
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
                .compatibilityButtonStyle(.prominent)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}
