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

    @Test func releaseFeedResolverUsesNewestPublishedMacAppcast() throws {
        let data = Data(#"""
        [
          {
            "draft": false,
            "published_at": "2026-08-10T04:26:12Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.3/appcast.xml"
              }
            ]
          },
          {
            "draft": true,
            "published_at": "2026-08-10T12:00:00Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.6/appcast.xml"
              }
            ]
          },
          {
            "draft": false,
            "published_at": "2026-08-10T10:00:20Z",
            "assets": [
              {
                "name": "Remote-Mic-1.8.5.zip",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.5/Remote-Mic-1.8.5.zip"
              },
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.5/appcast.xml"
              }
            ]
          }
        ]
        """#.utf8)

        #expect(
            try UpdateFeedResolver.latestAppcastURL(from: data).absoluteString
                == "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.5/appcast.xml"
        )
    }

    @Test func releaseFeedResolverFailsClosedWhenNoAppcastExists() {
        let data = Data(#"""
        [
          {
            "draft": false,
            "published_at": "2026-08-10T10:00:20Z",
            "assets": []
          }
        ]
        """#.utf8)

        #expect(throws: UpdateFeedResolutionError.self) {
            try UpdateFeedResolver.latestAppcastURL(from: data)
        }
    }

    @Test func releaseFeedResolverKeepsIntelPreReleaseChecksOnTheIntelFeed() throws {
        let data = Data(#"""
        [
          {
            "draft": false,
            "published_at": "2026-08-12T01:00:00Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.11/appcast.xml"
              },
              {
                "name": "appcast-intel.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.11/appcast-intel.xml"
              }
            ]
          }
        ]
        """#.utf8)

        #expect(
            try UpdateFeedResolver.latestAppcastURL(
                from: data,
                assetName: "appcast-intel.xml"
            ).lastPathComponent == "appcast-intel.xml"
        )
    }

    @Test func releaseFeedResolverSeparatesStableAndPreReleaseVersions() throws {
        let data = Data(#"""
        [
          {
            "draft": false,
            "prerelease": true,
            "tag_name": "v1.8.20",
            "published_at": "2026-08-14T03:40:24Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.20/appcast.xml"
              }
            ]
          },
          {
            "draft": false,
            "prerelease": false,
            "tag_name": "v1.8.3",
            "published_at": "2026-08-10T04:26:12Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/HD838A/remote-mic-app/releases/download/v1.8.3/appcast.xml"
              }
            ]
          }
        ]
        """#.utf8)

        let stable = try UpdateFeedResolver.latestFeed(
            from: data,
            includePreRelease: false
        )
        let preview = try UpdateFeedResolver.latestFeed(
            from: data,
            includePreRelease: true
        )
        #expect(stable.version == "1.8.3")
        #expect(preview.version == "1.8.20")
        #expect(!UpdateVersion.isNewer(stable.version, than: "1.8.19"))
        #expect(UpdateVersion.isNewer(preview.version, than: "1.8.19"))
    }

    @Test func updateVersionComparisonTreatsEqualAndOlderVersionsAsNotNewer() {
        #expect(!UpdateVersion.isNewer("v1.8.3", than: "1.8.19"))
        #expect(!UpdateVersion.isNewer("1.8.19", than: "1.8.19"))
        #expect(UpdateVersion.isNewer("1.8.20", than: "1.8.19"))
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
