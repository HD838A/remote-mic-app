import AppKit
import Foundation
import Testing

@Suite("Build signing")
struct BuildSigningTests {
    @Test func appIconUsesTransparentMacOSAsset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconURL = root.appendingPathComponent("Resources/AppIcon.png")
        let representation = try #require(
            NSBitmapImageRep(data: Data(contentsOf: iconURL))
        )
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        #expect(representation.pixelsWide == 1024)
        #expect(representation.pixelsHigh == 1024)
        #expect(representation.hasAlpha)
        let corners: [(Int, Int)] = [
            (0, 0),
            (representation.pixelsWide - 1, 0),
            (0, representation.pixelsHigh - 1),
            (representation.pixelsWide - 1, representation.pixelsHigh - 1),
        ]
        for (x, y) in corners {
            let alpha = representation.colorAt(x: x, y: y)?.alphaComponent ?? 1
            #expect(alpha <= (1.0 / 255.0))
        }
        let centerAlpha = representation.colorAt(
            x: representation.pixelsWide / 2,
            y: representation.pixelsHigh / 2
        )?.alphaComponent ?? 0
        #expect(centerAlpha >= 0.5)
        #expect(verifySource.contains("/usr/bin/iconutil --convert iconset"))
        #expect(verifySource.contains("app icon corner is not transparent"))
    }

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
        #expect(source.contains("Contents/Helpers/SayAllMCP"))
        #expect(source.contains("$MCP_HELPER_PATH"))
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
        #expect(buildSource.contains("DEFAULT_SCRATCH_PATH=\"/private/tmp/remote-mic-swiftpm/"))
        #expect(!buildSource.contains("DEFAULT_SCRATCH_PATH=\"$ROOT/.build-app-sayall-ai\""))
        #expect(notarizeSource.contains("export REQUIRE_SAYALL_AI_PACKAGE=1"))
        #expect(notarizeSource.contains("export REQUIRE_SAYALL_MACRO_PLATFORM=1"))
        #expect(verifySource.contains("App is missing the required SayAllAI package marker"))
        #expect(verifySource.contains("CFBundleDevelopmentRegion"))
    }

    @Test func optionalMacroPlatformResourcesArePackagedAndVerified() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        #expect(buildSource.contains("SAYALL_MACRO_PLATFORM_PATH"))
        #expect(buildSource.contains("SayAllMacroPlatformIncluded"))
        #expect(buildSource.contains("SayAllMacroPlatform_SayAllMacroRemoteMic.bundle"))
        #expect(buildSource.contains("SayAll macro platform resource bundle is missing"))
        #expect(buildSource.contains("SayAll macro page bypasses the packaged resource resolver"))
        #expect(verifySource.contains("REQUIRE_SAYALL_MACRO_PLATFORM"))
        #expect(verifySource.contains("SayAllMacroPlatformIncluded"))
        #expect(verifySource.contains("App is missing the required SayAll macro platform marker"))
        #expect(verifySource.contains("en.lproj/Localizable.strings"))
        #expect(verifySource.contains("zh-Hans.lproj/Localizable.strings"))
        #expect(verifySource.contains("zh-hans.lproj/Localizable.strings"))
        #expect(verifySource.contains("CFBundleDevelopmentRegion"))
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

        #expect(source.contains("resolved=false fallback=none"))
        #expect(source.contains("user_alert=false"))
        #expect(!source.contains("showPreReleaseFeedUnavailableAlert"))
    }

    @Test func fastReleaseOnlyPreflightsAndDispatchesTheProtectedWorkflow() throws {
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
        let releaseVariantsSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/package-macos-release-variants.sh"
            ),
            encoding: .utf8
        )
        let previewVerifierSource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-preview-branch.sh"),
            encoding: .utf8
        )

        #expect(fastReleaseSource.contains("RELEASE_REQUEST_STARTED_AT"))
        #expect(fastReleaseSource.contains("RELEASE_REQUEST_ID"))
        #expect(fastReleaseSource.contains("fast release requires a clean committed worktree"))
        #expect(fastReleaseSource.contains("fast release requires the single candidate branch release/pre-vX.Y.Z"))
        #expect(fastReleaseSource.contains("verify-preview-branch.sh"))
        #expect(fastReleaseSource.contains("verify_remote_candidate_identity"))
        #expect(fastReleaseSource.contains("verify-preview-candidate-ci.sh"))
        #expect(fastReleaseSource.contains("REQUIRE_PREVIEW_RECORDING_PR=1"))
        #expect(fastReleaseSource.contains("release-pipeline-digest.sh"))
        #expect(fastReleaseSource.contains("verify-release-pipeline-qualification.sh"))
        #expect(fastReleaseSource.contains("\"$GH_BIN\" workflow run \"$WORKFLOW_FILE\""))
        #expect(fastReleaseSource.contains("--ref \"$BRANCH\""))
        #expect(fastReleaseSource.contains("release_mode=preview"))
        #expect(fastReleaseSource.contains("expected_commit=$HEAD_COMMIT"))
        #expect(fastReleaseSource.contains("expected_pipeline_digest=$PIPELINE_DIGEST"))
        #expect(fastReleaseSource.contains("request_started_at=$REQUEST_STARTED_AT"))
        #expect(fastReleaseSource.contains("request_id=$REQUEST_ID"))
        #expect(fastReleaseSource.contains("DISPATCH_STARTED_AT"))
        #expect(fastReleaseSource.contains("EXPECTED_RUN_TITLE"))
        #expect(fastReleaseSource.contains(".displayTitle == $runTitle"))
        #expect(fastReleaseSource.contains(".display_title == $runTitle"))
        #expect(fastReleaseSource.contains("for lookup_attempt in {1..6}"))
        #expect(fastReleaseSource.contains("--workflow \"$WORKFLOW_FILE\""))
        #expect(fastReleaseSource.contains("--commit \"$HEAD_COMMIT\""))
        #expect(fastReleaseSource.contains("--event workflow_dispatch"))
        #expect(fastReleaseSource.contains(".path == $workflowPath"))
        #expect(fastReleaseSource.contains("RUN_ID: $RUN_ID"))
        #expect(fastReleaseSource.contains("RUN_URL: $RUN_URL"))
        #expect(fastReleaseSource.contains("dispatch succeeded, but its Run identity was not resolved within 25 seconds"))
        #expect(fastReleaseSource.contains("Do not redispatch automatically"))
        #expect(!fastReleaseSource.contains("gh run watch"))
        #expect(!fastReleaseSource.contains("while true"))
        #expect(!fastReleaseSource.contains("SPARKLE_PRIVATE_KEY"))
        #expect(!fastReleaseSource.contains("MATCH_PASSWORD"))
        #expect(!fastReleaseSource.contains("RELEASE_AGE_IDENTITY"))
        #expect(!fastReleaseSource.contains("validate-notary-secrets-repo.sh"))
        #expect(!fastReleaseSource.contains("run-with-isolated-release-keychain.sh"))
        #expect(!fastReleaseSource.contains("xcrun"))
        #expect(!fastReleaseSource.contains("swift test"))
        #expect(!fastReleaseSource.contains("security "))
        #expect(!fastReleaseSource.contains("codesign"))
        #expect(!fastReleaseSource.contains("productsign"))
        #expect(!fastReleaseSource.contains("notarytool"))
        #expect(!fastReleaseSource.contains("stapler"))
        #expect(!fastReleaseSource.contains("git tag"))
        #expect(!fastReleaseSource.contains("git push"))
        #expect(!fastReleaseSource.contains("gh release"))
        #expect(!fastReleaseSource.contains("notarize-release.sh"))
        #expect(!fastReleaseSource.contains("publish-release.sh"))
        #expect(!fastReleaseSource.contains("package-macos-release-variants.sh"))
        #expect(!fastReleaseSource.contains("build-dmg.sh"))
        #expect(!fastReleaseSource.contains("upload-artifact"))
        #expect(!fastReleaseSource.contains("appcast"))
        #expect(!fastReleaseSource.contains("/bin/rm"))
        #expect(!fastReleaseSource.contains("rmdir "))
        #expect(!fastReleaseSource.contains("unlink "))
        #expect(!fastReleaseSource.contains("find -delete"))
        #expect(!fastReleaseSource.contains("git push origin main"))
        #expect(notarizeSource.contains("wait \"$install_notary_pid\""))
        #expect(notarizeSource.contains("wait \"$uninstall_notary_pid\""))
        #expect(publishSource.contains("usage: $0 prerelease|resume-prerelease|verify-prerelease|promote"))
        #expect(!publishSource.contains("prerelease|promote|release"))
        #expect(publishSource.contains("EXISTING PRE-RELEASE VERIFICATION PASS"))
        #expect(publishSource.contains("stable promotion is restricted to main"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(publishSource.contains("schemaVersion: 3"))
        #expect(publishSource.contains("baseMainCommit"))
        #expect(publishSource.contains("requestId: $requestAttestation[0].requestId"))
        #expect(publishSource.contains("pipelineDigest: $requestAttestation[0].pipelineDigest"))
        #expect(publishSource.contains("pipelineQualificationArtifactDigest"))
        #expect(publishSource.contains("requestAttestationRunAttempt"))
        #expect(publishSource.contains("stable-promotion.json"))
        #expect(publishSource.contains("verify_cdn_assets"))
        #expect(publishSource.contains("EXPECTED_STABLE_TAG=\"${EXPECTED_STABLE_TAG:-v1.8.3}\""))
        #expect(publishSource.contains("require_expected_stable_latest"))
        #expect(publishSource.contains("stable latest must remain $EXPECTED_STABLE_TAG during Preview publication"))
        #expect(publishSource.contains("PUBLIC_PRODUCT_NAME=\"无线麦SayAll.app\""))
        #expect(publishSource.contains("--title \"$PUBLIC_PRODUCT_NAME $VERSION\""))
        #expect(!publishSource.contains("--title \"Remote Mic $VERSION\""))
        #expect(publishSource.contains("https://download.sayall.app/mac/releases/$RELEASE_TAG/"))
        #expect(publishSource.contains("gh workflow run release-guard.yml"))
        #expect(publishSource.contains("confidential enrollment detail"))
        #expect(publishSource.contains("secret gesture|hidden entry"))
        #expect(previewVerifierSource.contains("release/pre-vX.Y.Z"))
        #expect(previewVerifierSource.contains("preview candidate contains a non-release change"))
        #expect(previewVerifierSource.contains("git rev-parse HEAD^"))
        #expect(previewVerifierSource.contains("must be created from the current origin/main"))
        #expect(previewVerifierSource.contains("must contain exactly one release metadata commit after its frozen base main"))
        #expect(previewVerifierSource.contains("single candidate branch release/pre-vX.Y.Z"))
        #expect(previewVerifierSource.contains("BASE_MAIN_COMMIT:"))
        #expect(previewVerifierSource.contains("confidential enrollment detail"))
        #expect(previewVerifierSource.contains("secret gesture|hidden entry"))
        #expect(releaseVariantsSource.contains("PARALLEL_RELEASE_VARIANTS"))
        #expect(releaseVariantsSource.contains("run_variant apple-silicon"))
        #expect(releaseVariantsSource.contains("run_variant intel"))
        let candidateIndex = try #require(publishSource.range(of: "gh release create"))
        let promotionIndex = try #require(publishSource.range(of: "gh release edit"))
        #expect(candidateIndex.lowerBound < promotionIndex.lowerBound)
    }

    @Test func previewBranchPushReusesExactParentMainProofWithoutRepeatingBuilds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-preview-candidate.yml"),
            encoding: .utf8
        )

        #expect(workflowSource.contains("release/pre-v*"))
        #expect(!workflowSource.contains("-canary-"))
        #expect(!workflowSource.contains("skip-release-canary:"))
        #expect(workflowSource.contains("run-trusted-release-validation.sh"))
        #expect(workflowSource.contains("timeout-minutes: 3"))
        #expect(workflowSource.contains("reuse_parent_main_ci == 'true'"))
        #expect(workflowSource.contains("reuse_parent_main_ci != 'true'"))
        #expect(workflowSource.contains("Require the recording PR to be the sole full-CI producer"))
        #expect(!workflowSource.contains("swift test"))
        #expect(!workflowSource.contains("./scripts/test.sh"))
        #expect(!workflowSource.contains("./scripts/build-dmg.sh"))
        #expect(!workflowSource.contains("swift build -c release"))
        #expect(workflowSource.contains("${{ github.sha }}"))
        #expect(workflowSource.contains("01beeceac9c4091e7e8e122ad1e840ac5e5cee1c"))
        #expect(workflowSource.contains("b71482ccb3c5d3be319abe7cd61915ab90cbc3ba"))
        #expect(workflowSource.contains("3f3c782180eef4024b53941c1f65d80e7cff4c66"))
        #expect(!workflowSource.contains("SAYALL_AI_DEPLOY_KEY"))
        #expect(!workflowSource.contains("SAYALL_MACRO_PLATFORM_DEPLOY_KEY"))
        #expect(!workflowSource.contains("SAYALL_MAC_REMOTE_DEPLOY_KEY"))
        #expect(workflowSource.contains("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"))
        #expect(workflowSource.contains("contents: read"))
        #expect(!workflowSource.contains("environment: mac-release"))
        #expect(!workflowSource.contains("RELEASE_AGE_IDENTITY"))
        #expect(!workflowSource.contains("RELEASE_CREDENTIALS_DEPLOY_KEY"))
        #expect(!workflowSource.contains("APPLE_SIGNING_MATCH_DEPLOY_KEY"))
        #expect(!workflowSource.contains("remotemic-notary-secrets"))
        #expect(!workflowSource.contains("apple-signing-match"))
        #expect(!workflowSource.contains("package-macos-preview-in-actions.sh"))
        #expect(!workflowSource.contains("notarize-release.sh"))
        #expect(!workflowSource.contains("MATCH_PASSWORD"))
        #expect(!workflowSource.contains("AuthKey_"))

        let ciWorkflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-ci.yml"),
            encoding: .utf8
        )
        #expect(ciWorkflowSource.contains("workflow_dispatch:"))
        #expect(ciWorkflowSource.contains("GetSayAll/sayall-ai"))
        #expect(ciWorkflowSource.contains("01beeceac9c4091e7e8e122ad1e840ac5e5cee1c"))
        #expect(ciWorkflowSource.contains("GetSayAll/sayall-macro-platform"))
        #expect(ciWorkflowSource.contains("b71482ccb3c5d3be319abe7cd61915ab90cbc3ba"))
        #expect(ciWorkflowSource.contains("SAYALL_MACRO_PLATFORM_DEPLOY_KEY"))
        #expect(ciWorkflowSource.contains("GetSayAll/sayall-mac-remote"))
        #expect(ciWorkflowSource.contains("SAYALL_MAC_REMOTE_DEPLOY_KEY"))
        #expect(ciWorkflowSource.contains("swift package config set-mirror"))
        #expect(ciWorkflowSource.contains("classify_changes:"))
        #expect(ciWorkflowSource.contains("Detect documentation-only change"))
        #expect(ciWorkflowSource.contains("*.md|Screenshots/*) ;;"))
        #expect(ciWorkflowSource.contains("docs_only: ${{ steps.changes.outputs.docs_only }}"))
        #expect(ciWorkflowSource.contains("needs.classify_changes.outputs.docs_only == 'true' && 'ubuntu-latest' || 'macos-15'"))
        #expect(ciWorkflowSource.contains("Confirm documentation-only fast path"))
        #expect(ciWorkflowSource.contains("needs.classify_changes.outputs.docs_only != 'true'"))
    }

    @Test func releaseCriticalWorkflowsPinActionsToFullCommits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowPaths = [
            ".github/workflows/mac-ci.yml",
            ".github/workflows/mac-preview-candidate.yml",
            ".github/workflows/mac-release-package.yml",
            ".github/workflows/mac-stable-promote.yml",
            ".github/workflows/release-guard.yml",
        ]
        let approvedActionReferences = [
            "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
            "actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0",
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
        ]
        var combinedSource = ""

        for workflowPath in workflowPaths {
            let source = try String(
                contentsOf: root.appendingPathComponent(workflowPath),
                encoding: .utf8
            )
            combinedSource += source
            let actionUseLines = source.split(separator: "\n").filter {
                $0.contains("uses: actions/")
            }
            #expect(!actionUseLines.isEmpty)
            for actionUseLine in actionUseLines {
                #expect(
                    approvedActionReferences.contains {
                        actionUseLine.contains($0)
                    }
                )
                #expect(!actionUseLine.contains("@v"))
            }
        }

        for approvedActionReference in approvedActionReferences {
            #expect(combinedSource.contains(approvedActionReference))
        }
    }

    @Test func previewBranchLifecycleHasExecutableRegressionCoverage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lifecycleScript = root.appendingPathComponent(
            "scripts/test-preview-branch-lifecycle.sh"
        )
        let lifecycleSource = try String(
            contentsOf: lifecycleScript,
            encoding: .utf8
        )

        #expect(lifecycleSource.contains("release/pre-v1.8.15"))
        #expect(lifecycleSource.contains("release/pre-v1.8.15-rerun2"))
        #expect(lifecycleSource.contains("release/pre-v1.8.16"))
        #expect(lifecycleSource.contains("PREVIEW BRANCH PASS"))
        #expect(lifecycleSource.contains("ALLOW_FROZEN_BASE_MAIN=1"))
        #expect(lifecycleSource.contains("numbered rerun branch unexpectedly passed the single-candidate gate"))
        #expect(lifecycleSource.contains("must be created from the current origin/main"))
        #expect(lifecycleSource.contains("evidence retained at:"))
        #expect(!lifecycleSource.contains("/bin/rm"))
        #expect(!lifecycleSource.contains("/usr/bin/rm"))
        #expect(!lifecycleSource.contains("rmdir "))
        #expect(!lifecycleSource.contains("unlink "))
        #expect(!lifecycleSource.contains("find -delete"))
        #expect(lifecycleSource.contains("PREVIEW BRANCH LIFECYCLE TEST PASS"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [lifecycleScript.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func optimizedReleasePipelineHasExecutableRegressionCoverage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let regressionScript = root.appendingPathComponent(
            "scripts/test-release-pipeline-optimization.sh"
        )
        let regressionSource = try String(
            contentsOf: regressionScript,
            encoding: .utf8
        )
        let releaseWorkflowSource = try String(
            contentsOf: root.appendingPathComponent(
                ".github/workflows/mac-release-package.yml"
            ),
            encoding: .utf8
        )
        let releasingSource = try String(
            contentsOf: root.appendingPathComponent("RELEASING.md"),
            encoding: .utf8
        )
        let reconciliationSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/reconcile-release-event.sh"
            ),
            encoding: .utf8
        )
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )

        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let driverPackageSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/build-doubao-driver-pkg.sh"
            ),
            encoding: .utf8
        )
        let stageRunnerSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/run-release-stage.sh"
            ),
            encoding: .utf8
        )

        #expect(regressionSource.contains("RELEASE PIPELINE OPTIMIZATION TEST PASS"))
        #expect(regressionSource.contains("mismatched private dependency pins unexpectedly passed"))
        #expect(regressionSource.contains("candidate verification unexpectedly passed"))
        #expect(regressionSource.contains("release request attestation accepted a missing candidate gate timestamp"))
        #expect(regressionSource.contains("release qualification unexpectedly accepted artifact/run mismatch"))
        #expect(regressionSource.contains("checks-old-failure-new-success"))
        #expect(regressionSource.contains("checks-old-success-new-failure"))
        #expect(regressionSource.contains("html_url"))
        #expect(regressionSource.contains("draft"))
        #expect(regressionSource.contains("numbered rerun branch unexpectedly passed"))
        #expect(regressionSource.contains("evidence retained at:"))
        #expect(!regressionSource.contains("/bin/rm"))
        #expect(!regressionSource.contains("/usr/bin/rm"))
        #expect(!regressionSource.contains("rmdir "))
        #expect(!regressionSource.contains("unlink "))
        #expect(!regressionSource.contains("find -delete"))
        #expect(regressionSource.contains("stable request attestation allowed a retry to reset its timestamp"))
        #expect(regressionSource.contains("--draft"))
        #expect(regressionSource.contains("PARALLEL_RELEASE_VARIANTS=1"))
        #expect(releaseWorkflowSource.contains("validate-candidate:"))
        #expect(releaseWorkflowSource.contains("verify-preview-candidate-ci.sh"))
        #expect(releaseWorkflowSource.contains("REQUIRE_PREVIEW_RECORDING_PR: 1"))
        #expect(releaseWorkflowSource.contains("PARALLEL_RELEASE_VARIANTS: 1"))
        #expect(releaseWorkflowSource.contains("PARALLEL_PACKAGE_NOTARIZATION: 1"))
        #expect(releaseWorkflowSource.contains("environment: mac-release"))
        #expect(releaseWorkflowSource.contains("RELEASE_AGE_IDENTITY"))
        #expect(releaseWorkflowSource.contains("remotemic-notary-secrets"))
        #expect(releaseWorkflowSource.contains("apple-signing-match"))
        let signedStep = try #require(
            releaseWorkflowSource.components(
                separatedBy: "- name: Sign, notarize, staple, and verify both variants"
            ).last?.components(separatedBy: "- name: Upload signed release packages").first
        )
        #expect(signedStep.contains("timeout-minutes: 10"))
        #expect(releaseWorkflowSource.contains("SIGNED_RELEASE_TIMEOUT_SECONDS: 540"))
        #expect(!releaseWorkflowSource.contains("TOTAL_SLO_SECONDS:"))
        #expect(releaseWorkflowSource.contains("READY_SLO_SECONDS: 1740"))
        #expect(releaseWorkflowSource.contains("timeout-minutes: 30"))
        #expect(releaseWorkflowSource.contains("PREVIEW_READY_SLO_SECONDS: 1740"))
        #expect(releaseWorkflowSource.contains("request_id:"))
        #expect(releaseWorkflowSource.contains("resolve-release-request-attestation.sh"))
        #expect(releaseWorkflowSource.contains("release-request-attestation-${{ inputs.tag }}-${{ inputs.expected_commit }}"))
        #expect(releaseWorkflowSource.contains("release_mode:"))
        #expect(releaseWorkflowSource.contains("run-name: mac-release ${{ inputs.release_mode }}"))
        #expect(releaseWorkflowSource.contains("- qualification"))
        #expect(releaseWorkflowSource.contains("- preview"))
        #expect(releaseWorkflowSource.contains("inputs.release_mode == 'qualification'"))
        #expect(releaseWorkflowSource.contains("inputs.release_mode == 'preview'"))
        #expect(!releaseWorkflowSource.contains("inputs.canary"))
        #expect(releaseWorkflowSource.contains("mac-signed-tag-{0}"))
        #expect(releaseWorkflowSource.contains("verify-release-pipeline-qualification.sh"))
        #expect(releaseWorkflowSource.contains("mac-release-pipeline-qualification-${{ inputs.expected_pipeline_digest }}"))
        #expect(releaseWorkflowSource.contains("{schemaVersion:2"))
        #expect(releaseWorkflowSource.contains(".schemaVersion == 2 or .schemaVersion == 3"))
        #expect(releaseWorkflowSource.contains("--slurpfile requestAttestation"))
        #expect(releaseWorkflowSource.contains(".pipelineQualificationArtifactDigest == $requestAttestation[0].pipelineQualificationArtifactDigest"))
        #expect(releaseWorkflowSource.contains("externalDependencies"))
        #expect(releaseWorkflowSource.contains("ageVersion"))
        #expect(releaseWorkflowSource.contains("fastlaneVersion"))
        #expect(releaseWorkflowSource.contains("xcodeVersion"))
        #expect(releaseWorkflowSource.contains("RELEASE_MODE"))
        #expect(!releaseWorkflowSource.contains("CANARY_MODE"))
        #expect(releaseWorkflowSource.contains("release_ready_at=\"$request_started_at\""))
        #expect(releaseWorkflowSource.contains(".releaseReadyAt"))
        #expect(!releaseWorkflowSource.contains("release_ready_at:"))
        #expect(releaseWorkflowSource.contains("PUBLICATION_MAX_SECONDS: 180"))
        #expect(releaseWorkflowSource.contains("release-slo-ledger-published-${{ github.run_id }}"))
        #expect(releaseWorkflowSource.contains("release-slo-ledger-failed-${{ github.run_id }}"))
        #expect(releaseWorkflowSource.contains("Publish and verify exact signed preview bytes"))
        #expect(releaseWorkflowSource.contains("./scripts/publish-release.sh prerelease"))
        #expect(releaseWorkflowSource.contains("EXPECTED_STABLE_TAG: v1.8.3"))
        #expect(releaseWorkflowSource.contains("Preview requires stable latest $EXPECTED_STABLE_TAG"))
        #expect(releaseWorkflowSource.contains("git ls-remote origin \"refs/tags/$RELEASE_TAG^{}\""))
        #expect(releaseWorkflowSource.contains("test \"$remote_tag_commit\" = \"$head_commit\""))
        #expect(releaseWorkflowSource.contains("verify-release-pipeline-qualification-source.sh"))
        #expect(!releaseWorkflowSource.contains("verify-release-canary-provenance.sh"))
        #expect(releasingSource.contains("“发布正式版”不是合法命令"))
        #expect(releasingSource.contains("将用户明确指定的现有 Pre-release `vX.Y.Z` 晋升为正式版"))
        #expect(buildSource.contains("RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS:-300"))
        #expect(notarizeSource.contains("RELEASE_APP_BUILD_TIMEOUT_SECONDS:-330"))
        #expect(notarizeSource.contains("app-build \"$RELEASE_APP_BUILD_TIMEOUT_SECONDS\""))
        #expect(signedStep.contains("run-release-stage.sh"))
        #expect(signedStep.contains("\"$SIGNED_RELEASE_TIMEOUT_SECONDS\""))
        #expect(!releaseWorkflowSource.contains("Run Apple Silicon release gates"))
        #expect(!releaseWorkflowSource.contains("Run Intel Ventura release gates"))
        #expect(reconciliationSource.contains("gh pr ready"))
        #expect(notarizeSource.contains("REMOTE_MIC_BUILD_SCRATCH_PATH"))
        #expect(notarizeSource.contains("REMOTE_MIC_BUILD_CACHE_PATH"))
        #expect(notarizeSource.contains("app-notary"))
        #expect(notarizeSource.contains("driver-package-build"))
        #expect(notarizeSource.contains("installer-pkg-notary"))
        #expect(notarizeSource.contains("uninstaller-pkg-notary"))
        #expect(notarizeSource.contains("dmg-notary"))
        #expect(buildSource.contains("--cache-path \"$BUILD_CACHE_PATH\""))
        #expect(buildSource.contains("app-codesign-installer-xpc"))
        #expect(driverPackageSource.contains("installer-component-pkgbuild"))
        #expect(driverPackageSource.contains("COMPONENT_PLIST="))
        #expect(driverPackageSource.contains("--analyze"))
        #expect(driverPackageSource.contains("BundleIsRelocatable false"))
        #expect(driverPackageSource.contains("--component-plist \"$COMPONENT_PLIST\""))
        #expect(driverPackageSource.contains("installer-productbuild"))
        #expect(driverPackageSource.contains("UNSIGNED_INSTALL_PACKAGE"))
        #expect(driverPackageSource.contains("installer-signing-probe-productsign"))
        #expect(driverPackageSource.contains("run_locked_productsign installer-productsign"))
        #expect(driverPackageSource.contains("/usr/bin/lockf -k -t"))
        #expect(!driverPackageSource.contains("INSTALL_COMPONENT_SIGNING_ARGS"))
        #expect(driverPackageSource.contains("uninstaller-pkgbuild"))
        #expect(driverPackageSource.contains("uninstaller-productsign"))
        #expect(stageRunnerSource.contains("RELEASE STAGE START"))
        #expect(stageRunnerSource.contains("RELEASE STAGE HEARTBEAT"))
        #expect(stageRunnerSource.contains("RELEASE STAGE TIMEOUT"))
        #expect(stageRunnerSource.contains("exit 124"))
        let heartbeatIndex = try #require(
            stageRunnerSource.range(of: "if (( now_seconds >= NEXT_HEARTBEAT ))")
        )
        let timeoutIndex = try #require(
            stageRunnerSource.range(of: "if (( elapsed >= TIMEOUT_SECONDS ))")
        )
        #expect(heartbeatIndex.lowerBound < timeoutIndex.lowerBound)
        let buildIndex = try #require(notarizeSource.range(of: "\"$ROOT/scripts/build-app.sh\""))
        let sparkleToolCheckIndex = try #require(
            notarizeSource.range(of: "test -x \"$GENERATE_APPCAST\"")
        )
        #expect(buildIndex.lowerBound < sparkleToolCheckIndex.lowerBound)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [regressionScript.path]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(
            process.terminationStatus == 0,
            "Release pipeline regression failed. stdout: \(output) stderr: \(error)"
        )
    }

    @Test func intelVenturaReleaseLineStaysIsolatedFromAppleSilicon() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let variantSource = try String(
            contentsOf: root.appendingPathComponent("scripts/release-variant.sh"),
            encoding: .utf8
        )
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(
                ".github/workflows/mac-ci.yml"
            ),
            encoding: .utf8
        )
        let preinstallSource = try String(
            contentsOf: root.appendingPathComponent(
                "packaging/doubao-driver/install/preinstall"
            ),
            encoding: .utf8
        )
        let packageVerifierSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/verify-doubao-driver-pkg.sh"
            ),
            encoding: .utf8
        )
        let installerGuardScript = root.appendingPathComponent(
            "scripts/test-installer-architecture-guard.sh"
        )
        let installerGuardSource = try String(
            contentsOf: installerGuardScript,
            encoding: .utf8
        )
        let transcriptHistorySource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/TranscriptHistorySection.swift"
            ),
            encoding: .utf8
        )

        #expect(variantSource.contains("RELEASE_VARIANT=\"${RELEASE_VARIANT:-apple-silicon}\""))
        #expect(variantSource.contains("arm64-apple-macosx14.0"))
        #expect(variantSource.contains("x86_64-apple-macosx13.0"))
        #expect(variantSource.contains("RELEASE_OUTPUT_DIR=\"$ROOT/dist/intel\""))
        #expect(variantSource.contains("RELEASE_APPCAST_NAME=\"appcast-intel.xml\""))
        #expect(variantSource.contains("RELEASE_ASSET_SUFFIX=\"-Intel\""))

        #expect(workflowSource.contains("RELEASE_VARIANT: ${{ matrix.variant }}"))
        #expect(workflowSource.contains("x86_64-apple-macosx13.0"))
        #expect(workflowSource.contains("apple-silicon"))
        #expect(workflowSource.contains("intel"))
        #expect(transcriptHistorySource.contains(
            ".onChange(of: applications.map(\\.id)) { _ in"
        ))
        #expect(transcriptHistorySource.contains(
            ".onChange(of: activeApplicationKey) { applicationKey in"
        ))
        #expect(!transcriptHistorySource.contains(") { _, _ in"))

        #expect(preinstallSource.contains("CURRENT_ARCHITECTURE"))
        #expect(preinstallSource.contains("/usr/sbin/sysctl -in hw.optional.arm64"))
        #expect(!preinstallSource.contains("/usr/bin/uname -m"))
        #expect(preinstallSource.contains("Download the Intel version"))
        #expect(preinstallSource.contains("Download the Apple Silicon version"))
        #expect(!preinstallSource.contains("/bin/rm -rf -- \"$APP_DESTINATION\""))
        #expect(preinstallSource.contains("will be updated atomically"))
        #expect(packageVerifierSource.contains("preinstall must not delete an existing SayAll.app"))
        #expect(preinstallSource.contains("INSTALLED_BUILD="))
        #expect(preinstallSource.contains("The existing app was left intact. Use a newer installer."))
        #expect(packageVerifierSource.contains("PackageBuild raw"))
        #expect(packageVerifierSource.contains(
            "package scripts must not require Xcode or Command Line Tools"
        ))
        #expect(packageVerifierSource.contains("RemoteMicComponent.pkg"))
        #expect(packageVerifierSource.contains("Status: no signature"))
        #expect(packageVerifierSource.contains(
            "The deployable outer product archive is the Installer trust boundary."
        ))
        #expect(packageVerifierSource.contains("/usr/sbin/spctl -a -vv -t install \"$PACKAGE\""))
        #expect(packageVerifierSource.contains("my.result.type = 'Fatal'"))
        #expect(installerGuardSource.contains("INSTALLER ARCHITECTURE GUARD TEST PASS"))
        #expect(installerGuardSource.contains("assert_unsigned_stage_block"))
        #expect(installerGuardSource.contains("component-sign-mutation"))
        #expect(installerGuardSource.contains("product-sign-mutation"))
        #expect(installerGuardSource.contains("unexpectedly accepted --sign"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [installerGuardScript.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func ordinaryDmgHasOneInstallerAndKeepsHealthyDriver() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dmgSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-dmg.sh"),
            encoding: .utf8
        )
        let postinstallSource = try String(
            contentsOf: root.appendingPathComponent(
                "packaging/doubao-driver/install/postinstall"
            ),
            encoding: .utf8
        )
        let verifierSource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-dmg.sh"),
            encoding: .utf8
        )

        #expect(dmgSource.contains("$STAGING/$INSTALL_PACKAGE"))
        #expect(!dmgSource.contains("$STAGING/$DISPLAY_NAME.app"))
        #expect(!dmgSource.contains("$STAGING/$UNINSTALL_PACKAGE"))
        #expect(!dmgSource.contains("ln -s /Applications"))
        #expect(verifierSource.contains("EXPECTED_ROOT_ENTRIES=\"$RELEASE_INSTALL_PACKAGE_NAME\""))
        #expect(postinstallSource.contains("driver_is_healthy_and_current()"))
        #expect(postinstallSource.contains("/usr/bin/file -b \"$1\""))
        #expect(postinstallSource.contains("CFBundleVersion"))
        #expect(postinstallSource.contains("/usr/bin/codesign --verify --deep --strict"))
        #expect(postinstallSource.contains("was kept in place"))
        #expect(!postinstallSource.contains("/usr/bin/lipo"))
        #expect(!postinstallSource.contains("xcrun"))
    }

    @Test func releaseBundleNameMatchesBrandingAndInstallerPaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let buildSource = try source("scripts/build-app.sh")
        let runSource = try source("script/build_and_run.sh")
        let notarizeSource = try source("scripts/notarize-release.sh")
        let dmgSource = try source("scripts/build-dmg.sh")
        let dmgVerifierSource = try source("scripts/verify-dmg.sh")
        let packageSource = try source("scripts/build-doubao-driver-pkg.sh")
        let packageVerifierSource = try source("scripts/verify-doubao-driver-pkg.sh")
        let appVerifierSource = try source("scripts/verify-app.sh")
        let publishSource = try source("scripts/publish-release.sh")
        let preinstallSource = try source("packaging/doubao-driver/install/preinstall")
        let postinstallSource = try source("packaging/doubao-driver/install/postinstall")
        let trashHelperSource = try source(
            "packaging/doubao-driver/install/trash-legacy-app.zsh"
        )
        let trashMigrationTest = root.appendingPathComponent(
            "scripts/test-legacy-app-trash-migration.sh"
        )
        let infoPlist = try #require(
            NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        )
        let englishInfo = try source("Resources/en.lproj/InfoPlist.strings")
        let chineseInfo = try source("Resources/zh-Hans.lproj/InfoPlist.strings")

        #expect(buildSource.contains("DISPLAY_NAME=\"SayAll\""))
        #expect(runSource.contains("dist/SayAll.app"))
        #expect(notarizeSource.contains("DISPLAY_NAME=\"SayAll\""))
        #expect(notarizeSource.contains("ditto -c -k --keepParent \"$APP\" \"$UPDATE_ZIP\""))
        #expect(dmgSource.contains("DISPLAY_NAME=\"SayAll\""))
        #expect(dmgVerifierSource.contains("DISPLAY_NAME=\"SayAll\""))
        #expect(packageSource.contains("APP=\"$OUTPUT_DIR/SayAll.app\""))
        #expect(packageSource.contains("$PAYLOAD_ROOT/Applications/SayAll.app"))
        #expect(packageVerifierSource.contains("./Applications/SayAll.app/Contents/Info.plist"))
        #expect(packageVerifierSource.contains("*/Applications/SayAll.app"))
        #expect(appVerifierSource.contains("test \"${APP:t}\" = \"SayAll.app\""))
        #expect(appVerifierSource.contains("CFBundleName raw"))
        #expect(publishSource.contains("$extract_dir/SayAll.app"))
        #expect(publishSource.contains("Remote-Mic-$VERSION.zip"))

        #expect(preinstallSource.contains("Applications/SayAll.app"))
        #expect(preinstallSource.contains("Applications/Remote Mic.app"))
        #expect(preinstallSource.contains("Applications/无线麦.app"))
        #expect(preinstallSource.contains("OWNED_APP_FOUND=1"))
        #expect(preinstallSource.contains("/usr/bin/pkill -x RemoteMic"))
        #expect(preinstallSource.contains("before updating the audio driver"))
        #expect(!preinstallSource.contains("/bin/rm -rf -- \"$legacy_path\""))
        #expect(postinstallSource.contains("move_legacy_app_to_trash_if_owned"))
        #expect(postinstallSource.contains("LEGACY_APP_TRASH_ROOT"))
        #expect(postinstallSource.contains("com.hd838a.RemoteMic"))
        #expect(trashHelperSource.contains("/bin/mv -n -- \"$legacy_path\""))
        #expect(trashHelperSource.contains("where it can be restored if needed"))
        #expect(!trashHelperSource.contains("/bin/rm"))
        let canonicalVerification = try #require(
            postinstallSource.range(
                of: "/usr/bin/codesign --verify --deep --strict \"$APP_DESTINATION\""
            )
        )
        let legacyCleanupDefinition = try #require(
            postinstallSource.range(of: "move_legacy_app_to_trash_if_owned")
        )
        #expect(canonicalVerification.lowerBound < legacyCleanupDefinition.lowerBound)

        #expect(infoPlist["CFBundleDisplayName"] as? String == "SayAll")
        #expect(infoPlist["CFBundleName"] as? String == "SayAll")
        #expect(infoPlist["CFBundleExecutable"] as? String == "RemoteMic")
        #expect(infoPlist["CFBundleIdentifier"] as? String == "com.hd838a.RemoteMic")
        #expect(englishInfo.contains("\"CFBundleDisplayName\" = \"SayAll\";"))
        #expect(englishInfo.contains("\"CFBundleName\" = \"SayAll\";"))
        #expect(chineseInfo.contains("\"CFBundleDisplayName\" = \"无线麦\";"))
        #expect(chineseInfo.contains("\"CFBundleName\" = \"无线麦\";"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [trashMigrationTest.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
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
        let publishSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        )

        #expect(guardWorkflow.contains("types: [published, released, edited]"))
        #expect(guardWorkflow.contains("workflow_dispatch:"))
        #expect(guardWorkflow.contains("github.event.inputs.tag || github.event.release.tag_name"))
        #expect(guardWorkflow.contains("contents: write"))
        #expect(guardWorkflow.contains("pull-requests: write"))
        #expect(guardWorkflow.contains("issues: write"))
        #expect(guardWorkflow.contains("actions: write"))
        #expect(reconciliationSource.contains("restored $RELEASE_TAG to pre-release"))
        #expect(reconciliationSource.contains("candidate-provenance.json"))
        #expect(reconciliationSource.contains("stable-promotion.json"))
        #expect(reconciliationSource.contains("release guard schema 3 provenance must use release/pre-$RELEASE_TAG"))
        #expect(reconciliationSource.contains(".schemaVersion == 1 or .schemaVersion == 2 or .schemaVersion == 3"))
        #expect(reconciliationSource.contains("pipelineQualificationArtifactDigest"))
        #expect(reconciliationSource.contains("requestAttestationRunAttempt"))
        #expect(reconciliationSource.contains("baseMainCommit"))
        #expect(reconciliationSource.contains("Record $RELEASE_TAG preview candidate in main"))
        #expect(reconciliationSource.contains("This PR does not promote the GitHub Release to stable"))
        #expect(reconciliationSource.contains("preview candidate auto-merge"))
        #expect(reconciliationSource.contains("gh pr merge \"$PR_NUMBER\""))
        #expect(reconciliationSource.contains("--auto --merge"))
        #expect(reconciliationSource.contains("gh workflow run mac-ci.yml"))
        #expect(reconciliationSource.contains("stable-promotion-approved"))
        #expect(promotionWorkflow.contains("workflow_dispatch:"))
        #expect(promotionWorkflow.contains("workflow_run:"))
        #expect(promotionWorkflow.contains("reconciliation-requires-release-manager:"))
        #expect(promotionWorkflow.contains("workflow_run reconciliation has no authoritative command to promote a specified pre-release."))
        #expect(promotionWorkflow.contains("if: github.event_name == 'workflow_dispatch'"))
        #expect(!promotionWorkflow.contains("github.event.workflow_run.conclusion == 'success'"))
        #expect(!promotionWorkflow.contains("gh pr merge"))
        #expect(promotionWorkflow.contains("steps.release.outputs.should_promote == 'true'"))
        #expect(promotionWorkflow.contains("./scripts/publish-release.sh promote"))
        #expect(promotionWorkflow.contains("environment: mac-stable-release"))
        #expect(promotionWorkflow.contains("Enforce 30-minute release-ready stable promotion SLO"))
        #expect(promotionWorkflow.contains("request_id:"))
        #expect(promotionWorkflow.contains("resolve-stable-request-attestation.sh"))
        #expect(promotionWorkflow.contains("stable-request-attestation-${{ inputs.tag }}"))
        #expect(promotionWorkflow.contains(".requestStartedAt"))
        #expect(promotionWorkflow.contains("READY_SLO_SECONDS: 1740"))
        #expect(promotionWorkflow.contains("STABLE_READY_SLO_SECONDS: 1740"))
        #expect(promotionWorkflow.contains("stable-slo-ledger-complete-${{ github.run_id }}"))
        #expect(promotionWorkflow.contains("command -v rg >/dev/null 2>&1"))
        #expect(promotionWorkflow.contains("brew install ripgrep"))
        #expect(promotionWorkflow.contains("rg --version"))
        #expect(!promotionWorkflow.contains("secrets."))
        #expect(!promotionWorkflow.contains("notarize-release.sh"))
        #expect(!promotionWorkflow.contains("package-macos-release"))
        #expect(!promotionWorkflow.contains("build-app.sh"))
        let toolCheck = try #require(
            promotionWorkflow.range(of: "command -v rg >/dev/null 2>&1")
        )
        let promotionCommand = try #require(
            promotionWorkflow.range(of: "./scripts/publish-release.sh promote")
        )
        #expect(toolCheck.lowerBound < promotionCommand.lowerBound)
        let dependencyCheck = try #require(
            publishSource.range(of: "for command_name in cmp curl gh git jq plutil rg shasum stat")
        )
        let firstRipgrepUse = try #require(
            publishSource.range(of: "rg -Fq \"url=\\\"$CDN_DOWNLOAD_PREFIX")
        )
        #expect(dependencyCheck.lowerBound < firstRipgrepUse.lowerBound)
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
            source.contains("candidate_branch=\"$(jq -r '.candidateBranch' \"$provenance\")\"") &&
            source.contains("schema 3 candidate provenance must use release/pre-$RELEASE_TAG")
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
            "Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.zh.txt",
            "Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.en.txt",
            "PUBLISHED_ZH_NOTES_BASENAME=\"Remote-Mic-$VERSION.zh.txt\"",
            "PUBLISHED_EN_NOTES_BASENAME=\"Remote-Mic-$VERSION.en.txt\"",
            "--release-notes-url-prefix \"$CDN_DOWNLOAD_PREFIX\"",
        ] {
            #expect(notarizeSource.contains(requiredText))
        }
        #expect(notarizeSource.contains("GENERATE_SPARKLE_UPDATE=\"${GENERATE_SPARKLE_UPDATE:-1}\""))
        #expect(notarizeSource.contains("SPARKLE UPDATE: skipped for private test package"))
        #expect(notarizeSource.contains("appcast-intel-shared-notes.xml"))
        #expect(notarizeSource.contains("$PUBLISHED_ZH_NOTES_BASENAME"))
        #expect(notarizeSource.contains("$PUBLISHED_EN_NOTES_BASENAME"))
        #expect(publishSource.contains("$STAGING_DIR/${ZH_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("$STAGING_DIR/${EN_RELEASE_NOTES:t}"))
        #expect(!publishSource.contains("$STAGING_DIR/${INTEL_ZH_RELEASE_NOTES:t}"))
        #expect(!publishSource.contains("$STAGING_DIR/${INTEL_EN_RELEASE_NOTES:t}"))
        #expect(!publishSource.contains("PUBLIC_PAYLOAD_ASSET_COUNT"))
        #expect(!publishSource.contains("PUBLIC_RELEASE_ASSET_COUNT"))
        #expect(!publishSource.contains("11|14|16"))
        #expect(!publishSource.contains("12|15|17"))
        #expect(publishSource.contains("write_candidate_release_manifest"))
        #expect(publishSource.contains("asset set does not exactly match candidate provenance"))
        #expect(publishSource.contains("release_uploads+=(\"$STAGING_DIR/$asset_name\")"))
        #expect(publishSource.contains("release mutation is restricted to the expected protected GitHub workflow"))
        #expect(publishSource.contains("actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT"))
        #expect(publishSource.contains(".path == $workflowPath"))
        #expect(publishSource.contains(".event == $event"))
        #expect(publishSource.contains(".head_sha == $headSha"))
        #expect(publishSource.contains(".head_branch == $headBranch"))
        #expect(publishSource.contains("Remote-Mic-$VERSION.dmg.sha256"))
        #expect(publishSource.contains("candidate-provenance.json"))
        let releaseUploadSource = try #require(
            publishSource.components(separatedBy: "typeset -a release_uploads=()").last?
                .components(separatedBy: "--repo \"$REPOSITORY\"").first
        )
        #expect(!releaseUploadSource.contains("Remote-Mic-$VERSION-Installer.pkg"))
        #expect(!releaseUploadSource.contains("Remote-Mic-$VERSION-Intel-Installer.pkg"))
        #expect(!releaseUploadSource.contains("Remote-Mic-$VERSION-Uninstaller.pkg"))
        #expect(!releaseUploadSource.contains("Remote-Mic-$VERSION-Intel-Uninstaller.pkg"))
        #expect(releaseUploadSource.contains("release_uploads+=(\"$STAGING_DIR/$asset_name\")"))
        #expect(publishSource.contains("$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg"))
        #expect(publishSource.contains("$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg"))
        #expect(notarizeSource.contains("https://download.sayall.app/mac/releases/$RELEASE_TAG/"))
        #expect(publishSource.contains("appcast-intel.xml"))
        #expect(publishSource.contains("--range 0-1023"))
        #expect(publishSource.contains("x-remote-mic-cdn: cloudflare"))
    }

    @Test func protectedGitHubActionsReleasePackagesBothMacArchitectures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-release-package.yml"),
            encoding: .utf8
        )
        let bootstrapSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/package-macos-release-in-actions.sh"
            ),
            encoding: .utf8
        )

        #expect(workflowSource.contains("workflow_dispatch:"))
        #expect(workflowSource.contains("environment: mac-release"))
        #expect(workflowSource.contains("RELEASE_CREDENTIALS_DEPLOY_KEY"))
        #expect(workflowSource.contains("APPLE_SIGNING_MATCH_DEPLOY_KEY"))
        #expect(workflowSource.contains("RELEASE_AGE_IDENTITY"))
        #expect(workflowSource.contains("GetSayAll/sayall-mac-remote"))
        #expect(workflowSource.contains("SAYALL_MAC_REMOTE_DEPLOY_KEY"))
        #expect(workflowSource.contains("swift package config set-mirror"))
        #expect(workflowSource.contains("HD838A/remotemic-notary-secrets"))
        #expect(workflowSource.contains("HD838A/apple-signing-match"))
        #expect(workflowSource.contains("update-ref refs/heads/main \"$match_commit\""))
        #expect(workflowSource.contains("git ls-remote \"file://$match_repo\" refs/heads/main"))
        #expect(workflowSource.contains("package-macos-release-in-actions.sh"))
        #expect(!workflowSource.contains("dist/Install Remote Mic.pkg"))
        #expect(!workflowSource.contains("dist/intel/Install Remote Mic Intel.pkg"))
        #expect(!workflowSource.contains("dist/intel/Remote-Mic-*-Intel.*.txt"))
        #expect(workflowSource.contains("dist/Uninstall Remote Mic.pkg"))
        #expect(workflowSource.contains("dist/intel/Uninstall Remote Mic Intel.pkg"))
        #expect(workflowSource.contains("needs: validate-candidate"))
        #expect(workflowSource.contains("actions: read"))
        #expect(workflowSource.contains("pull-requests: read"))
        #expect(bootstrapSource.contains("GITHUB_ACTIONS"))
        #expect(bootstrapSource.contains("run-with-isolated-release-keychain.sh"))
        #expect(bootstrapSource.contains("validate-notary-secrets-repo.sh"))
        #expect(bootstrapSource.contains("validate-signing-repo.sh"))
        #expect(bootstrapSource.contains("MATCH_GIT_URL=\"file://$MATCH_REPO\""))
        #expect(bootstrapSource.contains("rev-parse refs/heads/main"))
        #expect(bootstrapSource.contains("readonly Match checkout must expose local main at its exact pinned HEAD"))
        #expect(bootstrapSource.contains("SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE"))
        #expect(!workflowSource.contains("CERTIFICATE_BASE64"))
        #expect(!workflowSource.contains("NOTARY_API_KEY_BASE64"))
        #expect(!workflowSource.contains("SPARKLE_PRIVATE_KEY_BASE64"))
        #expect(!workflowSource.contains("pull_request:"))
        #expect(!workflowSource.contains("push:"))
    }
}
