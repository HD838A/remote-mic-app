import AppKit
import Combine
import CoreBluetooth
import CoreImage
import CoreImage.CIFilterBuiltins
import SayAllMacRemoteCore
import SwiftUI

#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
import SayAllSiriRemote
#endif

#if SAYALL_CHROMECASE_ENABLED && canImport(SayAllChromecase)
import SayAllChromecase
#endif

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
    private let remoteInputDiagnosticOverride: FirstUseRemoteInputDiagnostic?

    @State private var bluetoothAuthorization = CBManager.authorization
    @State private var inputMonitoringGranted = HIDRemoteMonitor.isInputMonitoringGranted
    @State private var accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
    @State private var observedRemoteButtons = Set<RemoteButton>()
    @State private var remoteInputDiagnostic = FirstUseRemoteInputDiagnostic()
    @State private var requestedRemoteConnectionRecovery = false
    @State private var testedControlButtons = Set<RemoteButton>()
    @State private var voiceSessionStarted = false
    @State private var voiceSamplesReceived = false
    @State private var voiceSessionEnded = false
    @State private var transcript = ""
    @State private var transcriptCommitRequest = 0
    @State private var lastVoiceTranscriptCandidate = ""
    @State private var manualTranscriptInputObserved = false
    @State private var lastRecordedFailure: FirstUseFailureReason?
    @State private var inputSourceSwitchResult: OnboardingInputSourceSwitchResult = .notApplicable
    @State private var voiceToolAvailability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [:]
    @State private var voiceToolRuntimeState: [OnboardingVoiceTool: OnboardingVoiceToolRuntimeState] = [:]
    @State private var systemFunctionKeyUsage = OnboardingSystemFunctionKeyUsage.current
    @State private var voiceKeyMigrationSource: VoiceKeyMode?
    @State private var selectedInputMethodGuideStep = 0
    @State private var transcriptFocusRequest = 0
    @State private var transcriptEditorMounted = false
    @State private var transcriptWindowKey = false
    @State private var transcriptFirstResponder = false
    @State private var voiceAttempt = FirstUseVoiceAttemptDiagnostic()
    @State private var voiceAttemptStartedAtUptime: TimeInterval?
    @State private var voiceTranscriptWaitStartedAtUptime: TimeInterval?
    @State private var activeFocusLossStartedAtUptime: TimeInterval?
    @State private var externalToolVoiceKeyConfirmed = false
    @State private var externalToolGlobalVoiceConfirmed = false
    @State private var externalToolMicrophoneConfirmed = false
    @State private var voiceTranscriptDeadlineToken = UUID()
    @State private var suppressConnectedPhysicalRemoteAutoRouteOnce = false
    @State private var isCapturingVoiceShortcut = false
    @State private var shortcutCaptureErrorKey: String?
    @State private var vokieDeepLinkStatus: SayAllDeepLinkStatus?

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
        initialInputMethodGuideStep: Int = 0,
        remoteInputDiagnosticOverride: FirstUseRemoteInputDiagnostic? = nil
    ) {
        self.model = model
        settings = model.settings
        self.completeRuntimeReadyOverride = completeRuntimeReadyOverride
        self.allowsInputSourceSwitching = allowsInputSourceSwitching
        self.systemFunctionKeyAvailableOverride = systemFunctionKeyAvailableOverride
        self.voiceToolAvailabilityOverride = voiceToolAvailabilityOverride
        self.remoteInputDiagnosticOverride = remoteInputDiagnosticOverride
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
            refreshPermissionStates()
            refreshVoiceToolAvailability()
            prepareForStep(settings.onboardingStep)
        }
        .onReceive(permissionRefreshTimer) { _ in
            refreshPermissionStates()
            if settings.onboardingStep == .voiceTool {
                refreshSystemFunctionKeyUsage()
            }
            if settings.onboardingStep == .voiceTest {
                refreshSelectedVoiceToolRuntimeState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            switch settings.onboardingStep {
            case .voiceTool:
                refreshVoiceToolAvailability()
                refreshSelectedInputMethodStatus()
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
        .onReceive(NotificationCenter.default.publisher(for: .sayAllDeepLinkReceived)) { notification in
            guard let request = notification.object as? SayAllDeepLinkRequest,
                  request.source == "vokie" else { return }
            vokieDeepLinkStatus = request.status
            refreshVoiceToolAvailability()
        }
        .onReceive(model.$isConnected.removeDuplicates()) { isConnected in
            guard isConnected else { return }
            routeConnectedPhysicalRemoteIfNeeded()
        }
        .onReceive(model.$activeRemoteButtons) { buttons in
            guard settings.onboardingControlMethod == .physicalRemote,
                  selectedPhysicalRemoteProfileMatchesSource,
                  !buttons.isEmpty else { return }
            if settings.onboardingStep == .remote {
                recordRemoteControlButtons(buttons, source: "physical_remote")
                recoverRemoteConnectionIfNeeded()
            } else if settings.onboardingStep == .controls {
                testedControlButtons.formUnion(buttons)
            }
        }
        .onReceive(model.$lastRemoteButtonPress.compactMap { $0 }) { button in
            guard settings.onboardingControlMethod == .physicalRemote,
                  selectedPhysicalRemoteProfileMatchesSource else { return }
            if settings.onboardingStep == .remote {
                recordRemoteControlButtons(Set([button]), source: "physical_remote")
                recoverRemoteConnectionIfNeeded()
            } else if settings.onboardingStep == .controls {
                testedControlButtons.insert(button)
            }
        }
        .onReceive(model.$lastMobileRemoteButtonObservation.compactMap { $0 }) { observation in
            guard selectedControlAccepts(observation.source) else { return }
            if settings.onboardingStep == .remote {
                recordRemoteControlButtons(Set([observation.button]), source: observation.source.rawValue)
            } else if settings.onboardingStep == .controls {
                testedControlButtons.insert(observation.button)
            }
        }
        .onReceive(model.$isStreaming) { isStreaming in
            guard selectedControlAcceptsVoice(model.activeVoiceSource) else { return }
            switch settings.onboardingStep {
            case .remote where isStreaming:
                recordRemoteVoiceButtonPress()
            case .voiceTest:
                if isStreaming {
                    beginVoiceAttempt(triggerPath: model.activeVoiceSource?.rawValue ?? "unknown")
                } else if voiceSessionStarted {
                    endVoiceAttempt()
                }
            default:
                break
            }
        }
        .onReceive(model.$hasReceivedCurrentVoiceSamples.removeDuplicates()) { hasReceivedSamples in
            guard settings.onboardingStep == .voiceTest,
                  hasReceivedSamples,
                  selectedControlAcceptsVoice(model.activeVoiceSource) else { return }
            voiceSamplesReceived = true
            voiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
            if voiceAttempt.firstSampleLatencyMilliseconds == nil,
               let voiceAttemptStartedAtUptime {
                voiceAttempt.firstSampleLatencyMilliseconds = elapsedMilliseconds(
                    sinceUptime: voiceAttemptStartedAtUptime
                )
            }
        }
        .onChange(of: settings.onboardingStep) { step in
            prepareForStep(step)
        }
        .onChange(of: settings.onboardingVoiceTool) { _ in
            resetExternalToolVoiceKeyConfirmation(reason: "voice_tool_changed")
            resetExternalToolGlobalVoiceConfirmation(reason: "voice_tool_changed")
            resetExternalToolMicrophoneConfirmation(reason: "voice_tool_changed")
            refreshSelectedVoiceToolRuntimeState()
        }
        .onChange(of: settings.selectedAudioDeviceUID) { _ in
            resetExternalToolMicrophoneConfirmation(reason: "audio_device_changed")
        }
        .onChange(of: externalToolMicrophoneConfirmed) { confirmed in
            AppLogger.shared.write(
                "ONBOARDING EXTERNAL_MICROPHONE_CONFIRMATION source=user " +
                    "confirmed=\(confirmed) tool=\(settings.onboardingVoiceTool.rawValue) " +
                    "expected_device=\(selectedAudioDeviceDiagnosticKind.rawValue)"
            )
        }
        .onChange(of: externalToolVoiceKeyConfirmed) { confirmed in
            AppLogger.shared.write(
                "ONBOARDING EXTERNAL_VOICE_KEY_CONFIRMATION source=user " +
                    "confirmed=\(confirmed) tool=\(settings.onboardingVoiceTool.rawValue) " +
                    "expected=\(externalToolExpectedVoiceKeyDiagnosticValue)"
            )
        }
        .onChange(of: externalToolGlobalVoiceConfirmed) { confirmed in
            AppLogger.shared.write(
                "ONBOARDING EXTERNAL_GLOBAL_VOICE_CONFIRMATION source=user " +
                    "confirmed=\(confirmed) tool=\(settings.onboardingVoiceTool.rawValue) " +
                    "applicable=\(externalToolGlobalVoiceConfirmationRequired)"
            )
        }
        .onChange(of: transcript) { updatedText in
            captureVoiceTranscriptCandidate(updatedText)
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
            refreshVoiceAttemptObservableState(atDeadline: false)
            if voiceAttempt.audioDelivery.result == .deliveredToSelectedDevice {
                finishVoiceAttempt(result: .passed)
            } else {
                scheduleVoiceCompletionEvaluation(attemptID: voiceAttempt.attemptID)
            }
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
                    Label {
                        Text(verbatim: localization.text("onboarding.action.back"))
                    } icon: {
                        Image(systemName: "arrow.left")
                    }
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            } else {
                Color.clear.frame(height: 40)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    stepContent
                    if let failureReason {
                        recoveryCard(for: failureReason)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.visible)

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
            Text(verbatim: localization.text("onboarding.welcome.detail"))
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
        VStack(alignment: .leading, spacing: 10) {
            onboardingTitle("onboarding.voice_tool.title")
            Text(verbatim: localization.text("onboarding.voice_tool.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            onboardingVoiceKeyMigrationNotice

            if allRecognizedVoiceToolsUnavailable {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Text(verbatim: localization.text("onboarding.voice_tool.none_detected"))
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
                    GridItem(.flexible(), spacing: 8, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 8
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
                                    .lineLimit(3, reservesSpace: true)
                                if tool == .vokie {
                                    Text(verbatim: localization.text("onboarding.voice_tool.vokie.deep_integration"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                if voiceToolAvailability[tool] == .notInstalled {
                                    Text(verbatim: localization.text("onboarding.voice_tool.status.not_installed"))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                } else if voiceToolAvailability[tool] == .unknown,
                                          tool != .other {
                                    Text(verbatim: localization.text("onboarding.voice_tool.status.unknown"))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: settings.onboardingVoiceTool == tool ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(settings.onboardingVoiceTool == tool ? Color.accentColor : Color.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 104, alignment: .top)
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
                    Text(verbatim: localization.text("onboarding.voice_tool.doubao.install_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link(destination: AppLinks.doubaoInputMethod) {
                        Text(verbatim: localization.text("onboarding.voice_tool.doubao.install"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.onboardingVoiceTool == .other {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.badge.xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: localization.text("onboarding.voice_tool.other.setup_detail"))
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
        let profile = VoiceToolAdapterProfile.profile(for: settings.onboardingVoiceTool)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(verbatim: localization.text("onboarding.voice_tool.binding.title"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button {
                    selectVoiceBindingPreference(.documentedDefault)
                } label: {
                    Label {
                        Text(verbatim: localization.text("onboarding.voice_tool.binding.recommended"))
                    } icon: {
                        Image(systemName: settings.onboardingVoiceBindingPreference == .documentedDefault
                            ? "checkmark.circle.fill"
                            : "circle")
                    }
                }
                .buttonStyle(.bordered)

                Button {
                    selectVoiceBindingPreference(.learnCurrent)
                } label: {
                    Label {
                        Text(verbatim: localization.text("onboarding.voice_tool.binding.learn"))
                    } icon: {
                        Image(systemName: settings.onboardingVoiceBindingPreference == .learnCurrent
                            ? "checkmark.circle.fill"
                            : "circle")
                    }
                }
                .buttonStyle(.bordered)
            }

            Text(verbatim: localization.text(
                settings.onboardingVoiceBindingPreference == .learnCurrent
                    ? "onboarding.voice_tool.binding.learn_detail"
                    : "onboarding.voice_tool.binding.recommended_detail"
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if settings.onboardingVoiceBindingPreference == .documentedDefault {
                Text(defaultBindingSummary(profile: profile))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(profile.evidenceState == .verified ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
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
                    Text(verbatim: localization.text("onboarding.voice_key.migration.detail"))
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
        let compact = availablePhysicalControlSources.count > 1 && !availableCompanionControlSources.isEmpty
        return VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            onboardingTitle("onboarding.control_source.title")
            Text(verbatim: localization.text("onboarding.control_source.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: localization.text("onboarding.control_source.hardware"))
                .font(.system(size: 13, weight: .semibold))

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: compact ? 8 : 10
            ) {
                ForEach(availablePhysicalControlSources) { source in
                    controlSourceCard(source, emphasized: true)
                }
            }

            if !availableCompanionControlSources.isEmpty {
                Text(verbatim: localization.text("onboarding.control_source.alternatives"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: compact ? 8 : 10) {
                    ForEach(availableCompanionControlSources) { source in
                        controlSourceCard(source, emphasized: false)
                    }
                }
            }

            if settings.onboardingControlSource.supportedGestureModes.count > 1 {
                gestureModeChoice
            }

            if let plan = proposedPairingPlan {
                pairingPlanSummary(plan)
            } else if settings.onboardingControlSource != .unselected {
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    title: localization.text("onboarding.pairing_plan.needs_learning"),
                    detail: localization.text("onboarding.pairing_plan.needs_learning_detail"),
                    isComplete: false,
                    pendingColor: .orange
                )
            }
        }
    }

    private var availablePhysicalControlSources: [OnboardingControlSource] {
        OnboardingBuildCapabilities.availableControlSources.filter {
            [.xiaomiRemote, .siriRemote, .chromecastRemote].contains($0)
        }
    }

    private var availableCompanionControlSources: [OnboardingControlSource] {
        OnboardingBuildCapabilities.availableControlSources.filter {
            [.appleCompanion, .webRemote].contains($0)
        }
    }

    private func controlSourceCard(
        _ source: OnboardingControlSource,
        emphasized: Bool
    ) -> some View {
        let compact = availablePhysicalControlSources.count > 1
        return Button {
            selectControlSource(source)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: controlSourceIcon(source))
                    .font(.system(size: emphasized ? 21 : 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: emphasized ? 40 : 34, height: emphasized ? 40 : 34)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(localization.text(source.titleKey))
                            .font(.system(size: emphasized ? 14 : 13, weight: .semibold))
                            .lineLimit(compact ? 2 : nil)
                        if source == .xiaomiRemote {
                            Text(verbatim: localization.text("onboarding.control_source.recommended"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(localization.text(source.detailKey))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(compact ? 2 : 3)
                }
                Spacer(minLength: 4)
                Image(systemName: settings.onboardingControlSource == source
                    ? "checkmark.circle.fill"
                    : "circle")
                    .foregroundStyle(settings.onboardingControlSource == source
                        ? Color.accentColor
                        : Color.secondary)
            }
            .padding(compact ? 10 : 12)
            .frame(
                maxWidth: .infinity,
                minHeight: emphasized
                    ? (availablePhysicalControlSources.count > 1 ? 84 : 92)
                    : (availablePhysicalControlSources.count > 1 ? 64 : 76),
                alignment: .topLeading
            )
            .background(
                settings.onboardingControlSource == source
                    ? Color.accentColor.opacity(0.09)
                    : Color.primary.opacity(emphasized ? 0.04 : 0.025),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        settings.onboardingControlSource == source
                            ? Color.accentColor.opacity(0.65)
                            : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var gestureModeChoice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: localization.text("onboarding.gesture.title"))
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(VoiceGestureMode.allCases) { mode in
                    Button {
                        selectPreferredGesture(mode)
                    } label: {
                        Label(
                            localization.text("onboarding.gesture.\(mode.rawValue)"),
                            systemImage: effectivePreferredGesture == mode
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!VoiceToolAdapterProfile.profile(
                        for: settings.onboardingVoiceTool
                    ).supportedModes.contains(mode))
                }
            }
        }
    }

    private func pairingPlanSummary(_ plan: OnboardingVoicePairingPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(verbatim: localization.text("onboarding.pairing_plan.title"))
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
                .font(.system(size: 13, weight: .semibold))
            Text(
                LocalizedMessage(
                    "onboarding.pairing_plan.summary",
                    arguments: [
                        localization.text("onboarding.gesture.\(plan.binding.gestureMode.rawValue)"),
                        localization.text(plan.binding.shortcut.localizationKey),
                        localization.text(plan.fnTapModeEnabled
                            ? "onboarding.pairing_plan.fn_tap_on"
                            : "onboarding.pairing_plan.fn_tap_off"),
                    ]
                ).text(using: localization)
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if plan.evidenceState != .verified {
                Text(verbatim: localization.text("onboarding.pairing_plan.pending_evidence"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
            if plan.binding.tool == .vokie {
                HStack(spacing: 8) {
                    Button {
                        guard let url = VokieDeepLink.launchURL(for: plan) else { return }
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(verbatim: localization.text("onboarding.vokie.open"))
                    }
                    .buttonStyle(.bordered)
                    if let vokieDeepLinkStatus {
                        Text(localization.text("onboarding.vokie.status.\(vokieDeepLinkStatus.rawValue)"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(vokieDeepLinkStatus == .failed ? Color.red : Color.secondary)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlMethodContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.control_method.title")
            Text(verbatim: localization.text("onboarding.control_method.detail"))
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
                                        Text(verbatim: localization.text("onboarding.control_method.recommended"))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.accentColor.opacity(0.10),
                                                in: Capsule()
                                            )
                                    } else if method == .webRemote {
                                        Text(verbatim: localization.text("onboarding.control_method.no_iphone"))
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
                Button {
                    activateSelectedInputMethod()
                } label: {
                    Text(verbatim: localization.text(
                        inputSourceSwitchResult == .failed
                            ? "onboarding.voice_tool.switch.retry"
                            : "onboarding.voice_tool.switch.select"
                    ))
                }
                .buttonStyle(.bordered)
            }

            if inputSourceSwitchResult == .notSelected {
                Button {
                    activateSelectedInputMethod()
                } label: {
                    Text(verbatim: localization.text("onboarding.voice_tool.switch.select"))
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
                Text(verbatim: localization.text("onboarding.voice_tool.guide.image_missing"))
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
                    Text(verbatim: localization.text("onboarding.voice_tool.system_fn.detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !systemFunctionKeyAvailable {
                    Button {
                        openKeyboardSettings()
                    } label: {
                        Text(verbatim: localization.text("onboarding.voice_tool.system_fn.open_settings"))
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
            Text(verbatim: localization.text("onboarding.permissions.detail"))
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

            if settings.onboardingVoiceBindingPreference == .learnCurrent {
                shortcutLearningCard
            }
        }
    }

    private var shortcutLearningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localization.text("onboarding.shortcut_learning.title"))
                .font(.system(size: 14, weight: .semibold))
            Text(verbatim: localization.text("onboarding.shortcut_learning.detail"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if VoiceToolAdapterProfile.profile(
                for: settings.onboardingVoiceTool
            ).supportedModes.count > 1 {
                gestureModeChoice
            }

            if let binding = settings.stagedVoiceToolBinding,
               binding.source == .userLearned {
                Label(
                    LocalizedMessage(
                        "onboarding.shortcut_learning.captured",
                        arguments: [localization.text(binding.shortcut.localizationKey)]
                    ).text(using: localization),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
            } else {
                Button {
                    shortcutCaptureErrorKey = nil
                    isCapturingVoiceShortcut = true
                } label: {
                    Text(verbatim: localization.text(
                        isCapturingVoiceShortcut
                            ? "onboarding.shortcut_learning.waiting"
                            : "onboarding.shortcut_learning.start"
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accessibilityGranted || !inputMonitoringGranted)
            }

            if let shortcutCaptureErrorKey {
                Text(localization.text(shortcutCaptureErrorKey))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }

            if isCapturingVoiceShortcut {
                OnboardingShortcutCaptureView(
                    onCapture: handleLearnedShortcut,
                    onFailure: handleShortcutCaptureFailure
                )
                .frame(width: 1, height: 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
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
            Text(verbatim: localization.text("onboarding.remote.detail"))
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
                title: !selectedControlConnected && !observedRemoteButtons.isEmpty
                    ? localization.text("onboarding.remote.hid_connected")
                    : selectedControlConnected
                        ? localization.text("onboarding.remote.connected")
                        : localization.text("onboarding.remote.searching"),
                detail: localization.text(
                    selectedControlConnected
                        ? "onboarding.remote.connected_detail"
                        : !observedRemoteButtons.isEmpty
                            ? "onboarding.remote.hid_connected_detail"
                            : "onboarding.remote.searching_detail"
                ),
                isComplete: selectedControlConnected
            )

            statusCard(
                icon: remoteInputDiagnostic.shouldShowVoiceButtonCorrection
                    ? "exclamationmark.triangle.fill"
                    : observedRemoteButtons.isEmpty
                        ? "button.programmable"
                        : "checkmark.circle.fill",
                title: localization.text(
                    remoteInputDiagnostic.shouldShowVoiceButtonCorrection
                        ? "onboarding.remote.voice_button_mistake.title"
                        : observedRemoteButtons.isEmpty
                            ? "onboarding.remote.button_waiting"
                            : "onboarding.remote.button_received"
                ),
                detail: physicalRemoteButtonStatusDetail,
                isComplete: !observedRemoteButtons.isEmpty,
                pendingColor: remoteInputDiagnostic.shouldShowVoiceButtonCorrection ? .orange : nil
            )

            if !selectedControlConnected {
                openBluetoothSettingsButton
            }
        }
    }

    private var physicalRemoteButtonStatusDetail: String {
        let instructionKey = remoteInputDiagnostic.shouldShowVoiceButtonCorrection
            ? "onboarding.remote.voice_button_mistake.detail"
            : observedRemoteButtons.isEmpty
                ? "onboarding.remote.button_waiting_detail"
                : "onboarding.remote.button_detail"
        let listenerStatus = LocalizedMessage(
            "onboarding.remote.listener_status",
            arguments: [model.hidStatus.text(using: localization)]
        ).text(using: localization)
        return "\(localization.text(instructionKey))\n\(listenerStatus)"
    }

    private var iPhoneRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.apple_companion.title")
            Text(verbatim: localization.text("onboarding.apple_companion.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: AppLinks.testFlightPublicBeta) {
                Label {
                    Text(verbatim: localization.text("onboarding.apple_companion.install"))
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .buttonStyle(.borderedProminent)

            statusCard(
                icon: selectedControlConnected
                    ? "checkmark.circle.fill"
                    : "iphone.and.arrow.forward",
                title: localization.text(
                    selectedControlConnected
                        ? "onboarding.apple_companion.connected"
                        : "onboarding.apple_companion.waiting"
                ),
                detail: localization.text("onboarding.apple_companion.connection_detail"),
                isComplete: selectedControlConnected
            )

            controllerButtonStatusCard(
                waitingDetailKey: "onboarding.apple_companion.button_detail"
            )
        }
    }

    private var webRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.web_remote.title")
            Text(verbatim: localization.text("onboarding.web_remote.detail"))
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
                Button {
                    model.enableWebRemoteConnection()
                } label: {
                    Text(verbatim: localization.text("onboarding.web_remote.retry"))
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
        Button {
            openBluetoothSettings()
        } label: {
            Text(verbatim: localization.text("onboarding.remote.open_bluetooth"))
        }
            .buttonStyle(.bordered)
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.audio.title")
            Text(verbatim: localization.text("onboarding.audio.detail"))
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
                Button {
                    model.openDoubaoDriverInstructions(using: localization)
                } label: {
                    Text(verbatim: localization.text("audio.compatibility.open_install_guide"))
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
            Text(verbatim: localization.text("onboarding.voice_test.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            externalToolConfigurationConfirmationCard

            ZStack(alignment: .topLeading) {
                OnboardingTranscriptEditor(
                    text: $transcript,
                    focusRequest: transcriptFocusRequest,
                    isActive: settings.onboardingStep == .voiceTest,
                    commitRequest: transcriptCommitRequest,
                    onTextStateChanged: captureVoiceTranscriptCandidate
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
                    Text(verbatim: localization.text("onboarding.voice_test.placeholder"))
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var externalToolConfigurationConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(
                    LocalizedMessage(
                        "onboarding.voice_test.configuration.title",
                        arguments: [localization.text(settings.onboardingVoiceTool.titleKey)]
                    ).text(using: localization)
                )
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }

            Text(
                LocalizedMessage(
                    "onboarding.voice_test.configuration.detail",
                    arguments: [localization.text(settings.onboardingVoiceTool.titleKey)]
                ).text(using: localization)
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            configurationStatusRow(
                label: localization.text("onboarding.voice_test.configuration.sayall_voice_key"),
                value: sayAllVoiceKeyConfigurationText,
                isComplete: sayAllVoiceKeyConfigurationReady
            )

            configurationStatusRow(
                label: localization.text("onboarding.voice_test.configuration.sayall_audio_output"),
                value: sayAllAudioOutputConfigurationText,
                isComplete: onboardingAudioReady
            )

            if let runtimeStatus = selectedVoiceToolRuntimeStatusText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selectedVoiceToolRuntimeReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(selectedVoiceToolRuntimeReady ? Color.green : Color.red)
                    Text(runtimeStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedVoiceToolRuntimeReady ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !selectedVoiceToolRuntimeReady {
                        Button {
                            openSelectedVoiceTool()
                        } label: {
                            Text(verbatim: localization.text("onboarding.voice_tool.runtime.reopen"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            Toggle(isOn: $externalToolVoiceKeyConfirmed) {
                Text(
                    LocalizedMessage(
                        "onboarding.voice_test.configuration.voice_key_checkbox",
                        arguments: [
                            localization.text(settings.onboardingVoiceTool.titleKey),
                            externalToolExpectedVoiceKeyText,
                        ]
                    ).text(using: localization)
                )
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            if externalToolGlobalVoiceConfirmationRequired {
                Toggle(isOn: $externalToolGlobalVoiceConfirmed) {
                Text(verbatim: localization.text("onboarding.voice_test.configuration.global_voice_checkbox"))
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }

            Toggle(isOn: $externalToolMicrophoneConfirmed) {
                Text(
                    LocalizedMessage(
                        "onboarding.voice_test.microphone_confirmation.checkbox",
                        arguments: [
                            localization.text(settings.onboardingVoiceTool.titleKey),
                            selectedAudioDevice?.name ?? localization.text("onboarding.audio.select_required"),
                        ]
                    ).text(using: localization)
                )
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            if voiceAttempt.result == .externalToolNoCommit {
                Label {
                    Text(verbatim: localization.text("onboarding.voice_test.configuration.no_commit"))
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private func configurationStatusRow(
        label: String,
        value: String,
        isComplete: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Label(value, systemImage: isComplete ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isComplete ? Color.green : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle("onboarding.controls.title")
            Text(verbatim: localization.text("onboarding.controls.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(RemoteButton.xiaomiCases) { button in
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
                Text(verbatim: localization.text(
                    testedControlButtons.count >= 3
                        ? "onboarding.controls.ready"
                        : "onboarding.controls.waiting"
                ))
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
            Text(verbatim: localization.text("onboarding.complete.detail"))
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
                        .fixedSize(horizontal: false, vertical: true)
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

                Button {
                    copyDiagnosticSummary()
                } label: {
                    Text(verbatim: localization.text("onboarding.diagnostics.copy"))
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

            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if settings.onboardingStep == .voiceTool,
                       settings.onboardingVoiceTool.requiresFunctionKeySetup {
                        inputMethodGuide(for: settings.onboardingVoiceTool)
                            .frame(maxWidth: 440)
                            .padding(28)
                    } else if settings.onboardingStep == .welcome || settings.onboardingStep == .voiceTool {
                        welcomeIllustration
                    } else if settings.onboardingStep == .remoteAvailability {
                        selectedControlSourceIllustration
                    } else if settings.onboardingStep == .controlMethod {
                        controlMethodIllustration
                    } else if settings.onboardingStep == .complete {
                        completeIllustration
                    } else {
                        selectedControlIllustration
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(minHeight: 0)
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
                Text(verbatim: localization.text("onboarding.illustration.tagline"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var remoteIllustration: some View {
        VStack(spacing: 16) {
            onboardingRemotePhoto
            sideStatusPanel
        }
        .padding(28)
    }

    @ViewBuilder
    private var selectedControlSourceIllustration: some View {
        switch settings.onboardingControlSource {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            remoteIllustration
        case .appleCompanion, .webRemote:
            controlMethodIllustration
        case .unselected:
            remoteAvailabilityIllustration
        }
    }

    @ViewBuilder
    private var onboardingRemotePhoto: some View {
        switch OnboardingRemotePhotoKind.resolve(
            source: settings.onboardingControlSource,
            selectedModel: settings.selectedRemoteProfile?.model
        ) {
        case let .bundled(resourceName):
            if let image = bundledRemoteImage(resourceName: resourceName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 480)
                    .shadow(color: .black.opacity(0.20), radius: 16, y: 10)
            } else {
                remotePhotoPlaceholder
            }
        case .siriRemote:
            #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
            SiriRemoteConnectionPhoto()
                .scaleEffect(1.8)
                .frame(width: 190, height: 360)
            #else
            remotePhotoPlaceholder
            #endif
        case .chromecastRemote:
            #if SAYALL_CHROMECASE_ENABLED && canImport(SayAllChromecase)
            ChromecaseConnectionPhoto()
                .scaleEffect(1.8)
                .frame(width: 190, height: 360)
            #else
            remotePhotoPlaceholder
            #endif
        case .placeholder:
            remotePhotoPlaceholder
        }
    }

    private var remotePhotoPlaceholder: some View {
        Image(systemName: "appletvremote.gen4.fill")
            .font(.system(size: 180))
            .foregroundStyle(.secondary)
    }

    private var controlMethodIllustration: some View {
        VStack(spacing: 26) {
            HStack(spacing: 38) {
                Image(systemName: "iphone")
                Image(systemName: "safari.fill")
            }
            .font(.system(size: 58, weight: .medium))
            .foregroundStyle(Color.accentColor)
                Text(verbatim: localization.text("onboarding.control_method.illustration"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var remoteAvailabilityIllustration: some View {
        VStack(spacing: 24) {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 150, weight: .medium))
                .foregroundStyle(Color.accentColor)
                Text(verbatim: localization.text("onboarding.remote_availability.illustration"))
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
                Text(verbatim: localization.text("onboarding.iphone_remote.scan"))
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
                Text(verbatim: localization.text("onboarding.web_remote.scan"))
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
                Text(verbatim: localization.text("onboarding.web_remote.connecting"))
                    .font(.system(size: 15, weight: .semibold))
            case .unavailable, .failed:
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 82))
                    .foregroundStyle(Color.orange)
                Text(verbatim: localization.text("onboarding.web_remote.unavailable"))
                    .font(.system(size: 15, weight: .semibold))
            case .disabled:
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 100))
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: localization.text("onboarding.web_remote.preparing"))
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
                Text(verbatim: localization.text("onboarding.complete.illustration"))
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
                .fixedSize(horizontal: false, vertical: true)
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
        isComplete: Bool,
        pendingColor: Color? = nil
    ) -> some View {
        let statusColor = isComplete ? Color.green : (pendingColor ?? Color.accentColor)
        return HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 36, height: 36)
                .background(statusColor.opacity(0.10), in: Circle())
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
        .background(
            (pendingColor?.opacity(0.08) ?? Color.primary.opacity(0.035)),
            in: RoundedRectangle(cornerRadius: 12)
        )
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
            return policyAllowsContinue &&
                voiceAttempt.phase == .passed &&
                externalToolConfigurationConfirmed &&
                selectedVoiceToolRuntimeReady
        }
        if settings.onboardingStep == .remoteAvailability {
            return settings.onboardingControlSource != .unselected &&
                (settings.onboardingVoiceBindingPreference == .learnCurrent ||
                    proposedPairingPlan != nil)
        }
        if settings.onboardingStep == .permissions,
           settings.onboardingVoiceBindingPreference == .learnCurrent {
            return policyAllowsContinue && settings.stagedVoiceToolBinding != nil
        }
        return policyAllowsContinue &&
            (settings.onboardingStep != .voiceTool || voiceToolSelectionIsValid)
    }

    private var visibleVoiceTools: [OnboardingVoiceTool] {
        [
            .vokie, .doubao, .weixin, .typeless, .chatterFly, .other,
        ]
    }

    private var allRecognizedVoiceToolsUnavailable: Bool {
        [OnboardingVoiceTool.doubao, .weixin, .typeless, .vokie].allSatisfy {
            voiceToolAvailability[$0] == .notInstalled
        }
    }

    private var voiceToolSelectionIsValid: Bool {
        switch settings.onboardingVoiceTool {
        case .unselected:
            return false
        case .other:
            return settings.onboardingVoiceBindingPreference == .learnCurrent
        case .chatterFly:
            return voiceToolAvailability[settings.onboardingVoiceTool] != .notInstalled
        case .doubao, .weixin, .typeless, .vokie:
            return voiceToolAvailability[settings.onboardingVoiceTool] == .available
        }
    }

    private var effectivePreferredGesture: VoiceGestureMode {
        settings.onboardingPreferredGesture ?? proposedPairingPlan?.binding.gestureMode ?? .hold
    }

    private var proposedPairingPlan: OnboardingVoicePairingPlan? {
        let selectedBinding: VoiceToolUserBinding?
        if let staged = settings.stagedVoiceToolBinding,
           staged.tool == settings.onboardingVoiceTool {
            selectedBinding = staged
        } else if let verified = settings.verifiedVoiceToolBinding,
                  verified.tool == settings.onboardingVoiceTool,
                  verified.validationState == .verified {
            // 重跑 Onboarding 时，已验证的用户 Binding 高于工具文档默认值。
            // 如果它与当前来源不兼容，resolve 会拒绝并回退到可用的推荐路径。
            selectedBinding = verified
        } else {
            selectedBinding = nil
        }
        return OnboardingVoicePairingPlan.resolve(
            tool: settings.onboardingVoiceTool,
            controlSource: settings.onboardingControlSource,
            preferredGesture: settings.onboardingPreferredGesture,
            userBinding: selectedBinding
        )
    }

    private var diagnosticContext: FirstUseDiagnosticContext {
        FirstUseDiagnosticContext(
            step: settings.onboardingStep,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            capabilities: capabilities,
            hasSelectedAudioUID: !settings.selectedAudioDeviceUID.isEmpty,
            voiceAttempt: settings.onboardingStep == .voiceTest ? voiceAttempt : nil,
            remoteInput: remoteInputDiagnostic
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

    private var selectedAudioDeviceDiagnosticKind: VirtualAudioDeviceDiagnosticKind {
        .classify(selectedAudioDevice)
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

    private func captureVoiceTranscriptCandidate(_ text: String) {
        guard settings.onboardingStep == .voiceTest,
              voiceAttempt.phase == .recording || voiceAttempt.phase == .awaitingTranscript,
              !manualTranscriptInputObserved,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        lastVoiceTranscriptCandidate = text
    }

    private var verifiedTranscriptionAppeared: Bool {
        transcriptionAppeared && !manualTranscriptInputObserved
    }

    private var selectedControlConnected: Bool {
        if settings.onboardingControlMethod == .physicalRemote {
            return OnboardingFlowPolicy.isPhysicalRemoteRecognized(
                at: settings.onboardingStep,
                voiceConnectionReady: model.isOnboardingControlSourceConnected(
                    settings.onboardingControlSource
                ),
                validatedHIDButtonObserved: !observedRemoteButtons.isEmpty
            )
        }
        return model.isOnboardingControlSourceConnected(settings.onboardingControlSource)
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

    private var externalToolExpectedVoiceKeyText: String {
        guard let plan = proposedPairingPlan else {
            return localization.text("onboarding.pairing_plan.needs_learning")
        }
        return LocalizedMessage(
            "onboarding.voice_test.configuration.binding_expected",
            arguments: [
                localization.text(plan.binding.shortcut.localizationKey),
                localization.text("onboarding.gesture.\(plan.binding.gestureMode.rawValue)"),
            ]
        ).text(using: localization)
    }

    private var externalToolExpectedVoiceKeyDiagnosticValue: String {
        guard let plan = proposedPairingPlan else { return "unresolved" }
        return "\(plan.binding.shortcut.rawValue)_\(plan.binding.gestureMode.rawValue)"
    }

    private var sayAllVoiceKeyConfigurationReady: Bool {
        guard let plan = proposedPairingPlan else { return false }
        return settings.voiceKeyMode == plan.binding.shortcut &&
            settings.voiceFnTapModeEnabled == plan.fnTapModeEnabled
    }

    private var sayAllVoiceKeyConfigurationText: String {
        guard !sayAllVoiceKeyConfigurationReady else {
            return externalToolExpectedVoiceKeyText
        }
        let current: String
        if settings.voiceKeyMode == .function {
            current = localization.text(
                settings.voiceFnTapModeEnabled
                    ? "onboarding.voice_test.configuration.voice_key_fn_tap"
                    : "onboarding.voice_test.configuration.voice_key_fn_hold"
            )
        } else {
            current = localization.text(settings.voiceKeyMode.localizationKey)
        }
        return LocalizedMessage(
            "onboarding.voice_test.configuration.sayall_voice_key_mismatch",
            arguments: [current, externalToolExpectedVoiceKeyText]
        ).text(using: localization)
    }

    private var sayAllAudioOutputConfigurationText: String {
        guard let selectedAudioDevice else {
            return localization.text("onboarding.audio.select_required")
        }
        guard onboardingAudioReady else {
            return LocalizedMessage(
                "onboarding.voice_test.configuration.audio_output_not_ready",
                arguments: [selectedAudioDevice.name]
            ).text(using: localization)
        }
        return selectedAudioDevice.name
    }

    private var externalToolGlobalVoiceConfirmationRequired: Bool {
        OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(
            for: settings.onboardingVoiceTool
        )
    }

    private var externalToolConfigurationConfirmed: Bool {
        sayAllVoiceKeyConfigurationReady &&
            onboardingAudioReady &&
            externalToolVoiceKeyConfirmed &&
            (!externalToolGlobalVoiceConfirmationRequired || externalToolGlobalVoiceConfirmed) &&
            externalToolMicrophoneConfirmed
    }

    private var selectedVoiceToolRuntimeReady: Bool {
        let tool = settings.onboardingVoiceTool
        let runtimeState = voiceToolRuntimeState[tool] ?? .unknown
        return !OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: tool) ||
            runtimeState == .running
    }

    private var selectedVoiceToolRuntimeStatusText: String? {
        switch voiceToolRuntimeState[settings.onboardingVoiceTool] ?? .unknown {
        case .running, .notApplicable:
            return nil
        case .notRunning:
            return LocalizedMessage(
                "onboarding.voice_tool.runtime.not_running",
                arguments: [localization.text(settings.onboardingVoiceTool.titleKey)]
            ).text(using: localization)
        case .unknown:
            guard OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(
                for: settings.onboardingVoiceTool
            ) else { return nil }
            return LocalizedMessage(
                "onboarding.voice_tool.runtime.unknown",
                arguments: [localization.text(settings.onboardingVoiceTool.titleKey)]
            ).text(using: localization)
        }
    }

    private func openSelectedVoiceTool() {
        let tool = settings.onboardingVoiceTool
        _ = OnboardingInputSourceSwitcher.launchApplication(for: tool, activates: true) { success in
            DispatchQueue.main.async {
                AppLogger.shared.write(
                    "ONBOARDING VOICE_TOOL open tool=\(tool.rawValue) success=\(success)"
                )
                refreshSelectedVoiceToolRuntimeState()
            }
        }
    }

    private func ensureSelectedVoiceToolRunning() {
        let tool = settings.onboardingVoiceTool
        guard OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: tool),
              voiceToolRuntimeState[tool] != .running else { return }
        _ = OnboardingInputSourceSwitcher.launchApplication(for: tool, activates: false) { success in
            DispatchQueue.main.async {
                AppLogger.shared.write(
                    "ONBOARDING VOICE_TOOL auto_launch tool=\(tool.rawValue) success=\(success)"
                )
                refreshSelectedVoiceToolRuntimeState()
            }
        }
    }

    private var voiceTestStatusText: String {
        if !selectedVoiceToolRuntimeReady {
            return localization.text("onboarding.voice_test.tool_not_running")
        }
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

    private func bundledRemoteImage(resourceName: String) -> NSImage? {
        guard let url = RemoteMicResourceBundle.mainOrDevelopment.url(
            forResource: resourceName,
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func voiceToolIcon(_ tool: OnboardingVoiceTool) -> String {
        switch tool {
        case .doubao: return "quote.bubble.fill"
        case .weixin: return "message.fill"
        case .typeless: return "waveform.badge.mic"
        case .vokie: return "sparkles.rectangle.stack.fill"
        case .chatterFly: return "bird.fill"
        case .other: return "ellipsis.circle.fill"
        case .unselected: return "circle"
        }
    }

    private func controlSourceIcon(_ source: OnboardingControlSource) -> String {
        switch source {
        case .xiaomiRemote: return "appletvremote.gen4.fill"
        case .siriRemote: return "appletvremote.gen4.fill"
        case .chromecastRemote: return "tv.and.hifispeaker.fill"
        case .appleCompanion: return "iphone.and.arrow.forward"
        case .webRemote: return "safari.fill"
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
        case .unselected, .typeless, .vokie, .chatterFly, .other:
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

    private func defaultBindingSummary(profile: VoiceToolAdapterProfile) -> String {
        let descriptions = VoiceGestureMode.allCases.compactMap { mode -> String? in
            guard let shortcut = profile.defaultShortcutByMode[mode] else { return nil }
            return "\(localization.text("onboarding.gesture.\(mode.rawValue)")): " +
                localization.text(shortcut.localizationKey)
        }
        if descriptions.isEmpty {
            return localization.text("onboarding.voice_tool.binding.no_documented_default")
        }
        let evidence = localization.text(
            profile.evidenceState == .verified
                ? "onboarding.voice_tool.binding.evidence_verified"
                : "onboarding.voice_tool.binding.evidence_pending"
        )
        return descriptions.joined(separator: " · ") + " · " + evidence
    }

    private func onboardingGuideImage(resourceName: String) -> NSImage? {
        let appearance = colorScheme == .dark ? "dark" : "light"
        guard let url = RemoteMicResourceBundle.mainOrDevelopment.url(
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
        if tool == .other {
            settings.setOnboardingVoiceBindingPreference(.learnCurrent)
        }
        AppLogger.shared.write(
            "ONBOARDING VOICE_TOOL selected=\(tool.rawValue) binding_policy=profile_or_learned"
        )
        selectedInputMethodGuideStep = 0
        refreshSelectedInputMethodStatus()
        refreshSystemFunctionKeyUsage()
    }

    private func selectVoiceBindingPreference(_ preference: OnboardingVoiceBindingPreference) {
        settings.setOnboardingVoiceBindingPreference(preference)
        stageCurrentDocumentedPairingPlanIfPossible()
    }

    private func selectPreferredGesture(_ gesture: VoiceGestureMode) {
        settings.setOnboardingPreferredGesture(gesture)
        stageCurrentDocumentedPairingPlanIfPossible()
    }

    private func stageCurrentDocumentedPairingPlanIfPossible() {
        guard settings.onboardingVoiceBindingPreference == .documentedDefault,
              let plan = proposedPairingPlan else { return }
        settings.beginOnboardingVoiceTrial(plan)
        model.setVoiceKeyMode(plan.binding.shortcut)
        model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)
        applyChromecastModeIfNeeded(plan)
    }

    private func enforceOnboardingVoiceKeyPolicy() {
        if let pending = settings.consumePendingOnboardingVoiceKeyMigration() {
            voiceKeyMigrationSource = pending
        }
    }

    private func refreshVoiceToolAvailability() {
        if let voiceToolAvailabilityOverride {
            voiceToolAvailability = voiceToolAvailabilityOverride
            refreshSelectedVoiceToolRuntimeState()
            return
        }
        var availability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [:]
        for tool in [
            OnboardingVoiceTool.doubao, .weixin, .typeless, .vokie, .chatterFly, .other,
        ] {
            availability[tool] = OnboardingInputSourceSwitcher.availability(for: tool)
        }
        voiceToolAvailability = availability
        refreshSelectedVoiceToolRuntimeState()
    }

    private func refreshSelectedVoiceToolRuntimeState() {
        let tool = settings.onboardingVoiceTool
        voiceToolRuntimeState[tool] = OnboardingInputSourceSwitcher.runtimeState(for: tool)
    }

    private func selectControlSource(_ source: OnboardingControlSource) {
        settings.setOnboardingControlSource(source)
        model.applyHIDSettings()
        if source.supportedGestureModes.count == 1 {
            settings.setOnboardingPreferredGesture(source.supportedGestureModes.first)
        } else {
            settings.setOnboardingPreferredGesture(nil)
        }
        observedRemoteButtons.removeAll()
        remoteInputDiagnostic = FirstUseRemoteInputDiagnostic()
        testedControlButtons.removeAll()
        stageCurrentDocumentedPairingPlanIfPossible()
    }

    private func handleLearnedShortcut(_ shortcut: CustomKeyboardShortcut) {
        isCapturingVoiceShortcut = false
        guard let modifier = shortcut.standaloneModifier,
              let mode = VoiceKeyMode(standaloneModifier: modifier) else {
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.unsupported"
            return
        }
        let gesture = settings.onboardingPreferredGesture ??
            VoiceToolAdapterProfile.profile(for: settings.onboardingVoiceTool).recommendedMode ??
            .hold
        guard let plan = settings.stageLearnedOnboardingBinding(
            shortcut: mode,
            gesture: gesture
        ) else {
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.incompatible"
            return
        }
        shortcutCaptureErrorKey = nil
        model.setVoiceKeyMode(plan.binding.shortcut)
        model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)
        applyChromecastModeIfNeeded(plan)
    }

    private func handleShortcutCaptureFailure(_ failure: ShortcutCaptureStartFailure) {
        isCapturingVoiceShortcut = false
        switch failure {
        case .accessibilityPermissionRequired:
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.permission_required"
        case .eventTapUnavailable:
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.unavailable"
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
        remoteInputDiagnostic = FirstUseRemoteInputDiagnostic()
        testedControlButtons.removeAll()
    }

    private func refreshSelectedInputMethodStatus() {
        guard settings.onboardingStep == .voiceTool else { return }
        let tool = settings.onboardingVoiceTool
        guard tool.requiresFunctionKeySetup else {
            inputSourceSwitchResult = .notApplicable
            return
        }
        inputSourceSwitchResult = OnboardingInputSourceSwitcher.selectionState(for: tool)
        AppLogger.shared.write(
            "ONBOARDING INPUT SOURCE tool=\(tool.rawValue) observed=\(inputSourceSwitchResult.rawValue)"
        )
    }

    private func activateSelectedInputMethod() {
        guard settings.onboardingStep == .voiceTool else { return }
        let tool = settings.onboardingVoiceTool
        guard tool.requiresFunctionKeySetup else { return }
        guard allowsInputSourceSwitching else {
            inputSourceSwitchResult = .selected
            return
        }

        inputSourceSwitchResult = OnboardingInputSourceSwitcher.selectIfNeeded(tool)
        AppLogger.shared.write(
            "ONBOARDING INPUT SOURCE tool=\(tool.rawValue) action=explicit_user result=\(inputSourceSwitchResult.rawValue)"
        )
    }

    private func inputSourceSwitchStatusText(for tool: OnboardingVoiceTool) -> String {
        let toolName = localization.text(tool.titleKey)
        let key: String
        switch inputSourceSwitchResult {
        case .selected:
            key = "onboarding.voice_tool.switch.selected"
        case .notSelected:
            key = "onboarding.voice_tool.switch.not_selected"
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
            refreshSelectedInputMethodStatus()
            refreshSystemFunctionKeyUsage()
        case .remoteAvailability:
            routeConnectedPhysicalRemoteIfNeeded()
        case .remote:
            observedRemoteButtons.removeAll()
            remoteInputDiagnostic = remoteInputDiagnosticOverride ?? FirstUseRemoteInputDiagnostic()
            requestedRemoteConnectionRecovery = false
            prepareSelectedControlConnection()
        case .audio:
            model.refreshAudioDevices()
        case .voiceTest:
            refreshSelectedVoiceToolRuntimeState()
            ensureSelectedVoiceToolRunning()
            resetVoiceTestForRetry()
        case .controls:
            testedControlButtons.removeAll()
        case .complete:
            prepareSelectedControlConnection()
            model.refreshAudioDevices()
        default:
            break
        }
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
        case .voiceNoSamples, .voiceAudioDeliveryFailed:
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
        voiceAttemptStartedAtUptime = nil
        voiceTranscriptWaitStartedAtUptime = nil
        activeFocusLossStartedAtUptime = nil
        voiceSessionStarted = false
        voiceSamplesReceived = false
        voiceSessionEnded = false
        lastVoiceTranscriptCandidate = ""
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
            let now = ProcessInfo.processInfo.systemUptime
            let targetReady = snapshot.editorMounted && snapshot.windowKey && snapshot.firstResponder
            if !targetReady {
                voiceAttempt.focusLost = true
                voiceAttempt.focusEditorUnmounted = voiceAttempt.focusEditorUnmounted || !snapshot.editorMounted
                voiceAttempt.focusWindowNotKey = voiceAttempt.focusWindowNotKey || !snapshot.windowKey
                voiceAttempt.focusFirstResponderChanged =
                    voiceAttempt.focusFirstResponderChanged || !snapshot.firstResponder
                if activeFocusLossStartedAtUptime == nil {
                    activeFocusLossStartedAtUptime = now
                    voiceAttempt.focusLossCount += 1
                    if voiceAttempt.firstFocusLossLatencyMilliseconds == nil,
                       let voiceAttemptStartedAtUptime {
                        voiceAttempt.firstFocusLossLatencyMilliseconds = max(
                            0,
                            Int((now - voiceAttemptStartedAtUptime) * 1_000)
                        )
                    }
                }
            } else if let lossStartedAt = activeFocusLossStartedAtUptime {
                voiceAttempt.totalFocusLossMilliseconds += max(
                    0,
                    Int((now - lossStartedAt) * 1_000)
                )
                activeFocusLossStartedAtUptime = nil
                voiceAttempt.focusRecovered = true
            }
            voiceAttempt.editorMounted = snapshot.editorMounted
        }
        if changed {
            AppLogger.shared.write(
                "ONBOARDING TRANSCRIPT_TARGET attempt=\(voiceAttempt.attemptID) " +
                    "phase=\(voiceAttempt.phase.rawValue) mounted=\(snapshot.editorMounted) " +
                    "window_key=\(snapshot.windowKey) first_responder=\(snapshot.firstResponder) " +
                    "ready=\(snapshot.editorMounted && snapshot.windowKey && snapshot.firstResponder) " +
                    "loss_count=\(voiceAttempt.focusLossCount)"
            )
        }
    }

    private func beginVoiceAttempt(triggerPath: String) {
        voiceTranscriptDeadlineToken = UUID()
        voiceAttemptStartedAtUptime = ProcessInfo.processInfo.systemUptime
        voiceTranscriptWaitStartedAtUptime = nil
        activeFocusLossStartedAtUptime = nil
        voiceSessionStarted = true
        voiceSamplesReceived = false
        voiceSessionEnded = false
        lastVoiceTranscriptCandidate = ""
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
            externalToolVoiceKeyUserConfirmed: externalToolVoiceKeyConfirmed,
            externalToolExpectedVoiceKey: externalToolExpectedVoiceKeyDiagnosticValue,
            externalToolGlobalVoiceApplicable: externalToolGlobalVoiceConfirmationRequired,
            externalToolGlobalVoiceUserConfirmed: !externalToolGlobalVoiceConfirmationRequired ||
                externalToolGlobalVoiceConfirmed,
            externalToolMicrophoneUserConfirmed: externalToolMicrophoneConfirmed,
            audioDelivery: model.voiceAudioDeliveryDiagnosticSnapshot(),
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
                "first_responder=\(transcriptFirstResponder) " +
                "external_microphone_observable=false " +
                "external_microphone_user_confirmed=\(externalToolMicrophoneConfirmed) " +
                "audio_generation=\(voiceAttempt.audioDelivery.generation) " +
                "audio_selected=\(voiceAttempt.audioDelivery.outputAtStart.selectedDeviceKind.rawValue) " +
                "audio_actual=\(voiceAttempt.audioDelivery.outputAtStart.actualDeviceKind.rawValue) " +
                "audio_bound=\(voiceAttempt.audioDelivery.outputAtStart.boundToSelectedDevice.map(String.init) ?? "unknown")"
        )
    }

    private func endVoiceAttempt() {
        guard voiceAttempt.phase == .recording else { return }
        voiceSessionEnded = true
        voiceAttempt.phase = .awaitingTranscript
        let attemptID = voiceAttempt.attemptID
        let transcriptCandidate = lastVoiceTranscriptCandidate
        transcriptCommitRequest &+= 1
        scheduleTranscriptRecovery(
            attemptID: attemptID,
            candidate: transcriptCandidate
        )
        let targetReadyAtEnd = transcriptEditorMounted && transcriptWindowKey && transcriptFirstResponder
        voiceAttempt.firstResponderAtEnd = targetReadyAtEnd
        voiceAttempt.focusReadyAtEnd = targetReadyAtEnd
        voiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        if let voiceAttemptStartedAtUptime {
            voiceAttempt.sessionDurationMilliseconds = elapsedMilliseconds(
                sinceUptime: voiceAttemptStartedAtUptime
            )
        }
        voiceTranscriptWaitStartedAtUptime = ProcessInfo.processInfo.systemUptime

        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: manualTranscriptInputObserved,
            samplesReceived: voiceSamplesReceived,
            transcriptionAppeared: transcriptionAppeared,
            triggerReady: voiceAttempt.triggerReady,
            focusReadyAtDeadline: targetReadyAtEnd,
            audioDeliveryResult: voiceAttempt.audioDelivery.result,
            finalObservation: false
        )
        if result == .manualInput || result == .noSamples || result == .audioDeliveryFailed {
            finishVoiceAttempt(result: result)
        } else {
            scheduleVoiceTranscriptDeadline(attemptID: voiceAttempt.attemptID)
        }
    }

    private func scheduleTranscriptRecovery(attemptID: Int, candidate: String) {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard settings.onboardingStep == .voiceTest,
                      voiceAttempt.attemptID == attemptID,
                      voiceSessionEnded,
                      !manualTranscriptInputObserved,
                      transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                transcript = candidate
                AppLogger.shared.write(
                    "ONBOARDING TRANSCRIPT restored_after_voice_release=true source=voice_candidate"
                )
            }
        }
    }

    private func scheduleVoiceCompletionEvaluation(attemptID: Int) {
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard settings.onboardingStep == .voiceTest,
                      voiceAttempt.attemptID == attemptID,
                      voiceAttempt.phase == .awaitingTranscript,
                      voiceSessionEnded,
                      !manualTranscriptInputObserved,
                      transcriptionAppeared else {
                    return
                }
                refreshVoiceAttemptObservableState(atDeadline: false)
                if voiceAttempt.audioDelivery.result == .deliveredToSelectedDevice {
                    finishVoiceAttempt(result: .passed)
                }
            }
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
            refreshVoiceAttemptObservableState(atDeadline: true)
            let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
                manualInputObserved: manualTranscriptInputObserved,
                samplesReceived: voiceSamplesReceived,
                transcriptionAppeared: transcriptionAppeared,
                triggerReady: voiceAttempt.triggerReady,
                focusReadyAtDeadline: voiceAttempt.focusReadyAtDeadline == true,
                audioDeliveryResult: voiceAttempt.audioDelivery.result,
                finalObservation: true
            )
            finishVoiceAttempt(result: result)
        }
    }

    private func finishVoiceAttempt(result: FirstUseVoiceAttemptResult) {
        guard voiceAttempt.phase == .awaitingTranscript else { return }
        voiceTranscriptDeadlineToken = UUID()
        refreshVoiceAttemptObservableState(atDeadline: false)
        if let voiceTranscriptWaitStartedAtUptime {
            voiceAttempt.transcriptWaitMilliseconds = elapsedMilliseconds(
                sinceUptime: voiceTranscriptWaitStartedAtUptime
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
                "result=\(result.rawValue) observed_failure=\(result.observedFailure) " +
                "probable_cause=\(voiceAttempt.probableCause) " +
                "probable_cause_confirmed=\(voiceAttempt.probableCauseConfirmed) " +
                "boundary=\(result.diagnosticBoundary) " +
                "audio_generation=\(voiceAttempt.audioDelivery.generation) " +
                "audio_route=\(voiceAttempt.audioDelivery.route.rawValue) " +
                "audio_result=\(voiceAttempt.audioDelivery.result.rawValue) " +
                "audio_selected=\(voiceAttempt.audioDelivery.outputAtStart.selectedDeviceKind.rawValue) " +
                "audio_actual_start=\(voiceAttempt.audioDelivery.outputAtStart.actualDeviceKind.rawValue) " +
                "audio_bound_start=\(voiceAttempt.audioDelivery.outputAtStart.boundToSelectedDevice.map(String.init) ?? "unknown") " +
                "audio_actual_observation=\(voiceAttempt.audioDelivery.outputAtObservation.actualDeviceKind.rawValue) " +
                "audio_bound_observation=\(voiceAttempt.audioDelivery.outputAtObservation.boundToSelectedDevice.map(String.init) ?? "unknown") " +
                "audio_received_samples=\(voiceAttempt.audioDelivery.receivedSamples) " +
                "audio_scheduled_samples=\(voiceAttempt.audioDelivery.scheduledSamples) " +
                "audio_played_samples=\(voiceAttempt.audioDelivery.playedSamples) " +
                "audio_interrupted_samples=\(voiceAttempt.audioDelivery.interruptedSamples) " +
                "audio_pending_samples=\(voiceAttempt.audioDelivery.outputAtObservation.pendingSamples) " +
                "audio_enqueue_failures=\(voiceAttempt.audioDelivery.enqueueFailures) " +
                "focus_loss_count=\(voiceAttempt.focusLossCount) " +
                "focus_editor_unmounted=\(voiceAttempt.focusEditorUnmounted) " +
                "focus_window_not_key=\(voiceAttempt.focusWindowNotKey) " +
                "focus_first_responder_changed=\(voiceAttempt.focusFirstResponderChanged) " +
                "focus_recovered=\(voiceAttempt.focusRecovered) " +
                "focus_ready_at_end=\(voiceAttempt.focusReadyAtEnd) " +
                "focus_ready_at_deadline=\(voiceAttempt.focusReadyAtDeadline.map(String.init) ?? "unknown") " +
                "focus_total_loss_ms=\(voiceAttempt.totalFocusLossMilliseconds) " +
                "external_voice_key_observable=false " +
                "external_voice_key_user_confirmed=\(voiceAttempt.externalToolVoiceKeyUserConfirmed) " +
                "external_expected_voice_key=\(voiceAttempt.externalToolExpectedVoiceKey) " +
                "external_global_voice_observable=false " +
                "external_global_voice_applicable=\(voiceAttempt.externalToolGlobalVoiceApplicable) " +
                "external_global_voice_user_confirmed=\(voiceAttempt.externalToolGlobalVoiceUserConfirmed) " +
                "external_microphone_observable=false " +
                "external_microphone_user_confirmed=\(voiceAttempt.externalToolMicrophoneUserConfirmed) " +
                "external_next_checks=trigger_matches_binding,global_voice_enabled_if_required," +
                "microphone_matches_selected_device " +
                "first_sample_latency_ms=\(voiceAttempt.firstSampleLatencyMilliseconds.map(String.init) ?? "unavailable") " +
                "session_duration_ms=\(voiceAttempt.sessionDurationMilliseconds.map(String.init) ?? "unavailable") " +
                "session_under_1s=\((voiceAttempt.sessionDurationMilliseconds ?? 1_000) < 1_000) " +
                "transcript_wait_ms=\(voiceAttempt.transcriptWaitMilliseconds.map(String.init) ?? "unavailable")"
        )
    }

    private func refreshVoiceAttemptObservableState(atDeadline: Bool) {
        voiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        let targetReady = transcriptEditorMounted && transcriptWindowKey && transcriptFirstResponder
        if atDeadline {
            voiceAttempt.focusReadyAtDeadline = targetReady
        }
        if let lossStartedAt = activeFocusLossStartedAtUptime {
            let now = ProcessInfo.processInfo.systemUptime
            voiceAttempt.totalFocusLossMilliseconds += max(
                0,
                Int((now - lossStartedAt) * 1_000)
            )
            activeFocusLossStartedAtUptime = targetReady ? nil : now
            voiceAttempt.focusRecovered = voiceAttempt.focusRecovered || targetReady
        }
    }

    private func resetExternalToolMicrophoneConfirmation(reason: String) {
        guard externalToolMicrophoneConfirmed else { return }
        externalToolMicrophoneConfirmed = false
        AppLogger.shared.write(
            "ONBOARDING EXTERNAL_MICROPHONE_CONFIRMATION reset reason=\(reason)"
        )
    }

    private func resetExternalToolVoiceKeyConfirmation(reason: String) {
        guard externalToolVoiceKeyConfirmed else { return }
        externalToolVoiceKeyConfirmed = false
        AppLogger.shared.write(
            "ONBOARDING EXTERNAL_VOICE_KEY_CONFIRMATION reset reason=\(reason)"
        )
    }

    private func resetExternalToolGlobalVoiceConfirmation(reason: String) {
        guard externalToolGlobalVoiceConfirmed else { return }
        externalToolGlobalVoiceConfirmed = false
        AppLogger.shared.write(
            "ONBOARDING EXTERNAL_GLOBAL_VOICE_CONFIRMATION reset reason=\(reason)"
        )
    }

    private func elapsedMilliseconds(sinceUptime uptime: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - uptime) * 1_000))
    }

    private func copyDiagnosticSummary() {
        var diagnosticVoiceAttempt = voiceAttempt
        diagnosticVoiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: FirstUseDiagnosticSnapshot.architecture,
            voiceTool: settings.onboardingVoiceTool,
            voiceKeyMode: settings.voiceKeyMode,
            voiceFnTapModeEnabled: settings.voiceFnTapModeEnabled,
            context: diagnosticContext,
            voiceAttempt: diagnosticVoiceAttempt,
            bluetoothStatus: model.connectionStatus.key,
            buttonStatus: model.hidStatus.key,
            audioStatus: model.audioStatus.key,
            events: settings.firstUseEvents,
            appLanguage: localization.locale.identifier,
            controlSource: settings.onboardingControlSource,
            voiceBinding: settings.stagedVoiceToolBinding ?? settings.verifiedVoiceToolBinding
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.redactedText, forType: .string)
        AppLogger.shared.write(
            "ONBOARDING DIAGNOSTICS copied step=\(settings.onboardingStep.rawValue) " +
                "failure=\(failureReason?.rawValue ?? "none")"
        )
        AppLogger.shared.writeDiagnosticSummary(
            snapshot.redactedText,
            event: "ONBOARDING DIAGNOSTICS"
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

    private func recordRemoteVoiceButtonPress() {
        remoteInputDiagnostic.recordVoiceButtonPress()
        AppLogger.shared.write(
            "ONBOARDING REMOTE_INPUT observed=voice " +
                "source=\(model.activeVoiceSource?.rawValue ?? "unknown") " +
                "voice_count=\(remoteInputDiagnostic.voiceButtonPressCount) " +
                "control_count=\(remoteInputDiagnostic.controlButtonObservationCount) " +
                "last_input=\(remoteInputDiagnostic.lastInputKind.rawValue)"
        )
    }

    private func recordRemoteControlButtons(_ buttons: Set<RemoteButton>, source: String) {
        let newlyObserved = buttons.subtracting(observedRemoteButtons)
        guard !newlyObserved.isEmpty else { return }
        observedRemoteButtons.formUnion(newlyObserved)
        for _ in newlyObserved {
            remoteInputDiagnostic.recordControlButtonObservation()
        }
        AppLogger.shared.write(
            "ONBOARDING REMOTE_INPUT observed=control source=\(source) " +
                "new_count=\(newlyObserved.count) " +
                "voice_count=\(remoteInputDiagnostic.voiceButtonPressCount) " +
                "control_count=\(remoteInputDiagnostic.controlButtonObservationCount) " +
                "last_input=\(remoteInputDiagnostic.lastInputKind.rawValue)"
        )
    }

    private func prepareSelectedControlConnection() {
        switch settings.onboardingControlSource {
        case .xiaomiRemote:
            model.refreshRemoteDiscovery()
            model.applyHIDSettings()
        case .siriRemote:
            model.applyHIDSettings()
        case .chromecastRemote:
            #if SAYALL_CHROMECASE_ENABLED
            model.applyChromecaseSettings()
            model.reconnectChromecase()
            #endif
        case .appleCompanion:
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
        guard availablePhysicalControlSources == [.xiaomiRemote] else { return }
        let suppressForUserBack = suppressConnectedPhysicalRemoteAutoRouteOnce
        suppressConnectedPhysicalRemoteAutoRouteOnce = false
        guard OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: settings.onboardingStep,
            remoteConnected: model.isOnboardingControlSourceConnected(.xiaomiRemote),
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
        selectControlSource(.xiaomiRemote)
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
        switch settings.onboardingControlSource {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return source == .bluetoothRemote &&
                (model.activePhysicalVoiceControlSource == settings.onboardingControlSource ||
                    selectedPhysicalRemoteProfileMatchesSource)
        case .appleCompanion:
            return source == .nearbyPhone
        case .webRemote:
            return source == .webRemote
        case .unselected:
            return false
        }
    }

    private var selectedPhysicalRemoteProfileMatchesSource: Bool {
        guard let model = settings.selectedRemoteProfile?.model else { return false }
        switch settings.onboardingControlSource {
        case .xiaomiRemote:
            return !model.usesPrivateAdapter
        case .siriRemote:
            return model.isAppleSiriRemote
        case .chromecastRemote:
            return model.isChromecaseRemote
        case .appleCompanion, .webRemote, .unselected:
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
        if settings.onboardingStep == .voiceTest {
            settings.verifyOnboardingVoiceBinding()
        }
        if settings.onboardingStep != .voiceTest {
            settings.recordFirstUseEvent(.passed, step: settings.onboardingStep)
        }
        if settings.onboardingStep == .remoteAvailability {
            if settings.onboardingVoiceBindingPreference == .documentedDefault,
               let plan = proposedPairingPlan {
                settings.beginOnboardingVoiceTrial(plan)
                model.setVoiceKeyMode(plan.binding.shortcut)
                model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)
                applyChromecastModeIfNeeded(plan)
            }
            settings.setOnboardingStep(.permissions)
            return
        }
        if settings.onboardingStep == .permissions {
            if settings.onboardingControlMethod == .physicalRemote {
                settings.customMappingEnabled = true
            }
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
        if settings.onboardingStep == .permissions {
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
        if settings.onboardingStep == .permissions, previous == .remoteAvailability {
            settings.discardOnboardingVoiceTrial()
            model.applyHIDSettings()
        }
        settings.setOnboardingStep(previous)
    }

    private func applyChromecastModeIfNeeded(_ plan: OnboardingVoicePairingPlan) {
        guard plan.chromecastVoiceMode != nil else { return }
        #if SAYALL_CHROMECASE_ENABLED
        model.applyChromecaseSettings()
        #endif
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
    let commitRequest: Int
    let onTextStateChanged: (String) -> Void
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
        private var appliedCommitRequest: Int?
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
            if appliedCommitRequest != parent.commitRequest {
                appliedCommitRequest = parent.commitRequest
                commitMarkedTextIfNeeded()
            }
            if let textView,
               !textView.hasMarkedText(),
               textView.string != parent.text {
                textView.string = parent.text
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
            guard let textView else { return }
            let updatedText = textView.string
            parent.onTextStateChanged(updatedText)
            guard parent.text != updatedText else { return }
            parent.text = updatedText
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

        private func commitMarkedTextIfNeeded() {
            guard let textView, textView.hasMarkedText() else { return }
            textView.unmarkText()
            let committedText = textView.string
            parent.onTextStateChanged(committedText)
            if parent.text != committedText {
                parent.text = committedText
            }
            AppLogger.shared.write(
                "ONBOARDING TRANSCRIPT marked_text_commit=true"
            )
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

private struct OnboardingShortcutCaptureView: NSViewRepresentable {
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
            let monitor = ShortcutCaptureMonitor(onCapture: onCapture)
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
