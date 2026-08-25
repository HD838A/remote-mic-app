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

    @Test func appIconRetainsItsIconComposerSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let documentURL = root.appendingPathComponent("Resources/AppIcon.icon")
        let manifestURL = documentURL.appendingPathComponent("icon.json")
        let manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        let groups = try #require(manifest["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let layers = try #require(group["layers"] as? [[String: Any]])
        let layerNames = layers.compactMap { $0["image-name"] as? String }
        let renderSource = try String(
            contentsOf: root.appendingPathComponent("scripts/render-app-icon.sh"),
            encoding: .utf8
        )
        let embeddedLayersExist = layerNames.allSatisfy { layerName in
            FileManager.default.fileExists(
                atPath: documentURL
                    .appendingPathComponent("Assets")
                    .appendingPathComponent(layerName)
                    .path
            )
        }
        let authoringLayersExist = layerNames.allSatisfy { layerName in
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("Resources/AppIconLayers")
                    .appendingPathComponent(layerName)
                    .path
            )
        }

        #expect(FileManager.default.fileExists(atPath: documentURL.path))
        #expect(groups.count == 1)
        #expect(group["name"] as? String == "SayAll")
        #expect(layerNames == ["03-microphone.svg", "02-duck.svg", "01-signal.svg"])
        #expect(embeddedLayersExist)
        #expect(authoringLayersExist)
        #expect(renderSource.contains("Icon Composer.app/Contents/Executables/ictool"))
        #expect(renderSource.contains("--platform macOS"))
        #expect(renderSource.contains("--rendition Default"))
        #expect(renderSource.contains("/usr/bin/iconutil --convert icns"))
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

    @Test func appBuildLinksAgainstTheSelectedXcodeSDKWithoutRaisingDeploymentTarget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(source.contains("xcrun --sdk macosx --show-sdk-path"))
        #expect(source.contains("xcrun --sdk macosx --show-sdk-version"))
        #expect(source.contains("-Xlinker -platform_version"))
        #expect(source.contains("-Xlinker \"$RELEASE_MIN_SYSTEM_VERSION\""))
        #expect(source.contains("-Xlinker \"$MACOS_SDK_VERSION\""))
        #expect(source.contains("\"${SWIFT_SDK_LINK_ARGUMENTS[@]}\""))
        #expect(source.contains("vtool -show-build \"$BIN_PATH\""))
        #expect(source.contains("App deployment target mismatch"))
        #expect(source.contains("App SDK mismatch"))
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

    @Test func mainBasedPreviewFlowUsesSingleImmutableStagingArtifact() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-release-package.yml"),
            encoding: .utf8
        )
        let publicationWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-preview-publication.yml"),
            encoding: .utf8
        )
        let stableWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-stable-promote.yml"),
            encoding: .utf8
        )
        let stagingSource = try String(
            contentsOf: root.appendingPathComponent("scripts/stage-macos-preview.sh"),
            encoding: .utf8
        )
        let publicationSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-preview-release.sh"),
            encoding: .utf8
        )
        let promotionSource = try String(
            contentsOf: root.appendingPathComponent("scripts/promote-preview-release.sh"),
            encoding: .utf8
        )

        #expect(packageWorkflow.contains("mode:"))
        #expect(packageWorkflow.contains("expected_commit:"))
        #expect(packageWorkflow.contains("environment: mac-release"))
        #expect(packageWorkflow.contains("prepare-public-release-assets.sh"))
        #expect(packageWorkflow.contains("mac-preview-payload-v"))
        #expect(packageWorkflow.contains("mac-preview-stage-v"))
        #expect(!packageWorkflow.contains("qualification"))
        #expect(!packageWorkflow.contains("release_mode"))
        #expect(!packageWorkflow.contains("gh release"))
        #expect(publicationWorkflow.contains("source_run_id:"))
        #expect(publicationWorkflow.contains("ui_attestation_b64:"))
        #expect(publicationWorkflow.contains("publish-preview-release.sh"))
        #expect(publicationWorkflow.contains("GH_TOKEN:"))
        #expect(publicationWorkflow.contains("ref: ${{ github.sha }}"))
        #expect(publicationWorkflow.contains("TRIGGER_REPOSITORY"))
        #expect(!publicationWorkflow.contains("secrets."))
        #expect(!publicationWorkflow.contains("environment: mac-release"))
        #expect(stableWorkflow.contains("promote-preview-release.sh"))
        #expect(stableWorkflow.contains("environment: mac-stable-release"))
        #expect(!stableWorkflow.contains("workflow_run:"))
        #expect(!stableWorkflow.contains("package-macos-release"))
        #expect(!stableWorkflow.contains("upload-artifact"))
        #expect(stagingSource.contains("--raw-field \"mode=$MODE\""))
        #expect(stagingSource.contains("run_title=\"mac-release $MODE $commit\""))
        #expect(stagingSource.contains("--include"))
        #expect(stagingSource.contains("releases/latest"))
        #expect(stagingSource.contains("verify-release-workflow-gh-token.sh"))
        #expect(publicationSource.contains("recover-preview-stage.sh"))
        #expect(publicationSource.contains("candidate-provenance.json"))
        #expect(publicationSource.contains("releases/latest"))
        #expect(publicationSource.contains("stagedAt"))
        #expect(publicationSource.contains("--arg stagedAt \"$staged_at\""))
        #expect(!publicationSource.contains("--arg publishedAt \"$(/bin/date"))
        #expect(publicationSource.contains("verify-preview-ui-attestation.sh"))
        #expect(publicationSource.contains("HD838A/remote-mic-app"))
        #expect(promotionSource.contains("--prerelease=false"))
        #expect(promotionSource.contains("candidate-provenance.json"))
        #expect(promotionSource.contains("needs_promotion=0"))
        #expect(promotionSource.contains("already Stable"))
        #expect(promotionSource.contains("GITHUB_WORKFLOW_REF"))
        #expect(promotionSource.contains("HD838A/remote-mic-app"))
        #expect(!promotionSource.contains("package-macos-release"))
        #expect(!promotionSource.contains("notary"))
    }

    @Test func previewPreparationBumpsOnlyForOccupiedPublicIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparationSource = try String(
            contentsOf: root.appendingPathComponent("scripts/prepare-preview-release.sh"),
            encoding: .utf8
        )
        let fixtureSource = try String(
            contentsOf: root.appendingPathComponent("scripts/test-prepare-preview-release.sh"),
            encoding: .utf8
        )

        #expect(preparationSource.contains("git ls-remote --exit-code origin"))
        #expect(preparationSource.contains("increment_patch"))
        #expect(preparationSource.contains("SELECTED_VERSION"))
        #expect(preparationSource.contains("SELECTED_BUILD"))
        #expect(!preparationSource.contains("release/pre-v"))
        #expect(!preparationSource.contains("qualification"))
        #expect(fixtureSource.contains("PREVIEW RELEASE PREPARATION FIXTURE PASS"))
        #expect(fixtureSource.contains("1.9.11"))
    }

    @Test func releaseControlPlaneFixtureHasExecutableRegressionCoverage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent("scripts/test-macos-release-flow.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [fixture.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(
            process.terminationStatus == 0,
            "Release control-plane fixture failed. stdout: \(output) stderr: \(error)"
        )
    }

    @Test func releaseCriticalWorkflowsPinActionsToFullCommits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowPaths = [
            ".github/workflows/mac-ci.yml",
            ".github/workflows/mac-release-package.yml",
            ".github/workflows/mac-preview-publication.yml",
            ".github/workflows/mac-stable-promote.yml",
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

        #expect(combinedSource.contains(approvedActionReferences[0]))
        #expect(!combinedSource.contains("mac-preview-candidate.yml"))
        #expect(!combinedSource.contains("release-guard.yml"))
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
        let publishSource = try source("scripts/publish-preview-release.sh")
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
        #expect(packageSource.contains(
            "Add :$component_index:BundleIsRelocatable bool false"
        ))
        #expect(packageVerifierSource.contains("./Applications/SayAll.app/Contents/Info.plist"))
        #expect(packageVerifierSource.contains("*/Applications/SayAll.app"))
        #expect(appVerifierSource.contains("test \"${APP:t}\" = \"SayAll.app\""))
        #expect(appVerifierSource.contains("CFBundleName raw"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(publishSource.contains("public_dir"))

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

    @Test func stablePromotionOnlyChangesExistingPreviewClassification() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let promotionWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-stable-promote.yml"),
            encoding: .utf8
        )
        let promotionSource = try String(
            contentsOf: root.appendingPathComponent("scripts/promote-preview-release.sh"),
            encoding: .utf8
        )

        #expect(promotionWorkflow.contains("workflow_dispatch:"))
        #expect(promotionWorkflow.contains("tag:"))
        #expect(promotionWorkflow.contains("environment: mac-stable-release"))
        #expect(promotionWorkflow.contains("group: mac-stable-promotion"))
        #expect(promotionWorkflow.contains("ref: ${{ github.sha }}"))
        #expect(promotionWorkflow.contains("TRIGGER_REPOSITORY"))
        #expect(promotionWorkflow.contains("./scripts/promote-preview-release.sh"))
        #expect(!promotionWorkflow.contains("workflow_run:"))
        #expect(!promotionWorkflow.contains("request_id:"))
        #expect(!promotionWorkflow.contains("upload-artifact"))
        #expect(!promotionWorkflow.contains("notarize-release.sh"))
        #expect(!promotionWorkflow.contains("package-macos-release"))
        #expect(promotionSource.contains("case \"$is_prerelease\" in"))
        #expect(promotionSource.contains("--prerelease=false"))
        #expect(!promotionSource.contains("git branch --show-current"))
        #expect(promotionSource.contains("Candidate provenance is invalid"))
        #expect(promotionSource.contains("asset set"))
        #expect(!promotionSource.contains("run-release-stage"))
        #expect(!promotionSource.contains("codesign"))
        #expect(!promotionSource.contains("notarytool"))
    }

    @Test func releaseAssetsKeepLocalizedNotesAndImmutableUrls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetSource = try String(
            contentsOf: root.appendingPathComponent("scripts/prepare-public-release-assets.sh"),
            encoding: .utf8
        )
        #expect(assetSource.contains("Remote-Mic-$version.zh.txt"))
        #expect(assetSource.contains("Remote-Mic-$version.en.txt"))
        #expect(assetSource.contains("production_prefix"))
        #expect(assetSource.contains("staged-assets.json"))
        #expect(assetSource.contains("verify-staged-release-assets.sh"))
        #expect(assetSource.contains("ASSET_COUNT: 11"))
        #expect(!assetSource.contains("candidate-provenance.json"))
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
        #expect(workflowSource.contains("mode:"))
        #expect(workflowSource.contains("expected_commit:"))
        #expect(workflowSource.contains("prepare-public-release-assets.sh"))
        #expect(workflowSource.contains("mac-preview-payload-v"))
        #expect(workflowSource.contains("mac-preview-stage-v"))
        #expect(!workflowSource.contains("needs: validate-candidate"))
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
