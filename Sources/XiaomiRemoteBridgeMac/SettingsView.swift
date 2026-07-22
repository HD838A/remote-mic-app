import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @State private var selectedRemoteButton: RemoteButton = .ok

    init(model: BridgeAppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("连接", systemImage: "antenna.radiowaves.left.and.right") }
            mappingTab
                .tabItem { Label("按键", systemImage: "keyboard") }
            permissionsTab
                .tabItem { Label("权限", systemImage: "lock.shield") }
        }
        .frame(width: 760, height: 600)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section(header: Text("遥控器")) {
                statusRow("蓝牙状态", value: model.connectionStatus)
                statusRow("语音状态", value: model.isStreaming ? "语音中" : "等待麦克风键")
                statusRow("语音触发", value: model.voiceShortcutStatus)
                Button("立即重新连接") { model.reconnect() }
            }

            Section(header: Text("虚拟麦克风")) {
                Picker("语音输出", selection: Binding(
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
                HStack {
                    Text("增益")
                    Slider(value: Binding(
                        get: { settings.gainDB },
                        set: { settings.gainDB = $0 }
                    ), in: 0...24, step: 1)
                    Text("\(Int(settings.gainDB)) dB")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                statusRow("音频状态", value: model.audioStatus)
                HStack {
                    Button("刷新音频设备") { model.refreshAudioDevices() }
                    Link("获取 BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!)
                }
                Text("应用只把 RC003 语音写到所选设备，不会修改系统默认输入或输出。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack {
                    Button("发送 1 秒测试音") { model.sendTestTone() }
                        .disabled(!model.canSendTestTone)
                    Text(model.testToneStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Text("测试音只在内存生成、低音量、固定频率，不落盘；RC003 语音进行中时不可用。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Divider()

                Text("豆包输入法兼容")
                    .font(.headline)
                statusRow("兼容虚拟麦克风", value: model.doubaoAudioStatus)
                HStack {
                    Button("选择 MiRemoteV 2ch") { model.selectDoubaoAudioDevice() }
                        .disabled(!model.hasDoubaoAudioDevice)
                    Button("打开驱动安装说明") { model.openDoubaoDriverInstructions() }
                }
                Text("豆包会过滤普通 virtual transport 音频设备。安装独立的 MiRemoteV 2ch 后，在这里选中它；原 BlackHole 不会被修改或替换。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var mappingTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用 RC003 自定义按键映射", isOn: Binding(
                    get: { settings.customMappingEnabled },
                    set: { enabled in
                        settings.customMappingEnabled = enabled
                        model.applyHIDSettings()
                    }
                ))
                    statusRow("按键状态", value: model.hidStatus)
                    Text("优先独占 RC003；系统不允许独占时自动使用兼容监听，并只在遥控器原始报告附近拦截对应的系统按键，避免影响其他键盘。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                RemoteControlDiagram(
                    selectedButton: $selectedRemoteButton,
                    voiceActive: model.isStreaming
                )
                    .frame(width: 210)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("按键动作")
                                .font(.headline)
                            Text("点击左侧按键定位；修改后自动保存。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("恢复默认") {
                            settings.resetBindings()
                            selectedRemoteButton = .ok
                        }
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 7) {
                                ForEach(RemoteButton.allCases) { button in
                                    mappingRow(button)
                                        .id(button.id)
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .onChange(of: selectedRemoteButton) { button in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(button.id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .padding(4)
    }

    private func mappingRow(_ button: RemoteButton) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedRemoteButton = button
            } label: {
                HStack(spacing: 9) {
                    Text(button.shortLabel)
                        .font(.caption.weight(.semibold))
                        .frame(width: 42, height: 30)
                        .background(
                            selectedRemoteButton == button
                                ? Color.accentColor
                                : Color.secondary.opacity(0.14)
                        )
                        .foregroundColor(selectedRemoteButton == button ? .white : .primary)
                        .clipShape(Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(button.displayName)
                        Text(String(format: "HID 0x%02X", button.hidUsage))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { settings.action(for: button) },
                set: { settings.setAction($0, for: button) }
            )) {
                ForEach(ButtonAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 175)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            selectedRemoteButton == button
                ? Color.accentColor.opacity(0.09)
                : Color.secondary.opacity(0.055)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    selectedRemoteButton == button
                        ? Color.accentColor.opacity(0.45)
                        : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private var permissionsTab: some View {
        Form {
            Section(header: Text("所需权限")) {
                permissionRow(
                    title: "蓝牙",
                    detail: "连接 RC003 并读取 ATVV 语音服务",
                    actionTitle: "打开蓝牙设置"
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
                permissionRow(
                    title: "输入监控",
                    detail: "读取 RC003 原始 HID 报告，并在兼容模式下抑制重复系统事件",
                    actionTitle: "请求权限"
                ) { model.requestInputMonitoringPermission() }
                permissionRow(
                    title: "辅助功能",
                    detail: "把映射后的按键动作发送给当前应用",
                    actionTitle: "请求权限"
                ) { model.requestAccessibilityPermission() }
            }

            Section(header: Text("诊断")) {
                Button("在 Finder 中显示日志") { model.openLogFolder() }
                Text("日志不记录语音内容、蓝牙地址或外设 UUID。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

private struct RemoteControlDiagram: View {
    @Binding var selectedButton: RemoteButton
    let voiceActive: Bool

    private static let photo: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "RC003-remote-photo",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack {
                    if let photo = Self.photo {
                        Image(nsImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                        Text("实物图资源缺失")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

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
            }
            .frame(width: 210, height: 426)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
            )

            Text("点击实物按键定位映射；麦克风键固定为硬件语音/Fn。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
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
        Button {
            selectedButton = button
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    selectedButton == button
                        ? Color.accentColor.opacity(0.27)
                        : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(
                            selectedButton == button ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 210 * width, height: 426 * height)
        .position(x: 210 * x, y: 426 * y)
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
            .fill(voiceActive ? Color.orange.opacity(0.30) : Color.clear)
            .overlay(
                Circle().stroke(
                    voiceActive ? Color.orange : Color.clear,
                    lineWidth: 2
                )
            )
            .contentShape(Circle())
            .frame(width: 210 * width, height: 426 * height)
            .position(x: 210 * x, y: 426 * y)
        .help("遥控器真实 F5 硬件按下/松开会映射为 Mac Fn；同时桥接 ATVV 语音")
        .accessibilityElement()
        .accessibilityLabel(Text("语音/Fn 键，固定核心功能"))
    }
}
