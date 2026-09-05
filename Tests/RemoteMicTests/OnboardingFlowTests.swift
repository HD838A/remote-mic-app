import Foundation
import Testing
@testable import RemoteMic

@Suite("First-run onboarding")
struct OnboardingFlowTests {
    @Test func navigationOrderIsStableAndGroupedIntoThreePhases() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .voiceTool)
        #expect(OnboardingStep.voiceTool.next == .remoteAvailability)
        #expect(OnboardingStep.remoteAvailability.next == .controlMethod)
        #expect(OnboardingStep.controlMethod.next == .permissions)
        #expect(OnboardingStep.permissions.next == .remote)
        #expect(OnboardingStep.remote.next == .audio)
        #expect(OnboardingStep.audio.next == .voiceTest)
        #expect(OnboardingStep.voiceTest.next == .controls)
        #expect(OnboardingStep.controls.next == .complete)
        #expect(OnboardingStep.complete.next == nil)

        #expect(OnboardingPhase.phase(for: .welcome) == .prepare)
        #expect(OnboardingPhase.phase(for: .remoteAvailability) == .prepare)
        #expect(OnboardingPhase.phase(for: .controlMethod) == .prepare)
        #expect(OnboardingPhase.phase(for: .permissions) == .setup)
        #expect(OnboardingPhase.phase(for: .complete) == .tryIt)
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

        #expect(viewSource.contains("Button(action: action)"))
        #expect(viewSource.contains("action: requestBluetoothPermission"))
        #expect(viewSource.contains("action: model.requestInputMonitoringPermission"))
        #expect(viewSource.contains("action: model.requestAccessibilityPermission"))
        #expect(viewSource.contains("if bluetoothAuthorization == .allowedAlways"))
        #expect(viewSource.contains("Privacy_Bluetooth"))
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

    @Test func permissionsBackNavigationSuppressesOnlyOneConnectedRemoteAutoRoute() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("suppressConnectedPhysicalRemoteAutoRouteOnce = true"))
        #expect(viewSource.contains("suppressConnectedPhysicalRemoteAutoRouteOnce = false"))
        #expect(viewSource.contains("auto_route_suppressed=true reason=user_back"))
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

    @Test func fnInputMethodsRequireTheSystemFnActionToBeReleased() {
        var capabilities = OnboardingCapabilities()

        #expect(OnboardingVoiceTool.doubao.preferredInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin")
        #expect(OnboardingVoiceTool.weixin.preferredInputSourceID == "com.tencent.inputmethod.wetype.pinyin")
        #expect(OnboardingVoiceTool.typeless.preferredInputSourceID == nil)
        #expect(OnboardingVoiceTool.other.preferredInputSourceID == nil)

        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .weixin,
            capabilities: capabilities
        ))

        capabilities.systemFunctionKeyAvailable = true
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

    @Test func onboardingCommandVoiceKeyIsAlwaysBlocked() {
        var capabilities = OnboardingCapabilities(systemFunctionKeyAvailable: true)
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .leftCommand,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .rightCommand,
            capabilities: capabilities
        ))
        capabilities.systemFunctionKeyAvailable = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .function,
            capabilities: capabilities
        ))
    }

    @Test func selectingAnyOnboardingVoiceToolResetsCommandToFn() throws {
        let suiteName = "RemoteMicTests.Onboarding.FnOnlyPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        for tool in [OnboardingVoiceTool.doubao, .weixin, .other] {
            settings.voiceKeyMode = .rightCommand
            settings.voiceFnTapModeEnabled = true
            settings.setOnboardingVoiceTool(tool)
            #expect(settings.voiceKeyMode == .function)
            #expect(!settings.voiceFnTapModeEnabled)
            #expect(settings.pendingOnboardingVoiceKeyMigration == .rightCommand)
            #expect(settings.consumePendingOnboardingVoiceKeyMigration() == .rightCommand)
        }

        settings.voiceKeyMode = .rightCommand
        settings.voiceFnTapModeEnabled = true
        settings.restartOnboarding()
        #expect(settings.voiceKeyMode == .function)
        #expect(!settings.voiceFnTapModeEnabled)
        #expect(settings.pendingOnboardingVoiceKeyMigration == .rightCommand)
        #expect(settings.consumePendingOnboardingVoiceKeyMigration() == .rightCommand)
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

    @Test func typelessOnboardingAlwaysUsesFnTapMode() throws {
        let suiteName = "RemoteMicTests.Onboarding.TypelessFnMode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .leftCommand
        settings.setOnboardingVoiceTool(.typeless)

        #expect(settings.voiceKeyMode == .function)
        #expect(settings.voiceFnTapModeEnabled)
        #expect(OnboardingVoiceTool.typeless.applicationBundleIdentifier == "now.typeless.desktop")
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
        #expect(viewSource.contains("onboarding.voice_tool.fn_only"))
        #expect(viewSource.contains("onboarding.voice_key.migration.title"))
        #expect(viewSource.contains("onboardingVoiceKeyMigrationNotice"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_VOICE_KEY_MODE"))
        #expect(!viewSource.contains("selectOnboardingVoiceKeyMode"))
        #expect(viewSource.contains("policy=fn_only"))
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        for resourceName in [
            "doubao-menu", "doubao-settings", "weixin-input-menu",
            "weixin-input-settings", "system-fn", "weixin-app-shortcuts",
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
        #expect(viewSource.contains("switchToSelectedInputMethod()"))
        #expect(viewSource.contains("OnboardingInputSourceSwitcher.selectIfNeeded(tool)"))
        #expect(viewSource.contains("openKeyboardSettings()"))
        #expect(!viewSource.contains("\n            ScrollView {"))
        #expect(viewSource.contains("GridItem(.flexible(), spacing: 10, alignment: .top)"))
        #expect(viewSource.contains(".frame(height: 112, alignment: .top)"))
        #expect(viewSource.contains("inputMethodGuide(for: settings.onboardingVoiceTool)"))
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
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_ALL_VOICE_TOOLS_UNAVAILABLE"))
        #expect(rendererSource.contains(".remoteAvailability"))
        #expect(rendererSource.contains("controlMethod != .physicalRemote"))
        #expect(rendererSource.contains("return \"remote-availability\""))
        #expect(rendererSource.contains("return \"control-method\""))
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
        #expect(viewSource.contains("guard settings.onboardingStep == .voiceTool else { return }"))
        #expect(viewSource.contains("private func requestTranscriptFocus()"))
        #expect(viewSource.contains("transcriptFocusRequest &+= 1"))
        #expect(viewSource.contains("window.makeFirstResponder(textView)"))
        #expect(viewSource.contains(".font(.system(size: 15))\n                        .foregroundStyle(.tertiary)\n                        .padding(.horizontal, 15)\n                        .padding(.vertical, 10)"))
        #expect(viewSource.contains(".onChange(of: transcript)"))
        #expect(!viewSource.contains(".onChange(of: transcript) { _, updatedText in"))
        #expect(viewSource.contains("OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput"))
        #expect(viewSource.contains("voiceAttempt.phase == .passed &&"))
        #expect(viewSource.contains("externalToolConfigurationConfirmed"))
        #expect(viewSource.contains("sayAllVoiceKeyConfigurationReady"))
        #expect(viewSource.contains("sayAllAudioOutputConfigurationText"))
        #expect(viewSource.contains(".foregroundStyle(onboardingAudioReady ? Color.green : Color.red)"))
        #expect(viewSource.contains(".eventSourceStateID"))
        #expect(viewSource.contains(".eventSourceUnixProcessID"))
        #expect(viewSource.contains("manualTranscriptInputObserved = true"))
        #expect(viewSource.contains("ONBOARDING TRANSCRIPT manual_keyboard_input=true"))
        #expect(viewSource.contains("voiceSessionStarted = true"))
        #expect(viewSource.contains("transcript = \"\""))
    }

    @Test func voiceTestConfigurationPolicyMatchesEachToolAndRequiresEveryConfirmation() {
        #expect(!OnboardingVoiceTestConfigurationPolicy.expectsFnTap(for: .doubao))
        #expect(!OnboardingVoiceTestConfigurationPolicy.expectsFnTap(for: .weixin))
        #expect(OnboardingVoiceTestConfigurationPolicy.expectsFnTap(for: .typeless))
        #expect(!OnboardingVoiceTestConfigurationPolicy.expectsFnTap(for: .other))

        #expect(OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .doubao))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .weixin))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .typeless))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .other))

        #expect(OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .doubao,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false
        ))
        #expect(!OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .doubao,
            voiceKeyMode: .rightCommand,
            voiceFnTapModeEnabled: false
        ))
        #expect(OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: true
        ))
        #expect(!OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false
        ))

        #expect(!OnboardingVoiceTestConfigurationPolicy.isComplete(
            voiceTool: .doubao,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            audioOutputReady: true,
            externalVoiceKeyConfirmed: true,
            externalGlobalVoiceConfirmed: false,
            externalMicrophoneConfirmed: true
        ))
        #expect(OnboardingVoiceTestConfigurationPolicy.isComplete(
            voiceTool: .doubao,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            audioOutputReady: true,
            externalVoiceKeyConfirmed: true,
            externalGlobalVoiceConfirmed: true,
            externalMicrophoneConfirmed: true
        ))
        #expect(OnboardingVoiceTestConfigurationPolicy.isComplete(
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: true,
            audioOutputReady: true,
            externalVoiceKeyConfirmed: true,
            externalGlobalVoiceConfirmed: false,
            externalMicrophoneConfirmed: true
        ))
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

    @Test func voiceTestConfigurationRequiresTheExpectedTriggerForEveryTool() {
        for tool in [OnboardingVoiceTool.doubao, .weixin, .other] {
            #expect(OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
                voiceTool: tool,
                voiceKeyMode: .function,
                voiceFnTapModeEnabled: false
            ))
            #expect(!OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
                voiceTool: tool,
                voiceKeyMode: .function,
                voiceFnTapModeEnabled: true
            ))
        }

        #expect(OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: true
        ))
        #expect(!OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false
        ))
        #expect(!OnboardingVoiceTestConfigurationPolicy.isSayAllVoiceKeyReady(
            voiceTool: .doubao,
            voiceKeyMode: .rightCommand,
            voiceFnTapModeEnabled: false
        ))
    }

    @Test func voiceTestConfigurationGateRequiresEveryVisibleConfirmation() {
        #expect(OnboardingVoiceTestConfigurationPolicy.isComplete(
            voiceTool: .weixin,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            audioOutputReady: true,
            externalVoiceKeyConfirmed: true,
            externalGlobalVoiceConfirmed: false,
            externalMicrophoneConfirmed: true
        ))
        #expect(!OnboardingVoiceTestConfigurationPolicy.isComplete(
            voiceTool: .doubao,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            audioOutputReady: true,
            externalVoiceKeyConfirmed: true,
            externalGlobalVoiceConfirmed: false,
            externalMicrophoneConfirmed: true
        ))
        #expect(OnboardingVoiceTestConfigurationPolicy.isComplete(
            voiceTool: .doubao,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            audioOutputReady: true,
            externalVoiceKeyConfirmed: true,
            externalGlobalVoiceConfirmed: true,
            externalMicrophoneConfirmed: true
        ))

        for missingCheck in 0..<3 {
            #expect(!OnboardingVoiceTestConfigurationPolicy.isComplete(
                voiceTool: .weixin,
                voiceKeyMode: .function,
                voiceFnTapModeEnabled: false,
                audioOutputReady: missingCheck != 0,
                externalVoiceKeyConfirmed: missingCheck != 1,
                externalGlobalVoiceConfirmed: true,
                externalMicrophoneConfirmed: missingCheck != 2
            ))
        }
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
        #expect(viewSource.contains("settings.setOnboardingStep(.permissions)"))
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
            of: ".onReceive(model.$isStreaming)",
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

    @Test func remoteStepExposesHIDStatusAndRoutesOneRecoveryActionToExistingRuntime() throws {
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
        #expect(remoteSource.contains("model.hidStatus.text(using: localization)"))
        #expect(remoteSource.contains("onboarding.remote.first_pairing.title"))
        #expect(remoteSource.contains("onboarding.remote.first_pairing.wake"))
        #expect(remoteSource.contains("onboarding.remote.first_pairing.pair"))
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
        #expect(viewSource.contains("onboarding.permissions.mobile_network.title"))
        #expect(viewSource.contains("onboarding.permissions.mobile_network.detail"))
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

    @Test func onboardingVoiceToolKeepsTheFnTapPreferenceInSync() throws {
        let suiteName = "RemoteMicTests.OnboardingFnTap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingVoiceTool(.typeless)
        #expect(settings.voiceFnTapModeEnabled)

        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.voiceFnTapModeEnabled)

        resumed.setOnboardingVoiceTool(.doubao)
        #expect(!resumed.voiceFnTapModeEnabled)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        #expect(viewSource.contains(
            """
            if settings.onboardingStep == .permissions {
                        if settings.onboardingControlMethod == .physicalRemote {
                            settings.customMappingEnabled = true
                        }
                        model.setVoiceFnTapModeEnabled(settings.onboardingVoiceTool == .typeless)
                    }
            """
        ))
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
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
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
        #expect(appSource.contains("showSettingsWindow(initialSection: .permissions)"))
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
            context: FirstUseDiagnosticContext(
                step: .permissions,
                capabilities: capabilities,
                hasSelectedAudioUID: false
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
            appLanguage: "zh-Hans"
        )

        let text = snapshot.redactedText
        #expect(text.contains("failure=permission.input_monitoring_denied"))
        #expect(text.contains("voice_attempt=2"))
        #expect(text.contains("diagnostic_schema=3"))
        #expect(text.contains("app_version=1.8.14"))
        #expect(text.contains("app_build=106"))
        #expect(text.contains("onboarding_voice_key_policy=fn_only"))
        #expect(text.contains("voice_key_policy_compliant=true"))
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
        #expect(text.contains("voice_external_tool_next_checks=trigger_mode_matches_fn"))
        #expect(text.contains("voice_audio_delivery_result=unavailable"))
        #expect(text.contains("voice_focus_ready_at_deadline=unknown"))
        #expect(text.contains("voice_first_sample_latency_ms=24"))
        #expect(text.contains("voice_diagnostic_boundary=external_tool_internal_state_unavailable"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("UUID"))
        #expect(!text.contains("无线麦已经连接成功"))
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
