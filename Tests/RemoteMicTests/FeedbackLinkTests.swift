import Foundation
import Testing
@testable import RemoteMic

struct FeedbackLinkTests {
    @Test func feedbackUsesThisForksOwnIssueTrackerWithoutCredentials() throws {
        // This fork has no equivalent to upstream's my.sayall.app feedback
        // backend, so feedback goes to this fork's own GitHub Issues.
        let components = try #require(URLComponents(
            url: AppLinks.feedback,
            resolvingAgainstBaseURL: false
        ))

        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path == "/unfla-sh/MiRemote2Pro-Whisper/issues")

        let forbiddenNames = ["code", "token", "device", "device_id", "deviceid"]
        #expect(components.queryItems?.allSatisfy {
            !forbiddenNames.contains($0.name.lowercased())
        } != false)
    }

    @Test func aboutPageOwnsFeedbackWithoutKeepingTheStatusMenuEntry() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/RemoteMicApp.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/SettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(!appSource.contains("#selector(openFeedback)"))
        #expect(!appSource.contains("@objc private func openFeedback()"))
        #expect(settingsSource.contains("Link(destination: AppLinks.feedback)"))
        #expect(settingsSource.contains("about.support.feedback_action"))
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
