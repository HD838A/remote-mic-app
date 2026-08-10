import Foundation
import Testing

@Suite("Build signing")
struct BuildSigningTests {
    @Test func buildDefaultsToStableAdHocSigning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(source.contains("CODE_SIGN_IDENTITY"))
        #expect(source.contains("SIGNING_IDENTITY=\"${CODE_SIGN_IDENTITY:--}\""))
        #expect(source.contains("if [[ \"$SIGNING_IDENTITY\" == \"-\" ]]; then"))
        #expect(source.contains("designated => identifier"))
        #expect(source.contains("XPCServices/Installer.xpc"))
        #expect(source.contains("XPCServices/Downloader.xpc"))
        #expect(source.contains("--preserve-metadata=entitlements"))
        #expect(source.contains("$SPARKLE_VERSION_DIR/Autoupdate"))
        #expect(source.contains("$SPARKLE_VERSION_DIR/Updater.app"))
        #expect(!source.contains("security find-identity -p codesigning -v"))
        #expect(!source.contains("git config --get user.email"))
        let signingSource = try #require(source.components(separatedBy: "codesign --verify --deep").first)
        #expect(!signingSource.contains("--deep"))
        let adHocSigningSource = try #require(
            signingSource.components(
                separatedBy: "if [[ \"$SIGNING_IDENTITY\" == \"-\" ]]; then"
            ).last
        )
        #expect(!adHocSigningSource.contains("--options runtime"))
    }

    @Test func productionReleaseRequiresAndVerifiesWebRemoteConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        #expect(buildSource.contains("REQUIRE_WEB_REMOTE_CONFIGURATION"))
        #expect(buildSource.contains("A production wss:// relay URL ending in /ws is required"))
        #expect(notarizeSource.contains("Apps/MobileWeb/.private/production.env"))
        #expect(notarizeSource.contains("export REQUIRE_WEB_REMOTE_CONFIGURATION=1"))
        #expect(notarizeSource.contains("export REMOTE_WEB_RELAY_URL"))
        #expect(verifySource.contains("Developer ID app is missing a production Web Remote relay URL"))
    }

    @Test func unavailablePreReleaseFeedDoesNotPresentACustomErrorAlert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        #expect(source.contains("resolved=false fallback=stable"))
        #expect(source.contains("user_alert=false"))
        #expect(!source.contains("showPreReleaseFeedUnavailableAlert"))
    }

    @Test func fastReleaseKeepsMandatorySafetyGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fastReleaseSource = try String(
            contentsOf: root.appendingPathComponent("scripts/fast-release.sh"),
            encoding: .utf8
        )
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let publishSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        )

        #expect(fastReleaseSource.contains("fast release requires a clean committed worktree"))
        #expect(fastReleaseSource.contains("fast release is restricted to main"))
        #expect(fastReleaseSource.contains("fast release rejected non-document/resource change"))
        #expect(fastReleaseSource.contains("fast release rejected a possible plaintext credential"))
        #expect(fastReleaseSource.contains("fast release requires a $VERSION entry"))
        #expect(fastReleaseSource.contains("xcrun swift test"))
        #expect(fastReleaseSource.contains("validate-notary-secrets-repo.sh"))
        #expect(fastReleaseSource.contains("ALLOW_ISOLATED_RELEASE_KEYCHAIN=1"))
        #expect(fastReleaseSource.contains("PARALLEL_PACKAGE_NOTARIZATION=1"))
        #expect(fastReleaseSource.contains("publish-release.sh\" release"))
        #expect(notarizeSource.contains("wait \"$install_notary_pid\""))
        #expect(notarizeSource.contains("wait \"$uninstall_notary_pid\""))
        #expect(publishSource.contains("prerelease|promote|release"))
        let candidateIndex = try #require(publishSource.range(of: "gh release create"))
        let promotionIndex = try #require(publishSource.range(of: "gh release edit"))
        #expect(candidateIndex.lowerBound < promotionIndex.lowerBound)
    }

    @Test func releasePublishesLocalizedUpdateNotesWithImmutableURLs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let publishSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "Remote-Mic-$VERSION.zh.txt",
            "Remote-Mic-$VERSION.en.txt",
            "--release-notes-url-prefix \"$DOWNLOAD_PREFIX\"",
        ] {
            #expect(notarizeSource.contains(requiredText))
        }
        #expect(publishSource.contains("$STAGING_DIR/${ZH_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("$STAGING_DIR/${EN_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("= \"8\""))
    }
}
