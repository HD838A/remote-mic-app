import Foundation
import Testing
@testable import RemoteMic

@Suite("Update information")
struct UpdateInformationTests {
    @Test func stableBuildKeepsAutomaticUpdateChecksAndAboutRefresh() {
        let policy = UpdateCheckPolicy(checksForPreReleaseUpdates: false)

        #expect(policy.startsUpdaterAutomatically)
        #expect(policy.allowsBackgroundUpdatePrompts)
        #expect(policy.refreshesAboutInformationOnAppear)
    }

    @Test func previewChecksRequireUserInitiatedAboutPageAction() {
        let policy = UpdateCheckPolicy(checksForPreReleaseUpdates: true)

        #expect(!policy.startsUpdaterAutomatically)
        #expect(!policy.allowsBackgroundUpdatePrompts)
        #expect(!policy.refreshesAboutInformationOnAppear)
    }

    @Test func uiTestFeedInjectionIsRestrictedToLocalPreviewFeed() throws {
        let feed = try #require(UpdateFeedResolver.testInjectedFeed(
            environment: [
                "REMOTE_MIC_UI_TEST_MODE": "1",
                "REMOTE_MIC_UI_TEST_FEED_URL": "http://127.0.0.1:8765/appcast.xml",
                "REMOTE_MIC_UI_TEST_VERSION": "v1.9.16",
            ],
            assetName: "appcast.xml",
            includePreRelease: true
        ))
        #expect(feed.url.absoluteString == "http://127.0.0.1:8765/appcast.xml")
        #expect(feed.version == "1.9.16")
        #expect(feed.isPreRelease)
        #expect(UpdateFeedResolver.testInjectedFeed(
            environment: [
                "REMOTE_MIC_UI_TEST_MODE": "1",
                "REMOTE_MIC_UI_TEST_FEED_URL": "https://example.com/appcast.xml",
                "REMOTE_MIC_UI_TEST_VERSION": "1.9.16",
            ],
            assetName: "appcast.xml",
            includePreRelease: true
        ) == nil)
        #expect(UpdateFeedResolver.testInjectedFeed(
            environment: [
                "REMOTE_MIC_UI_TEST_MODE": "1",
                "REMOTE_MIC_UI_TEST_FEED_URL": "http://127.0.0.1:8765/appcast.xml",
                "REMOTE_MIC_UI_TEST_VERSION": "1.9.16",
            ],
            assetName: "appcast.xml",
            includePreRelease: false
        ) == nil)
    }

    @Test func cloudflareChannelSelectionSeparatesStableAndPreviewFeeds() {
        let selection = UpdateFeedSelection(
            stableFeedURLString: "https://download.sayall.app/mac/channels/stable/appcast.xml"
        )

        #expect(selection.feedURLString(checksForPreReleaseUpdates: false)
            == "https://download.sayall.app/mac/channels/stable/appcast.xml")
        #expect(selection.feedURLString(checksForPreReleaseUpdates: true)
            == "https://download.sayall.app/mac/channels/preview/appcast.xml")
    }

    @Test func cloudflareChannelSelectionKeepsIntelOnIntelFeed() {
        let selection = UpdateFeedSelection(
            stableFeedURLString: "https://download.sayall.app/mac/channels/stable/appcast-intel.xml"
        )

        #expect(selection.appcastAssetName == "appcast-intel.xml")
        #expect(selection.feedURLString(checksForPreReleaseUpdates: false)
            == "https://download.sayall.app/mac/channels/stable/appcast-intel.xml")
        #expect(selection.feedURLString(checksForPreReleaseUpdates: true)
            == "https://download.sayall.app/mac/channels/preview/appcast-intel.xml")
    }

    @Test func previewChecksStillSelectANewerStableRelease() throws {
        let stable = UpdateFeedResolver.ResolvedFeed(
            url: try #require(URL(string: "https://download.sayall.app/mac/channels/stable/appcast.xml")),
            version: "1.9.21",
            isPreRelease: false
        )
        let preview = UpdateFeedResolver.ResolvedFeed(
            url: try #require(URL(string: "https://download.sayall.app/mac/channels/preview/appcast.xml")),
            version: "1.9.20",
            isPreRelease: true
        )

        #expect(UpdateFeedResolver.preferredFeed(stable: stable, preview: preview) == stable)
    }

    @Test func previewChecksSelectANewerPreviewReleaseAndTolerateOneMissingChannel() throws {
        let stable = UpdateFeedResolver.ResolvedFeed(
            url: try #require(URL(string: "https://download.sayall.app/mac/channels/stable/appcast.xml")),
            version: "1.9.20",
            isPreRelease: false
        )
        let preview = UpdateFeedResolver.ResolvedFeed(
            url: try #require(URL(string: "https://download.sayall.app/mac/channels/preview/appcast.xml")),
            version: "1.9.22",
            isPreRelease: true
        )

        #expect(UpdateFeedResolver.preferredFeed(stable: stable, preview: preview) == preview)
        #expect(UpdateFeedResolver.preferredFeed(stable: stable, preview: nil) == stable)
        #expect(UpdateFeedResolver.preferredFeed(stable: nil, preview: preview) == preview)
        #expect(UpdateFeedResolver.preferredFeed(stable: nil, preview: nil) == nil)
    }

    @Test func previewFeedResolutionComparesBothChannels() async throws {
        let stableURL = try #require(URL(
            string: "https://download.sayall.app/mac/channels/stable/appcast.xml"
        ))
        let previewURL = try #require(URL(
            string: "https://download.sayall.app/mac/channels/preview/appcast.xml"
        ))
        let stableXML = """
        <rss><channel><item><sparkle:shortVersionString>1.9.21</sparkle:shortVersionString></item></channel></rss>
        """
        let previewXML = """
        <rss><channel><item><sparkle:shortVersionString>1.9.20</sparkle:shortVersionString></item></channel></rss>
        """

        let resolution = await UpdateFeedResolver.resolvePreviewFeed(
            stableURL: stableURL,
            previewURL: previewURL
        ) { url in
            Data((url == stableURL ? stableXML : previewXML).utf8)
        }

        #expect(resolution.stable?.version == "1.9.21")
        #expect(resolution.preview?.version == "1.9.20")
        #expect(resolution.selected == resolution.stable)
    }

    @Test func feedResolutionUsesTheHighestVersionInEachAppcast() async throws {
        let stableURL = try #require(URL(
            string: "https://download.sayall.app/mac/channels/stable/appcast.xml"
        ))
        let previewURL = try #require(URL(
            string: "https://download.sayall.app/mac/channels/preview/appcast.xml"
        ))
        let stableXML = """
        <rss><channel>
        <item><sparkle:shortVersionString>1.9.19</sparkle:shortVersionString></item>
        <item><sparkle:shortVersionString>1.9.21</sparkle:shortVersionString></item>
        </channel></rss>
        """

        let resolution = await UpdateFeedResolver.resolvePreviewFeed(
            stableURL: stableURL,
            previewURL: previewURL
        ) { url in
            guard url == stableURL else { throw UpdateFeedResolutionError.invalidResponse }
            return Data(stableXML.utf8)
        }

        #expect(resolution.stable?.version == "1.9.21")
        #expect(resolution.preview == nil)
        #expect(resolution.selected == resolution.stable)
    }

    @Test func cloudflareChannelSelectionRejectsUnexpectedStableFeedURLs() {
        let invalidFeeds = [
            "http://download.sayall.app/mac/channels/stable/appcast.xml",
            "https://github.com/HD838A/remote-mic-app/releases/latest/download/appcast.xml",
            "https://download.sayall.app/mac/channels/stable/other.xml",
            "https://download.sayall.app/mac/channels/stable/nested/appcast.xml",
            "https://download.sayall.app/mac/channels/stable/appcast.xml?source=test",
        ]

        for invalidFeed in invalidFeeds {
            let selection = UpdateFeedSelection(stableFeedURLString: invalidFeed)
            #expect(selection.feedURLString(checksForPreReleaseUpdates: false) == nil)
            #expect(selection.feedURLString(checksForPreReleaseUpdates: true) == nil)
        }
    }

    @Test func updateVersionComparisonTreatsEqualAndOlderVersionsAsNotNewer() {
        #expect(!UpdateVersion.isNewer("v1.8.3", than: "1.8.19"))
        #expect(!UpdateVersion.isNewer("1.8.19", than: "1.8.19"))
        #expect(UpdateVersion.isNewer("1.8.20", than: "1.8.19"))
    }

    @Test func semanticVersionDetectsUpdateWhenPreviewBuildIsHigherThanReleaseBuild() {
        #expect(Int("137")! < Int("141")!)
        #expect(UpdateVersion.isNewer("1.9.16", than: "1.9.13"))
        #expect(!UpdateVersion.isNewer("1.9.16", than: "1.9.16"))
    }

    @Test func localizedReleaseNotesUseImmutableReleaseAssetURLs() throws {
        let archiveURL = try #require(URL(
            string: "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.zip"
        ))

        #expect(
            UpdateReleaseNotes.assetURL(
                for: archiveURL,
                displayVersion: "1.8.6",
                localeIdentifier: "zh-Hans-CN"
            )?.absoluteString
                == "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.zh.txt"
        )
        #expect(
            UpdateReleaseNotes.assetURL(
                for: archiveURL,
                displayVersion: "1.8.6",
                localeIdentifier: "en-US"
            )?.absoluteString
                == "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.en.txt"
        )
        #expect(UpdateReleaseNotes.assetURL(
            for: URL(string: "https://example.com/Remote-Mic-1.8.6.zip")!,
            displayVersion: "1.8.6",
            localeIdentifier: "en"
        ) == nil)

        let intelArchiveURL = try #require(URL(
            string: "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6-Intel.zip"
        ))
        #expect(
            UpdateReleaseNotes.assetURL(
                for: intelArchiveURL,
                displayVersion: "1.8.6",
                localeIdentifier: "zh-Hans"
            )?.lastPathComponent == "Remote-Mic-1.8.6.zh.txt"
        )
    }

    @Test func releaseNotesParserKeepsOnlyReadableContent() {
        #expect(UpdateReleaseNotes.parse("""
        # 1.8.6

        - First user-visible improvement
        • Second user-visible fix
        """) == [
            "First user-visible improvement",
            "Second user-visible fix",
        ])
    }

    @Test @MainActor func storeReloadsNotesForTheSelectedLanguage() async throws {
        let store = UpdateInformationStore { url in
            url.lastPathComponent.hasSuffix(".zh.txt")
                ? "- 中文更新内容"
                : "- English release note"
        }
        let archiveURL = try #require(URL(
            string: "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.zip"
        ))

        store.setAvailable(
            displayVersion: "1.8.6",
            buildVersion: "67",
            archiveURL: archiveURL,
            fallbackDescription: nil,
            localeIdentifier: "zh-Hans"
        )
        for _ in 0..<20 {
            if store.state == .available(AvailableUpdateInformation(
                displayVersion: "1.8.6",
                buildVersion: "67",
                releaseNotes: ["中文更新内容"]
            )) { break }
            await Task.yield()
        }
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.6",
            buildVersion: "67",
            releaseNotes: ["中文更新内容"]
        )))

        store.reloadReleaseNotes(localeIdentifier: "en")
        for _ in 0..<20 {
            if store.state == .available(AvailableUpdateInformation(
                displayVersion: "1.8.6",
                buildVersion: "67",
                releaseNotes: ["English release note"]
            )) { break }
            await Task.yield()
        }
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.6",
            buildVersion: "67",
            releaseNotes: ["English release note"]
        )))
    }
}
