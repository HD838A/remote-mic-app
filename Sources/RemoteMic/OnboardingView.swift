import AppKit
import Combine
import CoreBluetooth
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject private var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var bluetoothAuthorization = CBManager.authorization
    @State private var inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
    @State private var accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    @State private var observedRemoteButtons = Set<RemoteButton>()
    @State private var requestedRemoteConnectionRecovery = false
    @State private var testedControlButtons = Set<RemoteButton>()
    @State private var voiceSessionStarted = false
    @State private var voiceSamplesReceived = false
    @State private var voiceSessionEnded = false
    @State private var transcript = ""
    @FocusState private var transcriptFocused: Bool

    private let permissionRefreshTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    init(model: BridgeAppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            phaseHeader
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    leftPane
                        .frame(width: max(520, proxy.size.width * 0.53))
                    rightPane
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .environment(\.locale, localization.locale)
        .frame(minWidth: 980, minHeight: 732)
        .onAppear {
            refreshPermissionStates()
            prepareForStep(settings.onboardingStep)
        }
        .onReceive(permissionRefreshTimer) { _ in
            refreshPermissionStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
        .onReceive(model.$activeRemoteButtons) { buttons in
            guard !buttons.isEmpty else { return }
            if settings.onboardingStep == .remote {
                observedRemoteButtons.formUnion(buttons)
                recoverRemoteConnectionIfNeeded()
            } else if settings.onboardingStep == .controls {
                testedControlButtons.formUnion(buttons)
            }
        }
        .onReceive(model.$lastRemoteButtonPress.compactMap { $0 }) { button in
            if settings.onboardingStep == .remote {
                observedRemoteButtons.insert(button)
                recoverRemoteConnectionIfNeeded()
            } else if settings.onboardingStep == .controls {
                testedControlButtons.insert(button)
            }
        }
        .onReceive(model.$isStreaming) { isStreaming in
            guard settings.onboardingStep == .voiceTest else { return }
            if isStreaming {
                voiceSessionStarted = true
            } else if voiceSessionStarted {
                voiceSessionEnded = true
            }
        }
        .onReceive(model.$currentVoiceSampleCount) { sampleCount in
            guard settings.onboardingStep == .voiceTest, sampleCount > 0 else { return }
            voiceSamplesReceived = true
        }
        .onChange(of: settings.onboardingStep) { _, step in
            prepareForStep(step)
        }
        .onChange(of: transcript) { _, value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            transcriptFocused = true
        }
    }

    private var phaseHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                ForEach(Array(OnboardingPhase.allCases.enumerated()), id: \.element.rawValue) { index, phase in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(localization.text(phase.localizationKey))
                        .font(.system(size: 14, weight: phase == currentPhase ? .semibold : .regular))
                        .foregroundStyle(phase == currentPhase ? Color.primary : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: proxy.size.width * settings.onboardingStep.progress)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 28)
        }
        .padding(.top, 12)
        .frame(height: 76)
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previous = settings.onboardingStep.previous {
                Button {
                    settings.setOnboardingStep(previous)
                } label: {
                    Label("onboarding.action.back", systemImage: "arrow.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            } else {
                Color.clear.frame(height: 40)
            }

            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            HStack {
                Spacer()
                Button(action: continueFlow) {
                    Text(localization.text(primaryActionKey))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 118)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
            }
            .padding(.top, 14)
        }
        .padding(.top, 28)
        .padding(.horizontal, 48)
        .padding(.bottom, 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch settings.onboardingStep {
        case .welcome:
            welcomeContent
        case .voiceTool:
            voiceToolContent
        case .permissions:
            permissionsContent
        case .remote:
            remoteContent
        case .audio:
            audioContent
        case .voiceTest:
            voiceTestContent
        case .controls:
            controlsContent
        case .complete:
            completeContent
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.welcome.title")
            Text("onboarding.welcome.detail")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                featureLine("waveform", "onboarding.welcome.feature.voice")
                featureLine("rectangle.and.hand.point.up.left", "onboarding.welcome.feature.controls")
                featureLine("checkmark.shield", "onboarding.welcome.feature.verify")
            }
            .padding(.top, 10)
        }
    }

    private var voiceToolContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.voice_tool.title")
            Text("onboarding.voice_tool.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach([OnboardingVoiceTool.doubao, .typeless, .other]) { tool in
                    Button {
                        settings.setOnboardingVoiceTool(tool)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: voiceToolIcon(tool))
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(localization.text(tool.titleKey))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(localization.text(tool.detailKey))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: settings.onboardingVoiceTool == tool ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(settings.onboardingVoiceTool == tool ? Color.accentColor : Color.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            settings.onboardingVoiceTool == tool
                                ? Color.accentColor.opacity(0.09)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    settings.onboardingVoiceTool == tool
                                        ? Color.accentColor.opacity(0.65)
                                        : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.permissions.title")
            Text("onboarding.permissions.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                permissionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    titleKey: "permission.bluetooth.title",
                    detailKey: "onboarding.permissions.bluetooth.detail",
                    granted: bluetoothAuthorization == .allowedAlways,
                    action: requestBluetoothPermission
                )
                permissionRow(
                    icon: "keyboard",
                    titleKey: "permission.input_monitoring.title",
                    detailKey: "onboarding.permissions.input.detail",
                    granted: inputMonitoringGranted,
                    action: model.requestInputMonitoringPermission
                )
                permissionRow(
                    icon: "hand.point.up.left",
                    titleKey: "permission.accessibility.title",
                    detailKey: "onboarding.permissions.accessibility.detail",
                    granted: accessibilityGranted,
                    action: model.requestAccessibilityPermission
                )
            }
        }
    }

    private var remoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.remote.title")
            Text("onboarding.remote.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            statusCard(
                icon: model.isConnected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right",
                title: model.connectionStatus.text(using: localization),
                detail: localization.text(
                    model.isConnected
                        ? "onboarding.remote.connected_detail"
                        : "onboarding.remote.searching_detail"
                ),
                isComplete: model.isConnected
            )

            statusCard(
                icon: observedRemoteButtons.isEmpty ? "button.programmable" : "checkmark.circle.fill",
                title: localization.text(
                    observedRemoteButtons.isEmpty
                        ? "onboarding.remote.button_waiting"
                        : "onboarding.remote.button_received"
                ),
                detail: localization.text("onboarding.remote.button_detail"),
                isComplete: !observedRemoteButtons.isEmpty
            )

            HStack(spacing: 10) {
                Button("onboarding.remote.reconnect") { model.reconnect() }
                    .buttonStyle(.bordered)
                Button("onboarding.remote.open_bluetooth") { openBluetoothSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.audio.title")
            Text("onboarding.audio.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            statusCard(
                icon: model.hasDoubaoAudioDevice ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass",
                title: model.doubaoAudioStatus.text(using: localization),
                detail: localization.text("onboarding.audio.device_detail"),
                isComplete: model.hasDoubaoAudioDevice
            )

            statusCard(
                icon: compatibleMicrophoneSelected && model.isAudioOutputReady
                    ? "checkmark.circle.fill"
                    : "speaker.wave.2",
                title: localization.text(
                    compatibleMicrophoneSelected
                        ? "onboarding.audio.selected"
                        : "onboarding.audio.select_required"
                ),
                detail: model.audioStatus.text(using: localization),
                isComplete: compatibleMicrophoneSelected && model.isAudioOutputReady
            )

            HStack(spacing: 10) {
                if model.hasDoubaoAudioDevice {
                    Button("audio.compatibility.select_microphone") {
                        model.selectDoubaoAudioDevice()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("audio.compatibility.open_install_guide") {
                        model.openDoubaoDriverInstructions(using: localization)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("onboarding.audio.refresh") { model.refreshAudioDevices() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var voiceTestContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle("onboarding.voice_test.title")
            Text("onboarding.voice_test.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Text(voiceTestEnvironmentText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $transcript)
                    .font(.system(size: 15))
                    .focused($transcriptFocused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                transcriptFocused ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: transcriptFocused ? 1.5 : 1
                            )
                    }

                if transcript.isEmpty {
                    Text("onboarding.voice_test.placeholder")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150, maxHeight: 180)

            HStack(spacing: 12) {
                Image(systemName: voiceSamplesReceived ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 24))
                    .foregroundStyle(voiceSamplesReceived ? Color.accentColor : Color.secondary)
                Text(voiceTestStatusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle("onboarding.controls.title")
            Text("onboarding.controls.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(RemoteButton.allCases) { button in
                    let tested = testedControlButtons.contains(button)
                    HStack(spacing: 8) {
                        Image(systemName: tested ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(tested ? Color.green : Color.secondary)
                        Text(button.displayName(using: localization))
                            .font(.system(size: 12, weight: tested ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(
                        tested ? Color.green.opacity(0.10) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: testedControlButtons.count > index ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(testedControlButtons.count > index ? Color.green : Color.secondary)
                }
                Text(
                    testedControlButtons.count >= 3
                        ? "onboarding.controls.ready"
                        : "onboarding.controls.waiting"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var completeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.green)
            onboardingTitle("onboarding.complete.title")
            Text("onboarding.complete.detail")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                featureLine("mic.fill", "onboarding.complete.voice")
                featureLine("button.programmable", "onboarding.complete.controls")
                featureLine("gearshape", "onboarding.complete.settings")
            }
            .padding(.top, 8)
        }
    }

    private var rightPane: some View {
        ZStack {
            LinearGradient(
                colors: rightPaneGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(rightPaneHighlightColor)
                .frame(width: 360, height: 360)
                .blur(radius: 10)
                .offset(x: 110, y: -210)

            if settings.onboardingStep == .welcome || settings.onboardingStep == .voiceTool {
                welcomeIllustration
            } else if settings.onboardingStep == .complete {
                completeIllustration
            } else {
                remoteIllustration
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeIllustration: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 118, height: 118)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            Image(systemName: "waveform")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("onboarding.illustration.tagline")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var remoteIllustration: some View {
        VStack(spacing: 16) {
            if let remoteImage {
                Image(nsImage: remoteImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 480)
                    .shadow(color: .black.opacity(0.20), radius: 16, y: 10)
            } else {
                Image(systemName: "appletvremote.gen4.fill")
                    .font(.system(size: 180))
                    .foregroundStyle(.secondary)
            }
            sideStatusPanel
        }
        .padding(28)
    }

    private var completeIllustration: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 170, height: 170)
                Image(systemName: "checkmark")
                    .font(.system(size: 74, weight: .bold))
                    .foregroundStyle(Color.green)
            }
            Text("onboarding.complete.illustration")
                .font(.system(size: 18, weight: .semibold))
        }
    }

    @ViewBuilder
    private var sideStatusPanel: some View {
        switch settings.onboardingStep {
        case .permissions:
            sidePanel(titleKey: "onboarding.side.permissions") {
                sideCheck("permission.bluetooth.title", isComplete: bluetoothAuthorization == .allowedAlways)
                sideCheck("permission.input_monitoring.title", isComplete: inputMonitoringGranted)
                sideCheck("permission.accessibility.title", isComplete: accessibilityGranted)
            }
        case .remote:
            sidePanel(titleKey: "onboarding.side.remote") {
                sideCheck("onboarding.side.remote_connected", isComplete: model.isConnected)
                sideCheck("onboarding.side.button_received", isComplete: !observedRemoteButtons.isEmpty)
            }
        case .audio:
            sidePanel(titleKey: "onboarding.side.audio") {
                sideCheck("onboarding.side.device_found", isComplete: model.hasDoubaoAudioDevice)
                sideCheck("onboarding.side.device_selected", isComplete: compatibleMicrophoneSelected)
                sideCheck("onboarding.side.audio_ready", isComplete: model.isAudioOutputReady)
            }
        case .voiceTest:
            sidePanel(titleKey: "onboarding.side.voice_test") {
                sideCheck("onboarding.side.voice_key", isComplete: voiceSessionStarted && voiceSessionEnded)
                sideCheck("onboarding.side.samples", isComplete: voiceSamplesReceived)
                sideCheck("onboarding.side.audio_ready", isComplete: compatibleMicrophoneSelected && model.isAudioOutputReady)
                sideCheck("onboarding.side.transcript", isComplete: transcriptionAppeared)
            }
        case .controls:
            sidePanel(titleKey: "onboarding.side.controls") {
                sideCheck("onboarding.side.three_buttons", isComplete: testedControlButtons.count >= 3)
                sideCheck("onboarding.side.mapping_enabled", isComplete: settings.customMappingEnabled)
            }
        default:
            EmptyView()
        }
    }

    private func sidePanel<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.text(titleKey))
                .font(.system(size: 14, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private func sideCheck(_ titleKey: String, isComplete: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isComplete ? Color.green : Color.accentColor.opacity(0.65))
            Text(localization.text(titleKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }

    private var rightPaneGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.10, green: 0.13, blue: 0.18),
                Color(red: 0.13, green: 0.15, blue: 0.20)
            ]
        }
        return [
            Color(red: 0.91, green: 0.96, blue: 1.0),
            Color(red: 0.97, green: 0.98, blue: 1.0)
        ]
    }

    private var rightPaneHighlightColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.55)
    }

    private func onboardingTitle(_ key: String) -> some View {
        Text(localization.text(key))
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func featureLine(_ icon: String, _ titleKey: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            Text(localization.text(titleKey))
                .font(.system(size: 14, weight: .medium))
        }
    }

    private func permissionRow(
        icon: String,
        titleKey: String,
        detailKey: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 32, height: 32)
                .background((granted ? Color.green : Color.accentColor).opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(localization.text(titleKey))
                    .font(.system(size: 14, weight: .semibold))
                Text(localization.text(detailKey))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.green)
            } else {
                Button("permission.action.request", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(13)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusCard(
        icon: String,
        title: String,
        detail: String,
        isComplete: Bool
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isComplete ? Color.green : Color.accentColor)
                .frame(width: 36, height: 36)
                .background((isComplete ? Color.green : Color.accentColor).opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var currentPhase: OnboardingPhase {
        OnboardingPhase.phase(for: settings.onboardingStep)
    }

    private var capabilities: OnboardingCapabilities {
        OnboardingCapabilities(
            bluetoothGranted: bluetoothAuthorization == .allowedAlways,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            remoteConnected: model.isConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            audioReady: model.isAudioOutputReady,
            compatibleMicrophoneSelected: compatibleMicrophoneSelected,
            voiceSessionStarted: voiceSessionStarted,
            voiceSamplesReceived: voiceSamplesReceived,
            voiceSessionEnded: voiceSessionEnded,
            transcriptionAppeared: transcriptionAppeared,
            testedRemoteButtonCount: testedControlButtons.count
        )
    }

    private var canContinue: Bool {
        OnboardingFlowPolicy.canContinue(
            from: settings.onboardingStep,
            voiceTool: settings.onboardingVoiceTool,
            capabilities: capabilities
        )
    }

    private var compatibleMicrophoneSelected: Bool {
        guard let device = DoubaoAudioDevicePolicy.device(in: model.audioDevices) else { return false }
        return settings.selectedAudioDeviceUID == device.uid
    }

    private var transcriptionAppeared: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var primaryActionKey: String {
        switch settings.onboardingStep {
        case .welcome: return "onboarding.action.start"
        case .complete: return "onboarding.action.open_app"
        default: return "onboarding.action.continue"
        }
    }

    private var voiceTestEnvironmentText: String {
        let tool = localization.text(settings.onboardingVoiceTool.titleKey)
        return "\(tool)  ·  \(DoubaoAudioDevicePolicy.deviceName)"
    }

    private var voiceTestStatusText: String {
        if transcriptionAppeared, voiceSessionEnded {
            return localization.text("onboarding.voice_test.success")
        }
        if voiceSamplesReceived {
            return localization.text("onboarding.voice_test.waiting_text")
        }
        if voiceSessionStarted {
            return localization.text("onboarding.voice_test.receiving")
        }
        return localization.text("onboarding.voice_test.waiting_voice")
    }

    private var remoteImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "RC003-remote-photo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func voiceToolIcon(_ tool: OnboardingVoiceTool) -> String {
        switch tool {
        case .doubao: return "quote.bubble.fill"
        case .typeless: return "waveform.badge.mic"
        case .other: return "ellipsis.circle.fill"
        case .unselected: return "circle"
        }
    }

    private func refreshPermissionStates() {
        bluetoothAuthorization = CBManager.authorization
        inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
        accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    }

    private func prepareForStep(_ step: OnboardingStep) {
        refreshPermissionStates()
        switch step {
        case .remote:
            observedRemoteButtons.removeAll()
            requestedRemoteConnectionRecovery = false
        case .audio:
            model.refreshAudioDevices()
        case .voiceTest:
            voiceSessionStarted = false
            voiceSamplesReceived = false
            voiceSessionEnded = false
            transcript = ""
            DispatchQueue.main.async {
                transcriptFocused = true
            }
        case .controls:
            testedControlButtons.removeAll()
        default:
            break
        }
    }

    private func recoverRemoteConnectionIfNeeded() {
        guard OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: model.isConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            recoveryRequested: requestedRemoteConnectionRecovery
        ) else { return }
        requestedRemoteConnectionRecovery = true
        model.reconnect()
    }

    private func continueFlow() {
        guard canContinue else { return }
        if settings.onboardingStep == .permissions {
            settings.customMappingEnabled = true
            model.setVoiceFnTapModeEnabled(settings.onboardingVoiceTool == .typeless)
        }
        if settings.onboardingStep == .complete {
            settings.completeOnboarding()
            return
        }
        if let next = settings.onboardingStep.next {
            settings.setOnboardingStep(next)
        }
    }

    private func requestBluetoothPermission() {
        model.reconnect()
        if bluetoothAuthorization == .denied || bluetoothAuthorization == .restricted {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
