import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Community help sheet")
struct CommunityHelpSheetTests {
    @Test func qrResourcesAreBundledAndSquare() throws {
        let bundle = RemoteMicResourceBundle.mainOrDevelopment
        for name in [
            "community-help-douyin-qr",
            "community-help-xiaohongshu-qr",
        ] {
            let url = try #require(
                bundle.url(forResource: name, withExtension: "png")
            )
            let image = try #require(NSImage(contentsOf: url))
            #expect(image.size.width == 512)
            #expect(image.size.height == 512)
        }
    }

    @Test func entrySourcesUseStableLogTokens() {
        #expect(CommunityHelpEntrySource.onboarding.rawValue == "onboarding")
        #expect(CommunityHelpEntrySource.settings.rawValue == "settings")
    }

    @Test func entriesAreWiredInBothSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let overlay = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/CommunityHelpSheet.swift"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(onboarding.contains("onboarding.community_help"))
        #expect(onboarding.contains("source: .onboarding"))
        #expect(settings.contains("settings.community_help"))
        #expect(settings.contains("source: .settings"))
        #expect(onboarding.contains("CommunityHelpOverlay("))
        #expect(settings.contains("CommunityHelpOverlay("))
        #expect(overlay.contains(".onTapGesture"))
        #expect(overlay.contains(".onExitCommand"))
        #expect(buildScript.contains("community-help-douyin-qr.png"))
        #expect(buildScript.contains("community-help-xiaohongshu-qr.png"))
    }
}
