import Foundation
import Testing
@testable import RemoteMic

@Suite("Apple Remote explicit activation")
struct SiriRemoteActivationTests {
    @Test func installedHelperReplacesMissingInstallerReceipt() {
        #expect(!SiriRemoteActivationPolicy.needsActivation(
            enabled: true,
            needsUserAction: false,
            audioStatus: "ready",
            installerReceiptPresent: false,
            helperInstalled: true
        ))
        #expect(SiriRemoteActivationPolicy.needsActivation(
            enabled: true,
            needsUserAction: false,
            audioStatus: "ready",
            installerReceiptPresent: false,
            helperInstalled: false
        ))
    }

    @Test func activationStillSurfacesRetryAndUnavailableStates() {
        #expect(SiriRemoteActivationPolicy.needsActivation(
            enabled: true,
            needsUserAction: true,
            audioStatus: "ready",
            installerReceiptPresent: true,
            helperInstalled: true
        ))
        #expect(SiriRemoteActivationPolicy.needsActivation(
            enabled: true,
            needsUserAction: false,
            audioStatus: "unavailable:authorization_helper_upgrade_denied",
            installerReceiptPresent: true,
            helperInstalled: true
        ))
    }

    @Test @MainActor func discoveryAndOldOnboardingSelectionDoNotEnableServices() throws {
        let suite = "SiriActivation.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.siriRemoteEnabled)
        let profile = settings.registerAppleSiriRemote(fingerprint: "activation-test")
        settings.selectRemoteProfile(profile)
        settings.setOnboardingControlSource(.siriRemote)
        #expect(!settings.siriRemoteEnabled)
        #expect(!AppSettings(defaults: defaults).siriRemoteEnabled)
    }

    @Test @MainActor func explicitEnableWithoutMembershipSurvivesRelaunch() throws {
        let suite = "SiriActivation.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "siriRemote.enabled")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.siriRemoteEnabled)
        let membership = MembershipFeatureIntegration(configuration: nil)
        #expect(membership.buttonProfilesAccessDecision == .unavailable)
        #expect(!membership.canUseSiriRemoteVoice)
        let model = BridgeAppModel(settings: settings, membershipFeature: membership)
        model.setSiriRemoteEnabled(true)
        #expect(AppSettings(defaults: defaults).siriRemoteEnabled)
        #expect(!membership.canUseSiriRemoteVoice)
        model.setSiriRemoteEnabled(false)
        #expect(!AppSettings(defaults: defaults).siriRemoteEnabled)
        #expect(model.siriRemoteAudioStatus == "disabled")
        model.prepareSiriRemoteFromUserAction()
        #expect(model.siriRemoteAudioStatus == "disabled")
    }

    @Test @MainActor func deferredAuthorizationSurvivesRelaunchUntilUserRetries() throws {
        let suite = "SiriActivation.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.siriRemoteEnabled = true
        settings.siriRemoteNeedsUserAction = true
        for _ in 0..<3 {
            let restored = AppSettings(defaults: defaults)
            let model = BridgeAppModel(settings: restored)
            #expect(restored.siriRemoteNeedsUserAction)
            #expect(model.siriRemoteAudioStatus == "unavailable:authorization_user_action_required")
        }
        let model = BridgeAppModel(settings: settings)
        model.prepareSiriRemoteFromUserAction()
        #if SAYALL_SIRI_REMOTE_ENABLED
        #expect(!AppSettings(defaults: defaults).siriRemoteNeedsUserAction)
        #if !canImport(SayAllSiriRemote)
        #expect(model.siriRemoteAudioStatus == "preparing_hci")
        #endif
        #else
        #expect(AppSettings(defaults: defaults).siriRemoteNeedsUserAction)
        #endif
        model.setSiriRemoteEnabled(false)
    }
}
