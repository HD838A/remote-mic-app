import AppKit
import Foundation
import Testing
import SwiftUI
@testable import RemoteMic

@Suite("First-run onboarding")
struct OnboardingFlowTests {
    @Test func deferredVoiceAuthorizationIsVisibleBeforeAnotherVoiceAttempt() {
        let context = FirstUseDiagnosticContext(
            step: .voiceTest,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            capabilities: OnboardingCapabilities(),
            hasSelectedAudioUID: true,
            voiceAttempt: FirstUseVoiceAttemptDiagnostic(),
            voiceAuthorizationRequired: true
        )
        #expect(context.failureReason == .voiceAuthorizationRequired)
        #expect(context.failureReason?.recoveryStep == .voiceTest)
    }

    #if SAYALL_SIRI_REMOTE_ENABLED && !canImport(SayAllSiriRemote)
    @Test @MainActor func resumedSiriVoiceTestExposesAuthorizationRetryWithoutRecording() throws {
        let fixture = try OnboardingOffscreenFixture(
            step: .voiceTest,
            controlSource: .siriRemote,
            siriRemoteInitiallyEnabled: true,
            siriRemoteNeedsUserAction: true
        )
        defer { fixture.close() }
        #expect(fixture.settings.onboardingStep == .voiceTest)
        #expect(fixture.settings.siriRemoteNeedsUserAction)
        #expect(fixture.probe.actions["voice-test.audio-retry"] != nil)
        #expect(fixture.probe.actions["diagnostics.copy"] != nil)
        fixture.probe.invoke("voice-test.audio-retry")
        #expect(!fixture.settings.siriRemoteNeedsUserAction)
        #expect(!fixture.settings.isOnboardingComplete)
        #expect(!fixture.settings.firstUseEvents.contains {
            $0.step == .voiceTest && ($0.kind == .passed || $0.kind == .recovered)
        })
        #expect(fixture.settings.firstUseEvents.contains {
            $0.kind == .retry && $0.failureReason == .voiceAuthorizationRequired
        })
    }
    #endif

    @Test func onboardingSourceVisibilityHidesChromecastButKeepsOtherSources() {
        let visible = OnboardingControlSourceVisibilityPolicy.visibleSources(
            OnboardingControlSource.allCases
        )
        #expect(!visible.contains(.chromecastRemote))
        #expect(visible.contains(.xiaomiRemote))
        #expect(visible.contains(.appleCompanion))
        #expect(visible.contains(.webRemote))
        #expect(visible.contains(.unselected))
    }

    @Test func onboardingRightPaneAndSourceScrollerUseTheApprovedLayoutRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".scrollIndicators(.hidden)"))
        #expect(source.contains("minHeight: max(0, proxy.size.height - 56)"))
        #expect(source.contains("alignment: .center"))
    }

    @Test func membershipSheetGivesTheMembershipCenterAnExplicitSize() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        // 会员中心以整页尺寸设计，内部用 GeometryReader 按可用宽度推算内容宽度
        // （可用宽度不足 48pt 时内容宽度会算成 0）。sheet 不给尺寸时会塌缩成
        // 一个只有「关闭」按钮的空弹窗，用户因此完全无法开通会员。
        #expect(source.contains(".frame(minWidth: 900, minHeight: 620)"))
    }

    @Test func webRemotePreparationCopyDescribesTheNextStep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(chinese.contains("\"onboarding.web_remote.preparing\" = \"下一步生成二维码\";"))
        #expect(english.contains("\"onboarding.web_remote.preparing\" = \"Next, generate a QR code\";"))
        #expect(!chinese.contains("\"onboarding.web_remote.preparing\" = \"正在生成二维码\";"))
        #expect(!english.contains("\"onboarding.web_remote.preparing\" = \"Generating a QR code\";"))
    }

    @Test func siriRemoteRequiresBothBuildSupportAndInstallerReceipt() {
        #expect(OnboardingBuildCapabilities.isSiriRemotePackageInstalled { path in
            path == "/var/db/receipts/com.hd838a.RemoteMic.siri-remote.plist"
        })
        #expect(!OnboardingBuildCapabilities.isSiriRemotePackageInstalled { _ in false })
        #expect(!OnboardingBuildCapabilities.availableControlSources(
            siriRemotePackageInstalled: false
        ).contains(.siriRemote))
        #if SAYALL_SIRI_REMOTE_ENABLED
        #expect(OnboardingBuildCapabilities.availableControlSources(
            siriRemotePackageInstalled: true
        ).contains(.siriRemote))
        #else
        #expect(!OnboardingBuildCapabilities.availableControlSources(
            siriRemotePackageInstalled: true
        ).contains(.siriRemote))
        #endif
    }

    @Test @MainActor func siriRemoteTrialPreservesEntryStateAndMembershipAccessAcrossResume() throws {
        for initiallyEnabled in [false, true] {
            let suite = "RemoteMicTests.Onboarding.SiriTrial.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.siriRemoteEnabled = initiallyEnabled
            settings.beginOnboardingSiriRemoteTrial()
            settings.siriRemoteEnabled = true
            let resumed = AppSettings(defaults: defaults)
            resumed.beginOnboardingSiriRemoteTrial()
            #expect(resumed.onboardingSiriRemoteInitiallyEnabled == initiallyEnabled)
            // 连接与按键不看会员：会员判定不再决定整个 Siri Remote 支持的开关。
            let model = BridgeAppModel(settings: resumed)
            model.completeOnboarding()
            #expect(resumed.siriRemoteEnabled)
            #expect(resumed.isOnboardingComplete)
            #expect(resumed.onboardingSiriRemoteInitiallyEnabled == nil)
        }
    }

    @Test @MainActor func hiddenChromecastSelectionReturnsToTheSourcePage() throws {
        let fixture = try OnboardingOffscreenFixture(
            step: .remoteAvailability,
            controlSource: .chromecastRemote
        )
        defer { fixture.close() }
        #expect(fixture.settings.onboardingStep == .remoteAvailability)
        #expect(fixture.settings.onboardingControlSource == .unselected)
        #expect(fixture.probe.actions["control-source.chromecast_remote"] == nil)
    }

    @Test @MainActor func missingSiriRemotePackageRemovesCardsAndRepairsSavedSelection() throws {
        let fixture = try OnboardingOffscreenFixture(
            step: .remote,
            controlSource: .siriRemote,
            siriRemotePackageInstalled: false
        )
        defer { fixture.close() }
        #expect(fixture.settings.onboardingStep == .remoteAvailability)
        #expect(fixture.settings.onboardingControlSource == .unselected)
        #expect(!fixture.settings.siriRemoteEnabled)
        for generation in OnboardingAppleRemoteGeneration.allCases {
            #expect(fixture.probe.actions["control-source.siri_remote.\(generation.rawValue)"] == nil)
        }
    }

    @Test @MainActor func completingProductionViewKeepsSiriRemoteSupportWithoutMembership() throws {
        for initiallyEnabled in [false, true] {
            let fixture = try OnboardingOffscreenFixture(
                step: .complete,
                controlSource: .xiaomiRemote,
                siriRemoteInitiallyEnabled: initiallyEnabled
            )
            defer { fixture.close() }
            fixture.model.enableSiriRemoteForOnboarding()
            fixture.probe.invoke("continue")
            #expect(fixture.settings.isOnboardingComplete)
            // 连接与按键不看会员：完成引导不再关闭 Siri Remote 支持，只有语音按权益判定。
            #expect(fixture.settings.siriRemoteEnabled)
        }
    }

    @Test func allAudioNamesKeepTheSavedSelectionAcrossResumeAndRerun() throws {
        for name in ["SayAll", "MiRemoteV 2ch", "BlackHole 2ch"] {
            let suite = "RemoteMicTests.Onboarding.AudioName.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            let uid = name == "BlackHole 2ch" ? "BlackHole2ch_UID" : DoubaoAudioDevicePolicy.deviceUID
            settings.selectedAudioDeviceUID = uid
            settings.restartOnboarding()
            let resumed = AppSettings(defaults: defaults)
            #expect(resumed.selectedAudioDeviceUID == uid)
            #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(uid: resumed.selectedAudioDeviceUID, name: name))
            #expect(OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
                selectedUID: resumed.selectedAudioDeviceUID,
                availableSupportedUIDs: [uid]
            ))
        }
    }

    @Test @MainActor func offscreenProductionViewCanBeHostedWithoutUnlockingMac() throws {
        let suiteName = "RemoteMicTests.Onboarding.Offscreen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        settings.setOnboardingStep(.welcome)
        let model = BridgeAppModel(settings: settings)
        let probe = OnboardingInteractionProbe()
        let localization = LocalizationStore(
            settings: settings,
            resourceBundle: RemoteMicResourceBundle.mainOrDevelopment
        )
        let rootView = OnboardingView(
            model: model,
            completeRuntimeReadyOverride: true,
            allowsInputSourceSwitching: false,
            voiceToolAvailabilityOverride: [
                .doubao: .available,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ],
            interactionProbe: probe,
            siriRemotePackageInstalledOverride: true
        )
        .environmentObject(localization)
        .frame(width: 1020, height: 772)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1020, height: 772),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = hostingController
        defer {
            window.contentViewController = nil
            window.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentView != nil)
        #expect(probe.actions.keys.contains("continue"))
        #expect(!probe.actions.keys.contains("back"))
        probe.invoke("continue")
        #expect(settings.onboardingStep == .remoteAvailability)
    }

    @Test func onboardingUserCopyDoesNotExposeInternalValidationLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let forbiddenPhrases = [
            "待验证", "待复核", "验证中", "未完成", "不确定", "状态未知",
            "默认值待", "安装状态待", "Needs validation", "Needs review",
            "versioned validation", "in development", "validation pending",
            "status unknown", "uncertain", "Radio"
        ]

        for relativePath in [
            "Resources/zh-Hans.lproj/Localizable.strings",
            "Resources/en.lproj/Localizable.strings",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for line in source.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("\"onboarding.") else { continue }
                for phrase in forbiddenPhrases {
                    #expect(
                        !line.localizedCaseInsensitiveContains(phrase),
                        "Onboarding copy must not expose internal phrase: \(phrase)"
                    )
                }
            }
        }
    }

    @Test func legacyChatterFlySelectionMigratesToUnselected() throws {
        let suiteName = "RemoteMicTests.Onboarding.ChatterFlyMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("chatterfly", forKey: "onboarding.voiceTool")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.onboardingVoiceTool == .unselected)
        #expect(defaults.string(forKey: "onboarding.voiceTool") == OnboardingVoiceTool.unselected.rawValue)
    }

    @Test func voiceTestPromptUsesOnlyTheSelectedGesture() {
        let hold = OnboardingVoiceGesturePrompt.text(for: .hold, locale: Locale(identifier: "zh-Hans"))
        let toggle = OnboardingVoiceGesturePrompt.text(for: .toggle, locale: Locale(identifier: "zh-Hans"))
        #expect(hold.contains("按住"))
        #expect(toggle.contains("按一下"))
        #expect(!hold.contains("Fn"))
        #expect(!toggle.contains("Fn"))
        #expect(!hold.contains("快捷键"))
        #expect(!toggle.contains("快捷键"))
    }

    @Test func welcomePromptDescribesHeadlessAgentConfiguration() {
        let prompt = OnboardingAIAssistantPrompt.chinese
        #expect(prompt.contains("--agent-configure"))
        #expect(prompt.contains("--json"))
        #expect(prompt.contains("不要操作屏幕"))
        #expect(prompt.contains("停在真实语音测试步骤"))
        #expect(prompt.contains("音频输出设备"))
        #expect(prompt.contains("同一设备选择为麦克风"))
        #expect(prompt.contains("staged 配置已准备"))
        #expect(!prompt.contains("/Users/"))

        let english = OnboardingAIAssistantPrompt.english
        #expect(english.contains("audio output device"))
        #expect(english.contains("same device as its microphone"))
        #expect(english.contains("staged configuration is prepared"))
    }

    @Test func welcomePromptSelectsOnlyInstalledApplicationCopies() throws {
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        let installations = [
            "/Applications/SayAll.app",
            "/Applications/无线麦SayAll.app",
            "\(userApplications)/SayAll.app",
            "\(userApplications)/无线麦SayAll.app",
        ]
        let scenarios: [(available: [String], expected: String?)] = [
            (installations, installations[0]),
            (Array(installations.dropFirst()), installations[1]),
            (Array(installations.suffix(2)), installations[2]),
            ([installations[3]], installations[3]),
            ([], nil),
        ]
        for prompt in [OnboardingAIAssistantPrompt.chinese, OnboardingAIAssistantPrompt.english] {
            let lines = prompt.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let start = try #require(lines.firstIndex { $0.hasPrefix("APP_PATH=") })
            let end = try #require(lines.firstIndex {
                $0 == #""$APP_PATH/Contents/MacOS/RemoteMic" --agent-configure --auto --json"#
            })
            // Print the selected path instead of starting an App or changing settings.
            let locator = lines[start..<end].joined(separator: "\n") +
                "\n" + #"printf '%s\n' "$APP_PATH""#
            for scenario in scenarios {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", """
                test() {
                    if /bin/test "$1" = "-x"; then
                        case ":$SAYALL_TEST_EXECUTABLES:" in
                            *":$2:"*) return 0 ;;
                            *) return 1 ;;
                        esac
                    fi
                    /bin/test "$@"
                }
                mdfind() { printf '%s\\n' '/developer-artifacts/old-build/SayAll.app'; }
                \(locator)
                """]
                var environment = ProcessInfo.processInfo.environment
                environment["SAYALL_TEST_EXECUTABLES"] = scenario.available
                    .map { "\($0)/Contents/MacOS/RemoteMic" }.joined(separator: ":")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let expected = scenario.expected {
                    #expect(process.terminationStatus == 0)
                    #expect(text == expected)
                } else {
                    #expect(process.terminationStatus == 1)
                    let json = try #require(
                        try JSONSerialization.jsonObject(with: output) as? [String: Any]
                    )
                    #expect(json["status"] as? String == "not_found")
                    #expect(json["reason"] as? String == "installed_app")
                }
            }
        }
    }

    @Test func agentConfigurationCommandIsHeadlessAndKeepsVerificationAsASeparateStep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let commandSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/AgentConfigurationCommand.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        #expect(commandSource.contains("--verify"))
        #expect(commandSource.contains("onboarding.agent_configuration_backup"))
        #expect(commandSource.contains("recoverInterruptedConfigurationIfNeeded"))
        #expect(commandSource.contains("real_voice_test"))
        #expect(commandSource.contains("permission_required"))
        #expect(appSource.contains("--agent-configure"))
        #expect(!commandSource.contains("NSAppleScript"))
        #expect(!commandSource.contains("CGWindowList"))
    }

    @Test func controlSourcePresentationUsesSourceSpecificPairingAndButtons() throws {
        let xiaomiPairing = OnboardingView.physicalRemotePairingGuide(for: .xiaomiRemote)
        #expect(xiaomiPairing.steps == [
            "onboarding.remote.first_pairing.wake",
            "onboarding.remote.first_pairing.pair",
        ])

        let siriPairing = OnboardingView.physicalRemotePairingGuide(for: .siriRemote)
        #expect(siriPairing.steps == (1...5).map { "onboarding.remote.siri_pairing.step\($0)" })

        let chromecastPairing = OnboardingView.physicalRemotePairingGuide(for: .chromecastRemote)
        #expect(chromecastPairing.steps == [
            "onboarding.remote.chromecast_pairing.first",
            "onboarding.remote.chromecast_pairing.second",
        ])

        #expect(OnboardingView.displayedControlButtons(for: .xiaomiRemote) == RemoteButton.xiaomiCases)
        #expect(Set(try #require(OnboardingView.displayedControlButtons(for: .siriRemote))) == [
            .power, .up, .left, .ok, .right, .down,
            .back, .volumeUp, .volumeDown, .tv, .playPause, .mute,
        ])
        #expect(Set(try #require(OnboardingView.displayedControlButtons(for: .chromecastRemote))) == [
            .power, .up, .left, .ok, .right, .down, .back,
            .home, .volumeUp, .volumeDown, .mute, .youtube, .netflix, .input,
        ])

        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .xiaomiRemote) ==
            "onboarding.recovery.remote.not_found.physical_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .siriRemote) ==
            "onboarding.recovery.remote.not_found.physical_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .chromecastRemote) ==
            "onboarding.recovery.remote.not_found.physical_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .appleCompanion) ==
            "onboarding.recovery.remote.not_found.apple_companion_detail")
        #expect(OnboardingView.remoteNotFoundRecoveryDetailKey(for: .webRemote) ==
            "onboarding.recovery.remote.not_found.web_remote_detail")
        #expect(OnboardingView.displayedControlButtons(for: .appleCompanion) == nil)
        #expect(OnboardingView.displayedControlButtons(for: .webRemote) == nil)
        #expect(OnboardingView.controlsDetailKey(for: .appleCompanion) ==
            "onboarding.controls.apple_companion.detail")
        #expect(OnboardingView.controlsDetailKey(for: .webRemote) ==
            "onboarding.controls.web_remote.detail")
    }

    @Test func siriPairingGuideLandsEveryStepInBothLanguages() throws {
        // 苹果遥控器的配对有两个坑，用户照着一句话版本做基本都会失败：
        // 遥控器会自己连回原来的 Apple TV；这台 Mac 上的旧配对记录会让它连不上。
        // 所以这张卡是五步，不是三步——每一步都必须真的翻译过，否则界面会直接吐出键名。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let guide = OnboardingView.physicalRemotePairingGuide(for: .siriRemote)
        #expect(guide.steps.count == 5)
        for resource in ["zh-Hans", "en"] {
            let text = try String(
                contentsOf: root.appendingPathComponent(
                    "Resources/\(resource).lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            for key in [guide.title] + guide.steps {
                #expect(text.contains("\"\(key)\" = "), "缺少 \(resource) 文案：\(key)")
            }
            // 旧的三步键已改名，不能留在文件里当死键。
            #expect(!text.contains("onboarding.remote.siri_pairing.first\""))
            #expect(!text.contains("onboarding.remote.siri_pairing.second\""))
            #expect(!text.contains("onboarding.remote.siri_pairing.third\""))
        }
        let zh = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        // 「必须做」这一步不能被压成可选项：它是用户按下按键却连不上的最常见原因。
        #expect(zh.contains("这一步必须做"))
        // 遥控器在蓝牙列表里常常显示成序列号，不能再让用户只按名字找。
        #expect(zh.contains("名称可能是一串序列号"))
        // 页面说明不能再写死步数：小米两步、苹果遥控器五步，同一句话会自相矛盾。
        #expect(!zh.contains("下面两步"))
        #expect(zh.contains("首次连接请先按下面的步骤配对"))
    }

    @Test func navigationOrderIsStableAndGroupedIntoThreePhases() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .remoteAvailability)
        #expect(OnboardingStep.remoteAvailability.next == .permissions)
        #expect(OnboardingStep.controlMethod.normalized == .remoteAvailability)
        #expect(OnboardingStep.controlMethod.next == .permissions)
        #expect(OnboardingStep.permissions.next == .remote)
        #expect(OnboardingStep.remote.next == .audio)
        #expect(OnboardingStep.audio.next == .voiceTool)
        #expect(OnboardingStep.voiceTool.next == .voiceTest)
        #expect(OnboardingStep.voiceTest.next == .controls)
        #expect(OnboardingStep.controls.next == .complete)
        #expect(OnboardingStep.complete.next == nil)

        #expect(OnboardingPhase.phase(for: .welcome) == .prepare)
        #expect(OnboardingPhase.phase(for: .remoteAvailability) == .prepare)
        #expect(OnboardingPhase.phase(for: .controlMethod) == .prepare)
        #expect(OnboardingPhase.phase(for: .permissions) == .setup)
        #expect(OnboardingPhase.phase(for: .complete) == .tryIt)
    }

    @Test func ordinaryButtonValidationSuppressesExistingMappingsOnlyOnControlsPage() {
        for source in [
            OnboardingControlSource.xiaomiRemote,
            .siriRemote,
            .chromecastRemote,
            .appleCompanion,
            .webRemote,
        ] {
            #expect(OnboardingControlValidationPolicy.suppressConfiguredActions(
                at: .controls,
                source: source
            ))
            #expect(!OnboardingControlValidationPolicy.suppressConfiguredActions(
                at: .voiceTest,
                source: source
            ))
        }
        #expect(!OnboardingControlValidationPolicy.suppressConfiguredActions(
            at: .controls,
            source: .unselected
        ))
    }

    @Test func secureInputWarningIsLimitedToConnectedPhysicalRemote() {
        #expect(OnboardingSecureInputPolicy.shouldMonitor(
            step: .remote,
            source: .xiaomiRemote
        ))
        #expect(OnboardingSecureInputPolicy.shouldMonitor(
            step: .controls,
            source: .chromecastRemote
        ))
        #expect(!OnboardingSecureInputPolicy.shouldMonitor(
            step: .controls,
            source: .appleCompanion
        ))
        #expect(!OnboardingSecureInputPolicy.shouldShowWarning(
            step: .controls,
            source: .xiaomiRemote,
            remoteConnected: false,
            remoteButtonObserved: false,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 20
        ))
        #expect(!OnboardingSecureInputPolicy.shouldShowWarning(
            step: .controls,
            source: .xiaomiRemote,
            remoteConnected: true,
            remoteButtonObserved: true,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 20
        ))
        #expect(OnboardingSecureInputPolicy.shouldShowWarning(
            step: .controls,
            source: .xiaomiRemote,
            remoteConnected: true,
            remoteButtonObserved: false,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 13
        ))
        #expect(OnboardingSecureInputPolicy.shouldShowWarning(
            step: .remote,
            source: .xiaomiRemote,
            remoteConnected: true,
            remoteButtonObserved: false,
            secureInputActive: true,
            waitStartedAtUptime: 10,
            nowUptime: 13
        ))
    }

    @Test func everyControlMethodRequiresAllThreePermissions() {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: true,
            remoteButtonObserved: true
        )

        for method in [
            OnboardingControlMethod.physicalRemote,
            .iPhoneApp,
            .webRemote,
        ] {
            #expect(method.requiresBluetoothPermission)
            #expect(method.requiresInputMonitoringPermission)
            #expect(OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))

            capabilities.bluetoothGranted = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            capabilities.bluetoothGranted = true
            capabilities.inputMonitoringGranted = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            capabilities.inputMonitoringGranted = true
            capabilities.accessibilityGranted = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            capabilities.accessibilityGranted = true
        }

        #expect(!OnboardingControlMethod.unselected.requiresBluetoothPermission)
        #expect(!OnboardingControlMethod.unselected.requiresInputMonitoringPermission)

        #expect(!OnboardingFlowPolicy.canContinue(
            from: .remoteAvailability,
            voiceTool: .typeless,
            remoteAvailability: .unselected,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .remoteAvailability,
            voiceTool: .typeless,
            remoteAvailability: .hasRemote,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .controlMethod,
            voiceTool: .typeless,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            remoteAvailability: .noRemote,
            controlMethod: .unselected,
            capabilities: capabilities
        ))

        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))
    }

    @Test func iphoneAppConfirmationGatesThePermissionsStepOnlyOnTheIPhonePath() {
        let allGranted = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: false,
            remoteButtonObserved: false
        )

        func canContinue(_ method: OnboardingControlMethod, confirmed: Bool) -> Bool {
            OnboardingFlowPolicy.canContinue(
                from: .permissions,
                voiceTool: .typeless,
                remoteAvailability: method == .physicalRemote ? .hasRemote : .noRemote,
                controlMethod: method,
                capabilities: allGranted,
                phoneAppInstallConfirmed: confirmed
            )
        }

        // 三项权限全开、只差「我已安装 iPhone App」没勾：iPhone 路径必须被挡住。
        #expect(!canContinue(.iPhoneApp, confirmed: false))
        #expect(canContinue(.iPhoneApp, confirmed: true))
        // 这一行只在 iPhone 路径上出现，其他控制方式不能被它拦住。
        #expect(canContinue(.physicalRemote, confirmed: false))
        #expect(canContinue(.webRemote, confirmed: false))
        // 不关心勾选的调用方（FirstUseDiagnostics）靠默认值保持原行为。
        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            capabilities: allGranted
        ))
    }

    @Test @MainActor func iphoneAppConfirmationRowIsAToggleOnTheIPhonePathOnly() throws {
        let iphone = try hostedOnboardingProbe(
            suite: "RemoteMicTests.Onboarding.InstalledRow.iPhone",
            method: .iPhoneApp,
            installed: false
        )
        defer { iphone.teardown() }
        // 未勾选时是一行真开关，探针读得到、也点得动。
        #expect(iphone.probe.toggleValues["permission.iphone-app-installed"] == false)
        iphone.probe.invoke("permission.iphone-app-installed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(iphone.probe.toggleValues["permission.iphone-app-installed"] == true)

        // 实体遥控器路径不该出现这一行：那个 App 和它无关。
        let physical = try hostedOnboardingProbe(
            suite: "RemoteMicTests.Onboarding.InstalledRow.physical",
            method: .physicalRemote,
            installed: false
        )
        defer { physical.teardown() }
        #expect(physical.probe.toggleValues["permission.iphone-app-installed"] == nil)

        // 已勾选状态要能从外部预置，离屏截图才能拍到第二种状态。
        let confirmed = try hostedOnboardingProbe(
            suite: "RemoteMicTests.Onboarding.InstalledRow.confirmed",
            method: .iPhoneApp,
            installed: true
        )
        defer { confirmed.teardown() }
        #expect(confirmed.probe.toggleValues["permission.iphone-app-installed"] == true)
    }

    @MainActor
    private func hostedOnboardingProbe(
        suite: String,
        method: OnboardingControlMethod,
        installed: Bool
    ) throws -> (probe: OnboardingInteractionProbe, teardown: () -> Void) {
        let suiteName = "\(suite).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        settings.setOnboardingControlMethod(method)
        settings.setOnboardingStep(.permissions)
        let model = BridgeAppModel(settings: settings)
        let probe = OnboardingInteractionProbe()
        let localization = LocalizationStore(
            settings: settings,
            resourceBundle: RemoteMicResourceBundle.mainOrDevelopment
        )
        let rootView = OnboardingView(
            model: model,
            completeRuntimeReadyOverride: true,
            allowsInputSourceSwitching: false,
            voiceToolAvailabilityOverride: [
                .doubao: .available,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ],
            interactionProbe: probe,
            siriRemotePackageInstalledOverride: true,
            initialPhoneAppInstalled: installed
        )
        .environmentObject(localization)
        .frame(width: 1020, height: 772)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1020, height: 772),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()

        return (probe, {
            window.contentViewController = nil
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    @Test func permissionRowsRemainClickableAfterAuthorization() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("onboardingActionButton(id: id, action: action)"))
        #expect(viewSource.contains("action: requestBluetoothPermission"))
        #expect(viewSource.contains("action: requestInputMonitoringPermission"))
        #expect(viewSource.contains("action: requestAccessibilityPermission"))
        #expect(viewSource.contains("model.requestInputMonitoringPermission()"))
        #expect(viewSource.contains("model.requestAccessibilityPermission()"))
        #expect(viewSource.contains("if bluetoothAuthorization == .allowedAlways"))
        #expect(viewSource.contains("Privacy_Bluetooth"))
    }

    @Test func permissionRefreshIntervalIsReducedAndBackgroundQueriesAreSkipped() {
        #expect(OnboardingPermissionRefreshPolicy.permissionRefreshIntervalSeconds == 2)
        #expect(OnboardingPermissionRefreshPolicy.shouldRefreshPermissions(isApplicationActive: true))
        #expect(!OnboardingPermissionRefreshPolicy.shouldRefreshPermissions(isApplicationActive: false))
    }

    @Test func onboardingPermissionRefreshUsesThePolicyIntervalAndSkipsBackgroundQueries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/OnboardingScreenshotRenderer.swift"
            ),
            encoding: .utf8
        )

        // 权限降频不得改变安全输入、Fn 配置与工具存活检查的原有 1 秒周期。
        let permissionTickStart = try #require(viewSource.range(of: ".onReceive(permissionRefreshTimer)"))
        let nextHandler = try #require(viewSource.range(of: ".onReceive", range: permissionTickStart.upperBound..<viewSource.endIndex))
        let permissionTick = String(viewSource[permissionTickStart.lowerBound..<nextHandler.lowerBound])
        #expect(!permissionTick.contains("refreshSecureInputState()"))
        #expect(!permissionTick.contains("refreshSystemFunctionKeyUsage()"))
        #expect(!permissionTick.contains("refreshSelectedVoiceToolRuntimeState()"))
        #expect(viewSource.contains(".onReceive(runtimeRefreshTimer)"))

        // 周期必须走策略常量，避免再出现硬编码的 1 Hz。
        #expect(viewSource.contains(
            "every: OnboardingPermissionRefreshPolicy.permissionRefreshIntervalSeconds"
        ))
        #expect(viewSource.contains("private let runtimeRefreshTimer = Timer.publish(every: 1, on: .main, in: .common)"))
        // 周期权限刷新必须以前台为前提。
        #expect(viewSource.contains("if shouldRefreshPermissionStates {"))
        #expect(viewSource.contains("isApplicationActive: NSApplication.shared.isActive"))
        // 离屏渲染没有前台会话，宿主显式开启周期刷新。
        #expect(rendererSource.contains("permissionRefreshInForegroundOverride: true"))
        // 用户回到前台时必须立即刷新一次，不能被前台判定挡住。
        let activeStart = try #require(viewSource.range(
            of: "publisher(for: NSApplication.didBecomeActiveNotification)"
        ))
        let activeEnd = viewSource.range(
            of: ".onReceive",
            range: activeStart.upperBound..<viewSource.endIndex
        )?.lowerBound ?? viewSource.endIndex
        let activeHandler = String(viewSource[activeStart.upperBound..<activeEnd])
        #expect(activeHandler.contains("refreshPermissionStates()"))
    }

    @Test func everyProductionInteractiveControlUsesTheOffscreenProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let helpersStart = try #require(viewSource.range(
            of: "private func onboardingActionButton"
        ))
        let productionBody = String(viewSource[..<helpersStart.lowerBound])

        #expect(!productionBody.contains("\n                    Button {"))
        #expect(!productionBody.contains("\n                Button {"))
        #expect(!productionBody.contains("\n            Button {"))
        #expect(!productionBody.contains("\n                    Link(destination:"))
        #expect(!productionBody.contains("\n            Link(destination:"))
        #expect(!productionBody.contains("Toggle(isOn:"))
        #expect(viewSource.contains("onboardingActionButton"))
        #expect(viewSource.contains("onboardingLink"))
        #expect(viewSource.contains("onboardingToggle"))
    }

    @Test func mobileControlPathsUseOnDemandAudioWithoutWeakeningDeviceSelection() {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: true,
            remoteButtonObserved: true,
            audioReady: false,
            audioOutputSelected: true
        )

        for method in [OnboardingControlMethod.iPhoneApp, .webRemote] {
            #expect(method.usesOnDemandAudioOutput)
            #expect(OnboardingFlowPolicy.canContinue(
                from: .audio,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            #expect(OnboardingFlowPolicy.canContinue(
                from: .complete,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))

            let diagnostic = FirstUseDiagnosticContext(
                step: .audio,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities,
                hasSelectedAudioUID: true
            )
            #expect(diagnostic.failureReason == nil)
        }

        #expect(!OnboardingControlMethod.physicalRemote.usesOnDemandAudioOutput)
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .audio,
            voiceTool: .typeless,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            controlMethod: .physicalRemote,
            capabilities: capabilities
        ))

        capabilities.audioOutputSelected = false
        for method in [OnboardingControlMethod.iPhoneApp, .webRemote] {
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .audio,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .complete,
                voiceTool: .typeless,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities
            ))

            let diagnostic = FirstUseDiagnosticContext(
                step: .audio,
                remoteAvailability: .noRemote,
                controlMethod: method,
                capabilities: capabilities,
                hasSelectedAudioUID: true
            )
            #expect(diagnostic.failureReason == .audioSelectedDeviceMissing)
        }
    }

    @Test func connectedPhysicalRemoteSkipsOnlyTheAvailabilityQuestion() {
        #expect(OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .remoteAvailability,
            remoteConnected: true
        ))
        #expect(!OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .remoteAvailability,
            remoteConnected: false
        ))
        #expect(!OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .controlMethod,
            remoteConnected: true
        ))
        #expect(!OnboardingFlowPolicy.shouldAutoSelectPhysicalRemote(
            at: .remoteAvailability,
            remoteConnected: true,
            suppressForUserBack: true
        ))
    }

    @Test func connectedRemotePreselectionDoesNotSkipTheControlSourcePage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("settings.onboardingControlSource == .unselected"))
        #expect(viewSource.contains("preselected=xiaomi_remote"))
        #expect(!viewSource.contains("to=permissions reason=connected_physical_remote"))
    }

    @Test func validatedRemoteButtonAlsoProvesThePhysicalRemoteIsRecognized() {
        #expect(OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .complete,
            voiceConnectionReady: true,
            validatedHIDButtonObserved: false
        ))
        #expect(OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .remote,
            voiceConnectionReady: false,
            validatedHIDButtonObserved: true
        ))
        #expect(!OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .remote,
            voiceConnectionReady: false,
            validatedHIDButtonObserved: false
        ))
        #expect(!OnboardingFlowPolicy.isPhysicalRemoteRecognized(
            at: .complete,
            voiceConnectionReady: false,
            validatedHIDButtonObserved: true
        ))
    }

    @Test func remoteInputDiagnosticDistinguishesVoiceFromControlButtons() {
        var diagnostic = FirstUseRemoteInputDiagnostic()

        diagnostic.recordVoiceButtonPress()
        diagnostic.recordVoiceButtonPress()

        #expect(diagnostic.voiceButtonPressCount == 2)
        #expect(diagnostic.controlButtonObservationCount == 0)
        #expect(diagnostic.lastInputKind == .voice)
        #expect(diagnostic.shouldShowVoiceButtonCorrection)

        diagnostic.recordControlButtonObservation()

        #expect(diagnostic.voiceButtonPressCount == 2)
        #expect(diagnostic.controlButtonObservationCount == 1)
        #expect(diagnostic.lastInputKind == .control)
        #expect(!diagnostic.shouldShowVoiceButtonCorrection)
    }

    @Test func everyRequiredCapabilityBlocksItsStepUntilVerified() {
        var capabilities = OnboardingCapabilities()

        #expect(OnboardingFlowPolicy.canContinue(
            from: .welcome,
            voiceTool: .unselected,
            capabilities: capabilities
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .unselected,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.bluetoothGranted = true
        capabilities.inputMonitoringGranted = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.accessibilityGranted = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.remoteConnected = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .remote,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.remoteButtonObserved = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .remote,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.audioReady = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .audio,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.audioOutputSelected = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .audio,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.voiceSessionStarted = true
        capabilities.voiceSamplesReceived = true
        capabilities.voiceSessionEnded = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTest,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.transcriptionAppeared = true
        capabilities.manualTranscriptInputObserved = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTest,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.manualTranscriptInputObserved = false
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTest,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        capabilities.testedRemoteButtonCount = 2
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .controls,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.testedRemoteButtonCount = 3
        #expect(OnboardingFlowPolicy.canContinue(
            from: .controls,
            voiceTool: .typeless,
            capabilities: capabilities
        ))

        #expect(OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.remoteConnected = false
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
        capabilities.remoteConnected = true
        capabilities.remoteButtonObserved = false
        capabilities.voiceSessionStarted = false
        capabilities.voiceSamplesReceived = false
        capabilities.voiceSessionEnded = false
        capabilities.transcriptionAppeared = false
        capabilities.testedRemoteButtonCount = 0
        #expect(OnboardingFlowPolicy.canContinue(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities
        ))
    }

    @Test func voiceToolSelectionKeepsSystemFnInstructionAdvisory() {
        let capabilities = OnboardingCapabilities()

        #expect(OnboardingVoiceTool.doubao.preferredInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin")
        #expect(OnboardingVoiceTool.weixin.preferredInputSourceID == "com.tencent.inputmethod.wetype.pinyin")
        #expect(OnboardingVoiceTool.typeless.preferredInputSourceID == nil)
        #expect(OnboardingVoiceTool.other.preferredInputSourceID == nil)

        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .weixin,
            capabilities: capabilities
        ))
    }

    @Test func voiceToolSelectionPreservesExistingCommandModesUntilAPlanIsStaged() {
        let capabilities = OnboardingCapabilities(systemFunctionKeyAvailable: true)
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .leftCommand,
            capabilities: capabilities
        ))
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTool,
            voiceTool: .doubao,
            voiceKeyMode: .rightCommand,
            capabilities: capabilities
        ))
    }

    @Test func selectingVoiceToolAndRestartingPreserveTheFormalVoiceConfiguration() throws {
        let suiteName = "RemoteMicTests.Onboarding.FnOnlyPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        for tool in [OnboardingVoiceTool.doubao, .weixin, .vokie, .typeless, .other] {
            settings.voiceKeyMode = .rightCommand
            settings.voiceFnTapModeEnabled = true
            settings.setOnboardingVoiceTool(tool)
            #expect(settings.voiceKeyMode == .rightCommand)
            #expect(settings.voiceFnTapModeEnabled)
            #expect(settings.pendingOnboardingVoiceKeyMigration == nil)
        }

        settings.voiceKeyMode = .rightCommand
        settings.voiceFnTapModeEnabled = true
        settings.restartOnboarding()
        #expect(settings.voiceKeyMode == .rightCommand)
        #expect(settings.voiceFnTapModeEnabled)
        #expect(settings.pendingOnboardingVoiceKeyMigration == nil)
    }

    @Test func onboardingFnModeDoesNotCreateVoiceKeyMigrationNotice() throws {
        let suiteName = "RemoteMicTests.Onboarding.FnOnlyPolicyNotice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .function
        settings.setOnboardingVoiceTool(.doubao)
        settings.restartOnboarding()

        #expect(settings.pendingOnboardingVoiceKeyMigration == nil)
    }

    @Test func typelessUsesFnTapOnlyAfterItsPairingPlanIsStaged() throws {
        let suiteName = "RemoteMicTests.Onboarding.TypelessFnMode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .leftCommand
        settings.setOnboardingVoiceTool(.typeless)

        #expect(settings.voiceKeyMode == .leftCommand)
        #expect(!settings.voiceFnTapModeEnabled)
        settings.setOnboardingControlSource(.xiaomiRemote)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .xiaomiRemote
        ))
        settings.beginOnboardingVoiceTrial(plan)
        #expect(settings.voiceKeyMode == .function)
        #expect(settings.voiceFnTapModeEnabled)
        #expect(OnboardingVoiceTool.typeless.applicationBundleIdentifier == "now.typeless.desktop")

        defaults.set(true, forKey: AppSettings.agentConfigurationPendingKey)
        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.stagedVoiceToolBinding == plan.binding)
        #expect(resumed.voiceKeyMode == .function)
        resumed.discardOnboardingVoiceTrial()
        #expect(resumed.stagedVoiceToolBinding == nil)
    }

    @Test func inputMethodSetupUsesProductionScreenshotsAndSafeScreenshotOverrides() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingScreenshotRenderer.swift"),
            encoding: .utf8
        )
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        #expect(!viewSource.contains("onboardingVoiceKeyControl\n"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_VOICE_KEY_MODE"))
        #expect(!viewSource.contains("selectOnboardingVoiceKeyMode"))
        #expect(viewSource.contains("binding_policy=function_key"))
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        for resourceName in [
            "doubao-menu", "doubao-settings", "weixin-input-menu",
            "weixin-input-settings", "system-fn", "weixin-app-shortcuts",
            "vokie-step-1", "vokie-step-2",
        ] {
            #expect(viewSource.contains(resourceName))
            for appearance in ["light", "dark"] {
                #expect(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "Resources/Onboarding/\(resourceName)-\(appearance).png"
                    ).path
                ))
            }
        }
        #expect(viewSource.contains("refreshSelectedInputMethodStatus()"))
        #expect(viewSource.contains("activateSelectedInputMethod()"))
        #expect(viewSource.contains("OnboardingInputSourceSwitcher.selectIfNeeded(tool)"))
        #expect(viewSource.contains("OnboardingInputSourceSwitcher.selectionState(for: tool)"))
        #expect(viewSource.contains("ensureSelectedVoiceToolRunning()"))
        #expect(!viewSource.contains("voiceToolSortRank"))
        #expect(!viewSource.contains("\n            ScrollView {"))
        #expect(viewSource.contains("GridItem(.flexible(), spacing: 8, alignment: .top)"))
        #expect(viewSource.contains("minHeight: tool == .vokie ? 108 : 100, alignment: .top"))
        #expect(!viewSource.contains("minHeight: 120, maxHeight: 120, alignment: .top"))
        #expect(!viewSource.contains(".lineLimit(3, reservesSpace: true)"))
        #expect(viewSource.contains(".frame(minHeight: 54)"))
        #expect(viewSource.contains("let physicalColumns = [GridItem(.flexible())]"))
        #expect(viewSource.contains("columns: physicalColumns"))
        #expect(viewSource.contains("inputMethodGuide(for: settings.onboardingVoiceTool)"))
        #expect(viewSource.contains("content: .systemFunctionKey"))
        #expect(viewSource.contains("onboarding.voice_tool.guide.release_system_fn"))
        #expect(viewSource.contains("allRecognizedVoiceToolsUnavailable"))
        #expect(viewSource.contains("onboarding.voice_tool.none_detected"))
        #expect(viewSource.contains("onboarding.voice_tool.other.setup_detail"))
        #expect(viewSource.contains("onboarding.voice_test.configuration.detail"))
        #expect(viewSource.contains("externalToolConfigurationConfirmationCard"))
        #expect(viewSource.contains("externalToolVoiceKeyConfirmed"))
        #expect(viewSource.contains("externalToolGlobalVoiceConfirmed"))
        #expect(viewSource.contains("externalToolMicrophoneConfirmed"))
        #expect(viewSource.contains("if voiceToolAvailability[.doubao] == .notInstalled"))
        #expect(!viewSource.contains("settings.onboardingVoiceTool == .doubao,\n"))
        #expect(viewSource.contains("localization.text(settings.onboardingVoiceTool.titleKey)"))
        #expect(rendererSource.contains("allowsInputSourceSwitching: false"))
        #expect(rendererSource.contains(
            "systemFunctionKeyAvailableOverride: systemFunctionKeyAvailable"
        ))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_GUIDE_STEP"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_SYSTEM_FN_AVAILABLE"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_METHOD"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_SOURCE"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_APPLE_REMOTE_GENERATION"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_ALL_VOICE_TOOLS_UNAVAILABLE"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_LANGUAGE"))
        #expect(rendererSource.contains("Unsupported screenshot language"))
        #expect(rendererSource.contains(".remoteAvailability"))
        #expect(rendererSource.contains("let controlSource = requestedControlSource"))
        #expect(rendererSource.contains("settings.setOnboardingControlSource(controlSource)"))
        #expect(rendererSource.contains("return \"control-source\""))
        #expect(rendererSource.contains("case .voiceTest, .controls, .complete:"))
        #expect(rendererSource.contains("DoubaoAudioDevicePolicy.deviceUID"))
        #expect(buildSource.contains("$ROOT/Resources/Onboarding"))
        #expect(verifySource.contains("Resources/Onboarding/*.png(N)"))
    }

    @Test func voiceTestReacquiresInputFocusAndRejectsManualKeyboardText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains(".onAppear {\n                    requestTranscriptFocus()"))
        #expect(viewSource.contains("case .voiceTest:\n                requestTranscriptFocus()"))
        #expect(!viewSource.contains("case .voiceTest:\n                switchToSelectedInputMethod()"))
        #expect(viewSource.contains("case .voiceTest:\n            refreshSelectedVoiceToolRuntimeState()\n            ensureSelectedVoiceToolRunning()"))
        #expect(viewSource.contains("guard settings.onboardingStep == .voiceTool else { return }"))
        #expect(viewSource.contains("private func requestTranscriptFocus()"))
        #expect(viewSource.contains("transcriptFocusRequest &+= 1"))
        #expect(viewSource.contains("window.makeFirstResponder(textView)"))
        #expect(viewSource.contains(".font(.system(size: 15))\n                        .foregroundStyle(.tertiary)\n                        .padding(.horizontal, 15)\n                        .padding(.vertical, 10)"))
        #expect(viewSource.contains(".onChange(of: transcript)"))
        #expect(!viewSource.contains(".onChange(of: transcript) { _, updatedText in"))
        #expect(viewSource.contains("OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput"))
        #expect(viewSource.contains("verifiedTranscriptionAppeared &&"))
        #expect(viewSource.contains("selectedVoiceToolRuntimeReady"))
        #expect(viewSource.contains("externalToolConfigurationConfirmed"))
        #expect(viewSource.contains("sayAllVoiceKeyConfigurationReady"))
        #expect(viewSource.contains("sayAllAudioOutputConfigurationText"))
        // 音频输出那一行现在独立在核对卡外，就绪时绿勾、未就绪时红叉。
        #expect(viewSource.contains(".foregroundStyle(onboardingAudioReady ? Color.green : Color.red)"))
        #expect(viewSource.contains(".eventSourceStateID"))
        #expect(viewSource.contains(".eventSourceUnixProcessID"))
        #expect(viewSource.contains("manualTranscriptInputObserved = true"))
        #expect(viewSource.contains("ONBOARDING TRANSCRIPT manual_keyboard_input=true"))
        #expect(viewSource.contains("voiceSessionStarted = true"))
        #expect(viewSource.contains("transcript = \"\""))
        #expect(viewSource.contains("transcriptCommitRequest &+= 1"))
        #expect(viewSource.contains("textView.unmarkText()"))
        #expect(viewSource.contains("!textView.hasMarkedText"))
        #expect(viewSource.contains("restored_after_voice_release=true"))
        #expect(viewSource.contains("scheduleVoiceCompletionEvaluation(attemptID: voiceAttempt.attemptID)"))
        #expect(viewSource.contains("voiceAttempt.audioDelivery.result == .deliveredToSelectedDevice"))
    }

    @Test func voiceTestExplainsAndExposesLiveGainAdjustment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("onboardingGainCard"))
        #expect(viewSource.contains("onboarding.voice_test.gain.title"))
        #expect(viewSource.contains("onboarding.voice_test.gain.detail"))
        #expect(viewSource.contains("in: 0...24"))
        #expect(viewSource.contains("onboarding.voice-test.gain"))
        #expect(viewSource.contains("settings.gainDB = min(24, max(0, $0))"))
        #expect(viewSource.contains("ONBOARDING GAIN editing="))
    }

    @Test func ordinaryButtonDetectionDoesNotExecuteExistingMappings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        #expect(modelSource.contains("OnboardingControlValidationPolicy.suppressConfiguredActions"))
        #expect(modelSource.contains("ONBOARDING CONTROLS"))
        #expect(modelSource.contains("source=apple_remote action=suppressed"))
        #expect(modelSource.contains("source=chromecast action=suppressed"))
        #expect(modelSource.contains("performMobileConfiguredAction"))
    }

    @Test func secureInputWarningUsesOnlyPublicBooleanSignal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SecureInputMonitor.swift"),
            encoding: .utf8
        )
        #expect(monitorSource.contains("IsSecureEventInputEnabled()"))
        #expect(!monitorSource.contains("IORegistry"))
        #expect(!monitorSource.contains("processIdentifier"))
    }

    @Test @MainActor func markedTranscriptTextCanBeCommittedWithoutChangingItsVisibleText() {
        let textView = NSTextView(frame: .zero)
        textView.setMarkedText(
            "测试文字",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        #expect(textView.hasMarkedText())
        #expect(textView.string == "测试文字")
        textView.unmarkText()
        #expect(!textView.hasMarkedText())
        #expect(textView.string == "测试文字")
    }

    @Test func voiceTestConfigurationOnlyRequiresGlobalVoiceForDoubao() {
        #expect(OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .doubao))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .weixin))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .typeless))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .vokie))
        #expect(!OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(for: .other))
    }

    @Test func globalVoiceSupportIsUnknownForToolsWeNeverObserved() {
        // `.other` / `.unselected` 没有观察过设置界面，标记为未知，页面就不追问——
        // 否则会让用户去找一个自己工具里并不存在的开关。
        #expect(VoiceToolAdapterProfile.profile(for: .doubao).globalActivationSupport == true)
        #expect(VoiceToolAdapterProfile.profile(for: .weixin).globalActivationSupport == false)
        #expect(VoiceToolAdapterProfile.profile(for: .typeless).globalActivationSupport == false)
        #expect(VoiceToolAdapterProfile.profile(for: .vokie).globalActivationSupport == false)
        #expect(VoiceToolAdapterProfile.profile(for: .other).globalActivationSupport == nil)
        #expect(VoiceToolAdapterProfile.profile(for: .unselected).globalActivationSupport == nil)
    }

    @Test func holdOnlyRemoteAndToggleOnlyToolBridgeThroughFunctionTap() throws {
        // Siri Remote / 小米遥控器 只有按住；Typeless 只有按一下。两边交集为空，
        // 靠 Fn 点按把一次长按换算成「按一下开始、再按一下结束」。
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .siriRemote,
            forceFunctionKey: true
        ))
        #expect(plan.binding.gestureMode == .toggle)
        #expect(plan.fnTapModeEnabled)

        // 反过来：豆包两种手势都支持，配上只能按住的遥控器仍然保持按住，不需要换算。
        let doubao = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .doubao,
            controlSource: .siriRemote,
            forceFunctionKey: true
        ))
        #expect(doubao.binding.gestureMode == .hold)
        #expect(!doubao.fnTapModeEnabled)
    }

    @Test func voiceTestGestureCheckboxFollowsTheResolvedGesture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        // 遥控器可能只能按住，语音工具可能只能按一下。勾选项必须和提示条同源于
        // plan.binding.gestureMode，否则会出现「上面说按一下、下面让你确认按住」。
        #expect(source.contains("private var resolvedVoiceGestureMode: VoiceGestureMode"))
        #expect(source.contains("proposedPairingPlan?.binding.gestureMode\n            ?? settings.onboardingPreferredGesture"))
        #expect(source.contains("\"onboarding.voice_test.configuration.gesture_checkbox.hold\""))
        #expect(source.contains("\"onboarding.voice_test.configuration.gesture_checkbox.toggle\""))
        #expect(!source.contains("\"onboarding.voice_test.configuration.voice_gesture_checkbox\""))
        #expect(source.contains("bridgedGestureHintVisible"))
        #expect(source.contains("proposedPairingPlan?.fnTapModeEnabled == true"))
    }

    @Test func voiceTestFailureHintOnlyMentionsGlobalActivationWhenTheToolHasIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        // 微信输入法 / Typeless / Vokie 没有「全局唤起语音」，失败提示不能把它们指向那个开关。
        #expect(source.contains("\"onboarding.voice_test.configuration.no_commit.no_global\""))
        #expect(source.contains("let key = externalToolGlobalVoiceConfirmationRequired"))
        #expect(chinese.contains("\"onboarding.voice_test.configuration.no_commit.no_global\""))
        #expect(english.contains("\"onboarding.voice_test.configuration.no_commit.no_global\""))
        // 中文那条通用提示原先写死了「全局唤起」，现在只剩豆包那条允许出现该词。
        #expect(!chinese.contains("重新核对上面的语音输入方式、全局唤起和麦克风设置"))
    }

    @Test func voiceTestDropsKeysNoViewEverRendered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        for key in [
            "\"onboarding.voice_test.configuration.binding_expected\"",
            "\"onboarding.voice_test.microphone_confirmation.title\"",
            "\"onboarding.voice_test.microphone_confirmation.detail\"",
            "\"onboarding.voice_test.other_detail\"",
        ] {
            #expect(!chinese.contains(key))
            #expect(!english.contains(key))
        }
    }

    @Test func audioOutputStatusSitsOutsideTheToolChecklistCard() throws {
        // 「音频输出设备」讲的是这一侧把声音送到哪个设备，语音工具并不知道这一行。
        // 它挂在「测试前在 X 里核对」的标题下面，会被读成「去语音工具里核对音频输出设备」。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let cardStart = try #require(source.range(
            of: "private var externalToolConfigurationConfirmationCard"
        ))
        let cardEnd = try #require(source.range(
            of: "private var externalToolAudioOutputRow",
            range: cardStart.upperBound..<source.endIndex
        ))
        let cardBody = String(source[cardStart.lowerBound..<cardEnd.lowerBound])
        #expect(!cardBody.contains("sayall_audio_output"))
        #expect(!cardBody.contains("configurationStatusRow"))
        // 它必须在卡片之前出现——先确认声音从哪出去，再核对对方要用的名字。
        #expect(source.contains("externalToolAudioOutputRow\n\n            externalToolConfigurationConfirmationCard"))
        #expect(source.contains("private var externalToolAudioOutputRow: some View"))
    }

    @Test func iphoneAppPermissionRowUsesTheSameStatusMarkAsOtherPermissions() throws {
        // 权限清单里第 4 项是唯一「勾选后自己变绿」的行，其余三项是「点进去授权、回来后变绿」。
        // 语义不同，但右侧状态标记必须是同一种——同一份清单里出现圆勾和方勾两种形态，
        // 用户会以为是两类不同的控件。曾自绘过 20pt 圆角方框，已改回圆形。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let rowStart = try #require(source.range(of: "private var iphoneAppInstalledRow"))
        let rowEnd = try #require(source.range(
            of: "private func statusCard(",
            range: rowStart.upperBound..<source.endIndex
        ))
        let rowBody = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
        #expect(rowBody.contains("Image(systemName: confirmed ? \"checkmark.circle.fill\" : \"circle\")"))
        #expect(rowBody.contains(".font(.system(size: 19))"))
        #expect(!rowBody.contains("checkboxMark"))
        #expect(!source.contains("func checkboxMark"))
    }

    @Test func remotePageDoesNotRepeatTheAppStoreInstallLink() throws {
        // 连接 iPhone 那一屏右侧已经有 App Store 二维码和官方徽章，
        // 左栏再来一个「从 App Store 安装无线麦 SayAll」按钮是把同一件事说两遍。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("\"iphone.install\""))
        #expect(!source.contains("onboarding.apple_companion.install"))

        let contentStart = try #require(source.range(of: "private var iPhoneRemoteContent"))
        let contentEnd = try #require(source.range(
            of: "private var webRemoteContent",
            range: contentStart.upperBound..<source.endIndex
        ))
        let contentBody = String(source[contentStart.lowerBound..<contentEnd.lowerBound])
        #expect(!contentBody.contains("onboardingLink"))
        #expect(!contentBody.contains("iOSAppStore"))
    }

    @Test func onboardingCallsTheCompanionAppIOSApp() throws {
        // 同一个 App 在文案里不能既叫「iPhone App」又叫「iOS App」——
        // iPhone 只是它运行的其中一台设备，叫 iOS App 才不会把 iPad 用户挡在门外。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for resource in ["zh-Hans", "en"] {
            let text = try String(
                contentsOf: root.appendingPathComponent(
                    "Resources/\(resource).lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            #expect(!text.contains("iPhone App"))
            #expect(!text.contains("iPhone app"))
        }
        let zh = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(zh.contains("\"onboarding.permissions.iphone_app_installed.title\" = \"我已安装 iOS App\";"))
        let en = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(en.contains("\"onboarding.permissions.iphone_app_installed.title\" = \"I already installed the iOS app\";"))
    }

    @Test func phoneRemoteMembershipGateIsShownBeforeTheAppStoreQRCode() throws {
        // 手机 / 手表这条连接是要会员的（和小程序路径一致）。
        // 这一屏原来的分支顺序是：邀请二维码 → App Store 二维码 → 会员门禁 → 占位图标。
        // App Store 二维码永远存在，会员分支永远轮不到；门禁那边还额外要求
        // supportsRemoteSessionAuthorization（公开构建里恒为 false），
        // 于是被会员挡住的用户只会看到一张永远扫不上的二维码。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let illustrationStart = try #require(source.range(of: "private var iPhoneRemoteIllustration"))
        let illustrationEnd = try #require(source.range(
            of: "private func appStoreDownloadEntry",
            range: illustrationStart.upperBound..<source.endIndex
        ))
        let body = String(source[illustrationStart.lowerBound..<illustrationEnd.lowerBound])
        let gateIndex = try #require(body.range(of: "model.phoneRemoteState == .membershipRequired"))
        let storeIndex = try #require(body.range(of: "appStoreDownloadQRCode != nil"))
        #expect(gateIndex.lowerBound < storeIndex.lowerBound)
        // 门禁视图不能再被「私有会员模块在不在」挡住。
        #expect(!body.contains("supportsRemoteSessionAuthorization"))
    }

    @Test func phoneRemoteConnectionRecordsTheMembershipBlockInsteadOfFailingSilently() throws {
        // 被门禁挡住时必须留下状态和日志：之前只是静默 return，
        // 不写状态、不记日志，界面上什么变化都没有，用户只会一直等。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let start = try #require(modelSource.range(of: "func enablePhoneRemoteConnection()"))
        let end = try #require(modelSource.range(
            of: "func disablePhoneRemoteConnection()",
            range: start.upperBound..<modelSource.endIndex
        ))
        let body = String(modelSource[start.lowerBound..<end.lowerBound])
        #expect(body.contains("phoneRemoteState = .membershipRequired"))
        #expect(body.contains("PHONE REMOTE blocked_by_membership"))
        #expect(!body.contains("objectWillChange.send()"))
        // 会员门禁要排在「运行时是否已启动」之前：门禁是产品结论，与运行时无关；
        // 先判运行时的话状态永远记不下来，界面也就没有东西可显示。
        let gateIndex = try #require(body.range(of: "canStartCompanionConnection"))
        let startedIndex = try #require(body.range(of: "guard started"))
        #expect(gateIndex.lowerBound < startedIndex.lowerBound)
    }

    @Test @MainActor func phoneRemoteConnectionIsBlockedByMembership() throws {
        let suiteName = "RemoteMicTests.Onboarding.PhoneMembership.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        model.enablePhoneRemoteConnection()
        if model.membershipFeature.canStartCompanionConnection {
            // 有会员权益时不该进门禁状态。
            #expect(model.phoneRemoteState != .membershipRequired)
        } else {
            #expect(model.phoneRemoteState == .membershipRequired)
        }
    }

    @Test func theMembershipEntryIsTheOnlyOneInTheApp() throws {
        // 会员按钮全 App 只有一个：私有会员模块提供的那个「会员功能，点击开通」。
        // 仓库曾另画一个不依赖私有模块的「通用会员按钮」，那会变成两个入口，
        // 而且两套文案会互相打架，已撤掉。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("genericMembershipRequiredView"))
        #expect(!source.contains("onboarding.membership.open"))
        #expect(!source.contains("iphone.membership.open"))
        #expect(!source.contains("onboarding.membership.required_title"))
        // 手机路径和小程序路径共用同一个入口。
        #expect(source.contains("private var companionMembershipRequiredView"))
        let illustrationStart = try #require(source.range(of: "private var iPhoneRemoteIllustration"))
        let illustrationEnd = try #require(source.range(
            of: "private func appStoreDownloadEntry",
            range: illustrationStart.upperBound..<source.endIndex
        ))
        let body = String(source[illustrationStart.lowerBound..<illustrationEnd.lowerBound])
        #expect(body.contains("companionMembershipRequiredView"))
        #expect(!body.contains("membershipRequiredView("))
    }

    @Test @MainActor func iphoneRemotePageEntersTheMembershipState() throws {
        let iPhone = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { iPhone.close() }
        // 这一屏确实进入了会员门禁状态，右栏才会走会员那一行而不是二维码。
        #expect(iPhone.model.phoneRemoteState == .membershipRequired)
        // 仓库不另画会员按钮：这里不应出现任何仓库自有的会员动作。
        #expect(iPhone.probe.actions["iphone.membership.open"] == nil)
        #expect(iPhone.probe.actions["membership.open"] == nil)
        // 橙色恢复卡在门禁态下不出现，它的「重新连接」动作也不该注册：
        // 改动前这张卡是显示的（截图里能看到），现在右栏会员入口才是下一步。
        #expect(iPhone.probe.actions["recovery.remoteNotFound"] == nil)
    }

    @Test func appleCompanionPageSaysItIsAMemberFeatureInTheLeftColumn() throws {
        // 小程序页面在会员态会把左栏状态卡标题换成「此连接需要 Plus 会员」
        // （webRemoteConnectionTitle → connection.web.plus_required_title）。
        // iPhone / Apple Watch 页面要一致：被会员门禁挡住时，左栏也写明这是会员功能，
        // 右栏再给出唯一的那个「点击开通会员功能」按钮。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let contentStart = try #require(source.range(of: "private var iPhoneRemoteContent"))
        let contentEnd = try #require(source.range(
            of: "private var appleCompanionConnectionTitle",
            range: contentStart.upperBound..<source.endIndex
        ))
        let content = String(source[contentStart.lowerBound..<contentEnd.lowerBound])
        // 左栏状态卡标题改由会员态决定，不再直接写死「等待 iPhone 或 Apple Watch」。
        #expect(content.contains("appleCompanionConnectionTitle"))
        #expect(!content.contains("onboarding.apple_companion.waiting"))
        // 说明文字同样随门禁切换：门禁下连接服务没启动，
        // 「保持 App 打开并完成当前 Mac 的连接」是用户此刻做不到的事。
        #expect(content.contains("appleCompanionConnectionDetail"))
        #expect(!content.contains("onboarding.apple_companion.connection_detail"))
        // 第二张卡（请在已连接的设备上按一个控制键）在门禁态下也是做不到的指引。
        #expect(content.contains("model.phoneRemoteState != .membershipRequired"))
        // 门禁态下左栏留一个重新发起连接的按钮，做法与小程序页的 `web.retry` 一致。
        #expect(content.contains("id: \"phone.retry\""))
        #expect(content.contains("model.enablePhoneRemoteConnection()"))

        let titleStart = try #require(source.range(of: "private var appleCompanionAccessReady"))
        let titleEnd = try #require(source.range(
            of: "private var webRemoteContent",
            range: titleStart.upperBound..<source.endIndex
        ))
        let title = String(source[titleStart.lowerBound..<titleEnd.lowerBound])
        #expect(title.contains("onboarding.apple_companion.membership_title"))
        let membershipIndex = try #require(title.range(of: "onboarding.apple_companion.membership_title"))
        let waitingIndex = try #require(title.range(of: "onboarding.apple_companion.waiting"))
        #expect(membershipIndex.lowerBound < waitingIndex.lowerBound)
        // 说明文字：门禁下给下一步，其余保持原来的连接指引。
        #expect(title.contains("onboarding.apple_companion.membership_detail"))
        #expect(title.contains("onboarding.apple_companion.connection_detail"))
        // 门禁文案要同时看「连接状态」和「会员权益」：只看状态的话，
        // 权益开通后回到这页仍会写「此连接是会员功能」。
        #expect(title.contains("appleCompanionConnectionIsBlocked"))
        #expect(title.contains("model.phoneRemoteState == .membershipRequired && !appleCompanionAccessReady"))

        // 参考的小程序页面本身仍然是「会员态换标题」那套写法。
        #expect(source.contains("connection.web.plus_required_title"))
    }

    @Test @MainActor func iphoneRemotePageOffersTheRetryThatTheMiniProgramPageHas() throws {
        // 小程序页在会员态下左栏一直有「重新生成二维码」（web.retry），会员开通回来
        // 点一下就能重新过门禁；手机页原来没有任何重试入口，只能切后台、返回上一步
        // 或重开 App 才会重试。这里补上同一个机制。
        let iPhone = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { iPhone.close() }
        #expect(iPhone.model.phoneRemoteState == .membershipRequired)
        #expect(iPhone.probe.actions["phone.retry"] != nil)

        let web = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .webRemote,
            voiceTool: .doubao
        )
        defer { web.close() }
        #expect(web.probe.actions["web.retry"] != nil)
    }

    @Test @MainActor func appleCompanionRetryGoesThroughTheMembershipGateAgain() throws {
        // 「重试连接」必须是真重跑门禁，不是空按钮：门禁没放开时仍是门禁态，
        // 放开时才启动连接服务。这条同时锁住「不会再变成静默 return」。
        let suiteName = "RemoteMicTests.Onboarding.PhoneRetry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        model.enablePhoneRemoteConnection()
        let afterFirstAttempt = model.phoneRemoteState
        model.enablePhoneRemoteConnection()
        if model.membershipFeature.canStartCompanionConnection {
            #expect(model.phoneRemoteState != .membershipRequired)
        } else {
            #expect(model.phoneRemoteState == .membershipRequired)
            #expect(afterFirstAttempt == .membershipRequired)
        }
    }

    @Test func webRemotePageSwitchesItsCopyWithTheMembershipEntitlement() throws {
        // 小程序这屏原来只看 `webRemoteState`：门禁态写死「此连接需要 Plus 会员」，
        // 说明写死「二维码是临时的…」。开通会员后状态不会变，于是文案也不变——
        // 刚开完会员的人回来看到的还是「需要 Plus」。
        // 现在两边都随权益切换：真被挡 → Plus 标题 + 开通说明；
        // 权益已放开、只差重新生成会话 → 「下一步生成二维码」。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let contentStart = try #require(source.range(of: "private var webRemoteContent"))
        let contentEnd = try #require(source.range(
            of: "private func controllerButtonStatusCard",
            range: contentStart.upperBound..<source.endIndex
        ))
        let content = String(source[contentStart.lowerBound..<contentEnd.lowerBound])
        // 状态卡的说明不再写死。
        #expect(content.contains("detail: webRemoteConnectionDetail"))
        #expect(!content.contains("\"onboarding.web_remote.connection_detail\""))
        // 重试入口照旧在（`web.retry`，条件仍是会话没起来）。
        #expect(content.contains("id: \"web.retry\""))
        #expect(content.contains("!model.webRemoteState.isEnabled"))

        let titleStart = try #require(source.range(of: "private var webRemoteConnectionTitle"))
        let titleEnd = try #require(source.range(
            of: "private var webRemoteConnectionIsBlocked",
            range: titleStart.upperBound..<source.endIndex
        ))
        let title = String(source[titleStart.lowerBound..<titleEnd.lowerBound])
        #expect(title.contains("webRemoteConnectionIsBlocked"))
        #expect(title.contains("connection.web.plus_required_title"))
        #expect(title.contains("onboarding.web_remote.preparing"))
        // 标题这一格不再写死「需要 Plus」。
        #expect(!title.contains("return localization.text(\"connection.web.plus_required_title\")"))

        let detailStart = try #require(source.range(of: "private var webRemoteConnectionIsBlocked"))
        let detailEnd = try #require(source.range(
            of: "private var selectedControlConnectedKey",
            range: detailStart.upperBound..<source.endIndex
        ))
        let detail = String(source[detailStart.lowerBound..<detailEnd.lowerBound])
        // 说明同样随权益切换：被挡给开通指引，其余给原来的二维码说明。
        #expect(detail.contains("onboarding.web_remote.membership_detail"))
        #expect(detail.contains("onboarding.web_remote.connection_detail"))
        // 服务端判定（`.plusRequired`）要一直被算作被挡：本地权益对了也不该放过。
        #expect(detail.contains("case .plusRequired:"))
        #expect(detail.contains("return !membershipFeature.canStartCompanionConnection"))
    }

    @Test func webRemoteMembershipCopyExistsInBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(chinese.contains(
            "\"onboarding.web_remote.membership_detail\" = \"开通会员后即可连接；右侧按钮可直接开通。\";"
        ))
        #expect(english.contains(
            "\"onboarding.web_remote.membership_detail\" = \"Open the membership to connect. Use the button on the right.\";"
        ))
        // 权益放开后要用的那句「下一步生成二维码」也得在两边。
        #expect(chinese.contains("\"onboarding.web_remote.preparing\" = \"下一步生成二维码\";"))
        #expect(english.contains("\"onboarding.web_remote.preparing\" = \"Next, generate a QR code\";"))
    }

    @Test func membershipRetryListensOnceAndIsDisarmedAfterwards() throws {
        // 正向监听不能是常驻订阅：只在门禁挡住时挂一条，命中「放开」立刻断开，
        // 用户离开这条路径（disable / App stop / 切服务环境）也要断开。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        for armName in ["armPhoneRemoteMembershipRetry", "armWebRemoteMembershipRetry"] {
            let start = try #require(modelSource.range(of: "private func \(armName)"))
            let end = try #require(modelSource.range(
                of: armName == "armPhoneRemoteMembershipRetry"
                    ? "private func cancelPhoneRemoteMembershipRetry"
                    : "private func cancelWebRemoteMembershipRetry",
                range: start.upperBound..<modelSource.endIndex
            ))
            let body = String(modelSource[start.lowerBound..<end.lowerBound])
            // 只等第一个 true 就结束，而不是把每次变化都处理一遍。
            #expect(body.contains(".first(where: { $0 })"))
            // 权益已经放开时不挂，否则 first 会立刻命中当前值造成反复重试。
            #expect(body.contains("!membershipFeature.canUseCompanionConnections"))
            // 命中后自己断开。
            #expect(body.contains("= nil"))
        }
        // disable 必须取消，而且要放在 guard 之前：门禁态下 isPhoneRemoteConnectionEnabled
        // 是 false，被 guard 挡住就漏掉了这条监听。
        let disableStart = try #require(modelSource.range(of: "func disablePhoneRemoteConnection()"))
        let disableEnd = try #require(modelSource.range(
            of: "func togglePhoneRemoteConnection()",
            range: disableStart.upperBound..<modelSource.endIndex
        ))
        let disable = String(modelSource[disableStart.lowerBound..<disableEnd.lowerBound])
        let cancelIndex = try #require(disable.range(of: "cancelPhoneRemoteMembershipRetry()"))
        let guardIndex = try #require(disable.range(of: "guard isPhoneRemoteConnectionEnabled"))
        #expect(cancelIndex.lowerBound < guardIndex.lowerBound)
        // 小程序路径在外层也被统一取消（App stop、切服务环境）。
        #expect(modelSource.contains("cancelWebRemoteMembershipRetry()"))
    }

    @Test @MainActor func membershipRetryIsArmedOnlyWhileTheGateBlocks() throws {
        let suiteName = "RemoteMicTests.Onboarding.RetryArmed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        // 一开始没有任何监听挂着。
        #expect(!model.isPhoneMembershipRetryArmed)
        #expect(!model.isWebMembershipRetryArmed)
        model.enablePhoneRemoteConnection()
        if model.membershipFeature.canStartCompanionConnection {
            // 权益可用时不装监听。
            #expect(!model.isPhoneMembershipRetryArmed)
        } else {
            #expect(model.isPhoneMembershipRetryArmed)
            // 反复调用只挂一条，不会叠加。
            model.enablePhoneRemoteConnection()
            model.enablePhoneRemoteConnection()
            #expect(model.isPhoneMembershipRetryArmed)
            // 离开这条路径就断开。
            model.disablePhoneRemoteConnection()
            #expect(!model.isPhoneMembershipRetryArmed)
        }
    }

    @Test func membershipGateSuppressesTheRecoveryCard() throws {
        // 门禁下橙色恢复卡给的补救办法（重开 App、重新连接）都不成立：
        // 连接服务压根没启动，重连还是会被挡。真正的原因和下一步在右栏会员入口那里。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func shouldShowStandaloneRecoveryCard"))
        let end = try #require(source.range(
            of: "private func recoveryDetailKey",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        #expect(body.contains("onboardingControlMethod == .iPhoneApp"))
        #expect(body.contains("model.phoneRemoteState == .membershipRequired"))
        // 物理遥控器那条既有判断不能被顺手改掉。
        #expect(body.contains("onboardingControlMethod == .physicalRemote"))
    }

    @Test func appleCompanionMembershipCopyExistsInBothLanguages() throws {
        // 左栏那句「这是会员功能」和它下面的下一步说明，中英都要有，
        // 且不能是空串或占位符。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(chinese.contains(
            "\"onboarding.apple_companion.membership_title\" = \"此连接是会员功能\";"
        ))
        #expect(chinese.contains(
            "\"onboarding.apple_companion.membership_detail\" = \"开通会员后即可连接；右侧按钮可直接开通。\";"
        ))
        #expect(english.contains(
            "\"onboarding.apple_companion.membership_title\" = \"This connection is a member feature\";"
        ))
        #expect(english.contains(
            "\"onboarding.apple_companion.membership_detail\" = \"Open the membership to connect. Use the button on the right.\";"
        ))
        // 门禁态下的重试按钮文案也要两边都有。
        #expect(chinese.contains(
            "\"onboarding.apple_companion.retry\" = \"重试连接\";"
        ))
        #expect(english.contains(
            "\"onboarding.apple_companion.retry\" = \"Retry connection\";"
        ))
    }

    @Test func voiceTestConfigurationCopyDoesNotPromiseAFixedNumberOfChecks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        // 勾选条数由能力字段决定：豆包三条，微信 / Typeless / Vokie 只有两条。
        // 文案里写死数量会在多数工具上自相矛盾，所以标题和说明都不许出现计数。
        // 只查这两个键：别的页面写「三项权限」是准确的事实描述，不该被这条规则波及。
        for (strings, banned) in [
            (chinese, ["核对这三项", "三条都勾上", "这三条"]),
            (english, ["these three", "all three", "the three"]),
        ] {
            for key in [
                "onboarding.voice_test.configuration.title",
                "onboarding.voice_test.configuration.detail",
            ] {
                let line = try #require(strings.split(separator: "\n").first {
                    $0.hasPrefix("\"\(key)\"")
                })
                for fragment in banned {
                    #expect(!line.lowercased().contains(fragment.lowercased()))
                }
            }
        }
    }

    @Test func selectingVoiceToolDoesNotChangeInputSourceOrReorderCards() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let selectionStart = try #require(source.range(of: "private func selectVoiceTool"))
        let selectionEnd = try #require(source.range(
            of: "private func selectVoiceBindingPreference",
            range: selectionStart.upperBound..<source.endIndex
        ))
        let selectionBody = String(source[selectionStart.lowerBound..<selectionEnd.lowerBound])
        #expect(selectionBody.contains("refreshSelectedInputMethodStatus()"))
        #expect(!selectionBody.contains("activateSelectedInputMethod()"))
        #expect(!selectionBody.contains("selectIfNeeded(tool)"))
        #expect(source.contains("OnboardingVoiceToolVisibilityPolicy.visibleTools"))
    }

    @Test @MainActor func uninstalledOptionalVoiceToolsAreHiddenWhileVokieRemainsVisible() throws {
        let unavailable: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [
            .doubao: .notInstalled,
            .weixin: .notInstalled,
            .vokie: .notInstalled,
            .typeless: .notInstalled,
            .other: .unknown,
        ]
        #expect(OnboardingVoiceToolVisibilityPolicy.visibleTools(availability: unavailable) == [
            .doubao, .vokie, .other,
        ])

        let fixture = try OnboardingOffscreenFixture(
            step: .voiceTool,
            voiceTool: .vokie,
            controlSource: .xiaomiRemote,
            voiceToolAvailability: unavailable
        )
        defer { fixture.close() }
        #expect(fixture.probe.actions["voice-tool.doubao"] != nil)
        #expect(fixture.probe.actions["voice-tool.vokie"] != nil)
        #expect(fixture.probe.actions["voice-tool.other"] != nil)
        #expect(fixture.probe.actions["voice-tool.weixin"] == nil)
        #expect(fixture.probe.actions["voice-tool.typeless"] == nil)

        var installed = unavailable
        installed[.weixin] = .available
        installed[.typeless] = .available
        #expect(OnboardingVoiceToolVisibilityPolicy.visibleTools(availability: installed) == [
            .doubao, .weixin, .vokie, .typeless, .other,
        ])
    }

    @Test func independentVoiceToolsAreAutoLaunchedAndMustBeRunningToComplete() throws {
        #expect(OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: .typeless))
        #expect(OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: .vokie))
        #expect(!OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: .doubao))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let canContinueStart = try #require(source.range(of: "private var canContinue"))
        let visibleToolsStart = try #require(source.range(
            of: "private var visibleVoiceTools",
            range: canContinueStart.upperBound..<source.endIndex
        ))
        let canContinueBody = String(source[canContinueStart.lowerBound..<visibleToolsStart.lowerBound])
        #expect(canContinueBody.contains("selectedVoiceToolRuntimeReady"))
        #expect(source.contains("ensureSelectedVoiceToolRunning()"))
        #expect(source.contains("onboarding.voice_tool.runtime.reopen"))
    }

    @Test func transcriptInputPolicyRejectsSyntheticAndUnknownEventSources() {
        #expect(OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: 0
        ))
        #expect(OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: -1
        ))

        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 11,
            sourceStateID: 1,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 0,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: -1,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 99,
            sourceUnixProcessID: 0
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: 42
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: nil,
            sourceStateID: nil,
            sourceUnixProcessID: nil
        ))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10,
            sourceStateID: 1,
            sourceUnixProcessID: nil
        ))
    }

    @Test func voiceSamplePresentationPublishesOnlyTheFirstNonemptyBatchPerSession() {
        var hasReceivedSamples = false
        var publicationCount = 0

        #expect(!VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedSamples,
            sampleCount: 0
        ))

        for _ in 0..<4_000 {
            if VoiceSamplePresentationPolicy.shouldPublishReceipt(
                hasReceivedSamples: hasReceivedSamples,
                sampleCount: 240
            ) {
                hasReceivedSamples = true
                publicationCount += 1
            }
        }

        #expect(hasReceivedSamples)
        #expect(publicationCount == 1)

        hasReceivedSamples = false
        #expect(VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedSamples,
            sampleCount: 240
        ))
    }

    @Test func mobileControlPathsPublishButtonsAndVoiceSamplesForTheSharedGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(modelSource.contains(
            "@Published private(set) var lastMobileRemoteButtonObservation"
        ))
        #expect(modelSource.contains(
            "@Published private(set) var activeVoiceSource: UsageEventSource?"
        ))
        #expect(modelSource.contains(
            "@Published private(set) var hasReceivedCurrentVoiceSamples = false"
        ))
        #expect(modelSource.components(separatedBy: "observeMobileButton(").count >= 7)

        let bluetoothAudioStart = try #require(modelSource.range(
            of: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16])"
        ))
        let bluetoothAudioEnd = try #require(modelSource.range(
            of: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel",
            range: bluetoothAudioStart.upperBound..<modelSource.endIndex
        ))
        let bluetoothAudioSource = modelSource[
            bluetoothAudioStart.lowerBound..<bluetoothAudioEnd.lowerBound
        ]
        let audioStart = try #require(modelSource.range(
            of: "private func receivePhoneAudio"
        ))
        let audioEnd = try #require(modelSource.range(
            of: "private func beginVoiceSessionIfNeeded",
            range: audioStart.upperBound..<modelSource.endIndex
        ))
        let audioSource = modelSource[audioStart.lowerBound..<audioEnd.lowerBound]
        let receiptCall = "publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: samples.count)"
        #expect(bluetoothAudioSource.contains(receiptCall))
        #expect(audioSource.contains(receiptCall))
        #expect(!modelSource.contains("currentVoiceSampleCount"))

        #expect(viewSource.contains(
            ".onReceive(model.$lastMobileRemoteButtonObservation.compactMap { $0 })"
        ))
        #expect(viewSource.contains("source == .nearbyPhone"))
        #expect(viewSource.contains("source == .webRemote"))
        #expect(viewSource.contains("selectedControlAcceptsVoice(model.activeVoiceSource)"))
        #expect(viewSource.contains("source == .bluetoothRemote"))
        #expect(viewSource.contains(
            "settings.onboardingControlMethod == .physicalRemote"
        ))
        #expect(viewSource.contains("model.isPhoneRemoteConnected"))
        #expect(viewSource.contains("model.phoneRemoteInvitation"))
        #expect(viewSource.contains("PhoneRemoteInvitationQRCode.image"))
        #expect(viewSource.contains("if case .connected = model.webRemoteState"))
        #expect(viewSource.contains(".onReceive(model.$isConnected.removeDuplicates())"))
        #expect(viewSource.contains(
            ".onReceive(model.$hasReceivedCurrentVoiceSamples.removeDuplicates())"
        ))
        #expect(viewSource.contains("routeConnectedPhysicalRemoteIfNeeded()"))
        #expect(viewSource.contains("selectControlSource(.xiaomiRemote)"))
    }

    @Test func rootViewObservesSettingsWithoutSubscribingToTheWholeBridgeModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicRootView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("let model: BridgeAppModel"))
        #expect(!source.contains("@ObservedObject var model: BridgeAppModel"))
        #expect(source.contains("@ObservedObject private var settings: AppSettings"))
    }

    @Test func observedRemoteButtonRequestsOnlyOneRecoveryWhileBluetoothIsDisconnected() {
        #expect(!OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: false,
            remoteButtonObserved: false,
            recoveryRequested: false
        ))
        #expect(!OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: true,
            remoteButtonObserved: true,
            recoveryRequested: false
        ))
        #expect(!OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: false,
            remoteButtonObserved: true,
            recoveryRequested: true
        ))
        #expect(OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: false,
            remoteButtonObserved: true,
            recoveryRequested: false
        ))
    }

    @Test func remoteRecoveryIsWiredToButtonObservationAndCanStartMissingBluetoothBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let buttonReceiveStart = try #require(viewSource.range(
            of: ".onReceive(model.$lastRemoteButtonPress.compactMap { $0 })"
        ))
        let buttonReceiveEnd = try #require(viewSource.range(
            of: ".onReceive(model.$isStreaming",
            range: buttonReceiveStart.upperBound..<viewSource.endIndex
        ))
        let buttonReceiveSource = viewSource[buttonReceiveStart.lowerBound..<buttonReceiveEnd.lowerBound]
        #expect(buttonReceiveSource.contains("recoverRemoteConnectionIfNeeded()"))

        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let reconnectStart = try #require(modelSource.range(of: "func reconnect()"))
        let reconnectEnd = try #require(modelSource.range(
            of: "func enablePhoneRemoteConnection()",
            range: reconnectStart.upperBound..<modelSource.endIndex
        ))
        let reconnectSource = modelSource[reconnectStart.lowerBound..<reconnectEnd.lowerBound]
        #expect(reconnectSource.contains("guard started else { return }"))
        #expect(reconnectSource.contains("bluetoothBridges.isEmpty && discoveryBluetoothBridge == nil"))
        #expect(reconnectSource.contains("startBluetoothConnections()"))
    }

    @Test func returningFromBluetoothSettingsRefreshesDiscovery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let activeStart = try #require(viewSource.range(
            of: "NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)"
        ))
        let activeEnd = try #require(viewSource.range(
            of: ".onReceive(model.$activeRemoteButtons)",
            range: activeStart.upperBound..<viewSource.endIndex
        ))
        let activeSource = viewSource[activeStart.lowerBound..<activeEnd.lowerBound]
        #expect(activeSource.contains("prepareSelectedControlConnection()"))

        let prepareStart = try #require(viewSource.range(
            of: "private func prepareSelectedControlConnection()"
        ))
        let prepareEnd = try #require(viewSource.range(
            of: "private func selectedControlAccepts",
            range: prepareStart.upperBound..<viewSource.endIndex
        ))
        let prepareSource = viewSource[prepareStart.lowerBound..<prepareEnd.lowerBound]
        #expect(prepareSource.contains("model.refreshRemoteDiscovery()"))
        #expect(prepareSource.contains("model.applyHIDSettings()"))

        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let refreshStart = try #require(modelSource.range(of: "func refreshRemoteDiscovery()"))
        let refreshEnd = try #require(modelSource.range(
            of: "func enablePhoneRemoteConnection()",
            range: refreshStart.upperBound..<modelSource.endIndex
        ))
        let refreshSource = modelSource[refreshStart.lowerBound..<refreshEnd.lowerBound]
        #expect(refreshSource.contains("discoveryBluetoothBridge?.reconnectNow()"))
    }

    @Test func returningToAudioSetupRefreshesAvailableOutputs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let activeStart = try #require(viewSource.range(
            of: "NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)"
        ))
        let activeEnd = try #require(viewSource.range(
            of: ".onReceive(model.$activeRemoteButtons)",
            range: activeStart.upperBound..<viewSource.endIndex
        ))
        let activeSource = viewSource[activeStart.lowerBound..<activeEnd.lowerBound]
        #expect(activeSource.contains("case .audio:"))
        #expect(activeSource.contains("model.refreshAudioDevices()"))
        #expect(activeSource.contains("case .complete:"))
        #expect(activeSource.contains("prepareSelectedControlConnection()"))
    }

    @Test func remoteStepUsesUserFacingButtonGuidanceAndRoutesRecoveryToExistingRuntime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let remoteStart = try #require(viewSource.range(of: "private var remoteContent"))
        let remoteEnd = try #require(viewSource.range(
            of: "private var audioContent",
            range: remoteStart.upperBound..<viewSource.endIndex
        ))
        let remoteSource = viewSource[remoteStart.lowerBound..<remoteEnd.lowerBound]
        #expect(!remoteSource.contains("model.hidStatus.text(using: localization)"))
        #expect(!remoteSource.contains("onboarding.remote.listener_status"))
        #expect(remoteSource.contains("physicalRemotePairingGuide.title"))
        #expect(remoteSource.contains("ForEach(Array(physicalRemotePairingGuide.steps.enumerated())"))
        #expect(!remoteSource.contains("ViewThatFits(in: .horizontal)"))
        let recoveryStart = try #require(viewSource.range(of: "private func performRecovery"))
        let recoveryEnd = try #require(viewSource.range(
            of: "private func resetVoiceTestForRetry",
            range: recoveryStart.upperBound..<viewSource.endIndex
        ))
        let recoverySource = viewSource[recoveryStart.lowerBound..<recoveryEnd.lowerBound]
        #expect(recoverySource.contains("case .remoteButtonNotReady, .controlsNotConfirmed:"))
        #expect(recoverySource.contains("model.applyHIDSettings()"))
    }

    @Test func remoteStepCorrectsVoiceButtonMistakesWithoutWeakeningTheControlGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingScreenshotRenderer.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("recordRemoteVoiceButtonPress()"))
        #expect(viewSource.contains("onboarding.remote.voice_button_mistake.title"))
        #expect(viewSource.contains("onboarding.remote.voice_button_mistake.detail"))
        #expect(viewSource.contains("onboarding.remote.button_waiting_detail"))
        #expect(viewSource.contains("ONBOARDING REMOTE_INPUT observed=voice"))
        #expect(viewSource.contains("ONBOARDING REMOTE_INPUT observed=control"))
        #expect(viewSource.contains("isComplete: !observedRemoteButtons.isEmpty"))
        #expect(rendererSource.contains("REMOTE_MIC_ONBOARDING_SCREENSHOT_REMOTE_INPUT"))
    }

    @Test func completionPageExplainsARegressedRuntimeCondition() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let completeStart = try #require(viewSource.range(of: "private var completeContent"))
        let completeEnd = try #require(viewSource.range(
            of: "private var rightPane",
            range: completeStart.upperBound..<viewSource.endIndex
        ))
        let completeSource = viewSource[completeStart.lowerBound..<completeEnd.lowerBound]
        #expect(completeSource.contains("if !canContinue"))
        #expect(completeSource.contains("onboarding.complete.runtime_changed"))

        let rendererSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingScreenshotRenderer.swift"),
            encoding: .utf8
        )
        #expect(rendererSource.contains("completeRuntimeReadyOverride: true"))
    }

    @Test func permissionsPageNoLongerShowsTheNextPageCheckCard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )

        // 权限页原有一张「iPhone 或 Apple Watch 连接将在下一页检查」的提示卡，
        // 和勾选项「已确认，下一页会用真实连接验证」说的是同一件事，2026-10-24 移除。
        // 文案键也一并删掉，不留死键；这条用例防止它以任何形式长回来。
        let permissionsStart = try #require(viewSource.range(of: "private var permissionsContent"))
        let permissionsEnd = try #require(viewSource.range(
            of: "private var shortcutLearningCard",
            range: permissionsStart.upperBound..<viewSource.endIndex
        ))
        let permissionsSource = viewSource[permissionsStart.lowerBound..<permissionsEnd.lowerBound]
        #expect(!permissionsSource.contains("statusCard("))

        for key in [
            "onboarding.permissions.apple_companion.title",
            "onboarding.permissions.apple_companion.detail",
            "onboarding.permissions.web_remote.title",
            "onboarding.permissions.web_remote.detail",
            "onboarding.permissions.mobile_network.title",
            "onboarding.permissions.mobile_network.detail",
        ] {
            #expect(!viewSource.contains(key))
            #expect(!chinese.contains("\"\(key)\""))
            #expect(!english.contains("\"\(key)\""))
        }
    }

    @Test func audioStepOnlyOffersSupportedVirtualAudioDevices() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let audioStart = try #require(viewSource.range(of: "private var audioContent"))
        let audioEnd = try #require(viewSource.range(
            of: "private var voiceTestContent",
            range: audioStart.upperBound..<viewSource.endIndex
        ))
        let audioSource = viewSource[audioStart.lowerBound..<audioEnd.lowerBound]

        #expect(audioSource.contains("ForEach(supportedAudioDevices"))
        #expect(!audioSource.contains("ForEach(model.audioDevices"))
        #expect(!audioSource.contains("Picker("))
        #expect(audioSource.contains("settings.selectedAudioDeviceUID = device.uid"))
        #expect(audioSource.contains("model.applyAudioSettings(reason: \"onboarding_audio_device_selected\")"))
        #expect(viewSource.contains("OnboardingAudioSelectionPolicy.isSupportedDevice"))
        #expect(viewSource.contains("onboarding.audio.on_demand_detail"))
        #expect(viewSource.contains("onboarding.side.audio_on_demand"))
    }

    @Test func onlySayAllLegacyMiRemoteAndBlackHoleCanSatisfyTheAudioSelectionGate() {
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(uid: DoubaoAudioDevicePolicy.deviceUID, name: "SayAll"))
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "MiRemoteV2ch_UID",
            name: "MiRemoteV 2ch"
        ))
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "BlackHole2ch_UID",
            name: "BlackHole 2ch"
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "Beosound_UID",
            name: "Beosound A1 2nd Gen"
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "BuiltInOutputDevice",
            name: "MacBook Pro Speakers"
        ))

        let availableSupportedUIDs = ["MiRemoteV2ch_UID", "BlackHole2ch_UID"]
        #expect(OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "MiRemoteV2ch_UID",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "BlackHole2ch_UID",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "Beosound_UID",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "",
            availableSupportedUIDs: availableSupportedUIDs
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: "MiRemoteV2ch_UID",
            availableSupportedUIDs: ["BlackHole2ch_UID"]
        ))
    }

    @Test func progressVoiceToolAndCompletionPersistAcrossLaunches() throws {
        let suiteName = "RemoteMicTests.Onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.isOnboardingComplete)
        #expect(settings.onboardingStep == .welcome)
        #expect(settings.onboardingVoiceTool == .unselected)
        #expect(settings.onboardingRemoteAvailability == .unselected)
        #expect(settings.onboardingControlMethod == .unselected)

        settings.setOnboardingVoiceTool(.doubao)
        settings.setOnboardingRemoteAvailability(.noRemote)
        settings.setOnboardingControlMethod(.iPhoneApp)
        settings.setOnboardingStep(.audio)

        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.onboardingStep == .audio)
        #expect(resumed.onboardingVoiceTool == .doubao)
        #expect(resumed.onboardingRemoteAvailability == .noRemote)
        #expect(resumed.onboardingControlMethod == .iPhoneApp)
        #expect(!resumed.isOnboardingComplete)

        resumed.completeOnboarding()
        let completed = AppSettings(defaults: defaults)
        #expect(completed.isOnboardingComplete)
        #expect(completed.onboardingCompletedVersion == AppSettings.currentOnboardingVersion)
        #expect(completed.onboardingStep == .complete)
        #expect(completed.onboardingVoiceTool == .doubao)
        #expect(completed.onboardingRemoteAvailability == .noRemote)
        #expect(completed.onboardingControlMethod == .iPhoneApp)

        completed.selectedAudioDeviceUID = "MiRemoteV 2ch"
        completed.customMappingEnabled = true
        completed.showDockIcon = false
        completed.openMainWindowAtLaunch = false
        completed.checksForPreReleaseUpdates = true
        completed.setAction(.escape, for: .ok)

        completed.restartOnboarding()
        let restarted = AppSettings(defaults: defaults)
        #expect(!restarted.isOnboardingComplete)
        #expect(restarted.onboardingStep == .welcome)
        #expect(restarted.onboardingVoiceTool == .unselected)
        #expect(restarted.onboardingRemoteAvailability == .unselected)
        #expect(restarted.onboardingControlMethod == .unselected)
        #expect(restarted.selectedAudioDeviceUID == "MiRemoteV 2ch")
        #expect(restarted.customMappingEnabled)
        #expect(!restarted.showDockIcon)
        #expect(!restarted.openMainWindowAtLaunch)
        #expect(restarted.checksForPreReleaseUpdates)
        #expect(restarted.action(for: .ok) == .escape)
    }

    @Test func onboardingPairingPlanControlsFnTapWithoutToolSelectionSideEffects() throws {
        let suiteName = "RemoteMicTests.OnboardingFnTap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingVoiceTool(.typeless)
        #expect(!settings.voiceFnTapModeEnabled)

        let resumed = AppSettings(defaults: defaults)
        #expect(!resumed.voiceFnTapModeEnabled)

        resumed.setOnboardingControlSource(.xiaomiRemote)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .typeless,
            controlSource: .xiaomiRemote
        ))
        resumed.beginOnboardingVoiceTrial(plan)
        #expect(resumed.voiceFnTapModeEnabled)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        #expect(viewSource.contains("settings.beginOnboardingVoiceTrial(plan)"))
        #expect(viewSource.contains("model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)"))
    }

    @Test func existingInstallSkipsOnboardingWhileNewAndResumedFlowsRemainRequired() throws {
        let legacySuiteName = "RemoteMicTests.Onboarding.Legacy.\(UUID().uuidString)"
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
        legacyDefaults.set("68", forKey: "launch.lastLaunchedBuild")

        let legacySettings = AppSettings(defaults: legacyDefaults)
        #expect(legacySettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: true
        ))
        #expect(legacySettings.isOnboardingComplete)
        #expect(legacySettings.onboardingStep == .complete)

        let sparkleLegacySuiteName = "RemoteMicTests.Onboarding.SparkleLegacy.\(UUID().uuidString)"
        let sparkleLegacyDefaults = try #require(UserDefaults(suiteName: sparkleLegacySuiteName))
        defer { sparkleLegacyDefaults.removePersistentDomain(forName: sparkleLegacySuiteName) }

        let sparkleLegacySettings = AppSettings(defaults: sparkleLegacyDefaults)
        #expect(sparkleLegacySettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: true
        ))
        #expect(sparkleLegacySettings.isOnboardingComplete)

        let configuredLegacySuiteName = "RemoteMicTests.Onboarding.ConfiguredLegacy.\(UUID().uuidString)"
        let configuredLegacyDefaults = try #require(UserDefaults(suiteName: configuredLegacySuiteName))
        defer { configuredLegacyDefaults.removePersistentDomain(forName: configuredLegacySuiteName) }
        configuredLegacyDefaults.set(Data("legacy".utf8), forKey: "buttonBindings")
        let configuredLegacySettings = AppSettings(defaults: configuredLegacyDefaults)
        #expect(!configuredLegacySettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: false
        ))
        #expect(configuredLegacySettings.isOnboardingComplete)

        let configuredAfterMigrationSuiteName = "RemoteMicTests.Onboarding.ConfiguredAfterMigration.\(UUID().uuidString)"
        let configuredAfterMigrationDefaults = try #require(UserDefaults(suiteName: configuredAfterMigrationSuiteName))
        defer { configuredAfterMigrationDefaults.removePersistentDomain(forName: configuredAfterMigrationSuiteName) }
        configuredAfterMigrationDefaults.set(AppSettings.currentOnboardingVersion, forKey: "onboarding.migrationVersion")
        configuredAfterMigrationDefaults.set(Data("legacy".utf8), forKey: "buttonBindings")
        let configuredAfterMigrationSettings = AppSettings(defaults: configuredAfterMigrationDefaults)
        #expect(!configuredAfterMigrationSettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: false
        ))
        #expect(configuredAfterMigrationSettings.isOnboardingComplete)

        let freshSuiteName = "RemoteMicTests.Onboarding.Fresh.\(UUID().uuidString)"
        let freshDefaults = try #require(UserDefaults(suiteName: freshSuiteName))
        defer { freshDefaults.removePersistentDomain(forName: freshSuiteName) }

        let firstFreshLaunch = AppSettings(defaults: freshDefaults)
        #expect(!firstFreshLaunch.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: false
        ))
        #expect(!firstFreshLaunch.isOnboardingComplete)

        let secondFreshLaunch = AppSettings(defaults: freshDefaults)
        #expect(secondFreshLaunch.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "103",
            sparkleHadLaunchedBefore: true
        ))
        #expect(!secondFreshLaunch.isOnboardingComplete)
        #expect(secondFreshLaunch.onboardingStep == .welcome)

        let resumedSuiteName = "RemoteMicTests.Onboarding.Resumed.\(UUID().uuidString)"
        let resumedDefaults = try #require(UserDefaults(suiteName: resumedSuiteName))
        defer { resumedDefaults.removePersistentDomain(forName: resumedSuiteName) }
        resumedDefaults.set("101", forKey: "launch.lastLaunchedBuild")
        resumedDefaults.set(OnboardingStep.audio.rawValue, forKey: "onboarding.step")
        resumedDefaults.set(OnboardingVoiceTool.typeless.rawValue, forKey: "onboarding.voiceTool")

        let resumedSettings = AppSettings(defaults: resumedDefaults)
        #expect(resumedSettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "102",
            sparkleHadLaunchedBefore: true
        ))
        #expect(!resumedSettings.isOnboardingComplete)
        #expect(resumedSettings.onboardingStep == .audio)
        #expect(resumedSettings.onboardingVoiceTool == .typeless)
        #expect(resumedSettings.onboardingRemoteAvailability == .hasRemote)
        #expect(resumedSettings.onboardingControlMethod == .physicalRemote)

        resumedSettings.completeOnboarding()
        resumedSettings.restartOnboarding()
        let restartedSettings = AppSettings(defaults: resumedDefaults)
        _ = restartedSettings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: "103",
            sparkleHadLaunchedBefore: true
        )
        #expect(!restartedSettings.isOnboardingComplete)
        #expect(restartedSettings.onboardingStep == .welcome)
    }

    @Test func incompleteFlowAlwaysShowsItsWindowAndDelaysRuntimeUntilSetup() {
        #expect(OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: false,
            completedUpdate: false,
            openMainWindowAtLaunch: false
        ))
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .welcome
        ))
        #expect(OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .voiceTool
        ))
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .remoteAvailability
        ))
        #expect(!OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .controlMethod
        ))
        #expect(OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: false,
            step: .permissions
        ))
        #expect(OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: true,
            step: .welcome
        ))
        #expect(!OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: true,
            completedUpdate: false,
            openMainWindowAtLaunch: false
        ))
    }

    @Test func completedUpdateOpensPermissionRepairOnlyWhenARequiredPermissionIsMissing() throws {
        #expect(CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(!CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: true,
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(!CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: true,
            completedUpdate: false,
            bluetoothGranted: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))
        #expect(!CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: false,
            completedUpdate: true,
            bluetoothGranted: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let rootViewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicRootView.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("showSettingsWindow(initialSection: .about)"))
        #expect(appSource.contains("UPDATE PERMISSION_REPAIR"))
        #expect(rootViewSource.contains("initialSection: initialSettingsSection"))
    }

    @Test func firstUseFailuresPointToTheExactRecoveryStep() {
        var capabilities = OnboardingCapabilities()
        var context = FirstUseDiagnosticContext(
            step: .permissions,
            capabilities: capabilities,
            hasSelectedAudioUID: false
        )
        #expect(context.failureReason == .bluetoothPermissionDenied)
        capabilities.bluetoothGranted = true
        context = FirstUseDiagnosticContext(
            step: .permissions,
            capabilities: capabilities,
            hasSelectedAudioUID: false
        )
        #expect(context.failureReason == .inputMonitoringPermissionDenied)

        capabilities.inputMonitoringGranted = true
        capabilities.accessibilityGranted = true
        capabilities.remoteConnected = true
        capabilities.remoteButtonObserved = true
        context = FirstUseDiagnosticContext(
            step: .audio,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        )
        #expect(context.failureReason == .audioSelectedDeviceMissing)

        capabilities.voiceSessionStarted = true
        capabilities.voiceSamplesReceived = true
        capabilities.voiceSessionEnded = true
        capabilities.transcriptionAppeared = true
        capabilities.manualTranscriptInputObserved = true
        context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        )
        #expect(context.failureReason == .voiceManualInput)

        capabilities.audioOutputSelected = true
        capabilities.audioReady = true
        capabilities.manualTranscriptInputObserved = false
        #expect(OnboardingFlowPolicy.recoveryStep(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        ) == nil)

        capabilities.remoteConnected = false
        #expect(OnboardingFlowPolicy.recoveryStep(
            from: .complete,
            voiceTool: .typeless,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        ) == .remote)
    }

    @Test func voiceAttemptUsesOneTerminalCauseAfterTheSessionEnds() {
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: true,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .passed)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: false,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .noSamples,
            finalObservation: true
        ) == .noSamples)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: false,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .inputTargetNotReady)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: false,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .inputTargetFocusLost)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .enqueueFailed,
            finalObservation: true
        ) == .audioDeliveryFailed)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        ) == .externalToolNoCommit)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .playbackPending,
            finalObservation: false
        ) == .externalToolNoCommit)
        #expect(FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .playbackPending,
            finalObservation: true
        ) == .audioDeliveryFailed)
    }

    @Test func voiceAttemptIntermediatePhasesAreNotFailures() {
        let capabilities = OnboardingCapabilities(
            voiceSessionStarted: true,
            voiceSamplesReceived: true
        )
        var attempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: 1,
            phase: .recording,
            triggerPath: UsageEventSource.bluetoothRemote.rawValue,
            triggerReady: true,
            editorMounted: true,
            windowKeyAtStart: true,
            firstResponderAtStart: true
        )
        var context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: attempt
        )
        #expect(context.failureReason == nil)

        attempt.phase = .awaitingTranscript
        context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: attempt
        )
        #expect(context.failureReason == nil)

        attempt.phase = .failed
        attempt.result = .externalToolNoCommit
        context = FirstUseDiagnosticContext(
            step: .voiceTest,
            capabilities: capabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: attempt
        )
        #expect(context.failureReason == .voiceExternalToolNoCommit)
    }

    @Test func recoveredTransientFocusLossDoesNotOverrideTheExternalToolBoundary() {
        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: true,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        )
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusLost: true,
            focusLossCount: 1,
            focusRecovered: true,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: true,
            externalToolMicrophoneUserConfirmed: true,
            result: result
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(result == .externalToolNoCommit)
        #expect(attempt.probableCause == "external_tool_no_commit")
        #expect(!attempt.probableCauseConfirmed)
    }

    @Test func focusStillMissingAtTheDeadlineIsAConfirmedSayAllFailure() {
        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: false,
            samplesReceived: true,
            transcriptionAppeared: false,
            triggerReady: true,
            focusReadyAtDeadline: false,
            audioDeliveryResult: .deliveredToSelectedDevice,
            finalObservation: true
        )

        #expect(result == .inputTargetFocusLost)
        #expect(FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: false,
            result: result
        ).probableCauseConfirmed)
    }

    @Test func unconfirmedExternalMicrophoneIsReportedAsAnUnverifiedNextCheck() {
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: true,
            externalToolMicrophoneUserConfirmed: false,
            result: .externalToolNoCommit
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(attempt.probableCause == "external_tool_microphone_not_confirmed")
        #expect(!attempt.probableCauseConfirmed)
        #expect(attempt.result.diagnosticBoundary == "external_tool_internal_state_unavailable")
    }

    @Test func unconfirmedExternalVoiceKeyIsReportedBeforeOtherExternalChecks() {
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: false,
            externalToolGlobalVoiceApplicable: true,
            externalToolGlobalVoiceUserConfirmed: false,
            externalToolMicrophoneUserConfirmed: false,
            result: .externalToolNoCommit
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(attempt.probableCause == "external_tool_voice_key_not_confirmed")
        #expect(!attempt.probableCauseConfirmed)
    }

    @Test func unconfirmedDoubaoGlobalVoiceIsReportedAfterVoiceKeyConfirmation() {
        var attempt = FirstUseVoiceAttemptDiagnostic(
            phase: .failed,
            focusReadyAtDeadline: true,
            externalToolVoiceKeyUserConfirmed: true,
            externalToolGlobalVoiceApplicable: true,
            externalToolGlobalVoiceUserConfirmed: false,
            externalToolMicrophoneUserConfirmed: true,
            result: .externalToolNoCommit
        )
        attempt.audioDelivery = deliveredAudioDiagnostic()

        #expect(attempt.probableCause == "external_tool_global_voice_not_confirmed")
        #expect(!attempt.probableCauseConfirmed)
    }

    @Test func voiceTestUsesNativeFirstResponderAsTheFocusFact() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )

        #expect(viewSource.contains("struct OnboardingTranscriptEditor: NSViewRepresentable"))
        #expect(viewSource.contains("window.makeFirstResponder(textView)"))
        #expect(viewSource.contains("window?.firstResponder === textView"))
        #expect(!viewSource.contains("@FocusState private var transcriptFocused"))
    }

    @Test func firstUseEventsDeduplicatePollingAndKeepExplicitRetries() throws {
        let suiteName = "RemoteMicTests.Onboarding.Diagnostics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        settings.recordFirstUseEvent(.entered, step: .permissions, at: now)
        settings.recordFirstUseEvent(
            .blocked,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(1)
        )
        settings.recordFirstUseEvent(
            .blocked,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(2)
        )
        settings.recordFirstUseEvent(
            .retry,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(3)
        )
        settings.recordFirstUseEvent(
            .retry,
            step: .permissions,
            failureReason: .bluetoothPermissionDenied,
            at: now.addingTimeInterval(4)
        )

        #expect(settings.firstUseEvents.count == 4)
        #expect(settings.firstUseEvents.last?.elapsedMilliseconds == 4_000)
    }

    @Test func firstUseEventsPersistVoiceAttemptIdentityAndDecodeLegacyEvents() throws {
        let suiteName = "RemoteMicTests.Onboarding.VoiceDiagnostics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.recordFirstUseEvent(
            .blocked,
            step: .voiceTest,
            failureReason: .voiceExternalToolNoCommit,
            voiceAttemptID: 3,
            voiceResult: .externalToolNoCommit
        )
        #expect(settings.firstUseEvents.last?.voiceAttemptID == 3)
        #expect(settings.firstUseEvents.last?.voiceResult == .externalToolNoCommit)

        let legacyData = Data("""
        [{"timestamp":0,"kind":"entered","step":"voiceTest","elapsedMilliseconds":0,"failureReason":null}]
        """.utf8)
        let legacyEvents = try JSONDecoder().decode([FirstUseEvent].self, from: legacyData)
        #expect(legacyEvents.first?.voiceAttemptID == nil)
        #expect(legacyEvents.first?.voiceResult == nil)
    }

    @Test func firstUseEventsHaveStableRuntimeLogMessages() {
        let event = FirstUseEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            kind: .blocked,
            step: .voiceTest,
            elapsedMilliseconds: 1_234,
            failureReason: .voiceNoTranscript,
            voiceAttemptID: 7,
            voiceResult: .externalToolNoCommit
        )

        #expect(event.runtimeLogMessage ==
            "ONBOARDING EVENT kind=blocked step=voiceTest elapsed_ms=1234 " +
                "failure=voice.no_transcript attempt=7 voice_result=external_tool_no_commit"
        )
    }

    @Test func diagnosticSummaryContainsOnlyNormalizedState() {
        let capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false,
            remoteConnected: false,
            remoteButtonObserved: false,
            audioReady: false,
            audioOutputSelected: false,
            voiceSessionStarted: false,
            voiceSamplesReceived: false,
            voiceSessionEnded: false,
            transcriptionAppeared: false,
            testedRemoteButtonCount: 0
        )
        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: "1.8.14",
            appBuild: "106",
            systemMajorVersion: 14,
            architecture: "arm64",
            voiceTool: .typeless,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: true,
            context: FirstUseDiagnosticContext(
                step: .permissions,
                capabilities: capabilities,
                hasSelectedAudioUID: false,
                remoteInput: FirstUseRemoteInputDiagnostic(
                    voiceButtonPressCount: 2,
                    controlButtonObservationCount: 0,
                    lastInputKind: .voice
                )
            ),
            voiceAttempt: FirstUseVoiceAttemptDiagnostic(
                attemptID: 2,
                phase: .failed,
                triggerPath: UsageEventSource.bluetoothRemote.rawValue,
                triggerReady: true,
                editorMounted: true,
                windowKeyAtStart: true,
                firstResponderAtStart: true,
                firstResponderAtEnd: true,
                firstSampleLatencyMilliseconds: 24,
                sessionDurationMilliseconds: 1_500,
                transcriptWaitMilliseconds: 3_000,
                externalToolVoiceKeyUserConfirmed: true,
                externalToolExpectedVoiceKey: "fn_tap",
                result: .externalToolNoCommit
            ),
            bluetoothStatus: "connection.status.searching",
            buttonStatus: "button_mapping.status.disabled",
            audioStatus: "audio.output.none_selected",
            events: [],
            appLanguage: "zh-Hans",
            controlSource: .xiaomiRemote,
            voiceBinding: VoiceToolUserBinding(
                tool: .typeless,
                shortcut: .function,
                gestureMode: .toggle,
                source: .documentedDefault,
                validationState: .staged,
                verifiedToolVersion: nil,
                verifiedAt: nil
            )
        )

        let text = snapshot.redactedText
        #expect(text.contains("failure=permission.input_monitoring_denied"))
        #expect(text.contains("voice_attempt=2"))
        #expect(text.contains("diagnostic_schema=3"))
        #expect(text.contains("app_version=1.8.14"))
        #expect(text.contains("app_build=106"))
        #expect(text.contains("onboarding_voice_key_policy=profile_or_user_binding"))
        #expect(text.contains("voice_fn_tap_mode_enabled=true"))
        #expect(text.contains("voice_key_policy_compliant=true"))
        #expect(text.contains("control_source=xiaomi_remote"))
        #expect(text.contains("voice_gesture=toggle"))
        #expect(text.contains("voice_binding_source=documented_default"))
        #expect(text.contains("voice_binding_validation=staged"))
        #expect(text.contains("remote_voice_button_press_count=2"))
        #expect(text.contains("remote_control_button_observation_count=0"))
        #expect(text.contains("remote_last_input_kind=voice"))
        #expect(text.contains("remote_voice_button_mistake_detected=true"))
        #expect(text.contains("macos_version="))
        #expect(text.contains("macos_build="))
        #expect(text.contains("app_language=zh-Hans"))
        #expect(text.contains("voice_terminal_result=external_tool_no_commit"))
        #expect(text.contains("voice_probable_cause_confirmed=false"))
        #expect(text.contains("voice_external_tool_voice_key_observable=false"))
        #expect(text.contains("voice_external_tool_voice_key_user_confirmed=true"))
        #expect(text.contains("voice_external_tool_expected_voice_key=fn_tap"))
        #expect(text.contains("voice_external_tool_global_voice_observable=false"))
        #expect(text.contains("voice_external_tool_global_voice_applicable=false"))
        #expect(text.contains("voice_external_tool_microphone_observable=false"))
        #expect(text.contains("voice_external_tool_expected_microphone=unavailable"))
        #expect(text.contains("voice_external_tool_next_checks=trigger_matches_binding"))
        #expect(text.contains("voice_audio_delivery_result=unavailable"))
        #expect(text.contains("voice_focus_ready_at_deadline=unknown"))
        #expect(text.contains("voice_first_sample_latency_ms=24"))
        #expect(text.contains("voice_diagnostic_boundary=external_tool_internal_state_unavailable"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("UUID"))
        #expect(!text.contains("无线麦已经连接成功"))
    }

    @Test @MainActor func offscreenOnboardingRegistersAndDrivesEveryInteractiveControl() throws {
        func invoke(_ id: String, on fixture: OnboardingOffscreenFixture) {
            #expect(fixture.probe.actions[id] != nil, "missing action: \(id)")
            fixture.probe.invoke(id)
            #expect(fixture.probe.invokedActions.last == id)
        }

        func invokeIfPresent(_ id: String, on fixture: OnboardingOffscreenFixture) {
            guard fixture.probe.actions[id] != nil else { return }
            invoke(id, on: fixture)
        }

        let welcome = try OnboardingOffscreenFixture(step: .welcome)
        defer { welcome.close() }
        #expect(Set(welcome.probe.actions.keys) == ["welcome.copy-ai-prompt", "continue"])
        invoke("continue", on: welcome)
        #expect(welcome.settings.onboardingStep == .remoteAvailability)

        let voiceTool = try OnboardingOffscreenFixture(
            step: .voiceTool,
            voiceTool: .doubao,
            systemFunctionKeyAvailable: false,
            initialInputMethodGuideStep: 2,
            controlSource: .xiaomiRemote,
            voiceToolAvailability: [
                .doubao: .notInstalled,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ]
        )
        defer { voiceTool.close() }
        #expect(voiceTool.probe.actions.keys.contains("back"))
        for id in ["continue", "voice-tool.doubao.install"] {
            #expect(voiceTool.probe.actions.keys.contains(id), "missing voice-tool action: \(id)")
        }
        for index in 0...3 {
            #expect(voiceTool.probe.actions.keys.contains("input-guide.\(index)"))
        }
        #expect(voiceTool.probe.actions.keys.contains("keyboard-settings.open"))
        invoke("keyboard-settings.open", on: voiceTool)
        #expect(voiceTool.probe.openedURLs.last?.absoluteString ==
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        invoke("voice-tool.doubao.install", on: voiceTool)
        #expect(voiceTool.probe.openedURLs.last == AppLinks.doubaoInputMethod)
        for tool in [OnboardingVoiceTool.doubao, .weixin, .vokie, .typeless, .other] {
            let id = "voice-tool.\(tool.rawValue)"
            invoke(id, on: voiceTool)
            #expect(voiceTool.settings.onboardingVoiceTool == tool)
        }
        invoke("voice-tool.typeless", on: voiceTool)
        invoke("continue", on: voiceTool)
        #expect(voiceTool.settings.onboardingStep == .voiceTool)
        for index in 0...3 {
            invoke("input-guide.\(index)", on: voiceTool)
        }
        invoke("continue", on: voiceTool)
        #expect(voiceTool.settings.onboardingStep == .voiceTest)
        invoke("back", on: voiceTool)

        let remoteSource = try OnboardingOffscreenFixture(
            step: .remoteAvailability,
            voiceTool: .doubao,
            controlSource: .webRemote
        )
        defer { remoteSource.close() }
        if remoteSource.probe.actions["control-source.more"] != nil {
            invoke("control-source.more", on: remoteSource)
        }
        #expect(!remoteSource.settings.siriRemoteEnabled)
        #expect(remoteSource.probe.actions["control-source.chromecast_remote"] == nil)
        let visibleSources = OnboardingControlSourceVisibilityPolicy.visibleSources(
            OnboardingBuildCapabilities.availableControlSources
        )
        for source in visibleSources where source != .siriRemote {
            let id = "control-source.\(source.rawValue)"
            invoke(id, on: remoteSource)
            #expect(remoteSource.settings.onboardingControlSource == source)
            #expect(!remoteSource.settings.siriRemoteEnabled)
        }
        #if SAYALL_SIRI_REMOTE_ENABLED
        for generation in OnboardingAppleRemoteGeneration.allCases {
            let id = "control-source.siri_remote.\(generation.rawValue)"
            invoke(id, on: remoteSource)
            #expect(remoteSource.settings.onboardingAppleRemoteGeneration == generation)
            #expect(remoteSource.settings.siriRemoteEnabled)
        }
        #endif
        invoke("control-source.xiaomi_remote", on: remoteSource)
        invoke("continue", on: remoteSource)
        invoke("back", on: remoteSource)

        let vokieSource = try OnboardingOffscreenFixture(
            step: .voiceTool,
            voiceTool: .vokie,
            controlSource: .webRemote
        )
        defer { vokieSource.close() }
        #expect(vokieSource.probe.actions["voice-tool.vokie.website"] != nil)
        invoke("voice-tool.vokie.website", on: vokieSource)
        #expect(vokieSource.probe.openedURLs.last == AppLinks.vokieWebsite)
        #expect(AppLinks.vokieWebsite.query == "utm_source=sayall.app")
        for index in 0...3 {
            #expect(vokieSource.probe.actions.keys.contains("input-guide.\(index)"))
        }
        for mode in VoiceGestureMode.allCases {
            #expect(vokieSource.probe.actions["gesture.\(mode.rawValue)"] != nil)
            invoke("gesture.\(mode.rawValue)", on: vokieSource)
            #expect(vokieSource.settings.onboardingPreferredGesture == mode)
        }
        #expect(!vokieSource.probe.actions.keys.contains("vokie.open"))

        let iPhone = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { iPhone.close() }
        // 下载入口只保留右栏那一个（App Store 二维码 + 官方徽章）。
        // 左栏曾经还有一个「从 App Store 安装无线麦 SayAll」按钮，同一屏把同一件事说了两遍。
        #expect(iPhone.probe.actions["iphone.install"] == nil)
        invokeIfPresent("recovery.remote.not_found", on: iPhone)
        invokeIfPresent("diagnostics.copy", on: iPhone)
        invoke("back", on: iPhone)

        let web = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .noRemote,
            controlMethod: .webRemote,
            voiceTool: .doubao
        )
        defer { web.close() }
        invoke("web.retry", on: web)
        invokeIfPresent("recovery.remote.not_found", on: web)
        invokeIfPresent("diagnostics.copy", on: web)
        invoke("back", on: web)

        let permissions = try OnboardingOffscreenFixture(
            step: .permissions,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            voiceTool: .doubao,
            bindingPreference: .learnCurrent
        )
        defer { permissions.close() }
        for id in [
            "permission.bluetooth", "permission.input-monitoring", "permission.accessibility",
            "continue",
        ] {
            #expect(permissions.probe.actions.keys.contains(id), "missing permission action: \(id)")
        }
        invoke("permission.bluetooth", on: permissions)
        invoke("permission.input-monitoring", on: permissions)
        invoke("permission.accessibility", on: permissions)
        invoke("continue", on: permissions)
        invoke("back", on: permissions)

        let remote = try OnboardingOffscreenFixture(
            step: .remote,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            voiceTool: .doubao
        )
        defer { remote.close() }
        invoke("bluetooth.settings.open", on: remote)
        #expect(remote.probe.openedURLs.last?.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings")
        invokeIfPresent("recovery.remote.not_found", on: remote)
        invokeIfPresent("diagnostics.copy", on: remote)
        invoke("back", on: remote)

        let audio = try OnboardingOffscreenFixture(
            step: .audio,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { audio.close() }
        invoke("audio.install-guide", on: audio)
        invoke("recovery.audio.no_output_device", on: audio)
        invoke("diagnostics.copy", on: audio)
        invoke("audio.device.MiRemoteV2ch_UID", on: audio)
        #expect(audio.settings.selectedAudioDeviceUID == DoubaoAudioDevicePolicy.deviceUID)
        invoke("audio.device.BlackHole2ch_UID", on: audio)
        #expect(audio.settings.selectedAudioDeviceUID == "BlackHole2ch_UID")
        invoke("back", on: audio)

        let voiceTest = try OnboardingOffscreenFixture(
            step: .voiceTest,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .typeless
        )
        defer { voiceTest.close() }
        for id in [
            "voice-test.confirm.voice-key", "voice-test.confirm.microphone", "continue",
        ] {
            #expect(voiceTest.probe.actions.keys.contains(id), "missing voice-test action: \(id)")
        }
        #expect(voiceTest.probe.actions.keys.contains("voice-test.gain.set-12"))
        invoke("voice-test.gain.set-12", on: voiceTest)
        #expect(voiceTest.settings.gainDB == 12)
        invoke("voice-test.confirm.voice-key", on: voiceTest)
        invoke("voice-test.confirm.microphone", on: voiceTest)
        #expect(voiceTest.probe.toggleValues["voice-test.confirm.voice-key"] == true)
        invoke("voice-test.confirm.voice-key", on: voiceTest)
        #expect(voiceTest.probe.toggleValues["voice-test.confirm.voice-key"] == false)
        invoke("voice-tool.reopen", on: voiceTest)
        #expect(voiceTest.probe.launchedVoiceTools.last == .typeless)
        invokeIfPresent("recovery.remote.not_found", on: voiceTest)
        invokeIfPresent("diagnostics.copy", on: voiceTest)
        invoke("back", on: voiceTest)

        let doubaoVoiceTest = try OnboardingOffscreenFixture(
            step: .voiceTest,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { doubaoVoiceTest.close() }
        invoke("voice-test.confirm.global-voice", on: doubaoVoiceTest)

        let controls = try OnboardingOffscreenFixture(
            step: .controls,
            remoteAvailability: .noRemote,
            controlMethod: .webRemote,
            voiceTool: .doubao
        )
        defer { controls.close() }
        invoke("recovery.controls.not_confirmed", on: controls)
        invoke("diagnostics.copy", on: controls)
        invoke("back", on: controls)

        let complete = try OnboardingOffscreenFixture(
            step: .complete,
            remoteAvailability: .noRemote,
            controlMethod: .iPhoneApp,
            voiceTool: .doubao
        )
        defer { complete.close() }
        invoke("continue", on: complete)
        #expect(complete.settings.isOnboardingComplete)
        invoke("back", on: complete)
    }

    private func deliveredAudioDiagnostic() -> VoiceAudioDeliveryDiagnostic {
        let start = VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .miRemoteV2ch,
            actualDeviceKind: .miRemoteV2ch,
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true
        )
        var observation = start
        observation.counters = VirtualAudioPlaybackCounters(
            scheduledBuffers: 1,
            scheduledSamples: 320,
            playedBuffers: 1,
            playedSamples: 320
        )
        return VoiceAudioDeliveryDiagnostic(
            generation: 1,
            source: UsageEventSource.bluetoothRemote.rawValue,
            route: .virtualAudioDirect,
            sessionEnded: true,
            receivedBatches: 1,
            receivedSamples: 320,
            outputAtStart: start,
            outputAtObservation: observation
        )
    }
}

@MainActor
private final class OnboardingOffscreenFixture {
    let suiteName: String
    let defaults: UserDefaults
    let settings: AppSettings
    let model: BridgeAppModel
    let probe: OnboardingInteractionProbe
    let window: NSWindow

    init(
        step: OnboardingStep,
        remoteAvailability: OnboardingRemoteAvailability = .unselected,
        controlMethod: OnboardingControlMethod = .unselected,
        voiceTool: OnboardingVoiceTool = .doubao,
        bindingPreference: OnboardingVoiceBindingPreference = .documentedDefault,
        systemFunctionKeyAvailable: Bool = true,
        initialInputMethodGuideStep: Int? = nil,
        controlSource: OnboardingControlSource? = nil,
        voiceToolAvailability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability]? = nil,
        siriRemotePackageInstalled: Bool = true,
        siriRemoteInitiallyEnabled: Bool = false,
        siriRemoteNeedsUserAction: Bool = false
    ) throws {
        let suiteName = "RemoteMicTests.Onboarding.Fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.defaultsUnavailable
        }
        self.suiteName = suiteName
        self.defaults = defaults
        settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        settings.siriRemoteEnabled = siriRemoteInitiallyEnabled
        settings.siriRemoteNeedsUserAction = siriRemoteNeedsUserAction
        settings.setOnboardingVoiceTool(voiceTool)
        settings.setOnboardingVoiceBindingPreference(bindingPreference)
        settings.setOnboardingRemoteAvailability(remoteAvailability)
        settings.setOnboardingControlMethod(controlMethod)
        settings.setOnboardingControlSource(controlSource ?? .migrated(from: controlMethod))
        settings.setOnboardingStep(step)
        probe = OnboardingInteractionProbe(openURL: { _ in })
        model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [
                AudioDeviceInfo(id: 1, uid: DoubaoAudioDevicePolicy.deviceUID, name: "MiRemoteV 2ch"),
                AudioDeviceInfo(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
            ]
        )
        let localization = LocalizationStore(
            settings: settings,
            resourceBundle: RemoteMicResourceBundle.mainOrDevelopment
        )
        let view = OnboardingView(
            model: model,
            completeRuntimeReadyOverride: true,
            allowsInputSourceSwitching: false,
            systemFunctionKeyAvailableOverride: systemFunctionKeyAvailable,
            voiceToolAvailabilityOverride: voiceToolAvailability ?? [
                .doubao: .available,
                .weixin: .available,
                .typeless: .available,
                .vokie: .available,
                .other: .unknown,
            ],
            initialInputMethodGuideStep: initialInputMethodGuideStep,
            interactionProbe: probe,
            siriRemotePackageInstalledOverride: siriRemotePackageInstalled
        )
        .environmentObject(localization)
        .frame(width: 1020, height: 772)
        let hostingController = NSHostingController(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1020, height: 772),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentViewController = nil
        window.orderOut(nil)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private enum FixtureError: Error {
        case defaultsUnavailable
    }
}
