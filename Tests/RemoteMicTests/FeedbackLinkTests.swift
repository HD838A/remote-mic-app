import Foundation
import Testing
@testable import RemoteMic

struct FeedbackLinkTests {
    @Test func feedbackUsesPublicMacGuestEntryWithoutCredentials() throws {
        let components = try #require(URLComponents(
            url: AppLinks.feedback,
            resolvingAgainstBaseURL: false
        ))

        #expect(components.scheme == "https")
        #expect(components.host == "my.sayall.app")
        #expect(components.path == "/api/guest-entry")
        #expect(components.queryItems == [URLQueryItem(name: "source", value: "mac")])

        let forbiddenNames = ["code", "token", "device", "device_id", "deviceid"]
        #expect(components.queryItems?.allSatisfy {
            !forbiddenNames.contains($0.name.lowercased())
        } == true)
    }

    @Test func statusMenuWiresFeedbackImmediatelyAfterWebsite() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/RemoteMicApp.swift"
            ),
            encoding: .utf8
        )
        let websiteEntry = try #require(source.range(
            of: "menu.addItem(menuItem(\"about.support.website\", action: #selector(openWebsite)))"
        ))
        let feedbackEntry = try #require(source.range(
            of: "menu.addItem(menuItem(\"about.support.feedback\", action: #selector(openFeedback)))"
        ))
        let openFeedback = try #require(source.range(
            of: "@objc private func openFeedback()"
        ))

        #expect(websiteEntry.lowerBound < feedbackEntry.lowerBound)
        #expect(source[websiteEntry.upperBound..<feedbackEntry.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty)
        #expect(feedbackEntry.lowerBound < openFeedback.lowerBound)
        #expect(source[openFeedback.lowerBound...].prefix(180).contains(
            "NSWorkspace.shared.open(AppLinks.feedback)"
        ))
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
