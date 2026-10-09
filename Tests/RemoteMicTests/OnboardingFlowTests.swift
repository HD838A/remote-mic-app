import AppKit
import Foundation
import Testing
import SwiftUI
@testable import RemoteMic

@Suite("First-run onboarding")
struct OnboardingFlowTests {
    @Test @MainActor func offscreenProductionViewCanBeHostedWithoutUnlockingMac() throws {
        let suiteName = "RemoteMicTests.Onboarding.Offscreen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        settings.setOnboardingStep(.welcome)
        let model = BridgeAppModel(settings: settings)
        let probe = OnboardingInteractionProbe()
        let localization = LocalizationStore(
            settings: settings,
            resourceBundle: RemoteMicResourceBundle.mainOrDevelopment
        )
        let rootView = OnboardingView(
            model: model,
            completeRuntimeReadyOverride: true,
            allowsInputSourceSwitching: false,
            voiceToolAvailabilityOverride: [
                .doubao: .available,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ],
            interactionProbe: probe
        )
        .environmentObject(localization)
        .frame(width: 1020, height: 772)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1020, height: 772),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = hostingController
        defer {
            window.contentViewController = nil
            window.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentView != nil)
        #expect(probe.actions.keys.contains("continue"))
        #expect(!probe.actions.keys.contains("back"))
        probe.invoke("continue")
        #expect(settings.onboardingStep == .remoteAvailability)
    }

    @Test func onboardingUserCopyDoesNotExposeInternalValidationLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let forbiddenPhrases = [
            "待验证", "待复核", "验证中", "未完成", "不确定", "状态未知",
            "默认值待", "安装状态待", "Needs validation", "Needs review",
            "versioned validation", "in development", "validation pending",
            "status unknown", "uncertain", "Radio"
        ]

        for relativePath in [
            "Resources/zh-Hans.lproj/Localizable.strings",
            "Resources/en.lproj/Localizable.strings",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for line in source.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("\"onboarding.") else { continue }
                for phrase in forbiddenPhrases {
                    #expect(
                        !line.localizedCaseInsensitiveContains(phrase),
                        "Onboarding copy must not expose internal phrase: \(phrase)"
                    )
                }
            }
        }
    }

    @Test func legacyChatterFlySelectionMigratesToUnselected() throws {
        let suiteName = "RemoteMicTests.Onboarding.ChatterFlyMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("chatterfly", forKey: "onboarding.voiceTool")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.onboardingVoiceTool == .unselected)
        #expect(defaults.string(forKey: "onboarding.voiceTool") == OnboardingVoiceTool.unselected.rawValue)
    }

    @Test func voiceTestPromptUsesOnlyTheSelectedGesture() {
        let hold = OnboardingVoiceGesturePrompt.text(for: .hold, locale: Locale(identifier: "zh-Hans"))
        let toggle = OnboardingVoiceGesturePrompt.text(for: .toggle, locale: Locale(identifier: "zh-Hans"))
        #expect(hold.contains("按住"))
        #expect(toggle.contains("按一下"))
        #expect(!hold.contains("Fn"))
        #expect(!toggle.contains("Fn"))
        #expect(!hold.contains("快捷键"))
        #expect(!toggle.contains("快捷键"))
    }

    @Test func welcomePromptDescribesHeadlessAgentConfiguration() {
        let prompt = OnboardingAIAssistantPrompt.chinese
        #expect(prompt.contains("--agent-configure"))
        #expect(prompt.contains("--json"))
        #expect(prompt.contains("不要操作屏幕"))
        #expect(prompt.contains("停在真实语音测试步骤"))
        #expect(!prompt.contains("/Users/"))
    }

    @Test func agentConfigurationCommandIsHeadlessAndKeepsVerificationAsASeparateStep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let commandSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/AgentConfigurationCommand.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        #expect(commandSource.contains("--verify"))
        #expect(commandSource.contains("onboarding.agent_configuration_backup"))
        #expect(commandSource.contains("recoverInterruptedConfigurationIfNeeded"))
        #expect(commandSource.contains("real_voice_test"))
        #expect(commandSource.contains("permission_required"))
        #expect(appSource.contains("--agent-configure"))
        #expect(!commandSource.contains("NSAppleScript"))
        #expect(!commandSource.contains("CGWindowList"))
    }

    @Test func controlSourcePresentationUsesSourceSpecificPairingAndButtons() throws {
        let xiaomiPairing = OnboardingView.physicalRemotePairingKeys(for: .xiaomiRemote)
        #expect(xiaomiPairing.firstStep == "onboarding.remote.first_pairing.wake")
        #expect(xiaomiPairing.secondStep == "onboarding.remote.first_pairing.pair")

        let siriPairing = OnboardingView.physicalRemotePairingKeys(for: .siriRemote)
        #expect(siriPairing.firstStep == "onboarding.remote.siri_pairing.first")
        #expect(siriPairing.secondStep == "onboarding.remote.siri_pairing.second")
        #expect(siriPairing.thirdStep == "onboarding.remote.siri_pairing.third")

        let chromecastPairing = OnboardingView.physicalRemotePairingKeys(for: .chromecastRemote)
        #expect(chromecastPairing.firstStep == "onboarding.remote.chromecast_pairing.first")
        #expect(chromecastPairing.secondStep == "onboarding.remote.chromecast_pairing.second")

        #expect(OnboardingView.displayedControlButtons(for: .xiaomiRemote) == RemoteButton.xiaomiCases)
        #expect(Set(try #require(OnboardingView.displayedControlButtons(for: .siriRemote))) == [
            .power, .up, .left, .ok, .right, .down,
            .back, .volumeUp, .volumeDown, .tv, .playPause, .mute,
        ])
        #expect(Set(try #require(OnboardingView.displayedControlButtons(for: .chromecastRemote))) == [
            .power, .up, .left, .ok, .right, .down, .back,
            .home, .volumeUp, .volumeDown, .mute, .youtube, .netflix, .input,
        ])

        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .xiaomiRemote) ==
            "onboarding.recovery.remote.not_found.physical_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .siriRemote) ==
            "onboarding.recovery.remote.not_found.physical_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .chromecastRemote) ==
            "onboarding.recovery.remote.not_found.physical_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .appleCompanion) ==
            "onboarding.recovery.remote.not_found.apple_companion_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .webRemote) ==
            "onboarding.recovery.remote.not_found.web_remote_detail")
        #expect(OnboardingView.displayedControlButtons(for: .appleCompanion) == nil)
        #expect(OnboardingView.displayedControlButtons(for: .webRemote) == nil)
        #expect(OnboardingView.controlsDetailKey(for: .appleCompanion) ==
            "onboarding.controls.apple_companion.detail")
        #expect(OnboardingView.controlsDetailKey(for: .webRemote) ==
            "onboarding.controls.web_remote.detail")
    }

    @Test func navigationOrderIsStableAndGroupedIntoThreePhases() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .remoteAvailability)
        #expect(OnboardingStep.remoteAvailability.next == .permissions)
        #expect(OnboardingStep.controlMethod.normalized == .remoteAvailability)
        #expect(OnboardingStep.controlMethod.next == .permissions)
        #expect(OnboardingStep.permissions.next == .remote)
        #expect(OnboardingStep.remote.next == .audio)
        #expect(OnboardingStep.audio.next == .voiceTool)
        #expect(OnboardingStep.voiceTool.next == .voiceTest)
        #expect(OnboardingStep.voiceTest.next == .controls)
        #expect(OnboardingStep.controls.next == .complete)
        #expect(OnboardingStep.complete.next == nil)

        #expect(OnboardingPhase.phase(for: .welcome) == .prepare)
        #expect(OnboardingPhase.phase(for: .remoteAvailability) == .prepare)
        #expect(OnboardingPhase.phase(for: .controlMethod) == .prepare)
        #expect(OnboardingPhase.phase(for: .permissions) == .setup)
        #expect(OnboardingPhase.phase(for: .complete) == .tryIt)
    }

    @Test func ordinaryButtonValidationSuppressesExistingMappingsOnlyOnControlsPage() {
        for source in [
            OnboardingControlSource.xiaomiRemote,
            .siriRemote,
            .chromecastRemote,
            .appleCompanion,
            .webRemote,
        ] {
            #expect(OnboardingControlValidationPolicy.suppressConfiguredActions(
                at: .controls,
                source: source
            ))
            #expect(!OnboardingControlValidationPolicy.suppressConfiguredActions(
                at: .voiceTest,
                source: source
            ))
        }
        #expect(!OnboardingControlValidationPolicy.suppressConfiguredActions(
            at: .controls,
            source: .unselected
        ))
    }

    @Test func secureInputWarningIsLimitedToConnectedPhysicalRemote() {
        #expect(OnboardingSecureInputPolicy.shouldMonitor(
            step: .remote,
            source: .xiaomiRemote
        ))
        #expect(OnboardingSecureInputPolicy.shouldMonitor(
            step: .controls,
            source: .chromecastRemote
        ))
        #expect(!OnboardingSecureInputPolicy.shouldMonitor(
            step: .controls,
            source: .appleCompanion
        ))
        #expect(!OnboardingSecureInputPolicy.shouldShowWarning(
            step: .controls,
            source: .xiaomiRemote,
            remoteConnected: false,
            remoteButtonObserved: false,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 20
        ))
        #expect(!OnboardingSecureInputPolicy.shouldShowWarning(
            step: .controls,
            source: .xiaomiRemote,
            remoteConnected: true,
            remoteButtonObserved: true,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 20
        ))
        #expect(OnboardingSecureInputPolicy.shouldShowWarning(
            step: .controls,
            source: .xiaomiRemote,
            remoteConnected: true,
            remoteButtonObserved: false,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 13
        ))
        #expect(OnboardingSecureInputPolicy.shouldShowWarning(
            step: .remote,
            source: .xiaomiRemote,
            remoteConnected: true,
            remoteButtonObserved: false,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 13
        ))
    }

    @Test func everyControlMethodRequiresAllThreePermissions() {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: true,
            remoteButtonObserved: true
        )

        for method in [
            OnboardingControlMethod.physicalRemote,
            .iPhoneApp,
            .webRemote,
        ] {
            #expect(method.requiresBluetoothPermission)
            #expect(method.requiresInputMonitoringPermission)
            #expect(OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))

            capabilities.bluetoothGranted = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            capabilities.bluetoothGranted = true
            capabilities.inputMonitoringGranted = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            capabilities.inputMonitoringGranted = true
            capabilities.accessibilityGranted = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            capabilities.accessibilityGranted = true
        }

        #expect(!OnboardingControlMethod.unselected.requiresBluetoothPermission)
        #expect(!OnboardingControlMethod.unselected.requiresInputMonitoringPermission)

        #expect(!OnboardingFlowPolicy.canContinue(
            from: .remoteAvailability,
            voiceTool: .typeless,
            remoteAvailability: .unselected,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .remoteAvailability,
            voiceTool: .typeless,
            remoteAvailability: .hasRemote,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .controlMethod,
            voiceTool: .typeless,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            remoteAvailability: .noRemote,
            controlMethod: .unselected,
            capabilities: capabilities
        ))

        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))
    }

    @Test func permissionRowsRemainClickableAfterAuthorization() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("onboardingActionButton(id: id, action: action)"))
        #expect(viewSource.contains("action: requestBluetoothPermission"))
        #expect(viewSource.contains("action: requestInputMonitoringPermission"))
        #expect(viewSource.contains("action: requestAccessibilityPermission"))
        #expect(viewSource.contains("model.requestInputMonitoringPermission()"))
        #expect(viewSource.contains("model.requestAccessibilityPermission()"))
        #expect(viewSource.contains("if bluetoothAuthorization == .allowedAlways"))
        #expect(viewSource.contains("Privacy_Bluetooth"))
    }

    @Test func everyProductionInteractiveControlUsesTheOffscreenProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let helpersStart = try #require(viewSource.range(
            of: "private func onboardingActionButton"
        ))
        let productionBody = String(viewSource[..<helpersStart.lowerBound])

        #expect(!productionBody.contains("\n                    Button {"))
        #expect(!productionBody.contains("\n                Button {"))
        #expect(!productionBody.contains("\n            Button {"))
        #expect(!productionBody.contains("\n                    Link(destination:"))
        #expect(!productionBody.contains("\n            Link(destination:"))
        #expect(!productionBody.contains("Toggle(isOn:"))
        #expect(viewSource.contains("onboardingActionButton"))
        #expect(viewSource.contains("onboardingLink"))
        #expect(viewSource.contains("onboardingToggle"))
    }

    @Test func mobileControlPathsUseOnDemandAudioWithoutWeakeningDeviceSelection() {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: true,
            remoteButtonObserved: true,
            audioReady: false,
            audioOutputSelected: true
        )

        for method in [OnboardingControlMethod.iPhoneApp, .webRemote] {
            #expect(method.usesOnDemandAudioOutput)
            #expect(OnboardingFlowPolicy.canContinue(
                from: .audio,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            #expect(OnboardingFlowPolicy.canContinue(
                from: .complete,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))

            let diagnostic = FirstUseDiagnosticContext(
                step: .audio,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities,
                hasSelectedAudioUID: true
            )
            #expect(diagnostic.failureReason == nil)
        }

        #expect(!OnboardingControlMethod.physicalRemote.usesOnDemandAudioOutput)
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .audio,
            voiceTool: .typeless,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))

        capabilities.audioOutputSelected = false
        for method in [OnboardingControlMethod.iPhoneApp, .webRemote] {
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .audio,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .complete,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))

            let diagnostic = FirstUseDiagnosticContext(
                step: .audio,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities,
                hasSelectedAudioUID: true
            )
            #expect(diagnostic.failureReason == .audioSelectedDeviceMissing)
        }
    }

    @Test func connectedPhysicalRemoteSkipsOnlyTheAvailabilityQuestion() {
        #expect(OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .remoteAvailability,
            remoteConnected: true
        ))
        #expect(!OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .remoteAvailability,
            remoteConnected: false
        ))
        #expect(!OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .controlMethod,
            remoteConnected: true
        ))
        #expect(!OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .remoteAvailability,
            remoteConnected: true,
            suppressForUserBack: true
        ))
    }

    @Test func connectedRemotePreselectionDoesNotSkipTheControlSourcePage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("settings.onboardingControlSource == .unselected"))
        #expect(viewSource.contains("preselected=xiaomi_remote"))
        #expect(!viewSource.contains("to=permissions reason=connected_physical_remote"))
    }

    @Test func validatedRemoteButtonAlsoProvesThePhysicalRemoteIsRecognized() {
        #expect(OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .complete,
            voiceConnectionReady: true,
            validatedHIDButtonObserved: false
        ))
        #expect(OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .remote,
            voiceConnectionReady: false,
            validatedHIDButtonObserved: true
        ))
        #expect(!OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .remote,
            voiceConnectionReady: false,
            validatedHIDButtonObserved: false
        ))
        #expect(!OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .complete,
            voiceConnectionReady: false,
            validatedHIDButtonObserved: true
        ))
    }

    @Test func remoteInputDiagnosticDistinguishesVoiceFromControlButtons() {
        var diagnostic = FirstUseRemoteInputDiagnostic()

        diagnostic.recordVoiceButtonPress()
        diagnostic.recordVoiceButtonPress()

        #expect(diagnostic.voiceButtonPressCount == 2)
        #expect(diagnostic.controlButtonObservationCount == 0)
        #expect(diagnostic.lastInputKind == .voice)
        #expect(diagnostic.shouldShowVoiceButtonCorrection)

        diagnostic.recordControlButtonObservation()

        #expect(diagnostic.voiceButtonPressCount == 2)
        #expect(diagnostic.controlButtonObservationCount == 1)
        #expect(diagnostic.lastInputKind == .control)
        #expect(!diagnostic.shouldShowVoiceButtonCorrection)
    }

    @Test func everyRequiredCapabilityBlocksItsStepUntilVerified() {
        var capabilities = OnboardingCapabilities()

        #expect(OnboardingFlowPolicy.canContinue(
            from: .welcome,
            voiceTool: .unselected,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .unselected,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.bluetoothGranted = true
        capabilities.inputMonitoringGranted = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.accessibilityGranted = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.remoteConnected = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .remote,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.remoteButtonObserved = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .remote,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.audioReady = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .audio,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.audioOutputSelected = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .audio,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.voiceSessionStarted = true
        capabilities.voiceSamplesReceived = true
        capabilities.voiceSessionEnded = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTest,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.transcriptionAppeared = true
        capabilities.manualTranscriptInputObserved = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTest,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.manualTranscriptInputObserved = false
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTest,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.testedRemoteButtonCount = 2
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .controls,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.testedRemoteButtonCount = 3
        #expect(OnboardingFlowPolicy.canContinue(
            from: .controls,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        #expect(OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.remoteConnected = false
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.remoteConnected = true
        capabilities.remoteButtonObserved = false
        capabilities.voiceSessionStarted = false
        capabilities.voiceSamplesReceived = false
        capabilities.voiceSessionEnded = false
        capabilities.transcriptionAppeared = false
        capabilities.testedRemoteButtonCount = 0
        #expect(OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
    }

    @Test func voiceToolSelectionKeepsSystemFnInstructionAdvisory() {
        let capabilities = OnboardingCapabilities()

        #expect(OnboardingVoiceTool.doubao.preferredInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin")
        #expect(OnboardingVoiceTool.weixin.preferredInputSourceID == "com.tencent.inputmethod.wetype.pinyin")
        #expect(OnboardingVoiceTool.typeless.preferredInputSourceID == nil)
        #expect(OnboardingVoiceTool.other.preferredInputSourceID == nil)

        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .weixin,
            capabilities: capabilities
        ))
    }

    @Test func voiceToolSelectionPreservesExistingCommandModesUntilAPlanIsStaged() {
        let capabilities = OnboardingCapabilities(systemFunctionKeyAvailable: true)
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .leftCommand,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .rightCommand,
            capabilities: capabilities
        ))
    }

    @Test func selectingVoiceToolAndRestartingPreserveTheFormalVoiceConfiguration() throws {
        let suiteName = "RemoteMicTests.Onboarding.FnOnlyPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        for tool in [OnboardingVoiceTool.doubao, .weixin, .vokie, .typeless, .other] {
            settings.voiceKeyMode = .rightCommand
            settings.voiceFnTapModeEnabled = true
            settings.setOnboardingVoiceTool(tool)
            #expect(settings.voiceKeyMode == .rightCommand)
            #expect(settings.voiceFnTapModeEnabled)
            #expect(settings.pendingOnboardingVoiceKeyMigration == nil)
        }

        settings.voiceKeyMode = .rightCommand
        settings.voiceFnTapModeEnabled = true
        settings.restartOnboarding()
        #expect(settings.voiceKeyMode == .rightCommand)
        #expect(settings.voiceFnTapModeEnabled)
        #expect(settings.pendingOnboardingVoiceKeyMigration == nil)
    }

    @Test func onboardingFnModeDoesNotCreateVoiceKeyMigrationNotice() throws {
        let suiteName = "RemoteMicTests.Onboarding.FnOnlyPolicyNotice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .function
        settings.setOnboardingVoiceTool(.doubao)
        settings.restartOnboarding()

        #expect(settings.pendingOnboardingVoiceKeyMigration == nil)
    }

    @Test func typelessUsesFnTapOnlyAfterItsPairingPlanIsStaged() throws {
        let suiteName = "RemoteMicTests.Onboarding.TypelessFnMode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .leftCommand
        settings.setOnboardingVoiceTool(.typeless)

        #expect(settings.voiceKeyMode == .leftCommand)
        #expect(!settings.voiceFnTapModeEnabled)
        settings.setOnboardingControlSource(.xiaomiRemote)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .xiaomiRemote
        ))
        settings.beginOnboardingVoiceTrial(plan)
        #expect(settings.voiceKeyMode == .function)
        #expect(settings.voiceFnTapModeEnabled)
        #expect(OnboardingVoiceTool.typeless.applicationBundleIdentifier == "now.typeless.desktop")

        defaults.set(true, forKey: AppSettings.agentConfigurationPendingKey)
        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.stagedVoiceToolBinding == plan.binding)
        #expect(resumed.voiceKeyMode == .function)
        resumed.discardOnboardingVoiceTrial()
        #expect(resumed.stagedVoiceToolBinding == nil)
    }

    @Test func inputMethodSetupUsesProductionScreenshotsAndSafeScreenshotOverrides() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingScreenshotRenderer.swift"),
            encoding: .utf8
        )
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        #expect(!viewSource.contains("onboardingVoiceKeyControl\n"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_VOICE_KEY_MODE"))
        #expect(!viewSource.contains("selectOnboardingVoiceKeyMode"))
        #expect(viewSource.contains("binding_policy=function_key"))
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        for resourceName in [
            "doubao-menu", "doubao-settings", "weixin-input-menu",
            "weixin-input-settings", "system-fn", "weixin-app-shortcuts",
            "vokie-step-1", "vokie-step-2",
        ] {
            #expect(viewSource.contains(resourceName))
            for appearance in ["light", "dark"] {
                #expect(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "Resources/Onboarding/\(resourceName)-\(appearance).png"
                    ).path
                ))
            }
        }
        #expect(viewSource.contains("refreshSelectedInputMethodStatus()"))
        #expect(viewSource.contains("activateSelectedInputMethod()"))
        #expect(viewSource.contains("OnboardingInputSourceSwitcher.selectIfNeeded(tool)"))
        #expect(viewSource.contains("OnboardingInputSourceSwitcher.selectionState(for: tool)"))
        #expect(viewSource.contains("ensureSelectedVoiceToolRunning()"))
        #expect(!viewSource.contains("voiceToolSortRank"))
        #expect(!viewSource.contains("\n            ScrollView {"))
        #expect(viewSource.contains("GridItem(.flexible(), spacing: 8, alignment: .top)"))
        #expect(viewSource.contains("minHeight: tool == .vokie ? 108 : 100, alignment: .top"))
        #expect(!viewSource.contains("minHeight: 120, maxHeight: 120, alignment: .top"))
        #expect(!viewSource.contains(".lineLimit(3, reservesSpace: true)"))
        #expect(viewSource.contains(".frame(minHeight: 54)"))
        #expect(viewSource.contains("let physicalColumns = [GridItem(.flexible())]"))
        #expect(viewSource.contains("columns: physicalColumns"))
        #expect(viewSource.contains("inputMethodGuide(for: settings.onboardingVoiceTool)"))
        #expect(viewSource.contains("content: .systemFunctionKey"))
        #expect(viewSource.contains("onboarding.voice_tool.guide.release_system_fn"))
        #expect(viewSource.contains("allRecognizedVoiceToolsUnavailable"))
        #expect(viewSource.contains("onboarding.voice_tool.none_detected"))
        #expect(viewSource.contains("onboarding.voice_tool.other.setup_detail"))
        #expect(viewSource.contains("onboarding.voice_test.configuration.detail"))
        #expect(viewSource.contains("externalToolConfigurationConfirmationCard"))
        #expect(viewSource.contains("externalToolVoiceKeyConfirmed"))
        #expect(viewSource.contains("externalToolGlobalVoiceConfirmed"))
        #expect(viewSource.contains("externalToolMicrophoneConfirmed"))
        #expect(viewSource.contains("if voiceToolAvailability[.doubao] == .notInstalled"))
        #expect(!viewSource.contains("settings.onboardingVoiceTool == .doubao,\n"))
        #expect(viewSource.contains("localization.text(settings.onboardingVoiceTool.titleKey)"))
        #expect(rendererSource.contains("allowsInputSourceSwitching: false"))
        #expect(rendererSource.contains(
            "systemFunctionKeyAvailableOverride: systemFunctionKeyAvailable"
        ))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_GUIDE_STEP"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_SYSTEM_FN_AVAILABLE"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_METHOD"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_SOURCE"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_APPLE_REMOTE_GENERATION"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_ALL_VOICE_TOOLS_UNAVAILABLE"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_LANGUAGE"))
        #expect(rendererSource.contains("Unsupported screenshot language"))
        #expect(rendererSource.contains(".remoteAvailability"))
        #expect(rendererSource.contains("let controlSource = requestedControlSource"))
        #expect(rendererSource.contains("settings.setOnboardingControlSource(controlSource)"))
        #expect(rendererSource.contains("return \"control-source\""))
        #expect(rendererSource.contains("case .voiceTest, .controls, .complete:"))
        #expect(rendererSource.contains("DoubaoAudioDevicePolicy.deviceUID"))
        #expect(buildSource.contains("$ROOT/Resources/Onboarding"))
        #expect(verifySource.contains("Resources/Onboarding/*.png(N)"))
    }

    @Test func voiceTestReacquiresInputFocusAndRejectsManualKeyboardText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains(".onAppear {\n                    requestTranscriptFocus()"))
        #expect(viewSource.contains("case .voiceTest:\n                requestTranscriptFocus()"))
        #expect(!viewSource.contains("case .voiceTest:\n                switchToSelectedInputMethod()"))
        #expect(viewSource.contains("case .voiceTest:\n            refreshSelectedVoiceToolRuntimeState()\n            ensureSelectedVoiceToolRunning()"))
        #expect(viewSource.contains("guard settings.onboardingStep == .voiceTool else { return }"))
        #expect(viewSource.contains("private func requestTranscriptFocus()"))
        #expect(viewSource.contains("transcriptFocusRequest &+= 1"))
        #expect(viewSource.contains("window.makeFirstResponder(textView)"))
        #expect(viewSource.contains(".font(.system(size: 15))\n                        .foregroundStyle(.tertiary)\n                        .padding(.horizontal, 15)\n                        .padding(.vertical, 10)"))
        #expect(viewSource.contains(".onChange(of: transcript)"))
        #expect(!viewSource.contains(".onChange(of: transcript) { _, updatedText in"))
        #expect(viewSource.contains("OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput"))
        #expect(viewSource.contains("verifiedTranscriptionAppeared &&"))
        #expect(viewSource.contains("selectedVoiceToolRuntimeReady"))
        #expect(viewSource.contains("externalToolConfigurationConfirmed"))
        #expect(viewSource.contains("sayAllVoiceKeyConfigurationReady"))
        #expect(viewSource.contains("sayAllAudioOutputConfigurationText"))
        #expect(viewSource.contains(".foregroundStyle(isComplete ? Color.green : Color.red)"))
        #expect(viewSource.contains(".eventSourceStateID"))
        #expect(viewSource.contains(".eventSourceUnixProcessID"))
        #expect(viewSource.contains("manualTranscriptInputObserved = true"))
        #expect(viewSource.contains("ONBOARDING TRANSCRIPT manual_keyboard_input=true"))
        #expect(viewSource.contains("voiceSessionStarted = true"))
        #expect(viewSource.contains("transcript = \"\""))
        #expect(viewSource.contains("transcriptCommitRequest &+= 1"))
        #expect(viewSource.contains("textView.unmarkText()"))
        #expect(viewSource.contains("!textView.hasMarkedText"))
        #expect(viewSource.contains("restored_after_voice_release=true"))
        #expect(viewSource.contains("scheduleVoiceCompletionEvaluation(attemptID: voiceAttempt.attemptID)"))
        #expect(viewSource.contains("voiceAttempt.audioDelivery.result == .deliveredToSelectedDevice"))
    }

    @Test func voiceTestExplainsAndExposesLiveGainAdjustment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("onboardingGainCard"))
        #expect(viewSource.contains("onboarding.voice_test.gain.title"))
        #expect(viewSource.contains("onboarding.voice_test.gain.detail"))
        #expect(viewSource.contains("in: 0...24"))
        #expect(viewSource.contains("onboarding.voice-test.gain"))
        #expect(viewSource.contains("settings.gainDB = min(24, max(0, $0))"))
        #expect(viewSource.contains("ONBOARDING GAIN editing="))
    }

    @Test func ordinaryButtonDetectionDoesNotExecuteExistingMappings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        #expect(modelSource.contains("OnboardingControlValidationPolicy.suppressConfiguredActions"))
        #expect(modelSource.contains("ONBOARDING CONTROLS"))
        #expect(modelSource.contains("source=apple_remote action=suppressed"))
        #expect(modelSource.contains("source=chromecast action=suppressed"))
        #expect(modelSource.contains("performMobileConfiguredAction"))
    }

    @Test func secureInputWarningUsesOnlyPublicBooleanSignal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SecureInputMonitor.swift"),
            encoding: .utf8
        )
        #expect(monitorSource.contains("IsSecureEventInputEnabled()"))
        #expect(!monitorSource.contains("IORegistry"))
        #expect(!monitorSource.contains("processIdentifier"))
    }

    @Test @MainActor func markedTranscriptTextCanBeCommittedWithoutChangingItsVisibleText() {
        let textView = NSTextView(frame: .zero)
        textView.setMarkedText(
            "测试文字",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        #expect(textView.hasMarkedText())
        #expect(textView.string == "测试文字")
        textView.unmarkText()
        #expect(!textView.hasMarkedText())
        #expect(textView.string == "测试文字")
    }

    @Test func voiceTestConfigurationOnlyRequiresGlobalVoiceForDoubao() {
        #expect(OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .doubao))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .weixin))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .typeless))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .vokie))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .other))
    }

    @Test func selectingVoiceToolDoesNotChangeInputSourceOrReorderCards() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let selectionStart = try #require(source.range(of: "private func selectVoiceTool"))
        let selectionEnd = try #require(source.range(
            of: "private func selectVoiceBindingPreference",
            range: selectionStart.upperBound..<source.endIndex
        ))
        let selectionBody = String(source[selectionStart.lowerBound..<selectionEnd.lowerBound])
        #expect(selectionBody.contains("refreshSelectedInputMethodStatus()"))
        #expect(!selectionBody.contains("activateSelectedInputMethod()"))
        #expect(!selectionBody.contains("selectIfNeeded(tool)"))
        #expect(source.contains("OnboardingVoiceToolVisibilityPolicy.visibleTools"))
    }

    @Test @MainActor func uninstalledOptionalVoiceToolsAreHiddenWhileVokieRemainsVisible() throws {
        let unavailable: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [
            .doubao: .notInstalled,
            .weixin: .notInstalled,
            .vokie: .notInstalled,
            .typeless: .notInstalled,
            .other: .unknown,
        ]
        #expect(OnboardingVoiceToolVisibilityPolicy.visibleTools(availability: unavailable) == [
            .doubao, .vokie, .other,
        ])

        let fixture = try OnboardingOffscreenFixture(
            step: .voiceTool,
            voiceTool: .vokie,
            controlSource: .xiaomiRemote,
            voiceToolAvailability: unavailable
        )
        defer { fixture.close() }
        #expect(fixture.probe.actions["voice-tool.doubao"] != nil)
        #expect(fixture.probe.actions["voice-tool.vokie"] != nil)
        #expect(fixture.probe.actions["voice-tool.other"] != nil)
        #expect(fixture.probe.actions["voice-tool.weixin"] == nil)
        #expect(fixture.probe.actions["voice-tool.typeless"] == nil)

        var installed = unavailable
        installed[.weixin] = .available
        installed[.typeless] = .available
        #expect(OnboardingVoiceToolVisibilityPolicy.visibleTools(availability: installed) == [
            .doubao, .weixin, .vokie, .typeless, .other,
        ])
    }

    @Test func independentVoiceToolsAreAutoLaunchedAndMustBeRunningToComplete() throws {
        #expect(OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: .typeless))
        #expect(OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: .vokie))
        #expect(!OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: .doubao))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let canContinueStart = try #require(source.range(of: "private var canContinue"))
        let visibleToolsStart = try #require(source.range(
            of: "private var visibleVoiceTools",
            range: canContinueStart.upperBound..<source.endIndex
        ))
        let canContinueBody = String(source[canContinueStart.lowerBound..<visibleToolsStart.lowerBound])
        #expect(canContinueBody.contains("selectedVoiceToolRuntimeReady"))
        #expect(source.contains("ensureSelectedVoiceToolRunning()"))
        #expect(source.contains("onboarding.voice_tool.runtime.reopen"))
    }

    @Test func transcriptInputPolicyRejectsSyntheticAndUnknownEventSources() {
        #expect(OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: 0
        ))
        #expect(OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: -1
        ))

        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 11,
            sourceStateID: 1,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 0,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: -1,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 99,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: 42
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: nil,
            sourceStateID: nil,
            sourceUnixProcessID: nil
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: nil
        ))
    }

    @Test func voiceSamplePresentationPublishesOnlyTheFirstNonemptyBatchPerSession() {
        var hasReceivedSamples = false
        var publicationCount = 0

        #expect(!VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedSamples,
            sampleCount: 0
        ))

        for _ in 0..<4_000 {
            if VoiceSamplePresentationPolicy.shouldPublishReceipt(
                hasReceivedSamples: hasReceivedSamples,
                sampleCount: 240
            ) {
                hasReceivedSamples = true
                publicationCount += 1
            }
        }

        #expect(hasReceivedSamples)
        #expect(publicationCount == 1)

        hasReceivedSamples = false
        #expect(VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedSamples,
            sampleCount: 240
        ))
    }

    @Test func mobileControlPathsPublishButtonsAndVoiceSamplesForTheSharedGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(modelSource.contains(
            "@Published private(set) var lastMobileRemoteButtonObservation"
        ))
        #expect(modelSource.contains(
            "@Published private(set) var activeVoiceSource: UsageEventSource?"
        ))
        #expect(modelSource.contains(
            "@Published private(set) var hasReceivedCurrentVoiceSamples = false"
        ))
        #expect(modelSource.components(separatedBy: "observeMobileButton(").count >= 7)

        let bluetoothAudioStart = try #require(modelSource.range(
            of: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16])"
        ))
        let bluetoothAudioEnd = try #require(modelSource.range(
            of: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel",
            range: bluetoothAudioStart.upperBound..<modelSource.endIndex
        ))
        let bluetoothAudioSource = modelSource[
            bluetoothAudioStart.lowerBound..<bluetoothAudioEnd.lowerBound
        ]
        let audioStart = try #require(modelSource.range(
            of: "private func receivePhoneAudio"
        ))
        let audioEnd = try #require(modelSource.range(
            of: "private func beginVoiceSessionIfNeeded",
            range: audioStart.upperBound..<modelSource.endIndex
        ))
        let audioSource = modelSource[audioStart.lowerBound..<audioEnd.lowerBound]
        let receiptCall = "publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: samples.count)"
        #expect(bluetoothAudioSource.contains(receiptCall))
        #expect(audioSource.contains(receiptCall))
        #expect(!modelSource.contains("currentVoiceSampleCount"))

        #expect(viewSource.contains(
            ".onReceive(model.$lastMobileRemoteButtonObservation.compactMap { $0 })"
        ))
        #expect(viewSource.contains("source == .nearbyPhone"))
        #expect(viewSource.contains("source == .webRemote"))
        #expect(viewSource.contains("selectedControlAcceptsVoice(model.activeVoiceSource)"))
        #expect(viewSource.contains("source == .bluetoothRemote"))
        #expect(viewSource.contains(
            "settings.onboardingControlMethod == .physicalRemote"
        ))
        #expect(viewSource.contains("model.isPhoneRemoteConnected"))
        #expect(viewSource.contains("model.phoneRemoteInvitation"))
        #expect(viewSource.contains("PhoneRemoteInvitationQRCode.image"))
        #expect(viewSource.contains("if case .connected = model.webRemoteState"))
        #expect(viewSource.contains(".onReceive(model.$isConnected.removeDuplicates())"))
        #expect(viewSource.contains(
            ".onReceive(model.$hasReceivedCurrentVoiceSamples.removeDuplicates())"
        ))
        #expect(viewSource.contains("routeConnectedPhysicalRemoteIfNeeded()"))
        #expect(viewSource.contains("selectControlSource(.xiaomiRemote)"))
    }

    @Test func rootViewObservesSettingsWithoutSubscribingToTheWholeBridgeModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicRootView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("let model: BridgeAppModel"))
        #expect(!source.contains("@ObservedObject var model: BridgeAppModel"))
        #expect(source.contains("@ObservedObject private var settings: AppSettings"))
    }

    @Test func observedRemoteButtonRequestsOnlyOneRecoveryWhileBluetoothIsDisconnected() {
        #expect(!OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: false,
            remoteButtonObserved: false,
            recoveryRequested: false
        ))
        #expect(!OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: true,
            remoteButtonObserved: true,
            recoveryRequested: false
        ))
        #expect(!OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: false,
            remoteButtonObserved: true,
            recoveryRequested: true
        ))
        #expect(OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: false,
            remoteButtonObserved: true,
            recoveryRequested: false
        ))
    }

    @Test func remoteRecoveryIsWiredToButtonObservationAndCanStartMissingBluetoothBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let buttonReceiveStart = try #require(viewSource.range(
            of: ".onReceive(model.$lastRemoteButtonPress.compactMap { $0 })"
        ))
        let buttonReceiveEnd = try #require(viewSource.range(
            of: ".onReceive(model.$isStreaming",
            range: buttonReceiveStart.upperBound..<viewSource.endIndex
        ))
        let buttonReceiveSource = viewSource[buttonReceiveStart.lowerBound..<buttonReceiveEnd.lowerBound]
        #expect(buttonReceiveSource.contains("recoverRemoteConnectionIfNeeded()"))

        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let reconnectStart = try #require(modelSource.range(of: "func reconnect()"))
        let reconnectEnd = try #require(modelSource.range(
            of: "func enablePhoneRemoteConnection()",
            range: reconnectStart.upperBound..<modelSource.endIndex
        ))
        let reconnectSource = modelSource[reconnectStart.lowerBound..<reconnectEnd.lowerBound]
        #expect(reconnectSource.contains("guard started else { return }"))
        #expect(reconnectSource.contains("bluetoothBridges.isEmpty && discoveryBluetoothBridge == nil"))
        #expect(reconnectSource.contains("startBluetoothConnections()"))
    }

    @Test func returningFromBluetoothSettingsRefreshesDiscovery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let activeStart = try #require(viewSource.range(
            of: "NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)"
        ))
        let activeEnd = try #require(viewSource.range(
            of: ".onReceive(model.$activeRemoteButtons)",
            range: activeStart.upperBound..<viewSource.endIndex
        ))
        let activeSource = viewSource[activeStart.lowerBound..<activeEnd.lowerBound]
        #expect(activeSource.contains("prepareSelectedControlConnection()"))

        let prepareStart = try #require(viewSource.range(
            of: "private func prepareSelectedControlConnection()"
        ))
        let prepareEnd = try #require(viewSource.range(
            of: "private func selectedControlAccepts",
            range: prepareStart.upperBound..<viewSource.endIndex
        ))
        let prepareSource = viewSource[prepareStart.lowerBound..<prepareEnd.lowerBound]
        #expect(prepareSource.contains("model.refreshRemoteDiscovery()"))
        #expect(prepareSource.contains("model.applyHIDSettings()"))

        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let refreshStart = try #require(modelSource.range(of: "func refreshRemoteDiscovery()"))
        let refreshEnd = try #require(modelSource.range(
            of: "func enablePhoneRemoteConnection()",
            range: refreshStart.upperBound..<modelSource.endIndex
        ))
        let refreshSource = modelSource[refreshStart.lowerBound..<refreshEnd.lowerBound]
        #expect(refreshSource.contains("discoveryBluetoothBridge?.reconnectNow()"))
    }

    @Test func returningToAudioSetupRefreshesAvailableOutputs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let activeStart = try #require(viewSource.range(
            of: "NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)"
        ))
        let activeEnd = try #require(viewSource.range(
            of: ".onReceive(model.$activeRemoteButtons)",
            range: activeStart.upperBound..<viewSource.endIndex
        ))
        let activeSource = viewSource[activeStart.lowerBound..<activeEnd.lowerBound]
        #expect(activeSource.contains("case .audio:"))
        #expect(activeSource.contains("model.refreshAudioDevices()"))
        #expect(activeSource.contains("case .complete:"))
        #expect(activeSource.contains("prepareSelectedControlConnection()"))
    }

    @Test func remoteStepUsesUserFacingButtonGuidanceAndRoutesRecoveryToExistingRuntime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let remoteStart = try #require(viewSource.range(of: "private var remoteContent"))
        let remoteEnd = try #require(viewSource.range(
            of: "private var audioContent",
            range: remoteStart.upperBound..<viewSource.endIndex
        ))
        let remoteSource = viewSource[remoteStart.lowerBound..<remoteEnd.lowerBound]
        #expect(!remoteSource.contains("model.hidStatus.text(using: localization)"))
        #expect(!remoteSource.contains("onboarding.remote.listener_status"))
        #expect(remoteSource.contains("physicalRemotePairingKeys.title"))
        #expect(remoteSource.contains("physicalRemotePairingKeys.firstStep"))
        #expect(remoteSource.contains("physicalRemotePairingKeys.secondStep"))
        #expect(!remoteSource.contains("ViewThatFits(in: .horizontal)"))
        let recoveryStart = try #require(viewSource.range(of: "private func performRecovery"))
        let recoveryEnd = try #require(viewSource.range(
            of: "private func resetVoiceTestForRetry",
            range: recoveryStart.upperBound..<viewSource.endIndex
        ))
        let recoverySource = viewSource[recoveryStart.lowerBound..<recoveryEnd.lowerBound]
        #expect(recoverySource.contains("case .remoteButtonNotReady, .controlsNotConfirmed:"))
        #expect(recoverySource.contains("model.applyHIDSettings()"))
    }

    @Test func remoteStepCorrectsVoiceButtonMistakesWithoutWeakeningTheControlGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingScreenshotRenderer.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("recordRemoteVoiceButtonPress()"))
        #expect(viewSource.contains("onboarding.remote.voice_button_mistake.title"))
        #expect(viewSource.contains("onboarding.remote.voice_button_mistake.detail"))
        #expect(viewSource.contains("onboarding.remote.button_waiting_detail"))
        #expect(viewSource.contains("ONBOARDING REMOTE_INPUT observed=voice"))
        #expect(viewSource.contains("ONBOARDING REMOTE_INPUT observed=control"))
        #expect(viewSource.contains("isComplete: !observedRemoteButtons.isEmpty"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_REMOTE_INPUT"))
    }

    @Test func completionPageExplainsARegressedRuntimeCondition() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let completeStart = try #require(viewSource.range(of: "private var completeContent"))
        let completeEnd = try #require(viewSource.range(
            of: "private var rightPane",
            range: completeStart.upperBound..<viewSource.endIndex
        ))
        let completeSource = viewSource[completeStart.lowerBound..<completeEnd.lowerBound]
        #expect(completeSource.contains("if !canContinue"))
        #expect(completeSource.contains("onboarding.complete.runtime_changed"))

        let rendererSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingScreenshotRenderer.swift"),
            encoding: .utf8
        )
        #expect(rendererSource.contains("completeRuntimeReadyOverride: true"))
    }

    @Test func audioStepOnlyOffersSupportedVirtualAudioDevices() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let audioStart = try #require(viewSource.range(of: "private var audioContent"))
        let audioEnd = try #require(viewSource.range(
            of: "private var voiceTestContent",
            range: audioStart.upperBound..<viewSource.endIndex
        ))
        let audioSource = viewSource[audioStart.lowerBound..<audioEnd.lowerBound]

        #expect(audioSource.contains("ForEach(supportedAudioDevices"))
        #expect(!audioSource.contains("ForEach(model.audioDevices"))
        #expect(!audioSource.contains("Picker("))
        #expect(audioSource.contains("settings.selectedAudioDeviceUID = device.uid"))
        #expect(audioSource.contains("model.applyAudioSettings(reason: \"onboarding_audio_device_selected\")"))
        #expect(viewSource.contains("OnboardingAudioSelectionPolicy.isSupportedDevice"))
        #expect(viewSource.contains("onboarding.audio.on_demand_detail"))
        #expect(viewSource.contains("onboarding.permissions.apple_companion.title"))
        #expect(viewSource.contains("onboarding.permissions.apple_companion.detail"))
        #expect(viewSource.contains("onboarding.permissions.web_remote.title"))
        #expect(viewSource.contains("onboarding.permissions.web_remote.detail"))
        #expect(viewSource.contains("onboarding.side.audio_on_demand"))
    }

    @Test func onlyMiRemoteAndBlackHoleCanSatisfyTheAudioSelectionGate() {
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "MiRemoteV2ch_UID",
            name: "MiRemoteV 2ch"
        ))
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "BlackHole2ch_UID",
            name: "BlackHole 2ch"
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "Beosound_UID",
            name: "Beosound A1 2nd Gen"
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "BuiltInOutputDevice",
            name: "MacBook Pro Speakers"
        ))

        let availableSupportedUIDs = ["MiRemoteV2ch_UID", "BlackHole2ch_UID"]
        #expect(OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "MiRemoteV2ch_UID",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "BlackHole2ch_UID",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "Beosound_UID",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "MiRemoteV2ch_UID",
            availableSupportedUIDs: ["BlackHole2ch_UID"]
        ))
    }

    @Test func progressVoiceToolAndCompletionPersistAcrossLaunches() throws {
        let suiteName = "RemoteMicTests.Onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.isOnboardingComplete)
        #expect(settings.onboardingStep == .welcome)
        #expect(settings.onboardingVoiceTool == .unselected)
        #expect(settings.onboardingRemoteAvailability == .unselected)
        #expect(settings.onboardingControlMethod == .unselected)

        settings.setOnboardingVoiceTool(.doubao)
        settings.setOnboardingRemoteAvailability(.noRemote)
        settings.setOnboardingControlMethod(.iPhoneApp)
        settings.setOnboardingStep(.audio)

        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.onboardingStep == .audio)
        #expect(resumed.onboardingVoiceTool == .doubao)
        #expect(resumed.onboardingRemoteAvailability == .noRemote)
        #expect(resumed.onboardingControlMethod == .iPhoneApp)
        #expect(!resumed.isOnboardingComplete)

        resumed.completeOnboarding()
        let completed = AppSettings(defaults: defaults)
        #expect(completed.isOnboardingComplete)
        #expect(completed.onboardingCompletedVersion == AppSettings.currentOnboardingVersion)
        #expect(completed.onboardingStep == .complete)
        #expect(completed.onboardingVoiceTool == .doubao)
        #expect(completed.onboardingRemoteAvailability == .noRemote)
        #expect(completed.onboardingControlMethod == .iPhoneApp)

        completed.selectedAudioDeviceUID = "MiRemoteV 2ch"
        completed.customMappingEnabled = true
        completed.showDockIcon = false
        completed.openMainWindowAtLaunch = false
        completed.checksForPreReleaseUpdates = true
        completed.setAction(.escape, for: .ok)

        completed.restartOnboarding()
        let restarted = AppSettings(defaults: defaults)
        #expect(!restarted.isOnboardingComplete)
        #expect(restarted.onboardingStep == .welcome)
        #expect(restarted.onboardingVoiceTool == .unselected)
        #expect(restarted.onboardingRemoteAvailability == .unselected)
        #expect(restarted.onboardingControlMethod == .unselected)
        #expect(restarted.selectedAudioDeviceUID == "MiRemoteV 2ch")
        #expect(restarted.customMappingEnabled)
        #expect(!restarted.showDockIcon)
        #expect(!restarted.openMainWindowAtLaunch)
        #expect(restarted.checksForPreReleaseUpdates)
        #expect(restarted.action(for: .ok) == .escape)
    }

    @Test func onboardingPairingPlanControlsFnTapWithoutToolSelectionSideEffects() throws {
        let suiteName = "RemoteMicTests.OnboardingFnTap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingVoiceTool(.typeless)
        #expect(!settings.voiceFnTapModeEnabled)

        let resumed = AppSettings(defaults: defaults)
        #expect(!resumed.voiceFnTapModeEnabled)

        resumed.setOnboardingControlSource(.xiaomiRemote)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .xiaomiRemote
        ))
        resumed.beginOnboardingVoiceTrial(plan)
        #expect(resumed.voiceFnTapModeEnabled)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        #expect(viewSource.contains("settings.beginOnboardingVoiceTrial(plan)"))
        #expect(viewSource.contains("model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)"))
    }

    @Test func existingInstallSkipsOnboardingWhileNewAndResumedFlowsRemainRequired() throws {
        let legacySuiteName = "RemoteMicTests.Onboarding.Legacy.\(UUID().uuidString)"
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
        legacyDefaults.set("68", forKey: "launch.lastLaunchedBuild")

        let legacySettings = AppSettings(defaults: legacyDefaults)
        #expect(legacySettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: true
        ))
        #expect(legacySettings.isOnboardingComplete)
        #expect(legacySettings.onboardingStep == .complete)

        let sparkleLegacySuiteName = "RemoteMicTests.Onboarding.SparkleLegacy.\(UUID().uuidString)"
        let sparkleLegacyDefaults = try #require(UserDefaults(suiteName: sparkleLegacySuiteName))
        defer { sparkleLegacyDefaults.removePersistentDomain(forName: sparkleLegacySuiteName) }

        let sparkleLegacySettings = AppSettings(defaults: sparkleLegacyDefaults)
        #expect(sparkleLegacySettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: true
        ))
        #expect(sparkleLegacySettings.isOnboardingComplete)

        let configuredLegacySuiteName = "RemoteMicTests.Onboarding.ConfiguredLegacy.\(UUID().uuidString)"
        let configuredLegacyDefaults = try #require(UserDefaults(suiteName: configuredLegacySuiteName))
        defer { configuredLegacyDefaults.removePersistentDomain(forName: configuredLegacySuiteName) }
        configuredLegacyDefaults.set(Data("legacy".utf8), forKey: "buttonBindings")
        let configuredLegacySettings = AppSettings(defaults: configuredLegacyDefaults)
        #expect(!configuredLegacySettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: false
        ))
        #expect(configuredLegacySettings.isOnboardingComplete)

        let configuredAfterMigrationSuiteName = "RemoteMicTests.Onboarding.ConfiguredAfterMigration.\(UUID().uuidString)"
        let configuredAfterMigrationDefaults = try #require(UserDefaults(suiteName: configuredAfterMigrationSuiteName))
        defer { configuredAfterMigrationDefaults.removePersistentDomain(forName: configuredAfterMigrationSuiteName) }
        configuredAfterMigrationDefaults.set(AppSettings.currentOnboardingVersion, forKey: "onboarding.migrationVersion")
        configuredAfterMigrationDefaults.set(Data("legacy".utf8), forKey: "buttonBindings")
        let configuredAfterMigrationSettings = AppSettings(defaults: configuredAfterMigrationDefaults)
        #expect(!configuredAfterMigrationSettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: false
        ))
        #expect(configuredAfterMigrationSettings.isOnboardingComplete)

        let freshSuiteName = "RemoteMicTests.Onboarding.Fresh.\(UUID().uuidString)"
        let freshDefaults = try #require(UserDefaults(suiteName: freshSuiteName))
        defer { freshDefaults.removePersistentDomain(forName: freshSuiteName) }

        let firstFreshLaunch = AppSettings(defaults: freshDefaults)
        #expect(!firstFreshLaunch.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: false
        ))
        #expect(!firstFreshLaunch.isOnboardingComplete)

        let secondFreshLaunch = AppSettings(defaults: freshDefaults)
        #expect(secondFreshLaunch.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "103",
            sparkleHadLaunchedBefore: true
        ))
        #expect(!secondFreshLaunch.isOnboardingComplete)
        #expect(secondFreshLaunch.onboardingStep == .welcome)

        let resumedSuiteName = "RemoteMicTests.Onboarding.Resumed.\(UUID().uuidString)"
        let resumedDefaults = try #require(UserDefaults(suiteName: resumedSuiteName))
        defer { resumedDefaults.removePersistentDomain(forName: resumedSuiteName) }
        resumedDefaults.set("101", forKey: "launch.lastLaunchedBuild")
        resumedDefaults.set(OnboardingStep.audio.rawValue, forKey: "onboarding.step")
        resumedDefaults.set(OnboardingVoiceTool.typeless.rawValue, forKey: "onboarding.voiceTool")

        let resumedSettings = AppSettings(defaults: resumedDefaults)
        #expect(resumedSettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: true
        ))
        #expect(!resumedSettings.isOnboardingComplete)
        #expect(resumedSettings.onboardingStep == .audio)
        #expect(resumedSettings.onboardingVoiceTool == .typeless)
        #expect(resumedSettings.onboardingRemoteAvailability == .hasRemote)
        #expect(resumedSettings.onboardingControlMethod == .physicalRemote)

        resumedSettings.completeOnboarding()
        resumedSettings.restartOnboarding()
        let restartedSettings = AppSettings(defaults: resumedDefaults)
        _ = restartedSettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "103",
            sparkleHadLaunchedBefore: true
        )
        #expect(!restartedSettings.isOnboardingComplete)
        #expect(restartedSettings.onboardingStep == .welcome)
    }

    @Test func incompleteFlowAlwaysShowsItsWindowAndDelaysRuntimeUntilSetup() {
        #expect(OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: false,
            completedUpdate: false,
            openMainWindowAtLaunch: false
        ))
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .welcome
        ))
        #expect(OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .voiceTool
        ))
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .remoteAvailability
        ))
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .controlMethod
        ))
        #expect(OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .permissions
        ))
        #expect(OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: true,
            step: .welcome
        ))
        #expect(!OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: true,
            completedUpdate: false,
            openMainWindowAtLaunch: false
        ))
    }

    @Test func completedUpdateOpensPermissionRepairOnlyWhenARequiredPermissionIsMissing() throws {
        #expect(CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(!CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(!CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: false,
            bluetoothGranted: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))
        #expect(!CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: false,
            completedUpdate: true,
            bluetoothGranted: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let rootViewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicRootView.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("showSettingsWindow(initialSection: .about)"))
        #expect(appSource.contains("UPDATE PERMISSION_REPAIR"))
        #expect(rootViewSource.contains("initialSection: initialSettingsSection"))
    }

    @Test func firstUseFailuresPointToTheExactRecoveryStep() {
        var capabilities = OnboardingCapabilities()
        var context = FirstUseDiagnosticContext(
            step: .permissions,
            capabilities: capabilities,
            hasSelectedAudioUID: false
        )
        #expect(context.failureReason == .bluetoothPermissionDenied)
        capabilities.bluetoothGranted = true
        context = FirstUseDiagnosticContext(
            step: .permissions,
            capabilities: capabilities,
            hasSelectedAudioUID: false
        )
        #expect(context.failureReason == .inputMonitoringPermissionDenied)

        capabilities.inputMonitoringGranted = true
        capabilities.accessibilityGranted = true
        capabilities.remoteConnected = true
        capabilities.remoteButtonObserved = true
        context = FirstUseDiagnosticContext(
            step: .audio,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        )
        #expect(context.failureReason == .audioSelectedDeviceMissing)

        capabilities.voiceSessionStarted = true
        capabilities.voiceSamplesReceived = true
        capabilities.voiceSessionEnded = true
        capabilities.transcriptionAppeared = true
        capabilities.manualTranscriptInputObserved = true
        context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        )
        #expect(context.failureReason == .voiceManualInput)

        capabilities.audioOutputSelected = true
        capabilities.audioReady = true
        capabilities.manualTranscriptInputObserved = false
        #expect(OnboardingFlowPolicy.recoveryStep(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        ) == nil)

        capabilities.remoteConnected = false
        #expect(OnboardingFlowPolicy.recoveryStep(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        ) == .remote)
    }

    @Test func voiceAttemptUsesOneTerminalCauseAfterTheSessionEnds() {
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: true,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .passed)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: false,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .noSamples,
            finalObservation: true
        ) == .noSamples)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: false,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .inputTargetNotReady)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: false,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .inputTargetFocusLost)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .enqueueFailed,
            finalObservation: true
        ) == .audioDeliveryFailed)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .externalToolNoCommit)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .playbackPending,
            finalObservation: false
        ) == .externalToolNoCommit)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .playbackPending,
            finalObservation: true
        ) == .audioDeliveryFailed)
    }

    @Test func voiceAttemptIntermediatePhasesAreNotFailures() {
        let capabilities = OnboardingCapabilities(
            voiceSessionStarted: true,
            voiceSamplesReceived: true
        )
        var attempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: 1,
            phase: .recording,
            triggerPath: UsageEventSource.bluetoothRemote.rawValue,
            triggerReady: true,
            editorMounted: true,
            windowKeyAtStart: true,
            firstResponderAtStart: true
        )
        var context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: attempt
        )
        #expect(context.failureReason == nil)

        attempt.phase = .awaitingTranscript
        context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: attempt
        )
        #expect(context.failureReason == nil)

        attempt.phase = .failed
        attempt.result = .externalToolNoCommit
        context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: attempt
        )
        #expect(context.failureReason == .voiceExternalToolNoCommit)
    }

    @Test func recoveredTransientFocusLossDoesNotOverrideTheExternalToolBoundary() {
        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        )
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusLost: true,
            focusLossCount: 1,
            focusRecovered: true,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: true,
            externalToolMicrophoneUserConfirmed: true,
            result: result
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(result == .externalToolNoCommit)
        #expect(attempt.probableCause == "external_tool_no_commit")
        #expect(!attempt.probableCauseConfirmed)
    }

    @Test func focusStillMissingAtTheDeadlineIsAConfirmedSayAllFailure() {
        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: false,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        )

        #expect(result == .inputTargetFocusLost)
        #expect(FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: false,
            result: result
        ).probableCauseConfirmed)
    }

    @Test func unconfirmedExternalMicrophoneIsReportedAsAnUnverifiedNextCheck() {
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: true,
            externalToolMicrophoneUserConfirmed: false,
            result: .externalToolNoCommit
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(attempt.probableCause == "external_tool_microphone_not_confirmed")
        #expect(!attempt.probableCauseConfirmed)
        #expect(attempt.result.diagnosticBoundary == "external_tool_internal_state_unavailable")
    }

    @Test func unconfirmedExternalVoiceKeyIsReportedBeforeOtherExternalChecks() {
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: false,
            externalToolGlobalVoiceApplicable: true,
            externalToolGlobalVoiceUserConfirmed: false,
            externalToolMicrophoneUserConfirmed: false,
            result: .externalToolNoCommit
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(attempt.probableCause == "external_tool_voice_key_not_confirmed")
        #expect(!attempt.probableCauseConfirmed)
    }

    @Test func unconfirmedDoubaoGlobalVoiceIsReportedAfterVoiceKeyConfirmation() {
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: true,
            externalToolGlobalVoiceApplicable: true,
            externalToolGlobalVoiceUserConfirmed: false,
            externalToolMicrophoneUserConfirmed: true,
            result: .externalToolNoCommit
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(attempt.probableCause == "external_tool_global_voice_not_confirmed")
        #expect(!attempt.probableCauseConfirmed)
    }

    @Test func voiceTestUsesNativeFirstResponderAsTheFocusFact() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("struct OnboardingTranscriptEditor: NSViewRepresentable"))
        #expect(viewSource.contains("window.makeFirstResponder(textView)"))
        #expect(viewSource.contains("window?.firstResponder === textView"))
        #expect(!viewSource.contains("@FocusState private var transcriptFocused"))
    }

    @Test func firstUseEventsDeduplicatePollingAndKeepExplicitRetries() throws {
        let suiteName = "RemoteMicTests.Onboarding.Diagnostics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        settings.recordFirstUseEvent(.entered, step: .permissions, at: now)
        settings.recordFirstUseEvent(
            .blocked,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(1)
        )
        settings.recordFirstUseEvent(
            .blocked,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(2)
        )
        settings.recordFirstUseEvent(
            .retry,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(3)
        )
        settings.recordFirstUseEvent(
            .retry,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(4)
        )

        #expect(settings.firstUseEvents.count == 4)
        #expect(settings.firstUseEvents.last?.elapsedMilliseconds == 4_000)
    }

    @Test func firstUseEventsPersistVoiceAttemptIdentityAndDecodeLegacyEvents() throws {
        let suiteName = "RemoteMicTests.Onboarding.VoiceDiagnostics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.recordFirstUseEvent(
            .blocked,
            step: .voiceTest,
            failureReason: .voiceExternalToolNoCommit,
            voiceAttemptID: 3,
            voiceResult: .externalToolNoCommit
        )
        #expect(settings.firstUseEvents.last?.voiceAttemptID == 3)
        #expect(settings.firstUseEvents.last?.voiceResult == .externalToolNoCommit)

        let legacyData = Data("""
        [{"timestamp":0,"kind":"entered","step":"voiceTest","elapsedMilliseconds":0,"failureReason":null}]
        """.utf8)
        let legacyEvents = try JSONDecoder().decode([FirstUseEvent].self, from: legacyData)
        #expect(legacyEvents.first?.voiceAttemptID == nil)
        #expect(legacyEvents.first?.voiceResult == nil)
    }

    @Test func firstUseEventsHaveStableRuntimeLogMessages() {
        let event = FirstUseEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            kind: .blocked,
            step: .voiceTest,
            elapsedMilliseconds: 1_234,
            failureReason: .voiceNoTranscript,
            voiceAttemptID: 7,
            voiceResult: .externalToolNoCommit
        )

        #expect(event.runtimeLogMessage ==
            "ONBOARDING EVENT kind=blocked step=voiceTest elapsed_ms=1234 " +
                "failure=voice.no_transcript attempt=7 voice_result=external_tool_no_commit"
        )
    }

    @Test func diagnosticSummaryContainsOnlyNormalizedState() {
        let capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false,
            remoteConnected: false,
            remoteButtonObserved: false,
            audioReady: false,
            audioOutputSelected: false,
            voiceSessionStarted: false,
            voiceSamplesReceived: false,
            voiceSessionEnded: false,
            transcriptionAppeared: false,
            testedRemoteButtonCount: 0
        )
        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: "1.8.14",
            appBuild: "106",
            systemMajorVersion: 14,
            architecture: "arm64",
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: true,
            context: FirstUseDiagnosticContext(
                step: .permissions,
                capabilities: capabilities,
                hasSelectedAudioUID: false,
                remoteInput: FirstUseRemoteInputDiagnostic(
                    voiceButtonPressCount: 2,
                    controlButtonObservationCount: 0,
                    lastInputKind: .voice
                )
            ),
            voiceAttempt: FirstUseVoiceAttemptDiagnostic(
                attemptID: 2,
                phase: .failed,
                triggerPath: UsageEventSource.bluetoothRemote.rawValue,
                triggerReady: true,
                editorMounted: true,
                windowKeyAtStart: true,
                firstResponderAtStart: true,
                firstResponderAtEnd: true,
                firstSampleLatencyMilliseconds: 24,
                sessionDurationMilliseconds: 1_500,
                transcriptWaitMilliseconds: 3_000,
                externalToolVoiceKeyUserConfirmed: true,
                externalToolExpectedVoiceKey: "fn_tap",
                result: .externalToolNoCommit
            ),
            bluetoothStatus: "connection.status.searching",
            buttonStatus: "button_mapping.status.disabled",
            audioStatus: "audio.output.none_selected",
            events: [],
            appLanguage: "zh-Hans",
            controlSource: .xiaomiRemote,
            voiceBinding: VoiceToolUserBinding(
                tool: .typeless,
                shortcut: .function,
                gestureMode: .toggle,
                source: .documentedDefault,
                validationState: .staged,
                verifiedToolVersion: nil,
                verifiedAt: nil
            )
        )

        let text = snapshot.redactedText
        #expect(text.contains("failure=permission.input_monitoring_denied"))
        #expect(text.contains("voice_attempt=2"))
        #expect(text.contains("diagnostic_schema=3"))
        #expect(text.contains("app_version=1.8.14"))
        #expect(text.contains("app_build=106"))
        #expect(text.contains("onboarding_voice_key_policy=profile_or_user_binding"))
        #expect(text.contains("voice_fn_tap_mode_enabled=true"))
        #expect(text.contains("voice_key_policy_compliant=true"))
        #expect(text.contains("control_source=xiaomi_remote"))
        #expect(text.contains("voice_gesture=toggle"))
        #expect(text.contains("voice_binding_source=documented_default"))
        #expect(text.contains("voice_binding_validation=staged"))
        #expect(text.contains("remote_voice_button_press_count=2"))
        #expect(text.contains("remote_control_button_observation_count=0"))
        #expect(text.contains("remote_last_input_kind=voice"))
        #expect(text.contains("remote_voice_button_mistake_detected=true"))
        #expect(text.contains("macos_version="))
        #expect(text.contains("macos_build="))
        #expect(text.contains("app_language=zh-Hans"))
        #expect(text.contains("voice_terminal_result=external_tool_no_commit"))
        #expect(text.contains("voice_probable_cause_confirmed=false"))
        #expect(text.contains("voice_external_tool_voice_key_observable=false"))
        #expect(text.contains("voice_external_tool_voice_key_user_confirmed=true"))
        #expect(text.contains("voice_external_tool_expected_voice_key=fn_tap"))
        #expect(text.contains("voice_external_tool_global_voice_observable=false"))
        #expect(text.contains("voice_external_tool_global_voice_applicable=false"))
        #expect(text.contains("voice_external_tool_microphone_observable=false"))
        #expect(text.contains("voice_external_tool_expected_microphone=unavailable"))
        #expect(text.contains("voice_external_tool_next_checks=trigger_matches_binding"))
        #expect(text.contains("voice_audio_delivery_result=unavailable"))
        #expect(text.contains("voice_focus_ready_at_deadline=unknown"))
        #expect(text.contains("voice_first_sample_latency_ms=24"))
        #expect(text.contains("voice_diagnostic_boundary=external_tool_internal_state_unavailable"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("UUID"))
        #expect(!text.contains("无线麦已经连接成功"))
    }

    @Test @MainActor func offscreenOnboardingRegistersAndDrivesEveryInteractiveControl() throws {
        func invoke(_ id: String, on fixture: OnboardingOffscreenFixture) {
            #expect(fixture.probe.actions[id] != nil, "missing action: \(id)")
            fixture.probe.invoke(id)
            #expect(fixture.probe.invokedActions.last == id)
        }

        func invokeIfPresent(_ id: String, on fixture: OnboardingOffscreenFixture) {
            guard fixture.probe.actions[id] != nil else { return }
            invoke(id, on: fixture)
        }

        let welcome = try OnboardingOffscreenFixture(step: .welcome)
        defer { welcome.close() }
        #expect(Set(welcome.probe.actions.keys) == ["welcome.copy-ai-prompt", "continue"])
        invoke("continue", on: welcome)
        #expect(welcome.settings.onboardingStep == .remoteAvailability)

        let voiceTool = try OnboardingOffscreenFixture(
            step: .voiceTool,
            voiceTool: .doubao,
            systemFunctionKeyAvailable: false,
            initialInputMethodGuideStep: 2,
            controlSource: .xiaomiRemote,
            voiceToolAvailability: [
                .doubao: .notInstalled,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ]
        )
        defer { voiceTool.close() }
        #expect(voiceTool.probe.actions.keys.contains("back"))
        for id in ["continue", "voice-tool.doubao.install"] {
            #expect(voiceTool.probe.actions.keys.contains(id), "missing voice-tool action: \(id)")
        }
        for index in 0...3 {
            #expect(voiceTool.probe.actions.keys.contains("input-guide.\(index)"))
        }
        #expect(voiceTool.probe.actions.keys.contains("keyboard-settings.open"))
        invoke("keyboard-settings.open", on: voiceTool)
        #expect(voiceTool.probe.openedURLs.last?.absoluteString ==
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        invoke("voice-tool.doubao.install", on: voiceTool)
        #expect(voiceTool.probe.openedURLs.last == AppLinks.doubaoInputMethod)
        for tool in [OnboardingVoiceTool.doubao, .weixin, .vokie, .typeless, .other] {
            let id = "voice-tool.\(tool.rawValue)"
            invoke(id, on: voiceTool)
            #expect(voiceTool.settings.onboardingVoiceTool == tool)
        }
        invoke("voice-tool.typeless", on: voiceTool)
        invoke("continue", on: voiceTool)
        #expect(voiceTool.settings.onboardingStep == .voiceTool)
        for index in 0...3 {
            invoke("input-guide.\(index)", on: voiceTool)
        }
        invoke("continue", on: voiceTool)
        #expect(voiceTool.settings.onboardingStep == .voiceTest)
        invoke("back", on: voiceTool)

        let remoteSource = try OnboardingOffscreenFixture(
            step: .remoteAvailability,
            voiceTool: .doubao,
            controlSource: .webRemote
        )
        defer { remoteSource.close() }
        if remoteSource.probe.actions["control-source.more"] != nil {
            invoke("control-source.more", on: remoteSource)
        }
        #expect(!remoteSource.settings.siriRemoteEnabled)
        for source in OnboardingBuildCapabilities.availableControlSources where source != .siriRemote {
            let id = "control-source.\(source.rawValue)"
            invoke(id, on: remoteSource)
            #expect(remoteSource.settings.onboardingControlSource == source)
            #expect(!remoteSource.settings.siriRemoteEnabled)
        }
        #if SAYALL_SIRI_REMOTE_ENABLED
        for generation in OnboardingAppleRemoteGeneration.allCases {
            let id = "control-source.siri_remote.\(generation.rawValue)"
            invoke(id, on: remoteSource)
            #expect(remoteSource.settings.onboardingAppleRemoteGeneration == generation)
            #expect(remoteSource.settings.siriRemoteEnabled)
        }
        #endif
        invoke("control-source.xiaomi_remote", on: remoteSource)
        invoke("continue", on: remoteSource)
        invoke("back", on: remoteSource)

        let vokieSource = try OnboardingOffscreenFixture(
            step: .voiceTool,
            voiceTool: .vokie,
            controlSource: .webRemote
        )
        defer { vokieSource.close() }
        #expect(vokieSource.probe.actions["voice-tool.vokie.website"] != nil)
        invoke("voice-tool.vokie.website", on: vokieSource)
        #expect(vokieSource.probe.openedURLs.last == AppLinks.vokieWebsite)
        #expect(AppLinks.vokieWebsite.query == "from=sayall.app")
        for index in 0...3 {
            #expect(vokieSource.probe.actions.keys.contains("input-guide.\(index)"))
        }
        for mode in VoiceGestureMode.allCases {
            #expect(vokieSource.probe.actions["gesture.\(mode.rawValue)"] != nil)
            invoke("gesture.\(mode.rawValue)", on: vokieSource)
            #expect(vokieSource.settings.onboardingPreferredGesture == mode)
        }
        #expect(!vokieSource.probe.actions.keys.contains("vokie.open"))

        let iPhone = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { iPhone.close() }
        invoke("iphone.install", on: iPhone)
        #expect(iPhone.probe.openedURLs.last == AppLinks.iOSAppStore(for: Locale(identifier: "zh-Hans")))
        invokeIfPresent("recovery.remote.not_found", on: iPhone)
        invokeIfPresent("diagnostics.copy", on: iPhone)
        invoke("back", on: iPhone)

        let web = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .webRemote,
            voiceTool: .doubao
        )
        defer { web.close() }
        invoke("web.retry", on: web)
        invokeIfPresent("recovery.remote.not_found", on: web)
        invokeIfPresent("diagnostics.copy", on: web)
        invoke("back", on: web)

        let permissions = try OnboardingOffscreenFixture(
            step: .permissions,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            voiceTool: .doubao,
            bindingPreference: .learnCurrent
        )
        defer { permissions.close() }
        for id in [
            "permission.bluetooth", "permission.input-monitoring", "permission.accessibility",
            "continue",
        ] {
            #expect(permissions.probe.actions.keys.contains(id), "missing permission action: \(id)")
        }
        invoke("permission.bluetooth", on: permissions)
        invoke("permission.input-monitoring", on: permissions)
        invoke("permission.accessibility", on: permissions)
        invoke("continue", on: permissions)
        invoke("back", on: permissions)

        let remote = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            voiceTool: .doubao
        )
        defer { remote.close() }
        invoke("bluetooth.settings.open", on: remote)
        #expect(remote.probe.openedURLs.last?.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings")
        invokeIfPresent("recovery.remote.not_found", on: remote)
        invokeIfPresent("diagnostics.copy", on: remote)
        invoke("back", on: remote)

        let audio = try OnboardingOffscreenFixture(
            step: .audio,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { audio.close() }
        invoke("audio.install-guide", on: audio)
        invoke("recovery.audio.no_output_device", on: audio)
        invoke("diagnostics.copy", on: audio)
        invoke("audio.device.MiRemoteV2ch_UID", on: audio)
        #expect(audio.settings.selectedAudioDeviceUID == DoubaoAudioDevicePolicy.deviceUID)
        invoke("audio.device.BlackHole2ch_UID", on: audio)
        #expect(audio.settings.selectedAudioDeviceUID == "BlackHole2ch_UID")
        invoke("back", on: audio)

        let voiceTest = try OnboardingOffscreenFixture(
            step: .voiceTest,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .typeless
        )
        defer { voiceTest.close() }
        for id in [
            "voice-test.confirm.voice-key", "voice-test.confirm.microphone", "continue",
        ] {
            #expect(voiceTest.probe.actions.keys.contains(id), "missing voice-test action: \(id)")
        }
        #expect(voiceTest.probe.actions.keys.contains("voice-test.gain.set-12"))
        invoke("voice-test.gain.set-12", on: voiceTest)
        #expect(voiceTest.settings.gainDB == 12)
        invoke("voice-test.confirm.voice-key", on: voiceTest)
        invoke("voice-test.confirm.microphone", on: voiceTest)
        #expect(voiceTest.probe.toggleValues["voice-test.confirm.voice-key"] == true)
        invoke("voice-test.confirm.voice-key", on: voiceTest)
        #expect(voiceTest.probe.toggleValues["voice-test.confirm.voice-key"] == false)
        invoke("voice-tool.reopen", on: voiceTest)
        #expect(voiceTest.probe.launchedVoiceTools.last == .typeless)
        invokeIfPresent("recovery.remote.not_found", on: voiceTest)
        invokeIfPresent("diagnostics.copy", on: voiceTest)
        invoke("back", on: voiceTest)

        let doubaoVoiceTest = try OnboardingOffscreenFixture(
            step: .voiceTest,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { doubaoVoiceTest.close() }
        invoke("voice-test.confirm.global-voice", on: doubaoVoiceTest)

        let controls = try OnboardingOffscreenFixture(
            step: .controls,
            remoteAvailability: .noRemote,
            controlMethod: .webRemote,
            voiceTool: .doubao
        )
        defer { controls.close() }
        invoke("recovery.controls.not_confirmed", on: controls)
        invoke("diagnostics.copy", on: controls)
        invoke("back", on: controls)

        let complete = try OnboardingOffscreenFixture(
            step: .complete,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { complete.close() }
        invoke("continue", on: complete)
        #expect(complete.settings.isOnboardingComplete)
        invoke("back", on: complete)
    }

    private func deliveredAudioDiagnostic() -> VoiceAudioDeliveryDiagnostic {
        let start = VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .miRemoteV2ch,
            actualDeviceKind: .miRemoteV2ch,
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true
        )
        var observation = start
        observation.counters = VirtualAudioPlaybackCounters(
            scheduledBuffers: 1,
            scheduledSamples: 320,
            playedBuffers: 1,
            playedSamples: 320
        )
        return VoiceAudioDeliveryDiagnostic(
            generation: 1,
            source: UsageEventSource.bluetoothRemote.rawValue,
            route: .virtualAudioDirect,
            sessionEnded: true,
            receivedBatches: 1,
            receivedSamples: 320,
            outputAtStart: start,
            outputAtObservation: observation
        )
    }
}

