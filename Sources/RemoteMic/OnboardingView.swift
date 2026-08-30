import AppKit
import Combine
import CoreBluetooth
import CoreImage
import CoreImage.CIFilterBuiltins
import SayAllMacRemoteCore
import SwiftUI

private struct OnboardingInputMethodGuideStep: Identifiable {
    enum Content {
        case screenshot(String)
        case systemFunctionKey
    }

    let id: Int
    let titleKey: String
    let content: Content
}

struct OnboardingView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject private var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme
    private let completeRuntimeReadyOverride: Bool?
    private let allowsInputSourceSwitching: Bool
    private let systemFunctionKeyAvailableOverride: Bool?
    private let voiceToolAvailabilityOverride: [OnboardingVoiceTool: OnboardingVoiceToolAvailability]?

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
    @State private var manualTranscriptInputObserved = false
    @State private var lastRecordedFailure: FirstUseFailureReason?
    @State private var inputSourceSwitchResult: OnboardingInputSourceSwitchResult = .notApplicable
    @State private var voiceToolAvailability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [:]
    @State private var systemFunctionKeyUsage = OnboardingSystemFunctionKeyUsage.current
    @State private var voiceKeyMigrationSource: VoiceKeyMode?
    @State private var selectedInputMethodGuideStep = 0
    @State private var transcriptFocusRequest = 0
    @State private var transcriptEditorMounted = false
    @State private var transcriptWindowKey = false
    @State private var transcriptFirstResponder = false
    @State private var voiceAttempt = FirstUseVoiceAttemptDiagnostic()
    @State private var voiceAttemptStartedAt: Date?
    @State private var voiceTranscriptWaitStartedAt: Date?
    @State private var voiceTranscriptDeadlineToken = UUID()
    @State private var suppressConnectedPhysicalRemoteAutoRouteOnce = false

    private let permissionRefreshTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    init(
        model: BridgeAppModel,
        completeRuntimeReadyOverride: Bool? = nil,
        allowsInputSourceSwitching: Bool = true,
        systemFunctionKeyAvailableOverride: Bool? = nil,
        voiceToolAvailabilityOverride: [OnboardingVoiceTool: OnboardingVoiceToolAvailability]? = nil,
        initialInputMethodGuideStep: Int = 0
    ) {
        self.model = model
        settings = model.settings
        self.completeRuntimeReadyOverride = completeRuntimeReadyOverride
        self.allowsInputSourceSwitching = allowsInputSourceSwitching
        self.systemFunctionKeyAvailableOverride = systemFunctionKeyAvailableOverride
        self.voiceToolAvailabilityOverride = voiceToolAvailabilityOverride
        _selectedInputMethodGuideStep = State(initialValue: initialInputMethodGuideStep)
        _voiceKeyMigrationSource = State(
            initialValue: model.settings.pendingOnboardingVoiceKeyMigration
        )
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
            enforceOnboardingVoiceKeyPolicy()
            refreshPermissionStates()
            refreshVoiceToolAvailability()
            prepareForStep(settings.onboardingStep)
        }
        .onReceive(permissionRefreshTimer) { _ in
            refreshPermissionStates()
            if settings.onboardingStep == .voiceTool {
                refreshSystemFunctionKeyUsage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            switch settings.onboardingStep {
            case .voiceTool:
                refreshVoiceToolAvailability()
                switchToSelectedInputMethod()
                refreshSystemFunctionKeyUsage()
            case .voiceTest:
                requestTranscriptFocus()
            case .remoteAvailability:
                routeConnectedPhysicalRemoteIfNeeded()
            case .remote:
                prepareSelectedControlConnection()
            case .audio:
                model.refreshAudioDevices()
            case .complete:
                prepareSelectedControlConnection()
                model.refreshAudioDevices()
            default:
                break
            }
        }
        .onReceive(model.$isConnected.removeDuplicates()) { isConnected in
            guard isConnected else { return }
            routeConnectedPhysicalRemoteIfNeeded()
        }
        .onReceive(model.$activeRemoteButtons) { buttons in
            guard settings.onboardingControlMethod == .physicalRemote,
                  !buttons.isEmpty else { return }
            if settings.onboardingStep == .remote {
                observedRemoteButtons.formUnion(buttons)
                recoverRemoteConnectionIfNeeded()
            } else if settings.onboardingStep == .controls {
                testedControlButtons.formUnion(buttons)
            }
        }
        .onReceive(model.$lastRemoteButtonPress.compactMap { $0 }) { button in
            guard settings.onboardingControlMethod == .physicalRemote else { return }
            if settings.onboardingStep == .remote {
                observedRemoteButtons.insert(button)
                recoverRemoteConnectionIfNeeded()
            } else if settings.onboardingStep == .controls {
                testedControlButtons.insert(button)
            }
        }
        .onReceive(model.$lastMobileRemoteButtonObservation.compactMap { $0 }) { observation in
            guard selectedControlAccepts(observation.source) else { return }
            if settings.onboardingStep == .remote {
                observedRemoteButtons.insert(observation.button)
            } else if settings.onboardingStep == .controls {
                testedControlButtons.insert(observation.button)
            }
        }
        .onReceive(model.$isStreaming) { isStreaming in
            guard settings.onboardingStep == .voiceTest,
                  selectedControlAcceptsVoice(model.activeVoiceSource) else { return }
            if isStreaming {
                beginVoiceAttempt(triggerPath: model.activeVoiceSource?.rawValue ?? "unknown")
            } else if voiceSessionStarted {
                endVoiceAttempt()
            }
        }
        .onReceive(model.$hasReceivedCurrentVoiceSamples.removeDuplicates()) { hasReceivedSamples in
            guard settings.onboardingStep == .voiceTest,
                  hasReceivedSamples,
                  selectedControlAcceptsVoice(model.activeVoiceSource) else { return }
            voiceSamplesReceived = true
            if voiceAttempt.firstSampleLatencyMilliseconds == nil,
               let voiceAttemptStartedAt {
                voiceAttempt.firstSampleLatencyMilliseconds = elapsedMilliseconds(
                    since: voiceAttemptStartedAt
                )
            }
        }
        .onChange(of: settings.onboardingStep) { step in
            enforceOnboardingVoiceKeyPolicy()
            prepareForStep(step)
        }
        .onChange(of: transcript) { updatedText in
            guard settings.onboardingStep == .voiceTest,
                  !updatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let currentEvent = NSApp.currentEvent
            let currentCGEvent = currentEvent?.cgEvent
            guard OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
                eventTypeRawValue: currentEvent?.type.rawValue,
                sourceStateID: currentCGEvent?.getIntegerValueField(.eventSourceStateID),
                sourceUnixProcessID: currentCGEvent?.getIntegerValueField(
                    .eventSourceUnixProcessID
                )
            ) else { return }
            manualTranscriptInputObserved = true
            AppLogger.shared.write("ONBOARDING TRANSCRIPT manual_keyboard_input=true")
            finishVoiceAttempt(result: .manualInput)
        }
        .onChange(of: transcriptionAppeared) { appeared in
            guard appeared,
                  voiceSessionEnded,
                  !manualTranscriptInputObserved else { return }
            finishVoiceAttempt(result: .passed)
        }
        .onChange(of: failureReason) { failure in
            recordFailureTransition(failure)
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
            if let previous = previousStep {
                Button {
                    goBack(to: previous)
                } label: {
                    Label("onboarding.action.back", systemImage: "arrow.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            } else {
                Color.clear.frame(height: 40)
            }

            VStack(alignment: .leading, spacing: 18) {
                stepContent
                if let failureReason {
                    recoveryCard(for: failureReason)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
        case .remoteAvailability:
            remoteAvailabilityContent
        case .controlMethod:
            controlMethodContent
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

            onboardingVoiceKeyMigrationNotice

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

            onboardingVoiceKeyMigrationNotice

            if allRecognizedVoiceToolsUnavailable {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Text("onboarding.voice_tool.none_detected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 10
            ) {
                ForEach(visibleVoiceTools) { tool in
                    Button {
                        selectVoiceTool(tool)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: voiceToolIcon(tool))
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(localization.text(tool.titleKey))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(localization.text(tool.detailKey))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(4, reservesSpace: true)
                                if tool == .doubao,
                                   voiceToolAvailability[tool] == .notInstalled {
                                    Text("onboarding.voice_tool.status.not_installed")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: settings.onboardingVoiceTool == tool ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(settings.onboardingVoiceTool == tool ? Color.accentColor : Color.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 112, alignment: .top)
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

            if voiceToolAvailability[.doubao] == .notInstalled {
                HStack(spacing: 8) {
                    Text("onboarding.voice_tool.doubao.install_detail")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link(
                        "onboarding.voice_tool.doubao.install",
                        destination: AppLinks.doubaoInputMethod
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.onboardingVoiceTool == .other {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.badge.xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("onboarding.voice_tool.other.setup_detail")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                }
            }

            if settings.onboardingVoiceTool != .unselected {
                onboardingVoiceKeyControl
            }
        }
    }

    private var onboardingVoiceKeyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("connection.voice_key_mode.title")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text(
                    settings.onboardingVoiceTool == .typeless
                        ? "onboarding.voice_tool.typeless.fn_required"
                        : "onboarding.voice_tool.fn_only"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Text(
                LocalizedMessage(
                    "onboarding.voice_tool.voice_key_help",
                    arguments: [
                        localization.text("connection.voice_key.mode.fn"),
                    ]
                ).text(using: localization)
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var onboardingVoiceKeyMigrationNotice: some View {
        if let voiceKeyMigrationSource {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        LocalizedMessage(
                            "onboarding.voice_key.migration.title",
                            arguments: [localization.text(voiceKeyMigrationSource.localizationKey)]
                        ).text(using: localization)
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    Text("onboarding.voice_key.migration.detail")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private var remoteAvailabilityContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.remote_availability.title")
            Text("onboarding.remote_availability.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach([
                    OnboardingRemoteAvailability.hasRemote,
                    .noRemote,
                ]) { availability in
                    Button {
                        selectRemoteAvailability(availability)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: remoteAvailabilityIcon(availability))
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 46, height: 46)
                                .background(
                                    Color.accentColor.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )

                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(localization.text(availability.titleKey))
                                        .font(.system(size: 16, weight: .semibold))
                                    if availability == .hasRemote {
                                        Text("onboarding.remote_availability.recommended")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                                    }
                                }
                                Text(localization.text(availability.detailKey))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Image(systemName: settings.onboardingRemoteAvailability == availability
                                ? "checkmark.circle.fill"
                                : "circle")
                                .font(.system(size: 19))
                                .foregroundStyle(
                                    settings.onboardingRemoteAvailability == availability
                                        ? Color.accentColor
                                        : Color.secondary
                                )
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                        .background(
                            settings.onboardingRemoteAvailability == availability
                                ? Color.accentColor.opacity(0.09)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    settings.onboardingRemoteAvailability == availability
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

    private var controlMethodContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.control_method.title")
            Text("onboarding.control_method.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach([
                    OnboardingControlMethod.iPhoneApp,
                    .webRemote,
                ]) { method in
                    Button {
                        selectControlMethod(method)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: controlMethodIcon(method))
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 38, height: 38)
                                .background(
                                    Color.accentColor.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(localization.text(method.titleKey))
                                        .font(.system(size: 15, weight: .semibold))
                                    if method == .iPhoneApp {
                                        Text("onboarding.control_method.recommended")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.accentColor.opacity(0.10),
                                                in: Capsule()
                                            )
                                    } else if method == .webRemote {
                                        Text("onboarding.control_method.no_iphone")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(localization.text(method.detailKey))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Image(systemName: settings.onboardingControlMethod == method
                                ? "checkmark.circle.fill"
                                : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(
                                    settings.onboardingControlMethod == method
                                        ? Color.accentColor
                                        : Color.secondary
                                )
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                        .background(
                            settings.onboardingControlMethod == method
                                ? Color.accentColor.opacity(0.09)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    settings.onboardingControlMethod == method
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

    private func inputMethodGuide(for tool: OnboardingVoiceTool) -> some View {
        let steps = inputMethodGuideSteps(for: tool)
        let selectedIndex = min(selectedInputMethodGuideStep, max(0, steps.count - 1))
        let selectedStep = steps[selectedIndex]

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localization.text("onboarding.voice_tool.guide.title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(localization.text("onboarding.voice_tool.guide.detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputSourceSwitchStatus(for: tool)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 8
            ) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        selectedInputMethodGuideStep = index
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(step.id)")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 22, height: 22)
                                .background(
                                    selectedIndex == index
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.08),
                                    in: Circle()
                                )
                                .foregroundStyle(selectedIndex == index ? Color.white : Color.primary)
                            Text(localization.text(step.titleKey))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2, reservesSpace: true)
                            Spacer(minLength: 0)
                            if step.id == 3 {
                                Image(systemName: systemFunctionKeyAvailable
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(systemFunctionKeyAvailable ? Color.green : Color.orange)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 54)
                        .background(
                            selectedIndex == index
                                ? Color.accentColor.opacity(0.09)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selectedIndex == index
                                        ? Color.accentColor.opacity(0.55)
                                        : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            switch selectedStep.content {
            case let .screenshot(resourceName):
                onboardingGuideScreenshot(resourceName: resourceName)
            case .systemFunctionKey:
                systemFunctionKeyInstruction
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func inputSourceSwitchStatus(for tool: OnboardingVoiceTool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: inputSourceSwitchResult == .selected ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(inputSourceSwitchResult == .selected ? Color.green : Color.accentColor)

            Text(inputSourceSwitchStatusText(for: tool))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if inputSourceSwitchResult == .unavailable || inputSourceSwitchResult == .failed {
                Button("onboarding.voice_tool.switch.retry") {
                    switchToSelectedInputMethod()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func onboardingGuideScreenshot(resourceName: String) -> some View {
        Group {
            if let image = onboardingGuideImage(resourceName: resourceName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            } else {
                Text("onboarding.voice_tool.guide.image_missing")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var systemFunctionKeyInstruction: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingGuideScreenshot(resourceName: "system-fn")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemFunctionKeyAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(systemFunctionKeyAvailable ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text(
                        systemFunctionKeyAvailable
                            ? "onboarding.voice_tool.system_fn.ready"
                            : "onboarding.voice_tool.system_fn.conflict"
                    ))
                    .font(.system(size: 14, weight: .semibold))
                    Text("onboarding.voice_tool.system_fn.detail")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !systemFunctionKeyAvailable {
                    Button("onboarding.voice_tool.system_fn.open_settings") {
                        openKeyboardSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.permissions.title")
            Text("onboarding.permissions.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                if settings.onboardingControlMethod.requiresBluetoothPermission {
                    permissionRow(
                        icon: "antenna.radiowaves.left.and.right",
                        titleKey: "permission.bluetooth.title",
                        detailKey: "onboarding.permissions.bluetooth.detail",
                        granted: bluetoothAuthorization == .allowedAlways,
                        action: requestBluetoothPermission
                    )
                }
                if settings.onboardingControlMethod.requiresInputMonitoringPermission {
                    permissionRow(
                        icon: "keyboard",
                        titleKey: "permission.input_monitoring.title",
                        detailKey: "onboarding.permissions.input.detail",
                        granted: inputMonitoringGranted,
                        action: model.requestInputMonitoringPermission
                    )
                }
                permissionRow(
                    icon: "hand.point.up.left",
                    titleKey: "permission.accessibility.title",
                    detailKey: "onboarding.permissions.accessibility.detail",
                    granted: accessibilityGranted,
                    action: model.requestAccessibilityPermission
                )
            }

            if settings.onboardingControlMethod.usesOnDemandAudioOutput {
                statusCard(
                    icon: "network",
                    title: localization.text("onboarding.permissions.mobile_network.title"),
                    detail: localization.text("onboarding.permissions.mobile_network.detail"),
                    isComplete: true
                )
            }
        }
    }

    @ViewBuilder
    private var remoteContent: some View {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            physicalRemoteContent
        case .iPhoneApp:
            iPhoneRemoteContent
        case .webRemote:
            webRemoteContent
        case .unselected:
            remoteAvailabilityContent
        }
    }

    private var physicalRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.remote.title")
            Text("onboarding.remote.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text(localization.text("onboarding.remote.first_pairing.title"))
                    .font(.system(size: 14, weight: .semibold))

                Label {
                    Text(localization.text("onboarding.remote.first_pairing.wake"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                Label {
                    Text(localization.text("onboarding.remote.first_pairing.pair"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.system(size: 12))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            }

            statusCard(
                icon: selectedControlConnected
                    ? "checkmark.circle.fill"
                    : "dot.radiowaves.left.and.right",
                title: !model.isConnected && selectedControlConnected
                    ? localization.text("onboarding.remote.hid_connected")
                    : model.connectionStatus.text(using: localization),
                detail: localization.text(
                    model.isConnected
                        ? "onboarding.remote.connected_detail"
                        : selectedControlConnected
                            ? "onboarding.remote.hid_connected_detail"
                            : "onboarding.remote.searching_detail"
                ),
                isComplete: selectedControlConnected
            )

            statusCard(
                icon: observedRemoteButtons.isEmpty ? "button.programmable" : "checkmark.circle.fill",
                title: localization.text(
                    observedRemoteButtons.isEmpty
                        ? "onboarding.remote.button_waiting"
                        : "onboarding.remote.button_received"
                ),
                detail: observedRemoteButtons.isEmpty
                    ? model.hidStatus.text(using: localization)
                    : localization.text("onboarding.remote.button_detail"),
                isComplete: !observedRemoteButtons.isEmpty
            )

            if !selectedControlConnected {
                openBluetoothSettingsButton
            }
        }
    }

    private var iPhoneRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.iphone_remote.title")
            Text("onboarding.iphone_remote.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: AppLinks.testFlightPublicBeta) {
                Label("onboarding.iphone_remote.install", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)

            statusCard(
                icon: model.isPhoneRemoteConnected
                    ? "checkmark.circle.fill"
                    : "iphone.radiowaves.left.and.right",
                title: localization.text(
                    model.isPhoneRemoteConnected
                        ? "onboarding.iphone_remote.connected"
                        : "onboarding.iphone_remote.waiting"
                ),
                detail: localization.text("onboarding.iphone_remote.connection_detail"),
                isComplete: model.isPhoneRemoteConnected
            )

            controllerButtonStatusCard(
                waitingDetailKey: "onboarding.iphone_remote.button_detail"
            )
        }
    }

    private var webRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.web_remote.title")
            Text("onboarding.web_remote.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusCard(
                icon: webRemoteConnected
                    ? "checkmark.circle.fill"
                    : "qrcode.viewfinder",
                title: webRemoteConnectionTitle,
                detail: localization.text("onboarding.web_remote.connection_detail"),
                isComplete: webRemoteConnected
            )

            controllerButtonStatusCard(
                waitingDetailKey: "onboarding.web_remote.button_detail"
            )

            if !model.webRemoteState.isEnabled {
                Button("onboarding.web_remote.retry") {
                    model.enableWebRemoteConnection()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func controllerButtonStatusCard(waitingDetailKey: String) -> some View {
        statusCard(
            icon: observedRemoteButtons.isEmpty
                ? "button.programmable"
                : "checkmark.circle.fill",
            title: localization.text(
                observedRemoteButtons.isEmpty
                    ? "onboarding.remote.button_waiting"
                    : "onboarding.remote.button_received"
            ),
            detail: localization.text(
                observedRemoteButtons.isEmpty
                    ? waitingDetailKey
                    : "onboarding.remote.button_detail"
            ),
            isComplete: !observedRemoteButtons.isEmpty
        )
    }

    private var openBluetoothSettingsButton: some View {
        Button("onboarding.remote.open_bluetooth") { openBluetoothSettings() }
            .buttonStyle(.bordered)
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.audio.title")
            Text("onboarding.audio.detail")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if supportedAudioDevices.isEmpty {
                statusCard(
                    icon: "waveform.badge.magnifyingglass",
                    title: localization.text("onboarding.audio.no_devices"),
                    detail: localization.text("onboarding.audio.device_detail"),
                    isComplete: false
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(supportedAudioDevices, id: \.uid) { device in
                        audioDeviceRow(device)
                    }
                }
            }

            statusCard(
                icon: onboardingAudioReady
                    ? "checkmark.circle.fill"
                    : "speaker.wave.2",
                title: selectedAudioDeviceTitle,
                detail: selectedAudioDeviceDetail,
                isComplete: onboardingAudioReady
            )

            if failureReason == .audioNoOutputDevice ||
                failureReason == .audioSelectedDeviceMissing {
                Button("audio.compatibility.open_install_guide") {
                    model.openDoubaoDriverInstructions(using: localization)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func audioDeviceRow(_ device: AudioDeviceInfo) -> some View {
        let isSelected = settings.selectedAudioDeviceUID == device.uid
        return Button {
            settings.selectedAudioDeviceUID = device.uid
            model.applyAudioSettings(reason: "onboarding_audio_device_selected")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(
                isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
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

            if settings.onboardingVoiceTool == .other {
                Label {
                    Text(LocalizedMessage(
                        "onboarding.voice_test.other_detail",
                        arguments: [
                            localization.text(settings.onboardingVoiceTool.titleKey),
                            selectedAudioDevice?.name ?? localization.text("onboarding.audio.select_required")
                        ]
                    ).text(using: localization))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }

            ZStack(alignment: .topLeading) {
                OnboardingTranscriptEditor(
                    text: $transcript,
                    focusRequest: transcriptFocusRequest,
                    isActive: settings.onboardingStep == .voiceTest
                ) { snapshot in
                    updateTranscriptFocus(snapshot)
                }
                .onAppear {
                    requestTranscriptFocus()
                }
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            transcriptFirstResponder
                                ? Color.accentColor
                                : Color.primary.opacity(0.12),
                            lineWidth: transcriptFirstResponder ? 1.5 : 1
                        )
                }

                if transcript.isEmpty {
                    Text("onboarding.voice_test.placeholder")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
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

            if !canContinue {
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    title: localization.text("onboarding.complete.runtime_changed"),
                    detail: localization.text("onboarding.complete.runtime_changed_detail"),
                    isComplete: false
                )
            }
        }
    }

    private func recoveryCard(for failure: FirstUseFailureReason) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text("onboarding.recovery.\(failure.rawValue).title"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(localization.text("onboarding.recovery.\(failure.rawValue).detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button {
                    performRecovery(for: failure)
                } label: {
                    Text(localization.text("onboarding.recovery.\(failure.rawValue).action"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                Button("onboarding.diagnostics.copy") {
                    copyDiagnosticSummary()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
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

            if settings.onboardingStep == .voiceTool,
               settings.onboardingVoiceTool.requiresFunctionKeySetup {
                inputMethodGuide(for: settings.onboardingVoiceTool)
                    .frame(maxWidth: 440)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if settings.onboardingStep == .welcome || settings.onboardingStep == .voiceTool {
                welcomeIllustration
            } else if settings.onboardingStep == .remoteAvailability {
                remoteAvailabilityIllustration
            } else if settings.onboardingStep == .controlMethod {
                controlMethodIllustration
            } else if settings.onboardingStep == .complete {
                completeIllustration
            } else {
                selectedControlIllustration
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

    private var controlMethodIllustration: some View {
        VStack(spacing: 26) {
            HStack(spacing: 38) {
                Image(systemName: "iphone")
                Image(systemName: "safari.fill")
            }
            .font(.system(size: 58, weight: .medium))
            .foregroundStyle(Color.accentColor)
            Text("onboarding.control_method.illustration")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var remoteAvailabilityIllustration: some View {
        VStack(spacing: 24) {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 150, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("onboarding.remote_availability.illustration")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedControlIllustration: some View {
        switch settings.onboardingControlMethod {
        case .physicalRemote, .unselected:
            remoteIllustration
        case .iPhoneApp:
            iPhoneRemoteIllustration
        case .webRemote:
            webRemoteIllustration
        }
    }

    private var iPhoneRemoteIllustration: some View {
        VStack(spacing: 18) {
            if !model.isPhoneRemoteConnected,
               let invitation = model.phoneRemoteInvitation,
               let qrCode = PhoneRemoteInvitationQRCode.image(for: invitation) {
                Image(nsImage: qrCode)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                Text("onboarding.iphone_remote.scan")
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: model.isPhoneRemoteConnected
                    ? "iphone.gen3.radiowaves.left.and.right"
                    : "iphone.gen3")
                    .font(.system(size: 150, weight: .light))
                    .foregroundStyle(
                        model.isPhoneRemoteConnected ? Color.green : Color.accentColor
                    )
            }
            sideStatusPanel
        }
        .padding(28)
    }

    @ViewBuilder
    private var webRemoteIllustration: some View {
        VStack(spacing: 16) {
            switch model.webRemoteState {
            case let .waitingForPhone(joinURL, pairingCode, _),
                 let .awaitingApproval(joinURL, pairingCode, _):
                if let qrCode = webRemoteQRCode(for: joinURL) {
                    Image(nsImage: qrCode)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 250, height: 250)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                }
                Text("onboarding.web_remote.scan")
                    .font(.system(size: 15, weight: .semibold))
                Text(pairingCode.map(String.init).joined(separator: " "))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
            case let .connected(deviceName):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Color.green)
                Text(deviceName)
                    .font(.system(size: 16, weight: .semibold))
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                Text("onboarding.web_remote.connecting")
                    .font(.system(size: 15, weight: .semibold))
            case .unavailable, .failed:
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 82))
                    .foregroundStyle(Color.orange)
                Text("onboarding.web_remote.unavailable")
                    .font(.system(size: 15, weight: .semibold))
            case .disabled:
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 100))
                    .foregroundStyle(Color.accentColor)
                Text("onboarding.web_remote.preparing")
                    .font(.system(size: 15, weight: .semibold))
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
                if settings.onboardingControlMethod.requiresBluetoothPermission {
                    sideCheck(
                        "permission.bluetooth.title",
                        isComplete: bluetoothAuthorization == .allowedAlways
                    )
                }
                if settings.onboardingControlMethod.requiresInputMonitoringPermission {
                    sideCheck(
                        "permission.input_monitoring.title",
                        isComplete: inputMonitoringGranted
                    )
                }
                sideCheck("permission.accessibility.title", isComplete: accessibilityGranted)
            }
        case .remote:
            sidePanel(titleKey: "onboarding.side.remote") {
                sideCheck(
                    selectedControlConnectedKey,
                    isComplete: selectedControlConnected
                )
                sideCheck("onboarding.side.button_received", isComplete: !observedRemoteButtons.isEmpty)
            }
        case .audio:
            sidePanel(titleKey: "onboarding.side.audio") {
                sideCheck("onboarding.side.device_found", isComplete: !supportedAudioDevices.isEmpty)
                sideCheck("onboarding.side.device_selected", isComplete: audioOutputSelected)
                sideCheck(
                    settings.onboardingControlMethod.usesOnDemandAudioOutput
                        ? "onboarding.side.audio_on_demand"
                        : "onboarding.side.audio_ready",
                    isComplete: onboardingAudioReady
                )
            }
        case .voiceTest:
            sidePanel(titleKey: "onboarding.side.voice_test") {
                sideCheck("onboarding.side.voice_key", isComplete: voiceSessionStarted && voiceSessionEnded)
                sideCheck("onboarding.side.samples", isComplete: voiceSamplesReceived)
                sideCheck(
                    settings.onboardingControlMethod.usesOnDemandAudioOutput
                        ? "onboarding.side.audio_on_demand"
                        : "onboarding.side.audio_ready",
                    isComplete: onboardingAudioReady
                )
                sideCheck("onboarding.side.transcript", isComplete: verifiedTranscriptionAppeared)
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
        Button(action: action) {
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
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(granted ? Color.green : Color.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
            systemFunctionKeyAvailable: systemFunctionKeyAvailable,
            bluetoothGranted: bluetoothAuthorization == .allowedAlways,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            remoteConnected: selectedControlConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            audioReady: model.isAudioOutputReady,
            audioOutputSelected: audioOutputSelected,
            voiceSessionStarted: voiceSessionStarted,
            voiceSamplesReceived: voiceSamplesReceived,
            voiceSessionEnded: voiceSessionEnded,
            transcriptionAppeared: transcriptionAppeared,
            manualTranscriptInputObserved: manualTranscriptInputObserved,
            testedRemoteButtonCount: testedControlButtons.count
        )
    }

    private var canContinue: Bool {
        if settings.onboardingStep == .complete,
           let completeRuntimeReadyOverride {
            return completeRuntimeReadyOverride
        }
        let policyAllowsContinue = OnboardingFlowPolicy.canContinue(
            from: settings.onboardingStep,
            voiceTool: settings.onboardingVoiceTool,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            voiceKeyMode: settings.voiceKeyMode,
            capabilities: capabilities
        )
        if settings.onboardingStep == .voiceTest {
            return policyAllowsContinue && voiceAttempt.phase == .passed
        }
        return policyAllowsContinue &&
            (settings.onboardingStep != .voiceTool || voiceToolSelectionIsValid)
    }

    private var visibleVoiceTools: [OnboardingVoiceTool] {
        var tools: [OnboardingVoiceTool] = [.doubao]
        if voiceToolAvailability[.weixin] == .available {
            tools.append(.weixin)
        }
        if voiceToolAvailability[.typeless] == .available {
            tools.append(.typeless)
        }
        tools.append(.other)
        return tools
    }

    private var allRecognizedVoiceToolsUnavailable: Bool {
        [OnboardingVoiceTool.doubao, .weixin, .typeless].allSatisfy {
            voiceToolAvailability[$0] == .notInstalled
        }
    }

    private var voiceToolSelectionIsValid: Bool {
        switch settings.onboardingVoiceTool {
        case .unselected:
            return false
        case .other:
            return true
        case .doubao, .weixin, .typeless:
            return voiceToolAvailability[settings.onboardingVoiceTool] == .available
        }
    }

    private var diagnosticContext: FirstUseDiagnosticContext {
        FirstUseDiagnosticContext(
            step: settings.onboardingStep,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            capabilities: capabilities,
            hasSelectedAudioUID: !settings.selectedAudioDeviceUID.isEmpty,
            voiceAttempt: settings.onboardingStep == .voiceTest ? voiceAttempt : nil
        )
    }

    private var failureReason: FirstUseFailureReason? {
        if settings.onboardingStep == .complete,
           let completeRuntimeReadyOverride,
           completeRuntimeReadyOverride {
            return nil
        }
        return diagnosticContext.failureReason
    }

    private var supportedAudioDevices: [AudioDeviceInfo] {
        model.audioDevices.filter { device in
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: device.uid, name: device.name)
        }
    }

    private var selectedAudioDevice: AudioDeviceInfo? {
        supportedAudioDevices.first { $0.uid == settings.selectedAudioDeviceUID }
    }

    private var audioOutputSelected: Bool {
        OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: settings.selectedAudioDeviceUID,
            availableSupportedUIDs: supportedAudioDevices.lazy.map(\.uid)
        )
    }

    private var onboardingAudioReady: Bool {
        audioOutputSelected &&
            (settings.onboardingControlMethod.usesOnDemandAudioOutput || model.isAudioOutputReady)
    }

    private var selectedAudioDeviceTitle: String {
        guard let selectedAudioDevice else {
            return localization.text("onboarding.audio.select_required")
        }
        return LocalizedMessage(
            "onboarding.audio.selected",
            arguments: [selectedAudioDevice.name]
        ).text(using: localization)
    }

    private var selectedAudioDeviceDetail: String {
        guard audioOutputSelected else {
            return localization.text("onboarding.audio.select_detail")
        }
        if settings.onboardingControlMethod.usesOnDemandAudioOutput,
           !model.isAudioOutputReady {
            return localization.text("onboarding.audio.on_demand_detail")
        }
        return model.audioStatus.text(using: localization)
    }

    private var transcriptionAppeared: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var verifiedTranscriptionAppeared: Bool {
        transcriptionAppeared && !manualTranscriptInputObserved
    }

    private var selectedControlConnected: Bool {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            return OnboardingFlowPolicy.isPhysicalRemoteRecognized(
                at: settings.onboardingStep,
                voiceConnectionReady: model.isConnected,
                validatedHIDButtonObserved: !observedRemoteButtons.isEmpty
            )
        case .iPhoneApp:
            return model.isPhoneRemoteConnected
        case .webRemote:
            return webRemoteConnected
        case .unselected:
            return false
        }
    }

    private var webRemoteConnected: Bool {
        if case .connected = model.webRemoteState { return true }
        return false
    }

    private var webRemoteConnectionTitle: String {
        switch model.webRemoteState {
        case .connected:
            return localization.text("onboarding.web_remote.connected")
        case .unavailable, .failed:
            return localization.text("onboarding.web_remote.unavailable")
        case .connecting:
            return localization.text("onboarding.web_remote.connecting")
        case .disabled:
            return localization.text("onboarding.web_remote.preparing")
        case .waitingForPhone, .awaitingApproval:
            return localization.text("onboarding.web_remote.waiting")
        }
    }

    private var selectedControlConnectedKey: String {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            return "onboarding.side.remote_connected"
        case .iPhoneApp:
            return "onboarding.side.iphone_connected"
        case .webRemote:
            return "onboarding.side.web_connected"
        case .unselected:
            return "onboarding.side.control_selected"
        }
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
        let device = selectedAudioDevice?.name ?? localization.text("onboarding.audio.select_required")
        return "\(tool)  ·  \(device)"
    }

    private var voiceTestStatusText: String {
        if manualTranscriptInputObserved {
            return localization.text("onboarding.voice_test.manual_input")
        }
        if verifiedTranscriptionAppeared, voiceSessionEnded {
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
        case .weixin: return "message.fill"
        case .typeless: return "waveform.badge.mic"
        case .other: return "ellipsis.circle.fill"
        case .unselected: return "circle"
        }
    }

    private func controlMethodIcon(_ method: OnboardingControlMethod) -> String {
        switch method {
        case .physicalRemote: return "appletvremote.gen4.fill"
        case .iPhoneApp: return "iphone"
        case .webRemote: return "safari.fill"
        case .unselected: return "circle"
        }
    }

    private func remoteAvailabilityIcon(_ availability: OnboardingRemoteAvailability) -> String {
        switch availability {
        case .hasRemote: return "appletvremote.gen4.fill"
        case .noRemote: return "iphone.and.arrow.forward"
        case .unselected: return "circle"
        }
    }

    private var systemFunctionKeyAvailable: Bool {
        systemFunctionKeyAvailableOverride ?? (systemFunctionKeyUsage == .available)
    }

    private func inputMethodGuideSteps(
        for tool: OnboardingVoiceTool
    ) -> [OnboardingInputMethodGuideStep] {
        let inputMethodSteps: [OnboardingInputMethodGuideStep]
        switch tool {
        case .doubao:
            inputMethodSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.select_doubao",
                    content: .screenshot("doubao-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_doubao",
                    content: .screenshot("doubao-settings")
                ),
            ]
        case .weixin:
            inputMethodSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.select_weixin",
                    content: .screenshot("weixin-input-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_weixin",
                    content: .screenshot("weixin-input-settings")
                ),
            ]
        case .unselected, .typeless, .other:
            return []
        }

        return inputMethodSteps + [
            OnboardingInputMethodGuideStep(
                id: 3,
                titleKey: "onboarding.voice_tool.guide.release_system_fn",
                content: .systemFunctionKey
            ),
            OnboardingInputMethodGuideStep(
                id: 4,
                titleKey: "onboarding.voice_tool.guide.release_wechat_fn",
                content: .screenshot("weixin-app-shortcuts")
            ),
        ]
    }

    private func onboardingGuideImage(resourceName: String) -> NSImage? {
        let appearance = colorScheme == .dark ? "dark" : "light"
        guard let url = Bundle.main.url(
            forResource: "\(resourceName)-\(appearance)",
            withExtension: "png",
            subdirectory: "Onboarding"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func selectVoiceTool(_ tool: OnboardingVoiceTool) {
        settings.setOnboardingVoiceTool(tool)
        AppLogger.shared.write(
            "ONBOARDING VOICE_TOOL selected=\(tool.rawValue) voice_key_policy=fn_only"
        )
        selectedInputMethodGuideStep = 0
        switchToSelectedInputMethod()
        refreshSystemFunctionKeyUsage()
    }

    private func enforceOnboardingVoiceKeyPolicy() {
        if let pending = settings.consumePendingOnboardingVoiceKeyMigration() {
            voiceKeyMigrationSource = pending
        }
        guard settings.voiceKeyMode != .function else { return }
        let previousMode = settings.voiceKeyMode.rawValue
        voiceKeyMigrationSource = settings.voiceKeyMode
        AppLogger.shared.write(
            "ONBOARDING VOICE_KEY_POLICY requested from=\(previousMode) to=fn policy=fn_only"
        )
        model.setVoiceKeyMode(.function)
        AppLogger.shared.write(
            "ONBOARDING VOICE_KEY_POLICY result=\(settings.voiceKeyMode == .function ? "applied" : "blocked") " +
                "voice_key_mode=\(settings.voiceKeyMode.rawValue) policy=fn_only"
        )
    }

    private func refreshVoiceToolAvailability() {
        if let voiceToolAvailabilityOverride {
            voiceToolAvailability = voiceToolAvailabilityOverride
            return
        }
        var availability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [:]
        for tool in [OnboardingVoiceTool.doubao, .weixin, .typeless] {
            availability[tool] = OnboardingInputSourceSwitcher.availability(for: tool)
        }
        voiceToolAvailability = availability

        let selected = settings.onboardingVoiceTool
        if [.weixin, .typeless].contains(selected),
           availability[selected] == .notInstalled {
            settings.setOnboardingVoiceTool(.unselected)
        }
    }

    private func selectRemoteAvailability(_ availability: OnboardingRemoteAvailability) {
        guard settings.onboardingRemoteAvailability != availability else { return }
        settings.setOnboardingRemoteAvailability(availability)
        switch availability {
        case .hasRemote:
            selectControlMethod(.physicalRemote)
        case .noRemote:
            selectControlMethod(.unselected)
        case .unselected:
            break
        }
    }

    private func selectControlMethod(_ method: OnboardingControlMethod) {
        guard settings.onboardingControlMethod != method else { return }
        if settings.onboardingControlMethod == .iPhoneApp {
            model.disablePhoneRemoteConnection()
        } else if settings.onboardingControlMethod == .webRemote {
            model.disableWebRemoteConnection()
        }
        settings.setOnboardingControlMethod(method)
        observedRemoteButtons.removeAll()
        testedControlButtons.removeAll()
    }

    private func switchToSelectedInputMethod() {
        guard settings.onboardingStep == .voiceTool else { return }
        let tool = settings.onboardingVoiceTool
        guard tool.requiresFunctionKeySetup else {
            inputSourceSwitchResult = .notApplicable
            return
        }
        guard allowsInputSourceSwitching else {
            inputSourceSwitchResult = .selected
            return
        }

        inputSourceSwitchResult = OnboardingInputSourceSwitcher.selectIfNeeded(tool)
        AppLogger.shared.write(
            "ONBOARDING INPUT SOURCE tool=\(tool.rawValue) result=\(inputSourceSwitchResult.rawValue)"
        )
    }

    private func inputSourceSwitchStatusText(for tool: OnboardingVoiceTool) -> String {
        let toolName = localization.text(tool.titleKey)
        let key: String
        switch inputSourceSwitchResult {
        case .selected:
            key = "onboarding.voice_tool.switch.selected"
        case .unavailable:
            key = "onboarding.voice_tool.switch.unavailable"
        case .failed:
            key = "onboarding.voice_tool.switch.failed"
        case .notApplicable:
            key = "onboarding.voice_tool.switch.waiting"
        }
        return LocalizedMessage(key, arguments: [toolName]).text(using: localization)
    }

    private func refreshSystemFunctionKeyUsage() {
        guard systemFunctionKeyAvailableOverride == nil else { return }
        systemFunctionKeyUsage = OnboardingSystemFunctionKeyUsage.current
    }

    private func refreshPermissionStates() {
        bluetoothAuthorization = CBManager.authorization
        inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
        accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    }

    private func prepareForStep(_ step: OnboardingStep) {
        refreshPermissionStates()
        switch step {
        case .voiceTool:
            refreshVoiceToolAvailability()
            switchToSelectedInputMethod()
            refreshSystemFunctionKeyUsage()
        case .remoteAvailability:
            routeConnectedPhysicalRemoteIfNeeded()
        case .remote:
            observedRemoteButtons.removeAll()
            requestedRemoteConnectionRecovery = false
            prepareSelectedControlConnection()
        case .audio:
            model.refreshAudioDevices()
        case .voiceTest:
            resetVoiceTestForRetry()
        case .controls:
            testedControlButtons.removeAll()
        case .complete:
            prepareSelectedControlConnection()
            model.refreshAudioDevices()
        default:
            break
        }
        AppLogger.shared.write("ONBOARDING STEP entered=\(step.rawValue)")
        settings.recordFirstUseEvent(.entered, step: step)
        lastRecordedFailure = nil
        DispatchQueue.main.async {
            recordFailureTransition(failureReason)
        }
    }

    private func recordFailureTransition(_ failure: FirstUseFailureReason?) {
        guard settings.onboardingStep != .voiceTest else { return }
        if let failure {
            guard failure != lastRecordedFailure else { return }
            if let previousFailure = lastRecordedFailure {
                settings.recordFirstUseEvent(
                    .recovered,
                    step: settings.onboardingStep,
                    failureReason: previousFailure
                )
            }
            settings.recordFirstUseEvent(.blocked, step: settings.onboardingStep, failureReason: failure)
        } else if let previousFailure = lastRecordedFailure {
            settings.recordFirstUseEvent(
                .recovered,
                step: settings.onboardingStep,
                failureReason: previousFailure
            )
            settings.recordFirstUseEvent(.passed, step: settings.onboardingStep)
        }
        lastRecordedFailure = failure
    }

    private func performRecovery(for failure: FirstUseFailureReason) {
        settings.recordFirstUseEvent(
            .retry,
            step: settings.onboardingStep,
            failureReason: failure
        )
        switch failure {
        case .bluetoothPermissionDenied:
            requestBluetoothPermission()
        case .inputMonitoringPermissionDenied:
            model.requestInputMonitoringPermission()
        case .accessibilityPermissionDenied:
            model.requestAccessibilityPermission()
        case .remoteNotFound:
            prepareSelectedControlConnection()
        case .remoteButtonNotReady, .controlsNotConfirmed:
            if settings.onboardingControlMethod == .physicalRemote {
                model.applyHIDSettings()
            } else {
                prepareSelectedControlConnection()
            }
        case .audioNoOutputDevice, .audioSelectedDeviceMissing:
            model.refreshAudioDevices()
        case .audioOutputNotReady:
            model.applyAudioSettings(reason: "onboarding_recovery")
        case .voiceSessionNotStarted,
             .voiceSessionNotEnded,
             .voiceManualInput,
             .voiceNoTranscript,
             .voiceInputTargetNotReady,
             .voiceInputTargetFocusLost,
             .voiceExternalToolNoCommit:
            resetVoiceTestForRetry()
        case .voiceNoSamples:
            model.applyAudioSettings(reason: "onboarding_voice_retry")
            resetVoiceTestForRetry()
        case .completeRuntimeRegressed:
            guard let recoveryStep = OnboardingFlowPolicy.recoveryStep(
                from: .complete,
                voiceTool: settings.onboardingVoiceTool,
                remoteAvailability: settings.onboardingRemoteAvailability,
                controlMethod: settings.onboardingControlMethod,
                capabilities: capabilities,
                hasSelectedAudioUID: !settings.selectedAudioDeviceUID.isEmpty
            ) else { return }
            settings.setOnboardingStep(recoveryStep)
        }
    }

    private func resetVoiceTestForRetry() {
        voiceTranscriptDeadlineToken = UUID()
        voiceAttemptStartedAt = nil
        voiceTranscriptWaitStartedAt = nil
        voiceSessionStarted = false
        voiceSamplesReceived = false
        voiceSessionEnded = false
        manualTranscriptInputObserved = false
        transcript = ""
        voiceAttempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: voiceAttempt.attemptID,
            phase: .idle,
            triggerPath: "none",
            triggerReady: false,
            editorMounted: transcriptEditorMounted,
            windowKeyAtStart: false,
            firstResponderAtStart: false,
            firstResponderAtEnd: false,
            focusLost: false,
            firstSampleLatencyMilliseconds: nil,
            sessionDurationMilliseconds: nil,
            transcriptWaitMilliseconds: nil,
            result: .none
        )
        lastRecordedFailure = nil
        requestTranscriptFocus()
    }

    private func requestTranscriptFocus() {
        guard settings.onboardingStep == .voiceTest else { return }
        transcriptFocusRequest &+= 1
    }

    private func updateTranscriptFocus(_ snapshot: OnboardingTranscriptFocusSnapshot) {
        let changed = transcriptEditorMounted != snapshot.editorMounted ||
            transcriptWindowKey != snapshot.windowKey ||
            transcriptFirstResponder != snapshot.firstResponder
        transcriptEditorMounted = snapshot.editorMounted
        transcriptWindowKey = snapshot.windowKey
        transcriptFirstResponder = snapshot.firstResponder
        if voiceAttempt.phase == .recording || voiceAttempt.phase == .awaitingTranscript {
            if voiceAttempt.triggerReady &&
                (!snapshot.editorMounted || !snapshot.windowKey || !snapshot.firstResponder) {
                voiceAttempt.focusLost = true
            }
            voiceAttempt.editorMounted = snapshot.editorMounted
        }
        if changed {
            AppLogger.shared.write(
                "ONBOARDING TRANSCRIPT_TARGET mounted=\(snapshot.editorMounted) " +
                    "window_key=\(snapshot.windowKey) first_responder=\(snapshot.firstResponder)"
            )
        }
    }

    private func beginVoiceAttempt(triggerPath: String) {
        voiceTranscriptDeadlineToken = UUID()
        voiceAttemptStartedAt = Date()
        voiceTranscriptWaitStartedAt = nil
        voiceSessionStarted = true
        voiceSamplesReceived = false
        voiceSessionEnded = false
        manualTranscriptInputObserved = false
        transcript = ""

        let targetReady = transcriptEditorMounted && transcriptWindowKey && transcriptFirstResponder
        voiceAttempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: voiceAttempt.attemptID + 1,
            phase: .recording,
            triggerPath: triggerPath,
            triggerReady: targetReady,
            editorMounted: transcriptEditorMounted,
            windowKeyAtStart: transcriptWindowKey,
            firstResponderAtStart: transcriptFirstResponder,
            firstResponderAtEnd: false,
            focusLost: false,
            firstSampleLatencyMilliseconds: nil,
            sessionDurationMilliseconds: nil,
            transcriptWaitMilliseconds: nil,
            result: .none
        )
        lastRecordedFailure = nil
        if !targetReady {
            requestTranscriptFocus()
        }
        AppLogger.shared.write(
            "ONBOARDING VOICE_ATTEMPT started attempt=\(voiceAttempt.attemptID) " +
                "trigger_path=\(triggerPath) trigger_ready=\(targetReady) " +
                "editor_mounted=\(transcriptEditorMounted) window_key=\(transcriptWindowKey) " +
                "first_responder=\(transcriptFirstResponder)"
        )
    }

    private func endVoiceAttempt() {
        guard voiceAttempt.phase == .recording else { return }
        voiceSessionEnded = true
        voiceAttempt.phase = .awaitingTranscript
        voiceAttempt.firstResponderAtEnd = transcriptWindowKey && transcriptFirstResponder
        if let voiceAttemptStartedAt {
            voiceAttempt.sessionDurationMilliseconds = elapsedMilliseconds(since: voiceAttemptStartedAt)
        }
        voiceTranscriptWaitStartedAt = Date()

        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: manualTranscriptInputObserved,
            samplesReceived: voiceSamplesReceived,
            transcriptionAppeared: transcriptionAppeared,
            triggerReady: voiceAttempt.triggerReady,
            focusLost: voiceAttempt.focusLost
        )
        if result != .externalToolNoCommit &&
            result != .inputTargetNotReady &&
            result != .inputTargetFocusLost {
            finishVoiceAttempt(result: result)
        } else {
            scheduleVoiceTranscriptDeadline(attemptID: voiceAttempt.attemptID)
        }
    }

    private func scheduleVoiceTranscriptDeadline(attemptID: Int) {
        let token = UUID()
        voiceTranscriptDeadlineToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard settings.onboardingStep == .voiceTest,
                  voiceTranscriptDeadlineToken == token,
                  voiceAttempt.attemptID == attemptID,
                  voiceAttempt.phase == .awaitingTranscript else { return }
            let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
                manualInputObserved: manualTranscriptInputObserved,
                samplesReceived: voiceSamplesReceived,
                transcriptionAppeared: transcriptionAppeared,
                triggerReady: voiceAttempt.triggerReady,
                focusLost: voiceAttempt.focusLost
            )
            finishVoiceAttempt(result: result)
        }
    }

    private func finishVoiceAttempt(result: FirstUseVoiceAttemptResult) {
        guard voiceAttempt.phase == .awaitingTranscript else { return }
        voiceTranscriptDeadlineToken = UUID()
        if let voiceTranscriptWaitStartedAt {
            voiceAttempt.transcriptWaitMilliseconds = elapsedMilliseconds(
                since: voiceTranscriptWaitStartedAt
            )
        }
        voiceAttempt.result = result
        voiceAttempt.phase = result == .passed ? .passed : .failed
        let failure = result.failureReason
        settings.recordFirstUseEvent(
            result == .passed ? .passed : .blocked,
            step: .voiceTest,
            failureReason: failure,
            voiceAttemptID: voiceAttempt.attemptID,
            voiceResult: result
        )
        lastRecordedFailure = failure
        AppLogger.shared.write(
            "ONBOARDING VOICE_ATTEMPT terminal attempt=\(voiceAttempt.attemptID) " +
                "result=\(result.rawValue) probable_cause=\(result.rawValue) " +
                "boundary=\(result.diagnosticBoundary) " +
                "first_sample_latency_ms=\(voiceAttempt.firstSampleLatencyMilliseconds.map(String.init) ?? "unavailable") " +
                "session_duration_ms=\(voiceAttempt.sessionDurationMilliseconds.map(String.init) ?? "unavailable") " +
                "transcript_wait_ms=\(voiceAttempt.transcriptWaitMilliseconds.map(String.init) ?? "unavailable")"
        )
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private func copyDiagnosticSummary() {
        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: FirstUseDiagnosticSnapshot.architecture,
            voiceTool: settings.onboardingVoiceTool,
            voiceKeyMode: settings.voiceKeyMode,
            context: diagnosticContext,
            voiceAttempt: voiceAttempt,
            bluetoothStatus: model.connectionStatus.key,
            buttonStatus: model.hidStatus.key,
            audioStatus: model.audioStatus.key,
            events: settings.firstUseEvents,
            appLanguage: localization.locale.identifier
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.redactedText, forType: .string)
        AppLogger.shared.write(
            "ONBOARDING DIAGNOSTICS copied step=\(settings.onboardingStep.rawValue) " +
                "failure=\(failureReason?.rawValue ?? "none")"
        )
    }

    private func recoverRemoteConnectionIfNeeded() {
        guard settings.onboardingControlMethod == .physicalRemote else { return }
        guard OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: model.isConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            recoveryRequested: requestedRemoteConnectionRecovery
        ) else { return }
        requestedRemoteConnectionRecovery = true
        model.reconnect()
    }

    private func prepareSelectedControlConnection() {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            model.refreshRemoteDiscovery()
            model.applyHIDSettings()
        case .iPhoneApp:
            model.enablePhoneRemoteConnection()
        case .webRemote:
            if !model.webRemoteState.isEnabled {
                model.enableWebRemoteConnection()
            }
        case .unselected:
            break
        }
    }

    private func routeConnectedPhysicalRemoteIfNeeded() {
        let suppressForUserBack = suppressConnectedPhysicalRemoteAutoRouteOnce
        suppressConnectedPhysicalRemoteAutoRouteOnce = false
        guard OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: settings.onboardingStep,
            remoteConnected: model.isConnected,
            suppressForUserBack: suppressForUserBack
        ) else {
            if suppressForUserBack {
                AppLogger.shared.write(
                    "ONBOARDING NAVIGATION step=remoteAvailability " +
                        "auto_route_suppressed=true reason=user_back"
                )
            }
            return
        }
        settings.setOnboardingRemoteAvailability(.hasRemote)
        selectControlMethod(.physicalRemote)
        AppLogger.shared.write(
            "ONBOARDING NAVIGATION from=remoteAvailability to=permissions reason=connected_physical_remote"
        )
        settings.setOnboardingStep(.permissions)
    }

    private func selectedControlAccepts(_ source: UsageEventSource) -> Bool {
        switch settings.onboardingControlMethod {
        case .iPhoneApp:
            return source == .nearbyPhone
        case .webRemote:
            return source == .webRemote
        case .physicalRemote, .unselected:
            return false
        }
    }

    private func selectedControlAcceptsVoice(_ source: UsageEventSource?) -> Bool {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            return source == .bluetoothRemote
        case .iPhoneApp:
            return source == .nearbyPhone
        case .webRemote:
            return source == .webRemote
        case .unselected:
            return false
        }
    }

    private func webRemoteQRCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        ), let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private func continueFlow() {
        guard canContinue else { return }
        if settings.onboardingStep != .voiceTest {
            settings.recordFirstUseEvent(.passed, step: settings.onboardingStep)
        }
        if settings.onboardingStep == .remoteAvailability {
            switch settings.onboardingRemoteAvailability {
            case .hasRemote:
                settings.setOnboardingControlMethod(.physicalRemote)
                settings.setOnboardingStep(.permissions)
            case .noRemote:
                settings.setOnboardingControlMethod(.unselected)
                settings.setOnboardingStep(.controlMethod)
            case .unselected:
                break
            }
            return
        }
        if settings.onboardingStep == .permissions {
            if settings.onboardingControlMethod == .physicalRemote {
                settings.customMappingEnabled = true
            }
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

    private var previousStep: OnboardingStep? {
        if settings.onboardingStep == .permissions,
           settings.onboardingRemoteAvailability == .hasRemote {
            return .remoteAvailability
        }
        return settings.onboardingStep.previous
    }

    private func goBack(to previous: OnboardingStep) {
        if settings.onboardingStep == .permissions,
           previous == .remoteAvailability,
           settings.onboardingRemoteAvailability == .hasRemote {
            suppressConnectedPhysicalRemoteAutoRouteOnce = true
        }
        AppLogger.shared.write(
            "ONBOARDING NAVIGATION from=\(settings.onboardingStep.rawValue) " +
                "to=\(previous.rawValue) reason=user_back"
        )
        settings.setOnboardingStep(previous)
    }

    private func requestBluetoothPermission() {
        if bluetoothAuthorization == .allowedAlways {
            openBluetoothPrivacySettings()
            return
        }

        model.reconnect()
        if bluetoothAuthorization == .denied || bluetoothAuthorization == .restricted {
            openBluetoothPrivacySettings()
        }
    }

    private func openBluetoothPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openKeyboardSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct OnboardingTranscriptFocusSnapshot: Equatable {
    let editorMounted: Bool
    let windowKey: Bool
    let firstResponder: Bool
}

struct OnboardingTranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let isActive: Bool
    let onFocusStateChanged: (OnboardingTranscriptFocusSnapshot) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OnboardingTranscriptScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scrollView.documentView = textView

        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: OnboardingTranscriptEditor
        private weak var scrollView: OnboardingTranscriptScrollView?
        private weak var textView: NSTextView?
        private var appliedFocusRequest: Int?
        private var lastPublishedSnapshot: OnboardingTranscriptFocusSnapshot?

        init(parent: OnboardingTranscriptEditor) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowFocusChanged),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowFocusChanged),
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        fileprivate func attach(scrollView: OnboardingTranscriptScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            scrollView.didMoveToWindowHandler = { [weak self] in
                self?.applyFocusRequestIfPossible()
                self?.publishFocusSnapshot()
            }
            applyFocusRequestIfPossible()
            publishFocusSnapshot()
        }

        func update(parent: OnboardingTranscriptEditor) {
            self.parent = parent
            if textView?.string != parent.text {
                textView?.string = parent.text
            }
            applyFocusRequestIfPossible()
            publishFocusSnapshot()
        }

        func detach() {
            textView?.delegate = nil
            scrollView?.didMoveToWindowHandler = nil
            scrollView = nil
            textView = nil
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, parent.text != textView.string else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            publishFocusSnapshot()
        }

        func textDidEndEditing(_ notification: Notification) {
            publishFocusSnapshot()
        }

        @objc private func windowFocusChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === scrollView?.window else { return }
            applyFocusRequestIfPossible()
            publishFocusSnapshot()
        }

        private func applyFocusRequestIfPossible() {
            guard parent.isActive,
                  appliedFocusRequest != parent.focusRequest,
                  let textView,
                  let window = textView.window else { return }
            if window.makeFirstResponder(textView) {
                appliedFocusRequest = parent.focusRequest
            }
        }

        private func publishFocusSnapshot() {
            let snapshot = OnboardingTranscriptFocusSnapshot(
                editorMounted: textView?.window != nil,
                windowKey: textView?.window?.isKeyWindow == true,
                firstResponder: textView?.window?.firstResponder === textView
            )
            guard snapshot != lastPublishedSnapshot else { return }
            lastPublishedSnapshot = snapshot
            DispatchQueue.main.async { [weak self] in
                self?.parent.onFocusStateChanged(snapshot)
            }
        }
    }
}

private final class OnboardingTranscriptScrollView: NSScrollView {
    var didMoveToWindowHandler: (() -> Void)?

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        var frame = textView.frame
        let targetWidth = contentSize.width
        let targetHeight = max(frame.height, contentSize.height)
        guard frame.width != targetWidth || frame.height != targetHeight else { return }
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        textView.frame = frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindowHandler?()
    }
}
