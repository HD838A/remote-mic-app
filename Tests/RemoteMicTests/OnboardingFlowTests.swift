import Foundation
import Testing
@testable import RemoteMic

@Suite("First-run onboarding")
struct OnboardingFlowTests {
    @Test func navigationOrderIsStableAndGroupedIntoThreePhases() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .voiceTool)
        #expect(OnboardingStep.voiceTool.next == .permissions)
        #expect(OnboardingStep.permissions.next == .remote)
        #expect(OnboardingStep.remote.next == .audio)
        #expect(OnboardingStep.audio.next == .voiceTest)
        #expect(OnboardingStep.voiceTest.next == .controls)
        #expect(OnboardingStep.controls.next == .complete)
        #expect(OnboardingStep.complete.next == nil)

        #expect(OnboardingPhase.phase(for: .welcome) == .prepare)
        #expect(OnboardingPhase.phase(for: .permissions) == .setup)
        #expect(OnboardingPhase.phase(for: .complete) == .tryIt)
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
        #expect(activeSource.contains("model.refreshRemoteDiscovery()"))
        #expect(activeSource.contains("model.applyHIDSettings()"))

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
        #expect(activeSource.contains("model.refreshRemoteDiscovery()"))
    }

    @Test func remoteStepExposesHIDStatusAndAnExplicitRetry() throws {
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
        #expect(remoteSource.contains("model.applyHIDSettings()"))
        #expect(remoteSource.contains("ViewThatFits(in: .horizontal)"))
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

    @Test func audioStepOffersEveryAvailableOutputInsteadOfRequiringMiRemote() throws {
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

        #expect(audioSource.contains("ForEach(model.audioDevices"))
        #expect(!audioSource.contains("DoubaoAudioDevicePolicy.device"))
        #expect(!audioSource.contains("Picker("))
        #expect(audioSource.contains("settings.selectedAudioDeviceUID = device.uid"))
        #expect(audioSource.contains("model.applyAudioSettings(reason: \"onboarding_audio_device_selected\")"))
    }

    @Test func availableBlackHoleCanSatisfyTheAudioSelectionGate() {
        let availableUIDs = ["MiRemoteV2ch_UID", "BlackHole2ch_UID"]

        #expect(OnboardingAudioSelectionPolicy.isSelectedDeviceAvailable(
            selectedUID: "BlackHole2ch_UID",
            availableUIDs: availableUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSelectedDeviceAvailable(
            selectedUID: "missing",
            availableUIDs: availableUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSelectedDeviceAvailable(
            selectedUID: "",
            availableUIDs: availableUIDs
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

        settings.setOnboardingVoiceTool(.doubao)
        settings.setOnboardingStep(.audio)

        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.onboardingStep == .audio)
        #expect(resumed.onboardingVoiceTool == .doubao)
        #expect(!resumed.isOnboardingComplete)

        resumed.completeOnboarding()
        let completed = AppSettings(defaults: defaults)
        #expect(completed.isOnboardingComplete)
        #expect(completed.onboardingCompletedVersion == AppSettings.currentOnboardingVersion)
        #expect(completed.onboardingStep == .complete)

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
        #expect(restarted.selectedAudioDeviceUID == "MiRemoteV 2ch")
        #expect(restarted.customMappingEnabled)
        #expect(!restarted.showDockIcon)
        #expect(!restarted.openMainWindowAtLaunch)
        #expect(restarted.checksForPreReleaseUpdates)
        #expect(restarted.action(for: .ok) == .escape)
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
}
