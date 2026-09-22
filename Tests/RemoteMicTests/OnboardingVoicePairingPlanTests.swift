import Foundation
import Testing
@testable import RemoteMic

@Suite("Onboarding 输入工具与控制来源配对")
struct OnboardingVoicePairingPlanTests {
    @Test func selectedRemotePhotoFollowsTheControlSource() {
        #expect(
            OnboardingRemotePhotoKind.resolve(
                source: .xiaomiRemote,
                selectedModel: nil
            ) == .bundled(resourceName: "RC003-remote-photo")
        )
        #expect(
            OnboardingRemotePhotoKind.resolve(
                source: .siriRemote,
                selectedModel: nil
            ) == .siriRemote
        )
        #expect(
            OnboardingRemotePhotoKind.resolve(
                source: .chromecastRemote,
                selectedModel: nil
            ) == .chromecastRemote
        )
        #expect(
            OnboardingRemotePhotoKind.resolve(
                source: .xiaomiRemote,
                selectedModel: .unknown
            ) == .bundled(resourceName: "RC003-remote-photo")
        )
    }

    @Test func verifiedBindingWinsDuringOnboardingRerun() throws {
        let suiteName = "RemoteMicTests.Onboarding.VerifiedBindingPriority.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let learned = VoiceToolUserBinding(
            tool: .doubao,
            shortcut: .rightCommand,
            gestureMode: .toggle,
            source: .userLearned,
            validationState: .verified,
            verifiedToolVersion: nil,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        settings.setOnboardingVoiceTool(.doubao)
        settings.setOnboardingControlSource(.chromecastRemote)

        let learnedPlan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: settings.onboardingVoiceTool,
            controlSource: settings.onboardingControlSource,
            userBinding: learned
        ))
        settings.beginOnboardingVoiceTrial(learnedPlan)
        settings.verifyOnboardingVoiceBinding(at: Date(timeIntervalSince1970: 2))

        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: settings.onboardingVoiceTool,
            controlSource: settings.onboardingControlSource,
            userBinding: settings.verifiedVoiceToolBinding
        ))
        #expect(plan.binding.shortcut == .rightCommand)
        #expect(plan.binding.source == .userLearned)
    }

    @Test func documentedDefaultsMatchTheCapabilityMatrix() throws {
        let doubao = VoiceToolAdapterProfile.profile(for: .doubao)
        #expect(doubao.defaultShortcutByMode[.hold] == .function)
        #expect(doubao.defaultShortcutByMode[.toggle] == .rightCommand)

        let weixin = VoiceToolAdapterProfile.profile(for: .weixin)
        #expect(weixin.defaultShortcutByMode[.hold] == .function)
        #expect(weixin.defaultShortcutByMode[.toggle] == .rightCommand)

        for tool in [OnboardingVoiceTool.typeless, .vokie, .chatterFly] {
            let profile = VoiceToolAdapterProfile.profile(for: tool)
            #expect(profile.defaultShortcutByMode[.toggle] == .function)
        }
        #expect(VoiceToolAdapterProfile.profile(for: .vokie).defaultShortcutByMode[.hold] == nil)
        #expect(VoiceToolAdapterProfile.profile(for: .chatterFly).defaultShortcutByMode[.hold] == nil)
    }

    @Test func holdOnlyRemoteUsesNativeHoldForDoubaoAndFnConversionForToggleOnlyTools() throws {
        let doubao = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .doubao,
            controlSource: .xiaomiRemote
        ))
        #expect(doubao.binding.gestureMode == .hold)
        #expect(doubao.binding.shortcut == .function)
        #expect(!doubao.fnTapModeEnabled)

        for tool in [OnboardingVoiceTool.typeless, .vokie, .chatterFly] {
            let plan = try #require(OnboardingVoicePairingPlan.resolve(
                tool: tool,
                controlSource: .xiaomiRemote
            ))
            #expect(plan.binding.gestureMode == .toggle)
            #expect(plan.binding.shortcut == .function)
            #expect(plan.fnTapModeEnabled)
        }
    }

    @Test func chromecastUsesNativeToggleWithoutFnTapConversion() throws {
        let doubao = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .doubao,
            controlSource: .chromecastRemote
        ))
        #expect(doubao.binding.gestureMode == .toggle)
        #expect(doubao.binding.shortcut == .rightCommand)
        #expect(!doubao.fnTapModeEnabled)
        #expect(doubao.chromecastVoiceMode == .toggle)

        let typeless = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .chromecastRemote
        ))
        #expect(typeless.binding.shortcut == .function)
        #expect(!typeless.fnTapModeEnabled)
    }

    @Test func appleAndWebExposeHoldAndToggle() {
        #expect(OnboardingControlSource.appleCompanion.supportedGestureModes == [.hold, .toggle])
        #expect(OnboardingControlSource.webRemote.supportedGestureModes == [.hold, .toggle])
    }

    @Test func learnedBindingWinsAndIncompatibleConversionIsRejected() throws {
        let learned = VoiceToolUserBinding(
            tool: .doubao,
            shortcut: .rightCommand,
            gestureMode: .toggle,
            source: .userLearned,
            validationState: .verified,
            verifiedToolVersion: nil,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        let chromecast = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .doubao,
            controlSource: .chromecastRemote,
            userBinding: learned
        ))
        #expect(chromecast.binding == learned)

        #expect(OnboardingVoicePairingPlan.resolve(
            tool: .doubao,
            controlSource: .xiaomiRemote,
            userBinding: learned
        ) == nil)
    }

    @Test func restartDoesNotOverwriteExistingVoiceConfiguration() throws {
        let suiteName = "RemoteMicTests.Onboarding.BindingRestart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .rightOption
        settings.voiceFnTapModeEnabled = false
        settings.restartOnboarding()

        #expect(settings.voiceKeyMode == .rightOption)
        #expect(!settings.voiceFnTapModeEnabled)
    }

    @Test func stagedBindingRestoresOnFailureAndCommitsOnlyAfterVerification() throws {
        let suiteName = "RemoteMicTests.Onboarding.BindingTransaction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .rightOption
        settings.voiceFnTapModeEnabled = false
        settings.setOnboardingVoiceTool(.typeless)
        settings.setOnboardingControlSource(.xiaomiRemote)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .xiaomiRemote
        ))
        settings.beginOnboardingVoiceTrial(plan)
        #expect(settings.voiceKeyMode == .function)
        #expect(settings.voiceFnTapModeEnabled)
        #expect(settings.verifiedVoiceToolBinding == nil)

        settings.discardOnboardingVoiceTrial()
        #expect(settings.voiceKeyMode == .rightOption)
        #expect(!settings.voiceFnTapModeEnabled)

        settings.beginOnboardingVoiceTrial(plan)
        settings.verifyOnboardingVoiceBinding(at: Date(timeIntervalSince1970: 2))
        #expect(settings.verifiedVoiceToolBinding?.validationState == .verified)
        #expect(settings.voiceKeyMode == .function)
        #expect(settings.voiceFnTapModeEnabled)

        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.verifiedVoiceToolBinding?.tool == .typeless)
        #expect(resumed.voiceKeyMode == .function)
        #expect(resumed.voiceFnTapModeEnabled)
    }

    @Test func publicBuildOnlyOffersXiaomiRemote() {
        #if SAYALL_SIRI_REMOTE_ENABLED || SAYALL_CHROMECASE_ENABLED || SAYALL_MAC_REMOTE_ENABLED
        #expect(OnboardingBuildCapabilities.availableControlSources.contains(.xiaomiRemote))
        #else
        #expect(OnboardingBuildCapabilities.availableControlSources == [.xiaomiRemote])
        #endif
    }
}
