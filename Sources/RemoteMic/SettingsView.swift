import AppKit
import Combine
import CoreBluetooth
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case connection
    case mapping
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "连接"
        case .mapping: return "按键"
        case .permissions: return "权限"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "link"
        case .mapping: return "keyboard"
        case .permissions: return "shield.lefthalf.filled"
        }
    }
}

private enum PermissionVisualState {
    case granted
    case pending

    var title: String {
        switch self {
        case .granted: return "已开启"
        case .pending: return "待授权"
        }
    }

    var tint: Color {
        switch self {
        case .granted: return .green
        case .pending: return .orange
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings

    @State private var selectedSection: SettingsSection = .connection
    @State private var selectedRemoteButton: RemoteButton = .ok
    @State private var bluetoothAuthorization = CBManager.authorization
    @State private var inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
    @State private var accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    @Namespace private var navigationGlassNamespace

    init(model: BridgeAppModel) {
        self.model = model
        settings = model.settings
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
        .frame(minWidth: 760, minHeight: 600)
        .onAppear(perform: refreshPermissionStates)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
    }

    private var sidebar: some View {
        GlassEffectContainer(spacing: 10) {
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
        }
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "连接与语音",
                    subtitle: "连接 RC003，并配置语音输出与触发方式"
                )

                GlassEffectContainer(spacing: 14) {
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
        .scrollEdgeEffectStyle(.soft, for: .top)
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
                        title: "蓝牙状态",
                        detail: model.connectionStatus,
                        badge: connectionBadge,
                        tint: connectionTint
                    )
                    DeviceStatusStep(
                        symbol: "waveform",
                        title: "语音状态",
                        detail: model.isStreaming ? "正在传输遥控器语音" : "等待麦克风键",
                        badge: model.isStreaming ? "语音中" : "已就绪",
                        tint: model.isStreaming ? .orange : .blue
                    )
                    DeviceStatusStep(
                        symbol: "mic.fill",
                        title: "语音触发",
                        detail: model.voiceShortcutStatus,
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
                    .buttonStyle(.glassProminent)
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
                        ForEach(model.audioDevices) { device in
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
                    Text(model.audioStatus)
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
                        .buttonStyle(.glassProminent)
                    Link("获取 BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!)
                        .buttonStyle(.glass)
                    Button("发送 1 秒测试音") { model.sendTestTone() }
                        .buttonStyle(.glass)
                        .disabled(!model.canSendTestTone)
                }

                Text("应用只把 RC003 语音写到所选设备，不会修改系统默认输入或输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(model.testToneStatus)
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
                    Text(model.doubaoAudioStatus)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 10) {
                    Button("选择 MiRemoteV 2ch") { model.selectDoubaoAudioDevice() }
                        .buttonStyle(.glass)
                        .disabled(!model.hasDoubaoAudioDevice)
                    Button("打开驱动安装说明") { model.openDoubaoDriverInstructions() }
                        .buttonStyle(.glass)
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
                title: "按键映射",
                subtitle: "自定义 RC003 按键功能，并保留语音键的固定核心行为"
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
                        Text(model.hidStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    StatusPill(
                        text: settings.customMappingEnabled ? "已启用" : "未启用",
                        tint: settings.customMappingEnabled ? .green : .secondary
                    )
                    Button("恢复默认") {
                        settings.resetBindings()
                        selectedRemoteButton = .ok
                    }
                    .buttonStyle(.glass)
                }
            }

            GlassEffectContainer(spacing: 14) {
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
        let installedBundleIdentifiers = PresetApplication.installedBundleIdentifiers
        let content = HStack(spacing: 8) {
            Button {
                selectedRemoteButton = button
            } label: {
                Text(button.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("\(button.displayName) · HID \(String(format: "0x%02X", button.hidUsage))")

            Picker("", selection: Binding(
                get: { currentAction },
                set: { settings.setAction($0, for: button) }
            )) {
                ForEach(ButtonAction.pickerActions(
                    installedBundleIdentifiers: installedBundleIdentifiers,
                    current: currentAction
                )) { action in
                    let unavailable = action.presetApplication.map {
                        !installedBundleIdentifiers.contains($0.bundleIdentifier)
                    } ?? false
                    Text(action.displayName + (unavailable ? "（未安装）" : "")).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 112)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        if selected {
            content
                .glassEffect(
                    .clear.tint(Color.accentColor.opacity(0.10)).interactive(),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        } else {
            VStack(spacing: 0) {
                content
                Divider()
                    .padding(.leading, 8)
            }
        }
    }

    private var permissionsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "权限与隐私",
                    subtitle: "按顺序完成权限设置，确保 RC003 正常连接和发送按键"
                )

                GlassEffectContainer(spacing: 14) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("所需权限")
                                .font(.headline)
                                .padding(.bottom, 8)

                            permissionRow(
                                index: 1,
                                symbol: "antenna.radiowaves.left.and.right",
                                title: "蓝牙",
                                detail: "连接 RC003 并读取 ATVV 语音服务",
                                state: bluetoothPermissionState,
                                actionTitle: "打开蓝牙设置"
                            ) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                                    NSWorkspace.shared.open(url)
                                }
                            }

                            Divider().padding(.leading, 62)

                            permissionRow(
                                index: 2,
                                symbol: "keyboard",
                                title: "输入监控",
                                detail: "读取 RC003 原始 HID 报告，并在兼容模式下抑制重复系统事件",
                                state: inputMonitoringGranted ? .granted : .pending,
                                actionTitle: "请求权限"
                            ) {
                                model.requestInputMonitoringPermission()
                            }

                            Divider().padding(.leading, 62)

                            permissionRow(
                                index: 3,
                                symbol: "accessibility",
                                title: "辅助功能",
                                detail: "把映射后的按键动作发送给当前应用",
                                state: accessibilityGranted ? .granted : .pending,
                                actionTitle: "请求权限"
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
                                    .glassEffect(
                                        .clear.tint(Color.accentColor.opacity(0.14)),
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
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
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
                .glassEffect(
                    .clear.tint(Color.accentColor.opacity(0.14)),
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
            StatusPill(text: state.title, tint: state.tint)
            Button(actionTitle, action: action)
                .buttonStyle(.glass)
                .frame(width: 112)
        }
        .padding(.vertical, 12)
    }

    private var connectionBadge: String {
        model.connectionStatus.contains("已连接") ? "已连接" : "连接中"
    }

    private var connectionTint: Color {
        model.connectionStatus.contains("已连接") ? .green : .orange
    }

    private var voiceTriggerBadge: String {
        if model.voiceShortcutStatus.contains("已释放") ||
            model.voiceShortcutStatus.contains("已硬件映射") {
            return "已启用"
        }
        return "准备中"
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

private struct SidebarGlassModifier: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .foregroundStyle(Color.accentColor)
                .glassEffect(
                    .clear.tint(Color.accentColor.opacity(0.08)).interactive(),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .glassEffectID("settings-navigation-selection", in: namespace)
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
        content
            .padding(16)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
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
            .glassEffect(.clear.tint(tint.opacity(0.14)), in: Capsule())
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
                .glassEffect(.clear.tint(tint.opacity(0.14)), in: Circle())
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
        .help(button.displayName)
        .accessibilityLabel(Text(button.displayName))
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
            .help("遥控器真实 F5 硬件按下/松开会映射为 Mac Fn；同时桥接 ATVV 语音")
            .accessibilityElement()
            .accessibilityLabel(Text("语音/Fn 键，固定核心功能"))
    }
}
