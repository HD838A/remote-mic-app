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
        #expect(fastReleaseSource.contains("package-macos-release-variants.sh"))
        #expect(fastReleaseSource.contains("publish-release.sh\" prerelease"))
        #expect(!fastReleaseSource.contains("git push origin main"))
        #expect(notarizeSource.contains("wait \"$install_notary_pid\""))
        #expect(notarizeSource.contains("wait \"$uninstall_notary_pid\""))
        #expect(publishSource.contains("usage: $0 prerelease|promote"))
        #expect(!publishSource.contains("prerelease|promote|release"))
        #expect(publishSource.contains("stable promotion is restricted to main"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(publishSource.contains("schemaVersion: 2"))
        #expect(publishSource.contains("baseMainCommit"))
        #expect(publishSource.contains("stable-promotion.json"))
        #expect(publishSource.contains("verify_cdn_assets"))
        #expect(publishSource.contains("https://download.sayall.app/mac/releases/$RELEASE_TAG/"))
        #expect(publishSource.contains("gh workflow run release-guard.yml"))
        #expect(publishSource.contains("confidential enrollment detail"))
        #expect(publishSource.contains("secret gesture|hidden entry"))
        #expect(previewVerifierSource.contains("release/pre-vX.Y.Z"))
        #expect(previewVerifierSource.contains("preview candidate contains a non-release change"))
        #expect(previewVerifierSource.contains("git rev-parse HEAD^"))
        #expect(previewVerifierSource.contains("must exactly equal the latest origin/main"))
        #expect(previewVerifierSource.contains("must contain exactly one release metadata commit"))
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
        #expect(workflowSource.contains("./scripts/build-dmg.sh"))
        #expect(workflowSource.contains("./scripts/verify-dmg.sh"))
        #expect(workflowSource.contains("GetSayAll/sayall-ai"))
        #expect(workflowSource.contains("01beeceac9c4091e7e8e122ad1e840ac5e5cee1c"))
        #expect(workflowSource.contains("REQUIRE_SAYALL_AI_PACKAGE=1"))
        #expect(workflowSource.contains("GetSayAll/sayall-macro-platform"))
        #expect(workflowSource.contains("bd2b3d112594373aa10be2bd5e605a008e6182b1"))
        #expect(workflowSource.contains("SAYALL_MACRO_PLATFORM_DEPLOY_KEY"))
        #expect(workflowSource.contains("REQUIRE_SAYALL_MACRO_PLATFORM=1"))
        #expect(workflowSource.contains("GetSayAll/sayall-mac-remote"))
        #expect(workflowSource.contains("SAYALL_MAC_REMOTE_DEPLOY_KEY"))
        #expect(workflowSource.contains("swift package config set-mirror"))
        #expect(workflowSource.contains("file://$GITHUB_WORKSPACE/.private-dependencies/sayall-mac-remote"))
        #expect(workflowSource.contains("04a1bf2b713ee98c4d2c07cd690bb4b26288a82d"))
        #expect(workflowSource.contains("actions/upload-artifact@v4"))
        #expect(workflowSource.contains("contents: read"))
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
        #expect(ciWorkflowSource.contains("bd2b3d112594373aa10be2bd5e605a008e6182b1"))
        #expect(ciWorkflowSource.contains("SAYALL_MACRO_PLATFORM_DEPLOY_KEY"))
        #expect(ciWorkflowSource.contains("GetSayAll/sayall-mac-remote"))
        #expect(ciWorkflowSource.contains("SAYALL_MAC_REMOTE_DEPLOY_KEY"))
        #expect(ciWorkflowSource.contains("swift package config set-mirror"))
        #expect(ciWorkflowSource.contains("classify_changes:"))
        #expect(ciWorkflowSource.contains("Detect documentation-only change"))
        #expect(ciWorkflowSource.contains("*.md) ;;"))
        #expect(ciWorkflowSource.contains("docs_only: ${{ steps.changes.outputs.docs_only }}"))
        #expect(ciWorkflowSource.contains("needs.classify_changes.outputs.docs_only == 'true' && 'ubuntu-latest' || 'macos-15'"))
        #expect(ciWorkflowSource.contains("Confirm documentation-only fast path"))
        #expect(ciWorkflowSource.contains("needs.classify_changes.outputs.docs_only != 'true'"))
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
        #expect(lifecycleSource.contains("release/pre-v1.8.16"))
        #expect(lifecycleSource.contains("PREVIEW BRANCH PASS"))
        #expect(lifecycleSource.contains("must exactly equal the latest origin/main"))
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
        #expect(regressionSource.contains("--draft"))
        #expect(regressionSource.contains("PARALLEL_RELEASE_VARIANTS=1"))
        #expect(releaseWorkflowSource.contains("validate-candidate:"))
        #expect(releaseWorkflowSource.contains("verify-preview-candidate-ci.sh"))
        #expect(releaseWorkflowSource.contains("REQUIRE_PREVIEW_RECORDING_PR: 1"))
        #expect(releaseWorkflowSource.contains("PARALLEL_RELEASE_VARIANTS: 1"))
        #expect(releaseWorkflowSource.contains("PARALLEL_PACKAGE_NOTARIZATION: 1"))
        let signedStep = try #require(
            releaseWorkflowSource.components(
                separatedBy: "- name: Sign, notarize, staple, and verify both variants"
            ).last?.components(separatedBy: "- name: Upload signed release packages").first
        )
        #expect(signedStep.contains("timeout-minutes: 10"))
        #expect(releaseWorkflowSource.contains("SIGNED_RELEASE_TIMEOUT_SECONDS: 590"))
        #expect(signedStep.contains("run-release-stage.sh"))
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

        #expect(preinstallSource.contains("CURRENT_ARCHITECTURE"))
        #expect(preinstallSource.contains("/usr/sbin/sysctl -in hw.optional.arm64"))
        #expect(!preinstallSource.contains("/usr/bin/uname -m"))
        #expect(preinstallSource.contains("Download the Intel version"))
        #expect(preinstallSource.contains("Download the Apple Silicon version"))
        #expect(!preinstallSource.contains("/bin/rm -rf -- \"$APP_DESTINATION\""))
        #expect(preinstallSource.contains("will be updated atomically"))
        #expect(packageVerifierSource.contains("preinstall must not delete an existing Remote Mic.app"))
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
        #expect(reconciliationSource.contains(".candidateBranch == (\"release/pre-\" + $tag)"))
        #expect(reconciliationSource.contains(".schemaVersion == 1 or .schemaVersion == 2"))
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
        #expect(promotionWorkflow.contains("github.event.workflow_run.conclusion == 'success'"))
        #expect(promotionWorkflow.contains("github.event.workflow_run.event == 'workflow_dispatch'"))
        #expect(promotionWorkflow.contains("stable-promotion-approved"))
        #expect(promotionWorkflow.contains("skipping promotion"))
        #expect(promotionWorkflow.contains("steps.release.outputs.should_promote == 'true'"))
        #expect(promotionWorkflow.contains("gh pr merge \"$pr_number\""))
        #expect(promotionWorkflow.contains("./scripts/publish-release.sh promote"))
        #expect(promotionWorkflow.contains("environment: mac-stable-release"))
        #expect(promotionWorkflow.contains("command -v rg >/dev/null 2>&1"))
        #expect(promotionWorkflow.contains("brew install ripgrep"))
        #expect(promotionWorkflow.contains("rg --version"))
        #expect(!promotionWorkflow.contains("secrets."))
        #expect(!promotionWorkflow.contains("notarize-release.sh"))
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
        #expect(publishSource.contains("PUBLIC_PAYLOAD_ASSET_COUNT=11"))
        #expect(publishSource.contains("PUBLIC_RELEASE_ASSET_COUNT=12"))
        #expect(publishSource.contains("11|14|16"))
        #expect(publishSource.contains("12|15|17"))
        #expect(publishSource.contains("Remote-Mic-$VERSION.dmg.sha256"))
        #expect(publishSource.contains("candidate-provenance.json"))
        let releaseUploadSource = try #require(
            publishSource.components(separatedBy: "gh release create").last?
                .components(separatedBy: "--repo \"$REPOSITORY\"").first
        )
        #expect(!releaseUploadSource.contains("Remote-Mic-$VERSION-Installer.pkg"))
        #expect(!releaseUploadSource.contains("Remote-Mic-$VERSION-Intel-Installer.pkg"))
        #expect(releaseUploadSource.contains("Remote-Mic-$VERSION-Uninstaller.pkg"))
        #expect(releaseUploadSource.contains("Remote-Mic-$VERSION-Intel-Uninstaller.pkg"))
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
        #expect(bootstrapSource.contains("SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE"))
        #expect(!workflowSource.contains("CERTIFICATE_BASE64"))
        #expect(!workflowSource.contains("NOTARY_API_KEY_BASE64"))
        #expect(!workflowSource.contains("SPARKLE_PRIVATE_KEY_BASE64"))
        #expect(!workflowSource.contains("pull_request:"))
        #expect(!workflowSource.contains("push:"))
    }
}