@MainActor
private final class OnboardingOffscreenFixture {
    let suiteName: String
    let defaults: UserDefaults
    let settings: AppSettings
    let model: BridgeAppModel
    let probe: OnboardingInteractionProbe
    let window: NSWindow

    init(
        step: OnboardingStep,
        remoteAvailability: OnboardingRemoteAvailability = .unselected,
        controlMethod: OnboardingControlMethod = .unselected,
        voiceTool: OnboardingVoiceTool = .doubao,
        bindingPreference: OnboardingVoiceBindingPreference = .documentedDefault,
        systemFunctionKeyAvailable: Bool = true,
        initialInputMethodGuideStep: Int? = nil,
        controlSource: OnboardingControlSource? = nil,
        voiceToolAvailability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability]? = nil
    ) throws {
        let suiteName = "RemoteMicTests.Onboarding.Fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.defaultsUnavailable
        }
        self.suiteName = suiteName
        self.defaults = defaults
        settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        settings.setOnboardingVoiceTool(voiceTool)
        settings.setOnboardingVoiceBindingPreference(bindingPreference)
        settings.setOnboardingRemoteAvailability(remoteAvailability)
        settings.setOnboardingControlMethod(controlMethod)
        settings.setOnboardingControlSource(controlSource ?? .migrated(from: controlMethod))
        settings.setOnboardingStep(step)
        probe = OnboardingInteractionProbe(openURL: { _ in })
        model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [
                AudioDeviceInfo(id: 1, uid: DoubaoAudioDevicePolicy.deviceUID, name: "MiRemoteV 2ch"),
                AudioDeviceInfo(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
            ]
        )
        let localization = LocalizationStore(
            settings: settings,
            resourceBundle: RemoteMicResourceBundle.mainOrDevelopment
        )
        let view = OnboardingView(
            model: model,
            completeRuntimeReadyOverride: true,
            allowsInputSourceSwitching: false,
            systemFunctionKeyAvailableOverride: systemFunctionKeyAvailable,
            voiceToolAvailabilityOverride: voiceToolAvailability ?? [
                .doubao: .available,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ],
            initialInputMethodGuideStep: initialInputMethodGuideStep,
            interactionProbe: probe
        )
        .environmentObject(localization)
        .frame(width: 1020, height: 772)
        let hostingController = NSHostingController(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1020, height: 772),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentViewController = nil
        window.orderOut(nil)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private enum FixtureError: Error {
        case defaultsUnavailable
    }
}
