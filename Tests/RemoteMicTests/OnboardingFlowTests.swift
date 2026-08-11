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
        capabilities.compatibleMicrophoneSelected = true
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

        completed.restartOnboarding()
        let restarted = AppSettings(defaults: defaults)
        #expect(!restarted.isOnboardingComplete)
        #expect(restarted.onboardingStep == .welcome)
        #expect(restarted.onboardingVoiceTool == .unselected)
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
