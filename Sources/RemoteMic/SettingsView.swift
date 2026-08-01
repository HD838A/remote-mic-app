import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSection: String, CaseIterable, Identifiable {
    case connection
    case mapping
    case permissions
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .connection: return "连接"
        case .mapping: return "按键"
        case .permissions: return "权限"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "link"
        case .mapping: return "keyboard"
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
        case .granted: return localization.text("已开启")
        case .pending: return localization.text("待授权")
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
    @State private var shortcutEditingTarget: ShortcutEditingTarget?
    @State private var bluetoothAuthorization = CBManager.authorization
    @State private var inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
    @State private var accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    @State private var configurationStatus: ConfigurationStatus?
    @State private var isReleaseHistoryPresented = false
    @Namespace private var navigationGlassNamespace

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
        .environment(\.locale, localization.locale)
        .frame(minWidth: 760, minHeight: 600)
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
        case .permissions:
            permissionsPage
        case .about:
            aboutPage
        }
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("连接与语音"),
                    subtitle: localization.text("连接 RC003，并配置语音输出与触发方式")
                )

                CompatibilityGlassContainer(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        connectionDevicePanel
                            .frame(width: 196)
                        audioSettingsPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .compatibilityScrollEdgeEffect()
    }

    private var connectionDevicePanel: some View {
        GlassPanel {
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("RC003")
                        .font(.headline)
                    Text("语音遥控器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RC003Photo()
                    .frame(width: 70, height: 142)

                VStack(spacing: 12) {
                    DeviceStatusStep(
                        symbol: "antenna.radiowaves.left.and.right",
                        title: localization.text("蓝牙状态"),
                        detail: model.connectionStatus.text(using: localization),
                        badge: connectionBadge,
                        tint: connectionTint
                    )
                    DeviceStatusStep(
                        symbol: "waveform",
                        title: localization.text("语音状态"),
                        detail: localization.text(
                            model.isStreaming ? "正在传输遥控器语音" : "等待麦克风键"
                        ),
                        badge: localization.text(model.isStreaming ? "语音中" : "已就绪"),
                        tint: model.isStreaming ? .orange : .blue
                    )
                    DeviceStatusStep(
                        symbol: "mic.fill",
                        title: localization.text("语音触发"),
                        detail: model.voiceShortcutStatus.text(using: localization),
                        badge: voiceTriggerBadge,
                        tint: .blue
                    )
                }

                Button {
                    model.reconnect()
                } label: {
                    Text("立即重新连接")
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
                Text("音频设置")
                    .font(.headline)

                HStack(spacing: 14) {
                    Text("语音输出")
                        .frame(width: 72, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { settings.selectedAudioDeviceUID },
                        set: { value in
                            settings.selectedAudioDeviceUID = value
                            model.applyAudioSettings()
                        }
                    )) {
                        Text("不输出语音").tag("")
                        ForEach(model.audioDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 270)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 14) {
                        Text("增益")
                            .frame(width: 72, alignment: .leading)
                        Slider(value: Binding(
                            get: { settings.gainDB },
                            set: { settings.gainDB = $0 }
                        ), in: 0...24, step: 1)
                        Text("\(Int(settings.gainDB)) dB")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 54, alignment: .trailing)
                    }

                    Text("0 dB 保持原始音量；数值越大声音越响，也会放大环境噪声。建议先从 6–12 dB 开始。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 86)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("音频状态")
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
                        Text("刷新音频设备")
                            .foregroundStyle(.white)
                    }
                        .compatibilityButtonStyle(.prominent)
                    Link("获取 BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!)
                        .compatibilityButtonStyle(.standard)
                    Button("发送 1 秒测试音") { model.sendTestTone() }
                        .compatibilityButtonStyle(.standard)
                        .disabled(!model.canSendTestTone)
                }

                Text("应用只把 RC003 语音写到所选设备，不会修改系统默认输入或输出。")
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
                        Text("豆包输入法兼容")
                            .font(.headline)
                        Text("兼容虚拟麦克风")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Text(model.doubaoAudioStatus.text(using: localization))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 10) {
                    Button("选择 MiRemoteV 2ch") { model.selectDoubaoAudioDevice() }
                        .compatibilityButtonStyle(.standard)
                        .disabled(!model.hasDoubaoAudioDevice)
                    Button("打开驱动安装说明") {
                        model.openDoubaoDriverInstructions(using: localization)
                    }
                        .compatibilityButtonStyle(.standard)
                }

                Text("豆包会过滤普通 virtual transport 音频设备。安装独立的 MiRemoteV 2ch 后在这里选中；原 BlackHole 不会被修改或替换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mappingPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: localization.text("按键映射"),
                subtitle: localization.text("自定义 RC003 按键功能，并保留语音键的固定核心行为")
            )

            GlassPanel {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("启用 RC003 自定义按键映射", isOn: Binding(
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
                        text: localization.text(settings.customMappingEnabled ? "已启用" : "未启用"),
                        tint: settings.customMappingEnabled ? .green : .secondary
                    )
                    Button("恢复默认") {
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
                                Text("按键动作")
                                    .font(.headline)
                                Text("点击或按下左侧实体按键定位；修改后自动保存。")
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
            .frame(maxHeight: .infinity)
        }
        .padding(22)
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
                .help(
                    "\(button.displayName(using: localization)) · HID \(String(format: "0x%02X", button.hidUsage))"
                )

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
                        current: currentAction
                    )) { action in
                        let unavailable = action.presetApplication.map {
                            !installedBundleIdentifiers.contains($0.bundleIdentifier)
                        } ?? false
                        Text(
                            action.displayName(using: localization) +
                                (unavailable ? localization.text("（未安装）") : "")
                        )
                        .tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
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
                                localization.text("点击录入快捷键")
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
                .help(localization.text("录入要发送给当前应用的键盘快捷键"))
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
                        format: localization.text("%@其他触发"),
                        locale: localization.locale,
                        arguments: [button.displayName(using: localization)]
                    )
                )
                    .font(.caption.weight(.semibold))
                Spacer()
                if settings.hasSecondaryAction(for: button) {
                    Text("按住重复已停用")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }

            secondaryActionRow(button, trigger: .doubleClick)
            secondaryActionRow(button, trigger: .longPress)

            Text("双击会等待约 0.3 秒确认单击；长按约 0.55 秒触发。未配置时保持原有即时响应。")
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
                    current: configured.action
                )) { action in
                    let unavailable = action.presetApplication.map {
                        !installedBundleIdentifiers.contains($0.bundleIdentifier)
                    } ?? false
                    Text(
                        action.displayName(using: localization) +
                            (unavailable ? localization.text("（未安装）") : "")
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
                                localization.text("点击录入")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("权限与隐私"),
                    subtitle: localization.text("按顺序完成权限设置，确保 RC003 正常连接和发送按键")
                )

                CompatibilityGlassContainer(spacing: 14) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("所需权限")
                                .font(.headline)
                                .padding(.bottom, 8)

                            permissionRow(
                                index: 1,
                                symbol: "antenna.radiowaves.left.and.right",
                                title: localization.text("蓝牙"),
                                detail: localization.text("连接 RC003 并读取 ATVV 语音服务"),
                                state: bluetoothPermissionState,
                                actionTitle: localization.text("打开蓝牙设置")
                            ) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                                    NSWorkspace.shared.open(url)
                                }
                            }

                            Divider().padding(.leading, 62)

                            permissionRow(
                                index: 2,
                                symbol: "keyboard",
                                title: localization.text("输入监控"),
                                detail: localization.text("读取 RC003 原始 HID 报告，并在兼容模式下抑制重复系统事件"),
                                state: inputMonitoringGranted ? .granted : .pending,
                                actionTitle: localization.text("请求权限")
                            ) {
                                model.requestInputMonitoringPermission()
                            }

                            Divider().padding(.leading, 62)

                            permissionRow(
                                index: 3,
                                symbol: "accessibility",
                                title: localization.text("辅助功能"),
                                detail: localization.text("把映射后的按键动作发送给当前应用"),
                                state: accessibilityGranted ? .granted : .pending,
                                actionTitle: localization.text("请求权限")
                            ) {
                                model.requestAccessibilityPermission()
                            }
                        }
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("诊断")
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
                                    Text("应用日志")
                                    Text("日志不记录语音内容、蓝牙地址或外设 UUID。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("在 Finder 中显示日志") { model.openLogFolder() }
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

    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: localization.text("关于无线麦"),
                    subtitle: localization.text("你的无线语音工作台，配置、统计与隐私一目了然")
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
                                    Text("无线麦")
                                        .font(.system(size: 28, weight: .semibold))
                                    Text("让遥控器成为随手可用的 Mac 语音与快捷操作入口。")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    StatusPill(
                                        text: localization.text("数据仅存本机"),
                                        tint: .green
                                    )
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
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("本地使用统计")
                                            .font(.headline)
                                        Text("只记录使用量，不记录、保存或分析任何语音内容。")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "lock.shield.fill")
                                        .foregroundStyle(.green)
                                }

                                HStack(spacing: 12) {
                                    UsageStatisticCard(
                                        systemImage: "button.programmable",
                                        title: localization.text("按键次数"),
                                        value: buttonPressCountText,
                                        tint: .blue
                                    )
                                    UsageStatisticCard(
                                        systemImage: "waveform",
                                        title: localization.text("语音时长"),
                                        value: voiceDurationText,
                                        tint: .orange
                                    )
                                }

                                Text("统计仅保存在这台 Mac 上，配置导出不会包含这些数据。按键次数包含应用识别的普通按键与语音键。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("个性化配置")
                                            .font(.headline)
                                        Text("迁移增益、音频设备、按键映射、快捷键、语言与 Dock 显示设置。")
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
                                        Label("导出配置…", systemImage: "square.and.arrow.up")
                                    }
                                    .compatibilityButtonStyle(.prominent)

                                    Button(action: importConfiguration) {
                                        Label("导入配置…", systemImage: "square.and.arrow.down")
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
                                    Text("应用偏好")
                                        .font(.headline)

                                    Toggle("在 Dock 中显示应用图标", isOn: Binding(
                                        get: { settings.showDockIcon },
                                        set: { setDockIconVisible($0) }
                                    ))

                                    Text("关闭后仍可通过菜单栏图标打开无线麦。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Divider()

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("应用语言")
                                            .font(.subheadline.weight(.medium))
                                        Picker("应用语言", selection: Binding(
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
                                    Text("版本与更新")
                                        .font(.headline)

                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("当前版本")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(versionText)
                                            .font(.title3.weight(.semibold).monospacedDigit())

                                        Button(action: checkForUpdates) {
                                            Label(
                                                "检查更新…",
                                                systemImage: "arrow.triangle.2.circlepath"
                                            )
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .compatibilityButtonStyle(.prominent)
                                    }

                                    Divider()

                                    Button {
                                        isReleaseHistoryPresented = true
                                    } label: {
                                        Label("版本历史", systemImage: "clock.arrow.circlepath")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .compatibilityButtonStyle(.standard)

                                    Link(
                                        destination: URL(string: "https://github.com/HD838A/remote-mic-app")!
                                    ) {
                                        Label("GitHub", systemImage: "link")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .compatibilityButtonStyle(.standard)

                                    Button {
                                        NSApp.terminate(nil)
                                    } label: {
                                        Label("退出", systemImage: "power")
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
        ) as? String ?? localization.text("未知")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build else {
            return String(
                format: localization.text("版本 %@"),
                locale: localization.locale,
                arguments: [version]
            )
        }
        return String(
            format: localization.text("版本 %@ (%@)"),
            locale: localization.locale,
            arguments: [version, build]
        )
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        language == .system ? localization.text("跟随系统") : language.nativeDisplayName
    }

    private var buttonPressCountText: String {
        localizedNumber(settings.totalButtonPressCount)
    }

    private var voiceDurationText: String {
        let totalSeconds = max(
            0,
            Int(min(settings.totalVoiceDuration.rounded(), Double(Int.max)))
        )
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: localization.text("%@ 小时 %@ 分钟"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(hours)), localizedNumber(UInt64(minutes))]
            )
        }
        if minutes > 0 {
            return String(
                format: localization.text("%@ 分钟 %@ 秒"),
                locale: localization.locale,
                arguments: [localizedNumber(UInt64(minutes)), localizedNumber(UInt64(seconds))]
            )
        }
        return String(
            format: localization.text("%@ 秒"),
            locale: localization.locale,
            arguments: [localizedNumber(UInt64(seconds))]
        )
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
            title: localization.text("导出个性化配置"),
            prompt: localization.text("导出")
        ) else { return }
        do {
            let data = try settings.exportedConfigurationData()
            try data.write(to: url, options: .atomic)
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("配置已导出"),
                tint: .green,
                systemImage: "checkmark.circle.fill"
            )
        } catch {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("导出失败：无法写入文件"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private func importConfiguration() {
        configurationStatus = nil
        guard let url = ConfigurationFilePanel.importURL(
            title: localization.text("导入个性化配置"),
            prompt: localization.text("导入")
        ) else { return }
        do {
            try settings.importConfiguration(from: Data(contentsOf: url))
            localization.select(settings.applicationLanguage)
            setDockIconVisible(settings.showDockIcon)
            model.applyAudioSettings(reason: "configuration_import")
            model.applyHIDSettings()
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("配置已导入并应用"),
                tint: .green,
                systemImage: "checkmark.circle.fill"
            )
        } catch AppConfigurationError.unsupportedVersion {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("导入失败：不支持此配置版本"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("导入失败：配置文件无效"),
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
        localization.text(model.isConnected ? "已连接" : "连接中")
    }

    private var connectionTint: Color {
        model.isConnected ? .green : .orange
    }

    private var voiceTriggerBadge: String {
        localization.text(model.isVoiceTriggerEnabled ? "已启用" : "准备中")
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
                Text(localization.text("版本历史"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(localization.text("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
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
                    Text(localization.text("无法加载版本历史。"))
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
                        format: localization.text("录入%@%@快捷键"),
                        locale: localization.locale,
                        arguments: [
                            button.displayName(using: localization),
                            trigger.displayName(using: localization),
                        ]
                    )
                )
                    .font(.title3.weight(.semibold))
                Text("直接按下想要的按键组合，支持 Command、Option、Control、Shift 和 Fn。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(
                shortcut?.displayName(using: localization) ??
                    localization.text("等待按键…")
            )
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(shortcut == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            ShortcutCaptureView { shortcut = $0 }
                .frame(height: 1)

            HStack {
                Button("清除") {
                    onSave(nil)
                    dismiss()
                }
                .disabled(currentShortcut == nil)

                Spacer()

                Button("取消") { dismiss() }
                Button("保存") {
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
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 25, weight: .semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
                        Text("实物图资源缺失")
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

            Text("点击或按下实物按键定位映射；麦克风键固定为硬件语音/Fn。")
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
            .help(localization.text("遥控器真实 F5 硬件按下/松开会映射为 Mac Fn；同时桥接 ATVV 语音"))
            .accessibilityElement()
            .accessibilityLabel(Text(localization.text("语音/Fn 键，固定核心功能")))
    }
}
