import AppKit
import Charts
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSection: String, CaseIterable, Identifiable {
    case connection
    case mapping
    case statistics
    case permissions
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .connection: return "settings.section.connection"
        case .mapping: return "settings.section.buttons"
        case .statistics: return "settings.section.statistics"
        case .permissions: return "settings.section.permissions"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "link"
        case .mapping: return "keyboard"
        case .statistics: return "chart.bar.xaxis"
        case .permissions: return "shield.lefthalf.filled"
        case .about: return "info.circle"
        }
    }
}

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

private struct ShortcutEditingTarget: Identifiable {
    let button: RemoteButton
    let trigger: ButtonTrigger

    var id: String { "\(button.rawValue)-\(trigger.rawValue)" }
}

private struct ConfigurationStatus {
    let message: LocalizedMessage
    let tint: Color
    let systemImage: String
}

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore

    private let checkForUpdates: () -> Void
    private let setDockIconVisible: (Bool) -> Void

    @State private var selectedSection: SettingsSection = .connection
    @State private var selectedRemoteButton: RemoteButton = .ok
    @State private var selectedUsagePeriod: UsageStatisticsPeriod = .today
    @State private var shortcutEditingTarget: ShortcutEditingTarget?
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
    @State private var webRemoteInviteCode = ""
    @Namespace private var navigationGlassNamespace

    private static let requiredWebRemoteInviteCode = "8586"

    init(
        model: BridgeAppModel,
        checkForUpdates: @escaping () -> Void = {},
        setDockIconVisible: @escaping (Bool) -> Void = { _ in }
    ) {
        self.model = model
        settings = model.settings
        self.checkForUpdates = checkForUpdates
        self.setDockIconVisible = setDockIconVisible
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 96, ideal: 108, max: 120)
        } detail: {
            selectedPage
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .environment(\.locale, localization.locale)
        .frame(minWidth: 820, minHeight: 650)
        .onAppear(perform: refreshPermissionStates)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
        .sheet(item: $shortcutEditingTarget) { target in
            ShortcutEditorSheet(
                button: target.button,
                trigger: target.trigger,
                currentShortcut: settings.configuredAction(
                    for: target.button,
                    trigger: target.trigger
                ).shortcut
            ) { shortcut in
                settings.setShortcut(
                    shortcut,
                    for: target.button,
                    trigger: target.trigger
                )
            }
        }
        .sheet(isPresented: $isReleaseHistoryPresented) {
            ReleaseHistorySheet()
        }
        .sheet(isPresented: $isWebRemoteSessionPresented) {
            WebRemoteSessionView(model: model)
                .environmentObject(localization)
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
                WebRemoteSessionView(model: model)
                    .environmentObject(localization)
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

    private var sidebar: some View {
        CompatibilityGlassContainer(spacing: 10) {
            VStack(spacing: 10) {
                ForEach(SettingsSection.allCases) { section in
                    sidebarButton(section)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            VStack(spacing: 7) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 21, weight: .semibold))
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(
            SidebarGlassModifier(
                isSelected: selectedSection == section,
                namespace: navigationGlassNamespace
            )
        )
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selectedSection {
        case .connection:
            connectionPage
        case .mapping:
            mappingPage
        case .statistics:
            statisticsPage
        case .permissions:
            permissionsPage
        case .about:
            aboutPage
        }
    }

    private var connectionPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("connection.page.title")
                )

                CompatibilityGlassContainer(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        connectionDevicePanel
                            .frame(width: 196)
                        audioSettingsPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }

                trustedPhoneDevicesPanel
                webRemotePanel
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .compatibilityScrollEdgeEffect()
    }

    private var trustedPhoneDevicesPanel: some View {
        GlassPanel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("connection.trusted_devices.title")
                        .font(.headline)
                    Text("connection.trusted_devices.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Text(
                    LocalizedMessage(
                        "connection.trusted_devices.count",
                        arguments: [String(settings.trustedPhoneIdentityFingerprints.count)]
                    ).text(using: localization)
                )
                .foregroundStyle(.secondary)
                Button(
                    model.isPhoneRemoteConnectionEnabled
                        ? "connection.phone.enabled"
                        : "connection.phone.connect"
                ) {
                    model.enablePhoneRemoteConnection()
                }
                .compatibilityButtonStyle(.prominent)
                .disabled(model.isPhoneRemoteConnectionEnabled)
                Button("connection.trusted_devices.clear") {
                    isClearTrustedPhonesConfirmationPresented = true
                }
                .compatibilityButtonStyle(.standard)
                .disabled(settings.trustedPhoneIdentityFingerprints.isEmpty)
            }
        }
    }

    private var webRemotePanel: some View {
        GlassPanel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("connection.web.title")
                        .font(.headline)
                    Text("connection.web.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Text(webRemoteStatusText)
                    .foregroundStyle(webRemoteStatusTint)
                    .lineLimit(1)
                Button(
                    model.webRemoteState.isEnabled
                        ? "connection.web.show_qr"
                        : "connection.web.connect"
                ) {
                    requestWebRemoteSession()
                }
                .compatibilityButtonStyle(.prominent)
            }
        }
    }

    private var connectionDevicePanel: some View {
        GlassPanel {
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("connection.device.name")
                        .font(.headline)
                    Text("connection.device.type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RC003Photo()
                    .frame(width: 70, height: 142)

                VStack(spacing: 12) {
                    DeviceStatusStep(
                        symbol: "antenna.radiowaves.left.and.right",
                        title: localization.text("connection.status.bluetooth_title"),
                        detail: model.connectionStatus.text(using: localization),
                        badge: connectionBadge,
                        tint: connectionTint
                    )
                    DeviceStatusStep(
                        symbol: "waveform",
                        title: localization.text("connection.status.voice_title"),
                        detail: localization.text(
                            model.isStreaming ? "connection.status.voice_streaming" : "connection.status.waiting_voice_button"
                        ),
                        badge: localization.text(model.isStreaming ? "connection.status.voice_active" : "common.status.ready"),
                        tint: model.isStreaming ? .orange : .blue
                    )
                    DeviceStatusStep(
                        symbol: "mic.fill",
                        title: localization.text("connection.status.voice_trigger"),
                        detail: model.voiceShortcutStatus.text(using: localization),
                        badge: voiceTriggerBadge,
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
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var audioSettingsPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 13) {
                Text("audio.section.title")
                    .font(.headline)

                HStack(spacing: 14) {
                    Text("audio.output.title")
                        .frame(width: 72, alignment: .leading)
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
                            .frame(width: 72, alignment: .leading)
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
                        .padding(.leading, 86)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("audio.status.title")
                        .frame(width: 72, alignment: .leading)
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
                            .foregroundStyle(.white)
                    }
                        .compatibilityButtonStyle(.prominent)
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

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("audio.compatibility.title")
                            .font(.headline)
                        Text("audio.compatibility.microphone_label")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Text(model.doubaoAudioStatus.text(using: localization))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 10) {
                    Button("audio.compatibility.select_microphone") { model.selectDoubaoAudioDevice() }
                        .compatibilityButtonStyle(.standard)
                        .disabled(!model.hasDoubaoAudioDevice)
                    Button("audio.compatibility.open_install_guide") {
                        model.openDoubaoDriverInstructions(using: localization)
                    }
                        .compatibilityButtonStyle(.standard)
                }

                Text("audio.compatibility.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mappingPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: localization.text("button_mapping.page.title")
            )

            GlassPanel {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("button_mapping.toggle.enabled", isOn: Binding(
                            get: { settings.customMappingEnabled },
                            set: { enabled in
                                settings.customMappingEnabled = enabled
                                model.applyHIDSettings()
                            }
                        ))
                        Text(model.hidStatus.text(using: localization))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    }
                    Spacer(minLength: 12)
                    StatusPill(
                        text: localization.text(settings.customMappingEnabled ? "common.status.enabled" : "common.status.disabled"),
                        tint: settings.customMappingEnabled ? .green : .secondary
                    )
                    Button("common.action.restore_defaults") {
                        settings.resetBindings()
                        selectedRemoteButton = .ok
                    }
                    .compatibilityButtonStyle(.standard)
                }
            }

            CompatibilityGlassContainer(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    GlassPanel {
                        RemoteControlDiagram(
                            selectedButton: $selectedRemoteButton,
                            activeButtons: model.activeRemoteButtons,
                            voiceActive: model.isStreaming
                        )
                        .onReceive(model.$activeRemoteButtons) { buttons in
                            if let button = RemoteButton.allCases.first(where: { buttons.contains($0) }) {
                                selectedRemoteButton = button
                            }
                        }
                    }
                    .frame(width: 206)

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("button_mapping.actions.title")
                                    .font(.headline)
                                Text("button_mapping.actions.help")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            let buttons = RemoteButton.allCases
                            let midpoint = (buttons.count + 1) / 2

                            HStack(alignment: .top, spacing: 8) {
                                ForEach(0..<2, id: \.self) { column in
                                    VStack(spacing: 4) {
                                        let range = column == 0
                                            ? buttons.prefix(midpoint)
                                            : buttons.suffix(from: midpoint)
                                        ForEach(range) { button in
                                            mappingRow(button)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }

                            Divider()
                            secondaryActionsPanel(for: selectedRemoteButton)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .compatibilityScrollEdgeEffect()
    }

    @ViewBuilder
    private func mappingRow(_ button: RemoteButton) -> some View {
        let selected = selectedRemoteButton == button
        let currentAction = settings.action(for: button)
        let currentShortcut = settings.shortcut(for: button)
        let installedBundleIdentifiers = PresetApplication.installedBundleIdentifiers
        let content = VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    selectedRemoteButton = button
                } label: {
                    Text(button.displayName(using: localization))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(button.displayName(using: localization))

                Picker("", selection: Binding(
                    get: { currentAction },
                    set: { action in
                        settings.setAction(action, for: button)
                        selectedRemoteButton = button
                        if action == .customShortcut {
                            shortcutEditingTarget = ShortcutEditingTarget(
                                button: button,
                                trigger: .singleClick
                            )
                        }
                    }
                )) {
                    ForEach(ButtonAction.pickerActions(
                        installedBundleIdentifiers: installedBundleIdentifiers,
                        current: currentAction,
                        experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
                    )) { action in
                        let unavailableApplication = action.presetApplication.map {
                            !installedBundleIdentifiers.contains($0.bundleIdentifier)
                        } ?? false
                        let unavailableExperiment = action == .toggleLongRecording &&
                            !settings.experimentalContinuousRecordingEnabled
                        Text(
                            action.displayName(using: localization) +
                                (unavailableApplication
                                    ? localization.text("common.suffix.not_installed")
                                    : unavailableExperiment
                                        ? localization.text("common.suffix.experimental_disabled")
                                        : "")
                        )
                        .tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                .disabled(button == .power && settings.experimentalContinuousRecordingEnabled)
            }

            if button == .power && settings.experimentalContinuousRecordingEnabled {
                Text("button_mapping.continuous_recording_experiment.power_managed")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if currentAction == .customShortcut {
                Button {
                    selectedRemoteButton = button
                    shortcutEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: .singleClick
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                        Text(
                            currentShortcut?.displayName(using: localization) ??
                                localization.text("shortcut.action.record")
                        )
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "pencil")
                    }
                    .font(.caption)
                    .foregroundStyle(currentShortcut == nil ? Color.orange : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(localization.text("shortcut.record.help"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        if selected {
            content.compatibilityTintedGlass(
                tint: Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                interactive: true
            )
        } else {
            VStack(spacing: 0) {
                content
                Divider()
                    .padding(.leading, 8)
            }
        }
    }

    private func secondaryActionsPanel(for button: RemoteButton) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(
                    String(
                        format: localization.text("trigger.other_actions"),
                        locale: localization.locale,
                        arguments: [button.displayName(using: localization)]
                    )
                )
                    .font(.caption.weight(.semibold))
                Spacer()
                if settings.hasSecondaryAction(for: button) {
                    Text("trigger.hold_repeat_disabled")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }

            secondaryActionRow(button, trigger: .doubleClick)
            secondaryActionRow(button, trigger: .longPress)

            Text("trigger.timing.help")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func secondaryActionRow(
        _ button: RemoteButton,
        trigger: ButtonTrigger
    ) -> some View {
        let configured = settings.configuredAction(for: button, trigger: trigger)
        let installedBundleIdentifiers = PresetApplication.installedBundleIdentifiers
        return HStack(spacing: 8) {
            Text(trigger.displayName(using: localization))
                .font(.caption)
                .frame(width: 38, alignment: .leading)

            Picker("", selection: Binding(
                get: { configured.action },
                set: { action in
                    settings.setAction(action, for: button, trigger: trigger)
                    if action == .customShortcut {
                        shortcutEditingTarget = ShortcutEditingTarget(
                            button: button,
                            trigger: trigger
                        )
                    }
                }
            )) {
                ForEach(ButtonAction.pickerActions(
                    installedBundleIdentifiers: installedBundleIdentifiers,
                    current: configured.action,
                    experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
                )) { action in
                    let unavailableApplication = action.presetApplication.map {
                        !installedBundleIdentifiers.contains($0.bundleIdentifier)
                    } ?? false
                    let unavailableExperiment = action == .toggleLongRecording &&
                        !settings.experimentalContinuousRecordingEnabled
                    Text(
                        action.displayName(using: localization) +
                            (unavailableApplication
                                ? localization.text("common.suffix.not_installed")
                                : unavailableExperiment
                                    ? localization.text("common.suffix.experimental_disabled")
                                    : "")
                    )
                    .tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            if configured.action == .customShortcut {
                Button {
                    shortcutEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: trigger
                    )
                } label: {
                    HStack(spacing: 5) {
                        Text(
                            configured.shortcut?.displayName(using: localization) ??
                                localization.text("shortcut.action.click_to_record")
                        )
                            .lineLimit(1)
                        Image(systemName: "pencil")
                    }
                    .font(.caption)
                    .foregroundStyle(configured.shortcut == nil ? Color.orange : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    private var permissionsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("permissions.page.title")
                )

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
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .compatibilityScrollEdgeEffect()
    }

    private var statisticsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("statistics.page.title")
                )

                CompatibilityGlassContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
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

                            Spacer(minLength: 20)

                            StatusPill(
                                text: localization.text("about.privacy.local_only"),
                                tint: .green
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        statisticsPeriodContent
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .compatibilityScrollEdgeEffect()
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
                    subtitle: localization.text("statistics.chart.last_eight_weeks"),
                    systemImage: "button.programmable",
                    points: weeklyUsageChartPoints,
                    metric: .buttonPressCount,
                    tint: .blue
                )
                UsageBarChart(
                    title: localization.text("statistics.metric.voice_duration"),
                    subtitle: localization.text("statistics.chart.last_eight_weeks"),
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("menu.about")
                )

                CompatibilityGlassContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        GlassPanel {
                            HStack(spacing: 20) {
                                Image(nsImage: NSApp.applicationIconImage)
                                    .resizable()
                                    .frame(width: 88, height: 88)
                                    .shadow(color: .black.opacity(0.16), radius: 12, y: 6)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("app.name")
                                        .font(.system(size: 28, weight: .semibold))
                                    Text("about.page.hero_description")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 10) {
                                        Link(destination: localization.localizedWebsiteURL) {
                                            Label("about.support.website", systemImage: "globe")
                                        }
                                        .compatibilityButtonStyle(.prominent)

                                        Link(
                                            destination: AppLinks.githubRepository
                                        ) {
                                            Label("about.support.github", systemImage: "link")
                                        }
                                        .compatibilityButtonStyle(.standard)
                                    }
                                }

                                Spacer(minLength: 20)

                                Image(systemName: "waveform.and.mic")
                                    .font(.system(size: 42, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 76, height: 76)
                                    .compatibilityTintedGlass(
                                        tint: Color.accentColor.opacity(0.12),
                                        in: Circle()
                                    )
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("about.configuration.title")
                                            .font(.headline)
                                        Text("about.configuration.description")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(Color.accentColor)
                                }

                                HStack(spacing: 10) {
                                    Button(action: exportConfiguration) {
                                        Label("about.configuration.export", systemImage: "square.and.arrow.up")
                                    }
                                    .compatibilityButtonStyle(.prominent)

                                    Button(action: importConfiguration) {
                                        Label("about.configuration.import", systemImage: "square.and.arrow.down")
                                    }
                                    .compatibilityButtonStyle(.standard)

                                    Spacer()

                                    if let configurationStatus {
                                        Label(
                                            configurationStatus.message.text(using: localization),
                                            systemImage: configurationStatus.systemImage
                                        )
                                        .font(.caption)
                                        .foregroundStyle(configurationStatus.tint)
                                    }
                                }
                            }
                        }

                        HStack(alignment: .top, spacing: 14) {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("about.preferences.title")
                                        .font(.headline)

                                    Toggle("about.preferences.show_dock_icon", isOn: Binding(
                                        get: { settings.showDockIcon },
                                        set: { setDockIconVisible($0) }
                                    ))

                                    Text("about.preferences.show_dock_icon_help")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Divider()

                                    Toggle(
                                        "about.preferences.open_main_window_at_launch",
                                        isOn: $settings.openMainWindowAtLaunch
                                    )

                                    Text("about.preferences.open_main_window_help")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Divider()

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("about.preferences.language")
                                            .font(.subheadline.weight(.medium))
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
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)

                            GlassPanel {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("about.version.title")
                                        .font(.headline)

                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(versionText)
                                            .font(.title3.weight(.semibold).monospacedDigit())

                                        Button(action: checkForUpdates) {
                                            Label(
                                                "menu.check_for_updates",
                                                systemImage: "arrow.triangle.2.circlepath"
                                            )
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .compatibilityButtonStyle(.prominent)

                                        Toggle(
                                            "about.version.check_prerelease",
                                            isOn: $settings.checksForPreReleaseUpdates
                                        )

                                        Text("about.version.check_prerelease_help")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Divider()

                                    Button {
                                        isReleaseHistoryPresented = true
                                    } label: {
                                        Label("about.version.history", systemImage: "clock.arrow.circlepath")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .compatibilityButtonStyle(.standard)

                                    Button(action: openGlossary) {
                                        Label("help.glossary.open", systemImage: "book.closed")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .compatibilityButtonStyle(.standard)
                                }
                            }
                            .frame(width: 280, alignment: .top)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .compatibilityScrollEdgeEffect()
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build else {
            return String(
                format: localization.text("app.version"),
                locale: localization.locale,
                arguments: [version]
            )
        }
        return String(
            format: localization.text("app.version_with_build"),
            locale: localization.locale,
            arguments: [version, build]
        )
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        language == .system ? localization.text("language.system") : language.nativeDisplayName
    }

    private func openGlossary() {
        guard let url = localization.localizedURL(
            forResource: "Glossary",
            withExtension: "md"
        ) else { return }
        NSWorkspace.shared.open(url)
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
        usageChartPoints(
            from: settings.weeklyUsageStatistics(weeks: 8),
            dateFormatTemplate: "Md"
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
            UsageChartPoint(
                date: bucket.startDate,
                label: formatter.string(from: bucket.startDate),
                buttonPressCount: Double(bucket.statistics.buttonPressCount),
                buttonPressCountLabel: localizedNumber(bucket.statistics.buttonPressCount),
                voiceDuration: max(0, bucket.statistics.voiceDuration),
                voiceDurationLabel: compactDurationText(bucket.statistics.voiceDuration)
            )
        }
    }

    private func compactDurationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(min(duration.rounded(), Double(Int.max))))
        if totalSeconds >= 3_600 {
            return String(
                format: localization.text("usage.duration.compact_hours"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(totalSeconds / 3_600))]
            )
        }
        if totalSeconds >= 60 {
            return String(
                format: localization.text("usage.duration.compact_minutes"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(totalSeconds / 60))]
            )
        }
        return String(
            format: localization.text("usage.duration.compact_seconds"),
            locale: localization.locale,
            arguments: [localizedNumber(UInt64(totalSeconds))]
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
            Button(actionTitle, action: action)
                .compatibilityButtonStyle(.standard)
                .frame(width: 112)
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

private struct ShortcutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localization: LocalizationStore

    let button: RemoteButton
    let trigger: ButtonTrigger
    let currentShortcut: CustomKeyboardShortcut?
    let onSave: (CustomKeyboardShortcut?) -> Void

    @State private var shortcut: CustomKeyboardShortcut?

    init(
        button: RemoteButton,
        trigger: ButtonTrigger,
        currentShortcut: CustomKeyboardShortcut?,
        onSave: @escaping (CustomKeyboardShortcut?) -> Void
    ) {
        self.button = button
        self.trigger = trigger
        self.currentShortcut = currentShortcut
        self.onSave = onSave
        _shortcut = State(initialValue: currentShortcut)
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text(
                    String(
                        format: localization.text("shortcut.editor.title"),
                        locale: localization.locale,
                        arguments: [
                            button.displayName(using: localization),
                            trigger.displayName(using: localization),
                        ]
                    )
                )
                    .font(.title3.weight(.semibold))
                Text("shortcut.editor.instructions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(
                shortcut?.displayName(using: localization) ??
                    localization.text("shortcut.editor.waiting")
            )
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(shortcut == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            ShortcutCaptureView { shortcut = $0 }
                .frame(height: 1)

            HStack {
                Button("common.action.clear") {
                    onSave(nil)
                    dismiss()
                }
                .disabled(currentShortcut == nil)

                Spacer()

                Button("common.action.cancel") { dismiss() }
                Button("common.action.save") {
                    onSave(shortcut)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(shortcut == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (CustomKeyboardShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        context.coordinator.onCapture = onCapture
    }

    static func dismantleNSView(_ nsView: ShortcutCaptureNSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onCapture: (CustomKeyboardShortcut) -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(onCapture: @escaping (CustomKeyboardShortcut) -> Void) {
            self.onCapture = onCapture
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.view?.window else { return event }
                self.onCapture(CustomKeyboardShortcut(event: event))
                return nil
            }
        }

        func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            stopMonitoring()
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}

private enum CompatibilityButtonStyle {
    case standard
    case prominent
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
        if #available(macOS 26.0, *) {
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
        if #available(macOS 26.0, *) {
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
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
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
        if #available(macOS 26.0, *) {
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

private struct SidebarGlassModifier: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            if #available(macOS 26.0, *) {
                content
                    .foregroundStyle(Color.accentColor)
                    .glassEffect(
                        .clear.tint(Color.accentColor.opacity(0.08)).interactive(),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .glassEffectID("settings-navigation-selection", in: namespace)
            } else {
                content
                    .foregroundStyle(Color.accentColor)
                    .background(
                        Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
        } else {
            content
                .foregroundStyle(.secondary)
        }
    }
}

private struct PageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 25, weight: .semibold))
    }
}

private struct GlassPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .padding(16)
                .glassEffect(.regular, in: shape)
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
            .font(.caption.weight(.semibold))
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
                    .aspectRatio(contentMode: .fit)
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

private struct RemoteControlDiagram: View {
    @EnvironmentObject private var localization: LocalizationStore
    @Binding var selectedButton: RemoteButton
    let activeButtons: Set<RemoteButton>
    let voiceActive: Bool

    private let canvasSize = CGSize(width: 174, height: 352)

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RC003Photo()
                    .frame(width: canvasSize.width, height: canvasSize.height)

                hotspot(.power, x: 0.386, y: 0.099, width: 0.15, height: 0.072)
                voiceHotspot(x: 0.630, y: 0.099, width: 0.15, height: 0.072)

                hotspot(.up, x: 0.502, y: 0.179, width: 0.18, height: 0.065)
                hotspot(.left, x: 0.362, y: 0.246, width: 0.15, height: 0.080)
                hotspot(.ok, x: 0.502, y: 0.246, width: 0.19, height: 0.095)
                hotspot(.right, x: 0.638, y: 0.246, width: 0.15, height: 0.080)
                hotspot(.down, x: 0.502, y: 0.317, width: 0.18, height: 0.065)

                hotspot(.back, x: 0.406, y: 0.389, width: 0.17, height: 0.080)
                hotspot(.volumeUp, x: 0.604, y: 0.390, width: 0.16, height: 0.080)
                hotspot(.home, x: 0.406, y: 0.479, width: 0.17, height: 0.080)
                hotspot(.volumeDown, x: 0.604, y: 0.480, width: 0.16, height: 0.080)
                hotspot(.menu, x: 0.406, y: 0.569, width: 0.17, height: 0.080)
                hotspot(.tv, x: 0.604, y: 0.569, width: 0.17, height: 0.080)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("remote.mapping.instructions")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func hotspot(
        _ button: RemoteButton,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let active = activeButtons.contains(button)
        return Button {
            selectedButton = button
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(active ? Color.orange.opacity(0.30) : selectedButton == button ? Color.accentColor.opacity(0.24) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(
                            active ? Color.orange : selectedButton == button ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: canvasSize.width * width, height: canvasSize.height * height)
        .position(x: canvasSize.width * x, y: canvasSize.height * y)
        .help(button.displayName(using: localization))
        .accessibilityLabel(Text(button.displayName(using: localization)))
    }

    private func voiceHotspot(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Circle()
            .fill(voiceActive ? Color.orange.opacity(0.28) : Color.clear)
            .overlay {
                Circle().stroke(voiceActive ? Color.orange : Color.clear, lineWidth: 2)
            }
            .contentShape(Circle())
            .frame(width: canvasSize.width * width, height: canvasSize.height * height)
            .position(x: canvasSize.width * x, y: canvasSize.height * y)
            .help(localization.text("remote.voice_button.help"))
            .accessibilityElement()
            .accessibilityLabel(Text(localization.text("remote.voice_button.accessibility_label")))
    }
}
