import Foundation
import Testing
@testable import RemoteMic

@Suite("Bridge app model action regression", .serialized)
@MainActor
struct BridgeAppModelActionRegressionTests {
    private static func profile() -> CustomApplicationProfile {
        CustomApplicationProfile(
            displayName: "Example Agent",
            bundleIdentifier: "com.example.agent",
            applicationPath: "/Applications/Example Agent.app",
            focusStrategy: .recordedAccessibility
        )
    }

    private func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let suiteName = "BridgeAppModelActionRegression.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suiteName))
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    @Test func pendingApplicationOpensThroughBridgeAndSkipsFocus() async throws {
        let (settings, defaults, suiteName) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = Self.profile()
        settings.addCustomApplicationProfile(profile)
        defaults.set([profile.id.uuidString], forKey: "portableTransferPendingApplications")
        var sent: [(ButtonAction, UUID?, Bool)] = []
        let model = BridgeAppModel(
            settings: settings,
            externalActionSender: { action, _, applicationProfile, focusAllowed in
                sent.append((action, applicationProfile?.id, focusAllowed))
                return true
            },
            customApplicationURLResolver: { _ in
                URL(fileURLWithPath: "/Applications/Example Agent.app")
            }
        )
        NoticeCenter.shared.dismiss()

        let handled = model.performExternalConfiguredAction(ConfiguredButtonAction(
            action: .openCustomApplication,
            shortcut: nil,
            applicationProfileID: profile.id
        ))

        #expect(handled)
        #expect(sent.count == 1)
        #expect(sent.first?.0 == .openCustomApplication)
        #expect(sent.first?.1 == profile.id)
        #expect(sent.first?.2 == false)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(NoticeCenter.shared.current == nil)
    }

    @Test func missingApplicationThroughBridgeReturnsFailureAndShowsNotice() async throws {
        let (settings, defaults, suiteName) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = Self.profile()
        settings.addCustomApplicationProfile(profile)
        var sentCount = 0
        let model = BridgeAppModel(
            settings: settings,
            externalActionSender: { _, _, _, _ in
                sentCount += 1
                return true
            },
            customApplicationURLResolver: { _ in nil }
        )
        NoticeCenter.shared.dismiss()

        let handled = model.performExternalConfiguredAction(ConfiguredButtonAction(
            action: .openCustomApplication,
            shortcut: nil,
            applicationProfileID: profile.id
        ))

        #expect(!handled)
        #expect(sentCount == 0)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(NoticeCenter.shared.current?.tier == .warning)
        #expect(NoticeCenter.shared.current?.title ==
            noticeLocalized("button_mapping.action_failed.title"))
        NoticeCenter.shared.dismiss()
    }

    @Test func actionSenderFailureThroughBridgeShowsNotice() async throws {
        let (settings, defaults, suiteName) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = Self.profile()
        settings.addCustomApplicationProfile(profile)
        let model = BridgeAppModel(
            settings: settings,
            externalActionSender: { _, _, _, _ in false },
            customApplicationURLResolver: { _ in
                URL(fileURLWithPath: "/Applications/Example Agent.app")
            }
        )
        NoticeCenter.shared.dismiss()

        let handled = model.performExternalConfiguredAction(ConfiguredButtonAction(
            action: .openCustomApplication,
            shortcut: nil,
            applicationProfileID: profile.id
        ))

        #expect(!handled)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(NoticeCenter.shared.current?.tier == .warning)
        #expect(NoticeCenter.shared.current?.title ==
            noticeLocalized("button_mapping.action_failed.title"))
        NoticeCenter.shared.dismiss()
    }
}
