import Foundation
import Testing

struct MembershipRefreshRoutingTests {
    @Test func lifecycleRefreshesStaySeparateFromOpeningMembership() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/RemoteMic")
        let app = try String(contentsOf: sources.appendingPathComponent("RemoteMicApp.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sources.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        let foreground = try #require(app.range(of: "func applicationDidBecomeActive"))
        let reopen = try #require(app.range(of: "func applicationShouldHandleReopen"))
        #expect(!app[foreground.upperBound..<reopen.lowerBound].contains("membershipFeature.refreshIfNeeded()"))
        #expect(!app.contains("membershipFeature.refreshIfNeeded()"))

        let membershipPage = try #require(settings.range(of: "case .membership:\n            if membershipFeature.isFeatureVisible"))
        let nextPage = try #require(settings.range(of: "case .mapping:", range: membershipPage.upperBound..<settings.endIndex))
        let page = settings[membershipPage.upperBound..<nextPage.lowerBound]
        #expect(page.contains("membershipFeature.settingsView()"))
        #expect(page.contains(".onAppear { membershipFeature.refreshIfNeeded() }"))
        #expect(settings.components(separatedBy: "membershipFeature.refreshIfNeeded()").count == 2)
    }
}
