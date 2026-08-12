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

    @Test func productionReleaseRequiresAndVerifiesPrivateFeaturePackage() throws {
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

        #expect(buildSource.contains("SAYALL_AI_PACKAGE_PATH"))
        #expect(buildSource.contains("A SayAllAI package is required for this build"))
        #expect(buildSource.contains("SayAllAI_SayAllAI.bundle"))
        #expect(buildSource.contains("SayAllAIIncluded"))
        #expect(notarizeSource.contains("export REQUIRE_SAYALL_AI_PACKAGE=1"))
        #expect(verifySource.contains("App is missing the required SayAllAI package marker"))
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
        let previewVerifierSource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-preview-branch.sh"),
            encoding: .utf8
        )

        #expect(fastReleaseSource.contains("fast release requires a clean committed worktree"))
        #expect(fastReleaseSource.contains("fast release requires release/pre-v$VERSION"))
        #expect(fastReleaseSource.contains("verify-preview-branch.sh"))
        #expect(fastReleaseSource.contains("fast release rejected non-document/resource change"))
        #expect(fastReleaseSource.contains("fast release rejected a possible plaintext credential"))
        #expect(fastReleaseSource.contains("fast release requires a $VERSION entry"))
        #expect(fastReleaseSource.contains("xcrun swift test"))
        #expect(fastReleaseSource.contains("validate-notary-secrets-repo.sh"))
        #expect(fastReleaseSource.contains("ALLOW_ISOLATED_RELEASE_KEYCHAIN=1"))
        #expect(fastReleaseSource.contains("PARALLEL_PACKAGE_NOTARIZATION=1"))
        #expect(fastReleaseSource.contains("publish-release.sh\" prerelease"))
        #expect(!fastReleaseSource.contains("git push origin main"))
        #expect(notarizeSource.contains("wait \"$install_notary_pid\""))
        #expect(notarizeSource.contains("wait \"$uninstall_notary_pid\""))
        #expect(publishSource.contains("usage: $0 prerelease|promote"))
        #expect(!publishSource.contains("prerelease|promote|release"))
        #expect(publishSource.contains("stable promotion is restricted to main"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(publishSource.contains("stable-promotion.json"))
        #expect(publishSource.contains("verify_cdn_assets"))
        #expect(publishSource.contains("https://download.sayall.app/mac/releases/$RELEASE_TAG/"))
        #expect(previewVerifierSource.contains("release/pre-vX.Y.Z"))
        #expect(previewVerifierSource.contains("preview candidate contains a non-release change"))
        #expect(previewVerifierSource.contains("git merge-base --is-ancestor \"$BASE_REF\" HEAD"))
        let candidateIndex = try #require(publishSource.range(of: "gh release create"))
        let promotionIndex = try #require(publishSource.range(of: "gh release edit"))
        #expect(candidateIndex.lowerBound < promotionIndex.lowerBound)
    }

    @Test func previewBranchPushBuildsACandidateWithoutReleaseSecrets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-preview-candidate.yml"),
            encoding: .utf8
        )

        #expect(workflowSource.contains("release/pre-v*"))
        #expect(workflowSource.contains("./scripts/verify-preview-branch.sh"))
        #expect(workflowSource.contains("swift test"))
        #expect(workflowSource.contains("./scripts/test.sh"))
        #expect(workflowSource.contains("swift build -c release"))
        #expect(workflowSource.contains("./scripts/build-app.sh"))
        #expect(workflowSource.contains("GetSayAll/sayall-ai"))
        #expect(workflowSource.contains("REQUIRE_SAYALL_AI_PACKAGE=1"))
        #expect(workflowSource.contains("actions/upload-artifact@v4"))
        #expect(workflowSource.contains("contents: read"))
        #expect(!workflowSource.contains("MATCH_PASSWORD"))
        #expect(!workflowSource.contains("AuthKey_"))

        let ciWorkflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-ci.yml"),
            encoding: .utf8
        )
        #expect(ciWorkflowSource.contains("workflow_dispatch:"))
    }

    @Test func stablePromotionRequiresMainAndCandidateProvenance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let guardWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release-guard.yml"),
            encoding: .utf8
        )
        let promotionWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-stable-promote.yml"),
            encoding: .utf8
        )
        let reconciliationSource = try String(
            contentsOf: root.appendingPathComponent("scripts/reconcile-release-event.sh"),
            encoding: .utf8
        )

        #expect(guardWorkflow.contains("types: [published, released, edited]"))
        #expect(guardWorkflow.contains("contents: write"))
        #expect(guardWorkflow.contains("pull-requests: write"))
        #expect(guardWorkflow.contains("issues: write"))
        #expect(guardWorkflow.contains("actions: write"))
        #expect(reconciliationSource.contains("restored $RELEASE_TAG to pre-release"))
        #expect(reconciliationSource.contains("candidate-provenance.json"))
        #expect(reconciliationSource.contains("stable-promotion.json"))
        #expect(reconciliationSource.contains(".candidateBranch == (\"release/pre-\" + $tag)"))
        #expect(reconciliationSource.contains("gh pr merge \"$PR_NUMBER\""))
        #expect(reconciliationSource.contains("--auto --merge"))
        #expect(reconciliationSource.contains("gh workflow run mac-ci.yml"))
        #expect(reconciliationSource.contains("stable-promotion-approved"))
        #expect(promotionWorkflow.contains("workflow_dispatch:"))
        #expect(promotionWorkflow.contains("workflow_run:"))
        #expect(promotionWorkflow.contains("github.event.workflow_run.conclusion == 'success'"))
        #expect(promotionWorkflow.contains("stable-promotion-approved"))
        #expect(promotionWorkflow.contains("gh pr merge \"$pr_number\""))
        #expect(promotionWorkflow.contains("./scripts/publish-release.sh promote"))
        #expect(!promotionWorkflow.contains("notarize-release.sh"))
        #expect(publishSourceSupportsCrossVersionPromotion(root: root))
    }

    private func publishSourceSupportsCrossVersionPromotion(root: URL) -> Bool {
        guard let source = try? String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        ) else {
            return false
        }
        return source.contains("stable promotion requires an explicit RELEASE_TAG") &&
            source.contains("VERSION=\"$(jq -r '.version' \"$provenance\")\"") &&
            source.contains(".candidateBranch == (\"release/pre-\" + $tag)")
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
            "--release-notes-url-prefix \"$CDN_DOWNLOAD_PREFIX\"",
        ] {
            #expect(notarizeSource.contains(requiredText))
        }
        #expect(publishSource.contains("$STAGING_DIR/${ZH_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("$STAGING_DIR/${EN_RELEASE_NOTES:t}"))
        #expect(publishSource.contains(".payloadAssets | length == 8"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(notarizeSource.contains("https://download.sayall.app/mac/releases/$RELEASE_TAG/"))
        #expect(publishSource.contains("--range 0-1023"))
        #expect(publishSource.contains("x-remote-mic-cdn: cloudflare"))
    }
}
