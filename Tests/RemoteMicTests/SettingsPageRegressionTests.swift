import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RemoteMic

@Suite("Settings page regression")
struct SettingsPageRegressionTests {
    @Test func sidebarAccountTitleKeepsEveryCharacterForWidthBasedWrapping() {
        #expect(SettingsPageBehavior.sidebarAccountTitle(accountDisplayName: nil, loginTitle: "登录") == "登录")
        #expect(SettingsPageBehavior.sidebarAccountTitle(accountDisplayName: "  ", loginTitle: "Login") == "Login")
        #expect(SettingsPageBehavior.sidebarAccountTitle(accountDisplayName: "abcdefgh", loginTitle: "Login") == "abcdefgh")
        #expect(SettingsPageBehavior.sidebarAccountTitle(accountDisplayName: "abcdefghijklmnopq", loginTitle: "Login") == "abcdefghijklmnopq")
        #expect(SettingsPageBehavior.sidebarAccountTitle(accountDisplayName: "一二三四五六七八九", loginTitle: "登录") == "一二三四五六七八九")
        #expect(SettingsPageBehavior.sidebarAccountTitle(accountDisplayName: "  Christopher Anderson  ", loginTitle: "Me") == "Christopher Anderson")
    }

    @MainActor @Test func sidebarWidthLeavesEqualInsetsAroundTheWidestRow() {
        let inset = SettingsPageBehavior.sidebarRowInset
        let label = SettingsPageBehavior.sidebarTextWidth(
            "Permissions",
            size: SettingsPageBehavior.sidebarRowFontSize
        )
        let width = SettingsPageBehavior.sidebarWidth(
            headerTitleWidth: 0,
            headerVersionWidth: 0,
            rowLabelWidths: [label]
        )
        let expected = (label + inset * 2
            + SettingsPageBehavior.sidebarRowIconWidth
            + SettingsPageBehavior.sidebarRowIconSpacing).rounded(.up)
        #expect(width == expected)
        #expect(width <= SettingsPageBehavior.sidebarWidthBounds.upperBound)
    }

    @MainActor @Test func sidebarWidthStaysInsideBoundsForShortLabels() {
        let label = SettingsPageBehavior.sidebarTextWidth(
            "按键",
            size: SettingsPageBehavior.sidebarRowFontSize
        )
        let width = SettingsPageBehavior.sidebarWidth(
            headerTitleWidth: 0,
            headerVersionWidth: 0,
            rowLabelWidths: [label]
        )
        #expect(width == SettingsPageBehavior.sidebarWidthBounds.lowerBound)
        #expect(width < 136)
    }

    @MainActor @Test func sidebarWidthKeepsTheBrandHeaderInside() {
        let header = SettingsPageBehavior.sidebarHeaderTextWidth("SayAll")
        let width = SettingsPageBehavior.sidebarWidth(
            headerTitleWidth: header,
            headerVersionWidth: 0,
            rowLabelWidths: [0]
        )
        let needed = (SettingsPageBehavior.sidebarRowInset * 2
            + SettingsPageBehavior.sidebarHeaderIconWidth
            + SettingsPageBehavior.sidebarHeaderIconSpacing + header).rounded(.up)
        #expect(width >= needed)
    }

    @MainActor @Test func sidebarRowsGrowForLongNamesWithoutShrinkingText() {
        func height(_ title: String, badge: Bool = false) -> CGFloat {
            NSHostingView(rootView: SettingsSidebarRow(
                title: Text(verbatim: title), systemImage: "person.crop.circle",
                showsUpdateBadge: badge
            ).frame(width: 124).fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        #expect(height("Settings", badge: true) == 40)
        #expect(height("Button Profiles") == 40)
        #expect(height("Christopher Anderson") == 40)
        #expect(height("Christopher Alexander Anderson") > 40)
        #expect(height(String(repeating: "longusername", count: 6)) > 40)
    }

    @Test func webRemoteEntryDoesNotRequireAnInviteCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("WebRemoteInvite"))
        #expect(!source.contains("webRemoteInvite"))
        #expect(source.contains("private func requestWebRemoteSession() {\n        openWebRemoteSession()\n    }"))
        #expect(source.contains("model.enableWebRemoteConnection()"))
        #expect(source.contains("guard model.webRemoteState.isEnabled else { return }"))
    }

    @Test func gestureSectionExplainsDisabledHoldOptionsAndShowsLearningProgress() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        // A disabled option must say what it is missing, and two disabled options must
        // explain themselves instead of leaving the editor blank.
        #expect(source.contains("Text(holdBlockerText(blocker))"))
        #expect(source.contains("button_mapping.hold.blocker.long_configured"))
        #expect(source.contains("button_mapping.hold.repeat_prefix"))
        #expect(source.contains("button_mapping.hold.clear_long_to_enable"))
        // Both hold targets share one card height, so the pair cannot look ragged.
        #expect(source.contains("minHeight: 62, maxHeight: 62"))
        let holdPanelStart = try #require(source.range(of: "private func mappingHoldEditorPanel"))
        let holdPanelEnd = try #require(source.range(
            of: "private func mappingHoldOptionColumn",
            range: holdPanelStart.upperBound..<source.endIndex
        ))
        let holdPanel = source[holdPanelStart.lowerBound..<holdPanelEnd.lowerBound]
        // The panel is replaced by the next selection, so it needs no close button of its own.
        #expect(!holdPanel.contains("mappingHoldEditingButton = nil"))
        // One state colour only: no leftover orange warnings or link-blue actions.
        #expect(!holdPanel.contains(".orange"))
        #expect(!holdPanel.contains(".buttonStyle(.link)"))
        // Clicking the same hold entry again must still bring the editor into view.
        #expect(source.contains("requestMappingEditorScroll(focusHold: true)"))
        #expect(source.contains(".onChange(of: mappingEditorScrollRequest)"))
        #expect(source.contains(".id(\"mapping-hold-editor\")"))
        // Learning must state the three steps instead of leaving the count implicit.
        #expect(source.contains("button_mapping.learning.progress"))
        #expect(source.contains("Text(\"\\(number)/\\(total) · \\(localization.text(titleKey))\")"))
        // Internal range/step maths stays out of the user-facing panel.
        #expect(!source.contains("button_mapping.learning.adjusted"))
        // The panel no longer floods itself with the system accent colour.
        #expect(!source.contains("Color.accentColor.opacity(0.07)"))
    }

    @Test func mappingPageSelectsTheDefaultXiaomiStyleOnlyWhenTheSectionOpens() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("model.selectDefaultMappingRemoteIfAvailable()"))
        let hardwarePageStart = try #require(source.range(of: "private func hardwareMappingPage"))
        let hardwarePageEnd = try #require(source.range(
            of: "private var configurationImportBanner",
            range: hardwarePageStart.upperBound..<source.endIndex
        ))
        let hardwarePage = source[hardwarePageStart.lowerBound..<hardwarePageEnd.lowerBound]
        #expect(!hardwarePage.contains("selectDefaultMappingRemoteIfAvailable"))
    }

    @Test func mappingPageReappliesTheXiaomiDefaultAfterLateBluetoothReadiness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        // 启动时设置窗口常先于蓝牙就绪打开，那一刻只能得到 xiaomi_unavailable；
        // 小米 ready 之后必须再判一次默认画布，否则页面永远停在 Chromecast。
        let readyBranch = try #require(modelSource.range(
            of: "if case .ready = state {\n            refreshRemoteDeviceNames(reason: .connection)"
        ))
        let readyRemainder = modelSource[readyBranch.lowerBound...]
        let readyEnd = try #require(readyRemainder.range(of: "\n        }"))
        #expect(readyRemainder[..<readyEnd.upperBound].contains(
            "applyDefaultMappingRemoteAfterConnectionChange()"
        ))

        // Chromecast 的「连接即选中」必须经过统一策略：已连接的小米不能被抢占。
        let ensureStart = try #require(modelSource.range(
            of: "private func ensureChromecastProfile() -> UUID {"
        ))
        let ensureRemainder = modelSource[ensureStart.upperBound...]
        let ensureEnd = try #require(ensureRemainder.range(
            of: "private var hasConnectedXiaomiProfile"
        ))
        #expect(ensureRemainder[..<ensureEnd.lowerBound].contains(
            "RemoteDeviceNamePolicy.shouldAdoptConnectionSelection("
        ))

        // 用户手动点设备卡之后，连接事件不得把画布抢回小米。
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settingsSource.contains("model.noteManualRemoteProfileSelection()"))
        // 补优选只在按键页可见时发生：其他页面的编辑不能被自动切换打断。
        #expect(modelSource.contains("guard isMappingPageVisible else {"))
        #expect(settingsSource.contains("model.setMappingPageVisible(selectedSection == .mapping)"))
    }

    @Test func remoteSelectorKeepsTheSelectedCardInView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let selectorStart = try #require(source.range(of: "private func remoteDeviceSelector"))
        let selectorEnd = try #require(source.range(
            of: "private func remoteDeviceCard",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selectorSource = source[selectorStart.lowerBound..<selectorEnd.lowerBound]

        // 三款遥控器同时在线时卡片行放不下；选中的 Chromecast 排在最后，
        // 不主动滚动就完全看不见，用户会以为画布和顶部高亮对不上。
        #expect(selectorSource.contains("ScrollViewReader { proxy in"))
        #expect(selectorSource.contains(".id(profile.id)"))
        #expect(selectorSource.contains("revealSelectedRemoteCard(using: proxy"))
        #expect(selectorSource.contains(".onChange(of: settings.selectedRemoteProfileID)"))
        #expect(source.contains("proxy.scrollTo(selectedProfileID, anchor: .center)"))
    }

    @Test func holdChipUsesTheSharedCanvasChrome() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let canvasSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMappingCanvas.swift"),
            encoding: .utf8
        )

        // 三种画布的「按住」胶囊必须是同一份规格，不能在各自画布里再写一遍数值。
        #expect(canvasSource.contains("enum RemoteMappingCardChrome"))
        #expect(canvasSource.contains("static let background = AnyShapeStyle(.quaternary)"))
        let chipStart = try #require(canvasSource.range(of: "Text(holdSummary(button))"))
        let remainder = canvasSource[chipStart.lowerBound...]
        let chipEnd = try #require(remainder.range(of: ".background("))
        let chip = remainder[..<chipEnd.upperBound]
        #expect(chip.contains("RemoteMappingCardChrome.HoldChip"))
        #expect(!chip.contains("size: 12"))
        #expect(!chip.contains("padding(.horizontal, 6)"))
        #expect(!chip.contains("cornerRadius: 5"))
    }

    @Test func settingsSidebarAndPageUseTheSameBackgroundColor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(
            settingsSource.contains(
                ".background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea())"
            )
        )
        #expect(!settingsSource.contains(
            ".background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())"
        ))
    }

    @Test func connectionPageKeepsCompatibilityAudioControlsWithoutExtraTools() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("audio.action.refresh_devices"))
        #expect(settingsSource.contains("audioCompatibilityPanel"))
        #expect(settingsSource.contains("model.selectDoubaoAudioDevice()"))
        #expect(settingsSource.contains("model.openDoubaoDriverInstructions(using: localization)"))
        #expect(!settingsSource.contains("audio.action.learn_virtual_microphones"))
        #expect(!settingsSource.contains("audio.action.send_test_tone"))
        #expect(!settingsSource.contains("model.testToneStatus.text(using: localization)"))
    }

    @Test func connectionPageShowsVoiceKeyCompatibilityWarningOnlyFromModelState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("model.voiceKeyCompatibilityWarning"))
        #expect(settingsSource.contains("model.refreshVoiceKeyCompatibilityWarning()"))
        #expect(settingsSource.contains("model.recheckRemoteInput()"))
        #expect(settingsSource.contains("warning.messageKey"))
        #expect(settingsSource.contains("connection.voice_key_compatibility.title"))
    }

    @Test func everyHardwareMappingPageUsesTheSharedHostEditor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let packageSource = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(settingsSource.contains("#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)"))
        #expect(settingsSource.contains("siriRemoteMappingPage"))
        #expect(settingsSource.contains("model.isAppleSiriRemote"))
        #expect(settingsSource.contains("SiriRemoteMappingCanvas("))
        #expect(settingsSource.contains("private func hardwareMappingPage<HardwareCanvas: View>"))
        #expect(settingsSource.components(separatedBy: "hardwareMappingPage").count >= 4)
        #expect(settingsSource.components(separatedBy: "mappingEditorPanel(target)").count == 2)
        #expect(packageSource.contains("SAYALL_SIRI_REMOTE_ENABLED"))
        #expect(packageSource.contains("SAYALL_SIRI_REMOTE_PACKAGE_PATH"))
    }

    @Test func siriRemoteAddsPlayPauseAndMuteWithoutExpandingXiaomiLayout() {
        #expect(RemoteButton.xiaomiCases.count == 12)
        #expect(!RemoteButton.xiaomiCases.contains(.playPause))
        #expect(!RemoteButton.xiaomiCases.contains(.mute))
        #expect(RemoteButton.allCases.contains(.playPause))
        #expect(RemoteButton.allCases.contains(.mute))
    }

    @Test func permissionRecoveryRequestsMissingPermissionsAndOpensExactSystemSettings() {
        #expect(SettingsPageBehavior.permissionAction(for: .inputMonitoring, isGranted: false) == .request)
        #expect(SettingsPageBehavior.permissionAction(for: .accessibility, isGranted: false) == .request)
        #expect(SettingsPageBehavior.permissionAction(for: .bluetooth, isGranted: false) == .openSystemSettings(
            "x-apple.systempreferences:com.apple.BluetoothSettings"
        ))
        #expect(SettingsPageBehavior.permissionAction(for: .inputMonitoring, isGranted: true) == .openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ))
        #expect(SettingsPageBehavior.permissionAction(for: .accessibility, isGranted: true) == .openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ))

        var requestCount = 0
        var openedURLs: [String] = []
        SettingsPageBehavior.perform(
            .request,
            requestPermission: { requestCount += 1 },
            openSystemSettings: { openedURLs.append($0) }
        )
        SettingsPageBehavior.perform(
            SettingsPageBehavior.permissionAction(for: .accessibility, isGranted: true),
            requestPermission: { requestCount += 1 },
            openSystemSettings: { openedURLs.append($0) }
        )

        #expect(requestCount == 1)
        #expect(openedURLs == [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
        #expect(SettingsPermissionAction.request.titleKey == "permission.action.request")
        #expect(SettingsPageBehavior.permissionAction(
            for: .inputMonitoring,
            isGranted: true
        ).titleKey == "permission.action.open_settings")
    }

    @Test func diagnosticSummaryCopiesOnlyDeterministicSanitizedStatus() {
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.9.22 (183)",
            bluetoothGranted: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true,
            runtimeLogAvailable: true
        )
        var pastedValues: [String] = []
        var auditLogs: [String] = []

        SettingsPageBehavior.copyDiagnosticSummary(
            snapshot,
            writeToPasteboard: { pastedValues.append($0) },
            writeAuditLog: { auditLogs.append($0) }
        )

        #expect(pastedValues == [[
            "SayAll settings diagnostics",
            "app_version=1.9.22 (183)",
            "permission_bluetooth=true",
            "permission_input_monitoring=false",
            "permission_accessibility=true",
            "runtime_log_available=true",
        ].joined(separator: "\n")])
        #expect(auditLogs == [
            "SETTINGS DIAGNOSTICS copied permission_bluetooth=true " +
                "permission_input_monitoring=false permission_accessibility=true",
        ])

        let copiedText = pastedValues[0].lowercased()
        for forbiddenField in ["/users/", "device_id", "transcript", "audio_content", "app_path"] {
            #expect(!copiedText.contains(forbiddenField))
        }
    }

    @Test func legacyPermissionNavigationResolvesToTheConsolidatedSettingsPage() {
        #expect(SettingsPageBehavior.visibleSection(for: .permissions) == .about)
        for section in SettingsSection.allCases where section != .permissions {
            #expect(SettingsPageBehavior.visibleSection(for: section) == section)
        }
    }

    @Test func settingsRouteIsTheConsolidatedSettingsPage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("case .about: return \"settings.section.settings\""))
        #expect(source.contains("switch SettingsPageBehavior.visibleSection(for: selectedSection)"))
        #expect(source.contains("performPermissionAction(inputMonitoringAction)"))
        #expect(source.contains("SettingsPageBehavior.copyDiagnosticSummary("))
        #expect(source.contains("Text(\"settings.permissions.title\")"))
        #expect(source.contains("Text(\"settings.general.title\")"))
        #expect(source.contains("Button(\"about.configuration.export\", action: exportConfiguration)"))
        #expect(source.contains("Button(\"about.configuration.import\", action: importConfiguration)"))
        #expect(source.contains("about.preferences.show_status_bar_icon"))
        #expect(source.contains("about.preferences.launch_at_login"))
        #expect(source.contains("about.preferences.open_main_window_at_launch"))
        #expect(source.contains("diagnostics.logs.copy_summary"))
        #expect(source.contains("about.version.release_notes_title"))
    }

    @Test func applicationEditMenuPreservesStandardTextEditingShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        for key in ["copy:", "paste:", "cut:", "undo:", "redo:", "selectAll:"] {
            #expect(appSource.contains("action: \"\(key)\""))
        }
        #expect(appSource.contains("item.target = nil"))
        #expect(appSource.contains("common.action.copy"))
        #expect(appSource.contains("common.action.select_all"))
    }

    @Test func versionTapRevealRequiresFiveConsecutiveTaps() {
        var counter = VersionTapRevealCounter()

        for expectedCount in 1...4 {
            let revealed = counter.registerTap()
            #expect(!revealed)
            #expect(counter.tapCount == expectedCount)
        }

        let revealed = counter.registerTap()
        #expect(revealed)
        #expect(counter.tapCount == 0)
        let revealedAgain = counter.registerTap()
        #expect(!revealedAgain)
        #expect(counter.tapCount == 1)
    }

    @Test func privateFeatureFallbackRemainsCompletelyHiddenWithoutPackage() {
        #if !canImport(SayAllAI)
        let privateFeature = PrivateFeatureIntegration(localeIdentifier: "zh-Hans")

        #expect(!privateFeature.isAvailable)
        #expect(!privateFeature.isFeatureVisible)
        #expect(!privateFeature.shouldShowEnrollment)
        #endif
    }

    @Test func membershipFeatureRequiresExplicitServiceConfiguration() {
        let membershipFeature = MembershipFeatureIntegration(configuration: nil)

        #expect(!membershipFeature.isFeatureVisible)
        #expect(membershipFeature.buttonProfilesAccessDecision == .unavailable)
    }

    @Test func serviceEnvironmentLivesInGeneralSettingsPageOutsideMembership() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let integrationSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MembershipFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        #expect(!settingsSource.contains("case serviceEnvironment"))
        #expect(!settingsSource.contains("case .serviceEnvironment:"))
        #expect(settingsSource.contains("static let membership = SettingsSection"))
        #expect(settingsSource.contains("case .membership:"))
        #expect(settingsSource.contains("if membershipFeature.isEnvironmentSettingsVisible"))
        #expect(settingsSource.contains("membershipFeature.serviceEnvironmentSettingsView()"))
        #expect(integrationSource.contains("func serviceEnvironmentSettingsView()"))
        #expect(integrationSource.contains("adapter?.serviceEnvironmentSettingsView()"))
    }

    @Test func publicHostDoesNotOwnServiceEnvironmentConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let membership = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MembershipFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        #expect(!membership.contains("ServiceEnvironment"))
        #expect(!membership.contains("membership-staging.sayall.app"))
        #expect(!membership.contains("keychainNamespace"))
    }

    @Test func commerceBridgeKeepsPrivateCodeOptionalAndRoutesEveryRemoteSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let membership = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MembershipFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let macro = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MacroFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(package.contains("SAYALL_MEMBERSHIP_ADAPTER_PACKAGE_PATH"))
        #expect(package.contains("membership source packages are not supported"))
        #expect(package.contains("SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH"))
        #expect(package.contains("SAYALL_COMBINATION_ACTIONS_PATH"))
        #expect(package.contains("SAYALL_BUTTON_PROFILES_PACKAGE_PATH"))
        #expect(package.contains("SAYALL_BUTTON_PROFILES_PACKAGE_PATH requires SAYALL_COMBINATION_ACTIONS_PATH"))
        #expect(package.contains("private artifacts cannot be combined with private source packages"))
        #expect(package.contains("SayAllMembershipHostAdapter"))
        #expect(package.contains("SAYALL_MEMBERSHIP_ENABLED"))
        #expect(!package.contains("membershipAdapterPackagePath"))
        #expect(!package.contains(".product(name: \"SayAllMembershipCore\""))
        #expect(!package.contains(".product(name: \"SayAllMembershipUI\""))
        #expect(membership.contains("#if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)"))
        #expect(membership.contains("import SayAllMembershipHostAdapter"))
        #expect(!membership.contains("import SayAllMembershipCore"))
        #expect(!membership.contains("import SayAllMembershipUI"))
        #expect(membership.contains("AnyView(EmptyView())"))
        #expect(membership.contains("@unknown default:"))
        #expect(macro.contains("func executeBoundAction("))
        #expect(macro.contains("#if canImport(SayAllButtonProfiles)"))
        #expect(!macro.contains("canImport(SayAllMembershipCore)"))
        #expect(macro.contains(".chromecastVoiceRemote"))
        #expect(macro.contains("buttonProfilesFeature.executeBoundAction("))
        #expect(macro.contains("feature.executeBoundMacro("))
        #expect(macro.contains("return false"))
        #expect(model.contains("overrideActionPerformer:"))
        #expect(model.contains("performButtonProfileBoundAction("))
        #expect(model.contains("private func performMobileConfiguredAction("))
        #expect(model.contains("webRemoteClient.onCommand"))
        #expect(model.contains("webRemoteClient.onButtonEvent"))
        #expect(model.contains("JSONDecoder().decode(ConfiguredButtonAction.self, from: payload)"))
        #expect(settings.contains("case .macros: macroFeatureVisible"))
        #expect(settings.contains("case .buttonProfiles: buttonProfilesVisible"))
        #expect(settings.contains("case .membership: membershipVisible"))

        #if !canImport(SayAllMacroRemoteMic) && !canImport(SayAllButtonProfiles)
        let macroFeature = MacroFeatureIntegration(localeIdentifier: "zh-Hans")
        #expect(!macroFeature.executeBoundAction(
            profileID: nil,
            button: .menu,
            trigger: .singleClick,
            hostActionPerformer: { _ in true },
            shortcutPerformer: { _, _ in true }
        ))
        #endif
    }

    @Test func nearbyMobileListenerOnlyStartsFromAUserConnectionEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        let startup = try #require(source.range(of: "func startIfNeeded()"))
        let stop = try #require(source.range(
            of: "func stop()",
            range: startup.upperBound..<source.endIndex
        ))
        let startupSource = source[startup.lowerBound..<stop.lowerBound]
        #expect(!startupSource.contains("phoneRemoteServer.start()"))
        #expect(!startupSource.contains("watchBluetoothServer.start()"))

        let phoneEntry = try #require(source.range(of: "func enablePhoneRemoteConnection()"))
        let watchEntry = try #require(source.range(
            of: "func enableWatchRemoteConnection()",
            range: phoneEntry.upperBound..<source.endIndex
        ))
        let phoneEntrySource = source[phoneEntry.lowerBound..<watchEntry.lowerBound]
        #expect(phoneEntrySource.contains("phoneRemoteServer.start()"))
        #expect(phoneEntrySource.contains("watchBluetoothServer.start()"))

        let webEntry = try #require(source.range(
            of: "func enableWebRemoteConnection()",
            range: watchEntry.upperBound..<source.endIndex
        ))
        let watchEntrySource = source[watchEntry.lowerBound..<webEntry.lowerBound]
        #expect(watchEntrySource.contains("enablePhoneRemoteConnection()"))
        #expect(source.contains("func disablePhoneRemoteConnection()"))
        #expect(source.contains("phoneRemoteServer.stop()"))
        #expect(source.contains("watchBluetoothServer.stop()"))
        #expect(source.contains("watchBluetoothServer.updateButtonTitles(titles)"))
        #expect(source.contains("func togglePhoneRemoteConnection()"))
        #expect(source.contains("localization.text(\"connection.phone.cancel_waiting\")"))
        #expect(source.contains("response == .alertThirdButtonReturn"))
        #expect(source.contains("guard let self, self.isPhoneRemoteConnectionEnabled,"))
        #expect(source.contains("guard self.isPhoneRemoteConnectionEnabled else"))
        #expect(source.contains("phoneRemoteServer.onInvitationChange"))
        #expect(source.contains("@Published private(set) var phoneRemoteInvitation"))
    }

    @Test func iphoneAndWatchVoiceSessionsRemainSourceIsolated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("case nearbyPhone"))
        #expect(source.contains("case nearbyWatch"))
        #expect(source.contains("phoneRemoteServer.onVoiceStartResult"))
        #expect(source.contains("source: .nearbyPhone,\n                    completion: completion"))
        #expect(source.contains("stopPhoneVoice(source: .nearbyPhone)"))
        #expect(source.contains("watchBluetoothServer.onVoiceStartResult"))
        #expect(source.contains("source: .nearbyWatch,\n                    completion: completion"))
        #expect(source.contains("stopPhoneVoice(source: .nearbyWatch)"))
        #expect(source.contains("case .deferUntilStopped"))
        #expect(source.contains("return .busy"))
        #expect(!source.contains("startPhoneVoice(source: .nearby)"))
    }

    @Test func mobileConnectionStatusMeetsFontAndSnapshotGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/SettingsScreenshotRenderer.swift"
            ),
            encoding: .utf8
        )

        #expect(!settingsSource.contains("Text(\"connection.phone.qr_badge\")"))

        let statusPill = try #require(settingsSource.range(of: "private struct StatusPill"))
        let statusPillBlock = settingsSource[statusPill.lowerBound...]
            .prefix(420)
        #expect(statusPillBlock.contains(".font(.system(size: 12, weight: .semibold))"))
        #expect(appSource.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"))
        #expect(rendererSource.contains("width >= 800"))
        #expect(rendererSource.contains("height >= 650"))
        for section in ["connection", "mapping", "statistics", "about"] {
            #expect(rendererSource.contains(".\(section)"))
        }
        #expect(!rendererSource.contains("        .permissions,"))
    }

    @Test func mappingHeaderUsesCompactLayoutAtMinimumWindowWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let mappingPage = try #require(settingsSource.range(of: "private var mappingPage: some View"))
        let sharedPage = try #require(settingsSource.range(
            of: "private func hardwareMappingPage<HardwareCanvas: View>",
            range: mappingPage.upperBound..<settingsSource.endIndex
        ))
        let editorPanel = try #require(settingsSource.range(
            of: "private func mappingEditorPanel",
            range: sharedPage.upperBound..<settingsSource.endIndex
        ))
        let mappingSource = settingsSource[sharedPage.lowerBound..<editorPanel.lowerBound]

        let headerStart = try #require(settingsSource.range(of: "private var mappingPageHeader"))
        let headerSource = settingsSource[headerStart.lowerBound..<mappingPage.lowerBound]
        let title = try #require(headerSource.range(of: "PageHeader(title:"))
        let subtitle = try #require(headerSource.range(of: "Text(localization.text(\"button_mapping.page.subtitle\"))"))
        let toggle = try #require(headerSource.range(of: "mappingHeaderToggle"))
        #expect(title.lowerBound < subtitle.lowerBound)
        #expect(subtitle.lowerBound < toggle.lowerBound)
        #expect(headerSource.contains("VStack(alignment: .leading, spacing: 6)"))
        #expect(!headerSource.contains("HStack"))
        // 卡片按底边对齐页头：底边固定后，页头到工具行的间距不再随控制器卡片高度变化。
        #expect(mappingSource.contains("HStack(alignment: .bottom, spacing: 14)"))
        #expect(!mappingSource.contains("HStack(alignment: .top, spacing: 14)"))
        #expect(mappingSource.contains(".padding(.top, 18)"))

        #expect(!mappingSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(mappingSource.contains("private var mappingHeaderToggle"))
        #expect(!mappingSource.contains(".frame(width: 400)"))
        #expect(!mappingSource.contains(".frame(width: 320)"))
        #expect(mappingSource.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        #expect(mappingSource.contains(".fixedSize(horizontal: true, vertical: false)"))

        #expect(settingsSource.contains("hardwareMappingPage(includeSiriScrollArrow: true)"))
        #expect(settingsSource.contains("hardwareMappingPage {"))
    }

    /// 保存入口必须落在横向滚动区域之外，否则方案一多，它就会跟着方案左右漂移而不是右对齐。
    @Test func mappingProfileRowPinsTheSaveActionOutsideTheScrollingChips() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let selectorStart = try #require(source.range(of: "private var mappingProfileSelector"))
        let chipHelper = try #require(source.range(
            of: "private func mappingProfileChip",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let rowSource = source[selectorStart.lowerBound..<chipHelper.lowerBound]

        let scrollChips = try #require(rowSource.range(of: "ScrollView(.horizontal"))
        let saveAction = try #require(rowSource.range(of: "mappingSaveAsProfileButton"))
        #expect(scrollChips.upperBound < saveAction.lowerBound)
        // 给滚动区域加 maxWidth: .infinity 会把它变成贪心视图，保存入口会被挤出右边界。
        #expect(!rowSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        // 滚动区域里的 Spacer 只会被压缩到最小长度，起不到右对齐作用。
        #expect(!rowSource.contains("Spacer(minLength:"))
        #expect(!rowSource.contains(".controlSize(.small)"))
        #expect(!rowSource.contains(".font(.system(size: 11))"))

        let saveButtonStart = try #require(source.range(of: "private var mappingSaveAsProfileButton"))
        let saveButtonEnd = try #require(source.range(
            of: "private func mappingInheritanceControl",
            range: saveButtonStart.upperBound..<source.endIndex
        ))
        let saveButtonSource = source[saveButtonStart.lowerBound..<saveButtonEnd.lowerBound]
        // 保存、编辑、完成必须是同一份样式，切换方案时右侧只换文字，尺寸与描边不变。
        #expect(saveButtonSource.contains("mappingProfileRowButton("))

        let rowButtonStart = try #require(source.range(of: "private func mappingProfileRowButton"))
        let rowButtonSource = source[rowButtonStart.lowerBound..<saveButtonStart.lowerBound]
        // 中文标注字号不得小于 12pt，行内动作入口不能再退回 11pt 小号。
        #expect(rowButtonSource.contains(".font(.system(size: 12))"))
        // 入口只保留文字，不再带下载/编辑图标。
        #expect(!rowButtonSource.contains("square.and.arrow.down"))
        #expect(!rowButtonSource.contains("Image(systemName:"))
        #expect(rowButtonSource.contains(".fixedSize()"))
    }

    /// 选中方案只是**浏览**：右侧出现「编辑」，编辑是会员功能，未解锁时整页只读。
    @Test func mappingProfileEditingIsGatedByTheEditEntryAndMembership() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        // 行内右端只放一个动作：基础映射是「保存」，选中方案后是「编辑 / 完成」。
        let selectorStart = try #require(source.range(of: "private var mappingProfileSelector"))
        let chipHelper = try #require(source.range(
            of: "private func mappingProfileChip",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let rowSource = source[selectorStart.lowerBound..<chipHelper.lowerBound]
        #expect(rowSource.contains("\"button_mapping.profile.edit\""))
        #expect(rowSource.contains("\"button_mapping.profile.edit_done\""))
        #expect(rowSource.contains("if isMappingProfileUnlocked"))
        #expect(rowSource.contains("} else if selectedMappingProfileIsEditable {"))

        // 会员判定必须复用按键方案页那套决策，不能自己发明一套规则；
        // 而且要先过方案组件自己那份访问判定，否则测试构建里会出现「列表看得见、编辑被拦」的死按钮。
        let gateStart = try #require(source.range(of: "private var canEditMappingProfiles"))
        let gateSource = source[gateStart.lowerBound...].prefix(1400)
        #expect(gateSource.contains("guard macroFeature.canUseMappingProfiles else { return false }"))
        #expect(gateSource.contains("membershipFeature.buttonProfilesAccessDecision"))
        #expect(gateSource.contains("case .allowed, .temporarilyOffline, .authorized:"))
        #expect(gateSource.contains("case .requiresPlus, .unavailable:"))
        // 会员模块整体不可用的构建里没有可点开通的入口，不能把人锁死。
        #expect(gateSource.contains("guard membershipFeature.isFeatureVisible else { return true }"))

        let integration = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/MacroFeatureIntegration.swift"),
            encoding: .utf8
        )
        let accessStart = try #require(integration.range(of: "var canUseMappingProfiles: Bool"))
        let accessSource = integration[accessStart.lowerBound...].prefix(600)
        #expect(accessSource.contains("buttonProfilesFeature.buttonProfilesAccessDecision.permitsAccess"))

        // 唯一的会员入口是私有模块的视图，仓库不得自绘第二个开通按钮。
        let toolbarStart = try #require(source.range(of: "private var mappingProfileToolbar"))
        let toolbarSource = source[toolbarStart.lowerBound..<gateStart.lowerBound]
        #expect(toolbarSource.contains("membershipFeature.membershipRequiredView(forButtonProfiles: true)"))
        #expect(toolbarSource.contains("showsProfileMembershipNotice"))

        // 写入路径：编辑器禁用之外，保存函数自己也要拒绝只读预览。
        #expect(source.contains("guard !isMappingProfilePreviewOnly else { return }"))
        // 三处编辑器（动作、按住、单独的按住区）加页脚的「恢复默认」，一处都不能漏。
        #expect(source.components(separatedBy: ".disabled(isMappingProfilePreviewOnly)").count - 1 == 4)
        #expect(source.contains("private var isMappingProfilePreviewOnly: Bool"))

        // 切换方案必须回到只读预览，不能让「刚解锁过」跟着带过去。
        let selectStart = try #require(source.range(of: "private func selectMappingProfile("))
        let selectEnd = try #require(source.range(
            of: "private func openMappingProfileForEditing",
            range: selectStart.upperBound..<source.endIndex
        ))
        let selectSource = source[selectStart.lowerBound..<selectEnd.lowerBound]
        #expect(selectSource.contains("isEditingMappingProfile = false"))
        #expect(selectSource.contains("showsProfileMembershipNotice = false"))
    }

    /// 私有「默认」方案就是基础映射：行内只能出现一项，不能同时显示「基础映射」和「默认」。
    @Test func mappingProfileRowDoesNotDuplicateTheBaseEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let selectorStart = try #require(source.range(of: "private var mappingProfileSelector"))
        let baseHelper = try #require(source.range(
            of: "private func baseMappingProfile",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let rowSource = source[selectorStart.lowerBound..<baseHelper.lowerBound]

        // 基础映射项的名称优先取「默认」方案名，列表里只剩其余方案。
        #expect(rowSource.contains("baseProfile?.name ?? localization.text(\"button_mapping.base_profile\")"))
        #expect(rowSource.contains("ForEach(listedProfiles)"))
        #expect(!rowSource.contains("ForEach(macroFeature.mappingProfiles(device:"))
        // 组件无法区分可编辑性时回退到「基础映射 + 全部方案」，不能因此隐藏用户方案。
        #expect(rowSource.contains("baseMappingProfile(in: profiles)"))
        #expect(source.contains("!macroFeature.isMappingProfileEditable($0.id)"))
    }

    @Test func remoteMappingScrollsResetWhenSwitchingProfilesAndConnectionPhotoFollowsModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let connectionPanel = try #require(source.range(of: "private var connectionDevicePanel"))
        let mappingPage = try #require(source.range(
            of: "private var mappingPage",
            range: connectionPanel.upperBound..<source.endIndex
        ))
        let connectionSource = source[connectionPanel.lowerBound..<mappingPage.lowerBound]
        #expect(connectionSource.contains("private var connectionRemotePhoto"))
        #expect(connectionSource.contains("SiriRemoteConnectionPhoto()"))

        let mappingEnd = try #require(source.range(
            of: "private func mappingEditorPanel",
            range: mappingPage.upperBound..<source.endIndex
        ))
        let mappingSource = source[mappingPage.lowerBound..<mappingEnd.lowerBound]
        #expect(mappingSource.contains(".id(settings.selectedRemoteProfileID)"))
        #expect(mappingSource.components(
            separatedBy: ".id(settings.selectedRemoteProfileID)"
        ).count == 2)
    }

    @Test func mappingVoiceSettingsPanelUsesCompactLayoutAtMinimumWindowWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let panel = try #require(settingsSource.range(of: "private func mappingVoiceSettingsPanel"))
        let selector = try #require(settingsSource.range(
            of: "private func remoteDeviceSelector",
            range: panel.upperBound..<settingsSource.endIndex
        ))
        let panelSource = settingsSource[panel.lowerBound..<selector.lowerBound]

        #expect(panelSource.contains("VStack(alignment: .leading, spacing: 12)"))
        #expect(!panelSource.contains("HStack(spacing: 16)"))
        #expect(panelSource.contains("mappingVoiceKeyModeControl"))
        #expect(!panelSource.contains("\"connection.voice_key_mode.unverified\""))
        #expect(panelSource.contains("connection.voice_key_mode.unverified_detail"))
        #expect(panelSource.contains("mappingVoiceFnTapControl"))
        #expect(!panelSource.contains("mappingVoiceShortTapFocusControl"))
        #expect(panelSource.contains("mappingRestoreDefaultsButton"))
    }

    /// 语音键没有可映射动作，它的设置面板只能在点击语音键之后出现，而且出现时是页面上唯一的编辑区。
    @Test func voiceKeySettingsPanelOnlyAppearsAfterClickingTheVoiceKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let page = try #require(settingsSource.range(of: "private func hardwareMappingPage"))
        let pageEnd = try #require(settingsSource.range(
            of: "private var configurationImportBanner",
            range: page.upperBound..<settingsSource.endIndex
        ))
        let pageSource = settingsSource[page.lowerBound..<pageEnd.lowerBound]

        // 面板由状态门控，并且排在画布之后：页面加载时不存在这份内容。
        let canvas = try #require(pageSource.range(of: "hardwareCanvas()"))
        let gate = try #require(pageSource.range(
            of: "if isMappingVoiceSettingsPresented {",
            range: canvas.upperBound..<pageSource.endIndex
        ))
        #expect(pageSource[gate.upperBound...].contains(
            "mappingVoiceSettingsPanel(includeSiriScrollArrow: includeSiriScrollArrow)"
        ))
        // 旧的常驻页脚（含 ID）必须完全消失，否则内容会在没点语音键时就出现。
        #expect(!settingsSource.contains("mapping-footer"))
        #expect(!settingsSource.contains("private func mappingFooter"))

        // 三个遥控器画布都走同一个入口，不允许任一页面绕过面板直接展开。
        #expect(!settingsSource.contains("onVoiceSettings: { mappingVoiceSettingsRequest += 1 }"))
        #expect(settingsSource.components(separatedBy: "onVoiceSettings: presentMappingVoiceSettings").count == 4)

        let presentation = try #require(settingsSource.range(of: "private func presentMappingVoiceSettings()"))
        let presentationEnd = try #require(settingsSource.range(
            of: "private func mappingConfiguration(",
            range: presentation.upperBound..<settingsSource.endIndex
        ))
        let presentationSource = settingsSource[presentation.lowerBound..<presentationEnd.lowerBound]
        // 点语音键要收起普通按键的编辑器，点一次展开、再点一次收起。
        #expect(presentationSource.contains("mappingEditingTarget = nil"))
        #expect(presentationSource.contains("mappingHoldEditingButton = nil"))
        #expect(presentationSource.contains("isMappingVoiceSettingsPresented = true"))
        #expect(presentationSource.contains("isMappingVoiceSettingsPresented = false"))
        #expect(presentationSource.contains("mappingVoiceSettingsRequest &+= 1"))

        // 反过来，打开普通按键的编辑器时必须收起语音键面板。
        let actionEditor = try #require(settingsSource.range(of: ".onChange(of: mappingEditingTarget?.id)"))
        let holdEditor = try #require(settingsSource.range(of: ".onChange(of: mappingHoldEditingButton?.rawValue)"))
        let neighbor = try #require(settingsSource.range(
            of: ".onChange(of: mappingEditorScrollRequest)",
            range: holdEditor.upperBound..<settingsSource.endIndex
        ))
        #expect(settingsSource[actionEditor.upperBound..<holdEditor.lowerBound].contains(
            "isMappingVoiceSettingsPresented = false"
        ))
        #expect(settingsSource[holdEditor.upperBound..<neighbor.lowerBound].contains(
            "isMappingVoiceSettingsPresented = false"
        ))
    }

    @Test func voiceSessionStopDoesNotTriggerInputFocus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let voiceStart = try #require(source.range(of: "func bluetoothBridgeDidStartVoice"))
        let voiceStop = try #require(source.range(
            of: "func bluetoothBridgeDidStopVoice",
            range: voiceStart.upperBound..<source.endIndex
        ))
        let nextDelegate = try #require(source.range(
            of: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode",
            range: voiceStop.upperBound..<source.endIndex
        ))
        let startSource = source[voiceStart.lowerBound..<voiceStop.lowerBound]
        let stopSource = source[voiceStop.lowerBound..<nextDelegate.lowerBound]

        #expect(!startSource.contains("focusFrontmostComposer"))
        #expect(!stopSource.contains("VoiceShortTapFocusPolicy"))
        #expect(!stopSource.contains("focusFrontmostComposer"))
        #expect(!stopSource.contains("voice_short_tap_focus"))
        #expect(!source.contains("settings.voiceShortTapFocusEnabled"))
    }

    @Test func settingsWindowDragsOnlyFromDedicatedTopArea() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let sidebarStart = try #require(settingsSource.range(of: "private var sidebar: some View {"))
        let visibleSectionsStart = try #require(settingsSource.range(
            of: "private var visibleSections: [SettingsSection]",
            range: sidebarStart.upperBound..<settingsSource.endIndex
        ))
        let sidebarSource = settingsSource[sidebarStart.lowerBound..<visibleSectionsStart.lowerBound]

        #expect(appSource.contains("window.isMovableByWindowBackground = false"))
        #expect(!appSource.contains("window.isMovableByWindowBackground = true"))
        #expect(settingsSource.contains("WindowDragArea()"))
        #expect(settingsSource.contains("window?.performDrag(with: event)"))
        #expect(settingsSource.contains("SettingsPageBehavior.sidebarTopDragHeight"))
        #expect(!sidebarSource.contains(".ignoresSafeArea(.container, edges: .top)"))
    }

    @Test func settingsWindowEstablishesItsFullSizeBeforeCentering() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        let contentSize = try #require(appSource.range(
            of: "window.setContentSize(NSSize(width: 960, height: 742))"
        ))
        let autosave = try #require(appSource.range(
            of: "window.setFrameAutosaveName(\"RemoteMicSettings\")",
            range: contentSize.upperBound..<appSource.endIndex
        ))
        let center = try #require(appSource.range(
            of: "window.center()",
            range: autosave.upperBound..<appSource.endIndex
        ))

        #expect(contentSize.upperBound <= autosave.lowerBound)
        #expect(autosave.upperBound <= center.lowerBound)
    }

    @Test func settingsWindowHonorsDockPreferenceAndKeepsStandardWindowActions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("window.hidesOnDeactivate = false"))
        #expect(appSource.contains("window.delegate = self"))
        #expect(appSource.contains("SettingsWindowActivationPolicy.value("))
        #expect(appSource.contains("func windowWillClose(_ notification: Notification)"))
        #expect(appSource.contains("func windowDidMiniaturize(_ notification: Notification)"))
        #expect(appSource.contains("func windowDidDeminiaturize(_ notification: Notification)"))
        #expect(appSource.contains("source: \"window_miniaturized\""))
        #expect(appSource.contains("source: \"window_deminiaturized\""))
        #expect(appSource.contains("source: \"activation_policy\""))
        #expect(appSource.contains("isSettingsWindowOpen = false"))
        #expect(!appSource.contains("window.canHide = false"))
        #expect(appSource.contains("NSApp.keyWindow?.performClose(nil)"))
        #expect(appSource.contains("performMiniaturize:"))
        #expect(appSource.contains("hideOtherApplications:"))
        #expect(appSource.contains("unhideAllApplications:"))
        #expect(appSource.contains("NSApp.windowsMenu = windowMenu"))

        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: false,
            isSettingsWindowOpen: true
        ) == .accessory)
        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: false,
            isSettingsWindowOpen: false
        ) == .accessory)
        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: true,
            isSettingsWindowOpen: false
        ) == .regular)
    }

    @Test func hiddenDockAndMenuBarKeepAnExplicitLaunchRecoveryPath() throws {
        #expect(AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: true,
            showDockIcon: true,
            showStatusBarIcon: true
        ))
        #expect(AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: false,
            showDockIcon: false,
            showStatusBarIcon: false
        ))
        #expect(!AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: false,
            showDockIcon: true,
            showStatusBarIcon: false
        ))
        #expect(!AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: false,
            showDockIcon: false,
            showStatusBarIcon: true
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("guard statusItem == nil else"))
        #expect(appSource.contains("NSStatusBar.system.removeStatusItem(statusItem)"))
        #expect(appSource.contains("source: \"configuration_import\""))
        #expect(appSource.contains("source=application_reopen"))
    }

    @Test func systemMediaAndVolumeSummariesUseUnambiguousLabels() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent(
                "Resources/zh-Hans.lproj/Localizable.strings"
            ),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent(
                "Resources/en.lproj/Localizable.strings"
            ),
            encoding: .utf8
        )
        let remoteButtonsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteButtons.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("action.system_volume_up_short"))
        #expect(settingsSource.contains("action.system_volume_down_short"))
        #expect(chinese.contains(#""action.system_volume_up_short" = "Vol+""#))
        #expect(chinese.contains(#""action.system_volume_down_short" = "Vol-""#))
        #expect(chinese.contains("上一首（系统媒体）"))
        #expect(chinese.contains("下一首（系统媒体）"))
        #expect(chinese.contains(#""action.show_desktop" = "显示桌面（fn + F11）""#))
        #expect(english.contains("Previous Track (System Media)"))
        #expect(english.contains("Next Track (System Media)"))
        #expect(english.contains(#""action.show_desktop" = "Show Desktop (fn + F11)""#))
        #expect(remoteButtonsSource.contains("if self == .showDesktop"))
    }

    /// 「锁定当前按键」的开关已移除，但它的行为固定保留：按下实体遥控器不得移动选中项，
    /// 否则正在编辑的按键会被刚按下的按键顶掉。
    @Test func mappingSelectionNeverFollowsPhysicalPresses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        // 没有开关、没有策略、也没有把 activeRemoteButtons 接回选中项的通路。
        #expect(!settingsSource.contains("isMappingSelectionLocked"))
        #expect(!settingsSource.contains("mappingSelectionLockControl"))
        #expect(!settingsSource.contains("MappingSelectionPolicy"))
        #expect(!settingsSource.contains(".onReceive(model.$activeRemoteButtons)"))
        #expect(!settingsSource.contains("button_mapping.selection_lock"))
        // 按键仍要在画布上显示按下态，锁定只影响选中项。
        #expect(settingsSource.contains("activeButtons: model.activeRemoteButtons"))
        for language in ["zh-Hans", "en"] {
            let strings = try String(
                contentsOf: root.appendingPathComponent(
                    "Resources/\(language).lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            #expect(!strings.contains("button_mapping.selection_lock"))
        }
    }

    @Test func customMappingPromptsOnlyWhenAnEnabledPermissionIsMissing() {
        #expect(MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(!MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(!MappingPermissionPolicy.requiresPrompt(
            enabled: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))
    }

    @Test func remoteMappingLayoutCoversEveryRealButtonWithExactConnectorAnchors() throws {
        let placements = RemoteMappingLayout.buttonPlacements
        #expect(placements.count == RemoteButton.xiaomiCases.count)
        #expect(Set(placements.map(\.button)) == Set(RemoteButton.xiaomiCases))

        let expectedAnchors: [RemoteButton: UnitPoint] = [
            .power: UnitPoint(x: 0.386, y: 0.099),
            .up: UnitPoint(x: 0.502, y: 0.179),
            .left: UnitPoint(x: 0.362, y: 0.246),
            .ok: UnitPoint(x: 0.502, y: 0.246),
            .right: UnitPoint(x: 0.638, y: 0.246),
            .down: UnitPoint(x: 0.502, y: 0.317),
            .back: UnitPoint(x: 0.406, y: 0.389),
            .volumeUp: UnitPoint(x: 0.604, y: 0.390),
            .home: UnitPoint(x: 0.406, y: 0.479),
            .volumeDown: UnitPoint(x: 0.604, y: 0.480),
            .menu: UnitPoint(x: 0.406, y: 0.569),
            .tv: UnitPoint(x: 0.604, y: 0.569),
        ]
        for placement in placements {
            let expected = expectedAnchors[placement.button]
            #expect(placement.anchor.x == expected?.x)
            #expect(placement.anchor.y == expected?.y)
            #expect((0...1).contains(placement.targetY))
        }

        let canvasWidth: CGFloat = 866
        let cardWidth: CGFloat = 250
        let leftEnd = RemoteMappingLayout.cardEdgePoint(
            side: .left,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        let rightEnd = RemoteMappingLayout.cardEdgePoint(
            side: .right,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        #expect(leftEnd == CGPoint(x: cardWidth, y: RemoteMappingLayout.canvasHeight / 2))
        #expect(rightEnd == CGPoint(x: canvasWidth - cardWidth, y: RemoteMappingLayout.canvasHeight / 2))
        #expect(RemoteMappingLayout.voiceAnchor == UnitPoint(x: 0.630, y: 0.099))
        #expect(RemoteMappingLayout.cardWidth(for: canvasWidth) == 300)

        let menuPlacement = try #require(placements.first { $0.button == .menu })
        let tvPlacement = try #require(placements.first { $0.button == .tv })
        let homePlacement = try #require(placements.first { $0.button == .home })
        let volumeDownPlacement = try #require(placements.first { $0.button == .volumeDown })
        #expect(menuPlacement.side == .left)
        #expect(tvPlacement.side == .right)
        #expect(homePlacement.side == .left)
        #expect(volumeDownPlacement.side == .right)

        for side in [RemoteMappingSide.left, .right] {
            let orderedAnchors = placements
                .filter { $0.side == side }
                .sorted { $0.targetY < $1.targetY }
                .map(\.anchor.y)
            #expect(zip(orderedAnchors, orderedAnchors.dropFirst()).allSatisfy { $0 <= $1 })
        }

        let start = CGPoint(x: canvasWidth / 2, y: 100)
        let leftEndPoint = CGPoint(x: 285, y: 160)
        let leftControls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: leftEndPoint,
            side: .left
        )
        #expect(leftControls.start.x < start.x)
        #expect(leftControls.end.x > leftEndPoint.x)

        let rightEndPoint = CGPoint(x: canvasWidth - 285, y: 160)
        let rightControls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: rightEndPoint,
            side: .right
        )
        #expect(rightControls.start.x > start.x)
        #expect(rightControls.end.x < rightEndPoint.x)

        #expect(RemoteMappingLayout.arrowTip(cardEdge: leftEndPoint, side: .left).x == leftEndPoint.x + 7)
        #expect(RemoteMappingLayout.arrowTip(cardEdge: rightEndPoint, side: .right).x == rightEndPoint.x - 7)
    }

    @Test func redesignedPagesKeepEveryExistingUserAction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let mappingCanvasSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMappingCanvas.swift"),
            encoding: .utf8
        )
        let shortcutPickerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/KeyboardShortcutPicker.swift"),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let source = settingsSource + mappingCanvasSource + shortcutPickerSource

        for requiredAction in [
            "model.reconnect()",
            "model.applyAudioSettings()",
            "model.refreshAudioDevices()",
            "model.setVoiceFnTapModeEnabled",
            "model.togglePhoneRemoteConnection()",
            "model.toggleWatchRemoteConnection()",
            "copyIOSAppStoreLink()",
            "requestWebRemoteSession()",
            "settings.clearTrustedPhoneIdentities()",
            "setMappingAction(action, for: button, trigger: trigger)",
            "setMappingShortcut(",
            "pickCustomApplicationProfile(",
            "recordCustomApplicationInput(profileID:",
            "setMappingApplicationProfileID(",
            ".openCustomApplication",
            "settings.resetBindings()",
        ] {
            #expect(source.contains(requiredAction), Comment(rawValue: requiredAction))
        }

        #expect(source.contains("AppLinks.iOSAppStore(for: localization.locale)"))
        let phoneEntry = try #require(source.range(of: "connection.phone.ios_title"))
        let watchEntry = try #require(source.range(of: "connection.watch.title"))
        let webEntry = try #require(source.range(
            of: "connection.web.title",
            range: watchEntry.upperBound..<source.endIndex
        ))
        #expect(phoneEntry.lowerBound < watchEntry.lowerBound)
        #expect(watchEntry.lowerBound < webEntry.lowerBound)
        let mobileEntrySource = source[phoneEntry.lowerBound..<webEntry.lowerBound]
        #expect(mobileEntrySource.contains("connection.phone.cancel_waiting"))
        #expect(mobileEntrySource.contains("connection.phone.connected"))
        #expect(mobileEntrySource.contains("connection.phone.disconnect"))
        #expect(mobileEntrySource.contains("connection.watch.cancel_waiting"))
        #expect(mobileEntrySource.contains("connection.watch.connected"))
        #expect(mobileEntrySource.contains("connection.watch.disconnect"))
        #expect(mobileEntrySource.contains("model.togglePhoneRemoteConnection()"))
        #expect(mobileEntrySource.contains("model.toggleWatchRemoteConnection()"))
        #expect(!mobileEntrySource.contains(".disabled(model.isPhoneRemoteConnectionEnabled)"))
        #expect(!mobileEntrySource.contains(".disabled(model.isWatchRemoteConnectionEnabled)"))
        #expect(!mobileEntrySource.contains(".foregroundStyle(.green)"))
        #expect(mobileEntrySource.contains(".foregroundStyle(model.isPhoneRemoteConnected"))
        #expect(mobileEntrySource.contains(".foregroundStyle(model.isWatchRemoteConnected"))
        #expect(mobileEntrySource.contains("? Color.green"))
        #expect(mobileEntrySource.contains("model.isPhoneRemoteConnectionEnabled ? .orange"))
        #expect(mobileEntrySource.contains("model.isWatchRemoteConnectionEnabled ? .orange"))
        #expect(bridgeSource.contains("@Published private(set) var isPhoneRemoteConnected = false"))
        #expect(bridgeSource.contains("@Published private(set) var isWatchRemoteConnected = false"))
        #expect(bridgeSource.contains("phoneRemoteServer.onConnectionStateChange"))
        #expect(bridgeSource.contains("watchBluetoothServer.onConnectionStateChange"))
        #expect(mobileEntrySource.contains("PhoneRemoteInvitationCard"))
        #expect(source.contains("ButtonTrigger.allCases"))
        #expect(!source.contains("isMappingSelectionLocked"))
        #expect(!mobileEntrySource.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(!source.contains("remoteDeviceBindingPanel"))
        #expect(!source.contains("SidebarGlassModifier"))
        #expect(source.contains(".focusEffectDisabled()"))
        #expect(source.contains("SettingsPageBehavior.sidebarTopDragHeight"))
        let sidebarStart = try #require(source.range(of: "private var sidebar: some View {"))
        let visibleSectionsStart = try #require(source.range(
            of: "private var visibleSections: [SettingsSection]",
            range: sidebarStart.upperBound..<source.endIndex
        ))
        let sidebarSource = source[sidebarStart.lowerBound..<visibleSectionsStart.lowerBound]
        #expect(!sidebarSource.contains(".ignoresSafeArea(.container, edges: .top)"))
        #expect(source.contains("showsAnchor: activeButtons.contains(placement.button)"))
        #expect(source.contains(".toggleStyle(.switch)"))
        #expect(source.contains("button_mapping.permission_prompt.open"))
        #expect(source.contains("mappingVoiceKeyModeControl"))
        #expect(source.contains("Text(\"button_mapping.rapid_press\")"))
        #expect(source.contains("set: { settings.setAllowsRapidPress($0, for: button) }"))
        #expect(source.contains("button_mapping.hold.rapid_press_description"))
        #expect(source.contains("button_mapping.rapid_press_help"))
        #expect(source.contains("hardwareMappingPage(includeSiriScrollArrow: true)"))
        #expect(source.contains(
            "mappingVoiceSettingsPanel(includeSiriScrollArrow: includeSiriScrollArrow)"
        ))
        #expect(source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(source.contains("siriRemoteScrollArrowControl"))
        #expect(RemoteMappingLayout.remoteSize.height == 510)
        #expect(source.contains("!snapshot.single.action.allowsRepeat"))
        #expect(source.contains("connection.voice_fn_tap.hint_short"))
        #expect(source.contains("ButtonActionCategory.allCases"))
        #expect(source.contains("MappingActionFilter.visibleCases"))
        #expect(source.contains("[.basicKeys, .systemAndMedia, .custom, .commonPhrases, .applications, .applicationFocus]"))
        #expect(source.contains("mappingActionFilterControl"))
        #expect(source.contains("applicationFocusEditor(configured: configured)"))
        #expect(source.contains("customApplicationTargetPicker("))
        #expect(source.contains("custom_application.focus.scope_note"))
        // 「App 输入框和滚动」只切换正在配置的 App，不得改写当前按键动作。
        #expect(!source.contains("bindCustomApplication("))
        // 聚焦方式与滚动区域是和动作分类平级的独立分区，不能再折叠进「打开具体 APP」的动作组。
        #expect(!source.contains("private func customApplicationEditor("))
        #expect(source.contains("ButtonActionCategory.allCases.filter(mappingActionFilter.includes)"))
        #expect(source.contains("category == .commonPhrases"))
        #expect(source.contains("category == .applications"))
        #expect(source.contains("button_mapping.action_filter.all"))
        #expect(source.contains("macroFeature.configurationTransferView("))
        #expect(!source.contains("settings.portable_configuration.title"))
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(source.contains("in: Capsule()"))
        #expect(source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains("button_mapping.action.disable_switch"))
        #expect(source.contains(").filter { $0 != .disabled && $0 != .combinationAction }"))
        #expect(!source.contains("DisclosureGroup(isExpanded: $isPresetApplicationActionsExpanded)"))
        #expect(!source.contains("isPresetApplicationActionsExpanded"))
        #expect(source.contains("custom_application.accessibility.learn_help"))
        #expect(!source.contains(".popover(item: $mappingEditingTarget)"))
        #expect(!source.contains(".sheet(item: $shortcutEditingTarget)"))
        #expect(!source.contains("ApplicationShortcutEditorSheet"))
        #expect(source.contains("shortcut.editor.click_first_help"))
        #expect(source.contains("shortcut.editor.recording_prompt"))
        #expect(source.contains("shortcut.editor.success"))
        #expect(source.contains("KeyboardShortcutPicker("))
        #expect(source.contains(".accessibilityLabel(Text(detail?() ?? title))"))
        #expect(source.contains("KeyboardShortcutPreset.allCases"))
        #expect(source.contains("StandardKeyboardKey.mainRows"))
        #expect(source.contains("StandaloneKeyboardModifier.allCases"))
        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains(".tint(Color.accentColor)"))
        #expect(source.contains("requiresSiriRemoteMembership(for: profile)"))
        #expect(source.contains("siri_remote.activation.open_membership"))
        #expect(source.contains("selectedSection = .membership"))
        #expect(source.contains("membershipFeature.refreshIfNeeded()"))
        #expect(!source.contains("siri_remote.activation.disable"))
        #expect(!source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(!mappingCanvasSource.contains("size: 8"))
        #expect(!mappingCanvasSource.contains("size: 9"))
        #expect(!mappingCanvasSource.contains("size: 10"))
        #expect(!mappingCanvasSource.contains("size: 11"))
        #expect(!mappingCanvasSource.contains("minimumScaleFactor"))
        #expect(source.range(of: "MappingRemotePhoto()")!.lowerBound < source.range(of: "connectionLines(metrics: metrics)")!.lowerBound)

        let voiceFnToggle = "Toggle(\"connection.voice_fn_tap.enabled\""
        #expect(source.components(separatedBy: voiceFnToggle).count == 2)
        #expect(
            source.range(of: voiceFnToggle)!.lowerBound >
                source.range(of: "private var mappingPage")!.lowerBound
        )
    }

    @Test func mappingCardsKeepThreeActionColumnsAndUseASeparateHoldEditor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let canvas = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMappingCanvas.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let renderer = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsScreenshotRenderer.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )

        #expect(canvas.contains("ForEach(ButtonTrigger.allCases)"))
        #expect(canvas.contains("Text(holdSummary(button))"))
        #expect(canvas.contains("onEditHold(button)"))
        #expect(canvas.contains("let cardHeight: CGFloat = 72"))
        #expect(settings.contains("mappingHoldEditorPanel(button)"))
        #expect(settings.contains("RemoteButtonHoldMode.selectableCases"))
        #expect(settings.contains(".disabled(profileUnsupported || !blockers.isEmpty)"))
        #expect(settings.contains("reconcileMappingHoldMode(afterChanging: button)"))
        #expect(settings.contains("guard let mode = RemoteButtonHoldModeDefault.storedMode"))
        #expect(!settings.contains("resolvedMode == .repeatSingle, repeatSingle.unavailableReason != nil"))
        #expect(!settings.contains("mappingInteractionControl"))
        #expect(!settings.contains("holdSingle"))
        #expect(renderer.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_HOLD_EDITOR"))
        #expect(renderer.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_HOLD_MODE"))
        #expect(chinese.contains("\"button_mapping.hold.repeat_prefix\" = \"按住：重复 \""))
        #expect(!settings.contains("button_mapping.hold.paused_tag"))
    }

    @Test func cloudPhoneRemoteUsesOnlyTheCloudflareRelayContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let membershipSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MembershipFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/BridgeAppModel.swift"
            ),
            encoding: .utf8
        )
        let compatibilitySource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/PublicRemoteCompatibility/Core/RemoteCompatibility.swift"
            ),
            encoding: .utf8
        )

        #expect(membershipSource.contains("adapter.createRemoteSessionWithDiagnostics("))
        #expect(membershipSource.contains("supportsRemoteSessionAuthorization"))
        #expect(bridgeSource.contains(".createRemoteSessionAuthorization("))
        #expect(bridgeSource.contains("idempotencyKey: idempotencyKey"))
        #expect(bridgeSource.contains("webRemoteState = .membershipRequired"))
        #expect(bridgeSource.contains("membership_check=bypassed"))
        #expect(bridgeSource.contains("/__local-test/remote-session"))
        #expect(!bridgeSource.contains("webRemoteBuildChannel"))
        #expect(!bridgeSource.contains("webRemoteServiceEnvironment == \"staging\""))
        #expect(bridgeSource.contains("Self.isLoopbackRelayURL(relayURL)"))
        #expect(!bridgeSource.contains("webRemoteMembershipBypassRequested"))
        #expect(bridgeSource.contains("var isWebRemoteMembershipBypassAvailable: Bool { false }"))
        #expect(bridgeSource.contains("func setWebRemoteMembershipBypassEnabled(_ enabled: Bool) {}"))
        let bypassPolicy = bridgeSource.components(separatedBy: "var isWebRemoteMembershipBypassEnabled: Bool {")[1]
            .components(separatedBy: "private static func isLoopbackRelayURL")[0]
        #expect(bypassPolicy.contains("membershipFeature.remoteSessionMembershipBypassEnabled"))
        #expect(!bypassPolicy.contains("WebRemoteConfiguration.relayURL()"))
        #expect(bridgeSource.contains("testMembershipBypass: isWebRemoteMembershipBypassEnabled"))
        let environmentSubscription = bridgeSource.components(
            separatedBy: "membershipEnvironmentCancellable ="
        )[1].components(separatedBy: "audioOutput.onConfigurationChange")[0]
        #expect(environmentSubscription.contains("self.webRemoteClient.stop()"))
        #expect(environmentSubscription.contains("self.webRemoteState = .disabled"))
        #expect(environmentSubscription.contains("self.webRemoteSessionGeneration &+= 1"))
        #expect(environmentSubscription.contains("self.webRemoteSessionIdempotencyKey = nil"))
        #expect(environmentSubscription.contains("reason=service_environment_changed"))
        #expect(membershipSource.contains("testMembershipBypass: testMembershipBypass"))
        #expect(!bridgeSource.contains("legacyVPS"))
        #expect(!bridgeSource.contains("legacy_vps"))
        #expect(bridgeSource.contains("type: \"sessionAttach\"") == false)
        #expect(bridgeSource.contains("relay_mode=cloudflare_v1"))
        #expect(compatibilitySource.contains("public enum WebRemoteSessionAuthorization"))
        #expect(compatibilitySource.contains("case cloudflareV1("))
        #expect(!compatibilitySource.contains("legacyVPS"))
    }

    @Test func remoteCardsShowCompleteNamesWithoutDuplicateConnectionSummary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
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

        #expect(chinese.contains(#""remote.device.model.rc001" = "小米蓝牙遥控器 2";"#))
        #expect(chinese.contains(#""remote.device.model.rc003" = "小米蓝牙遥控器 2 Pro";"#))
        #expect(english.contains(#""remote.device.model.rc001" = "Xiaomi Bluetooth Remote 2";"#))
        #expect(english.contains(#""remote.device.model.rc003" = "Xiaomi Bluetooth Remote 2 Pro";"#))
        #expect(chinese.contains(#""remote.device.model.apple_siri_remote_a2854" = "苹果遥控器第 7 代";"#))
        #expect(chinese.contains(#""remote.device.model.apple_siri_remote_a2540" = "苹果遥控器第 6 代";"#))

        let cardStart = try #require(settingsSource.range(of: "private func remoteDeviceCard"))
        let cardEnd = try #require(settingsSource.range(
            of: "private func batterySymbol",
            range: cardStart.upperBound..<settingsSource.endIndex
        ))
        let cardSource = settingsSource[cardStart.lowerBound..<cardEnd.lowerBound]
        #expect(cardSource.contains("return HStack(alignment: .center, spacing: 10)"))
        #expect(cardSource.contains("fillsWidth ? nil : 232"))
        #expect(cardSource.contains("let modelName = remoteModelName(profile)"))
        #expect(cardSource.contains("let systemName = remoteSystemName(profile)"))
        #expect(cardSource.contains("Text(modelName)"))
        #expect(cardSource.contains("Text(systemName)"))
        #expect(cardSource.contains(".accessibilityLabel(Text(\"\\(modelName), \\(systemName)\"))"))
        #expect(cardSource.contains("remoteBatteryLabel("))
        #expect(cardSource.contains("let powerState = model.powerState(for: profile.id)"))
        #expect(cardSource.contains("if showsBattery"))
        #expect(cardSource.contains("Image(systemName: \"bolt.fill\")"))
        #expect(!cardSource.contains("Label(power.text"))
        #expect(!cardSource.contains("remote.device.power.rechargeable"))
        for symbol in [
            "battery.0percent",
            "battery.25percent",
            "battery.50percent",
            "battery.75percent",
            "battery.100percent",
        ] {
            #expect(settingsSource.contains(symbol))
        }
        #expect(settingsSource.contains("if level <= 10 { return .red }"))
        #expect(settingsSource.contains("if level <= 25 { return .orange }"))

        let panelStart = try #require(settingsSource.range(of: "private var connectionDevicePanel"))
        let panelEnd = try #require(settingsSource.range(
            of: "private var mappingPage",
            range: panelStart.upperBound..<settingsSource.endIndex
        ))
        let panelSource = settingsSource[panelStart.lowerBound..<panelEnd.lowerBound]
        #expect(!panelSource.contains("Text(selectedRemoteDisplayName)"))
        #expect(!panelSource.contains("StatusPill(text: connectionBadge"))

        #expect(appSource.contains(
            "fileMenu.addItem(menuItem(\"menu.open_log_folder\", action: #selector(showLog)))"
        ))
    }

    @Test func siriRemoteBatteryPresentationHidesOnlyWhenEveryPowerSignalIsUnavailable() {
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .appleSiriRemoteA2854,
            level: nil,
            powerState: nil
        ))
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .appleSiriRemoteA2540,
            level: nil,
            powerState: .unknown
        ))
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .appleSiriRemoteA2854,
            level: nil,
            powerState: .onBattery
        ))
        #expect(RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .appleSiriRemoteA2854,
            level: 75,
            powerState: .unknown
        ))
        #expect(RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .appleSiriRemoteA2540,
            level: nil,
            powerState: .charging
        ))
        #expect(RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .rc003,
            level: nil,
            powerState: nil
        ))
    }

    @Test func remoteSelectorsKeepAppleActivationCardsAndDiscoveryFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let selectorStart = try #require(source.range(of: "private func remoteDeviceSelector"))
        let selectorEnd = try #require(source.range(
            of: "private func remoteDeviceCard",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selectorSource = source[selectorStart.lowerBound..<selectorEnd.lowerBound]

        #expect(selectorSource.contains("model.isRemoteConnected(profile.id)"))
        #expect(selectorSource.contains("model.isRemoteConnected(profile.id) || profile.model.isAppleSiriRemote"))
        #expect(selectorSource.contains("RemoteDeviceNamePolicy.sortedForCards("))
        #expect(selectorSource.contains("modelName: remoteModelName"))
        #expect(selectorSource.contains("systemName: { model.systemDeviceName(for: $0) }"))
        #expect(selectorSource.contains("ForEach(visibleProfiles)"))
        #expect(selectorSource.contains("remoteDeviceEmptyState(vertical: vertical)"))
        #expect(!selectorSource.contains("fillsWidth: visibleProfiles.count == 2"))
        #expect(selectorSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(selectorSource.contains("cards.fixedSize(horizontal: true, vertical: false)"))
        #expect(selectorSource.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        #expect(selectorSource.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(!selectorSource.contains("ScrollView(.horizontal, showsIndicators: true)"))
        #expect(!selectorSource.contains("ForEach(settings.remoteDeviceProfiles)"))
        #expect(source.contains("Button(\"connection.action.reconnect\")"))
        #expect(source.contains("remote.device.system_name_unknown"))
    }

    @Test func settingsPageKeepsVersionFeaturesTogetherAndLanguagesVisible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let settingsPage = try #require(source.components(separatedBy: "private var aboutPage").last)
        #expect(settingsPage.contains("updateInformationContent"))
        #expect(settingsPage.contains("about.version.check_prerelease"))
        #expect(settingsPage.contains("about.version.update_to"))
        #expect(settingsPage.contains("settingsPage(contentPadding: 28)"))
        #expect(!settingsPage.contains("settings.application_updates.title"))
        #expect(!settingsPage.contains("about.version.recheck"))
        #expect(!settingsPage.contains("about.version.history"))
        #expect(settingsPage.contains("ForEach(AppLanguage.allCases)"))
        #expect(settingsPage.contains(".pickerStyle(.segmented)"))
        let languageSectionStart = try #require(
            settingsPage.range(of: "Text(\"about.preferences.language\")")
        )
        let languageSectionEnd = try #require(
            settingsPage.range(
                of: "Text(\"about.preferences.restart_onboarding\")",
                range: languageSectionStart.upperBound..<settingsPage.endIndex
            )
        )
        let languageSection = settingsPage[languageSectionStart.lowerBound..<languageSectionEnd.lowerBound]
        #expect(languageSection.contains(".frame(width: 300)"))
        #expect(languageSection.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!settingsPage.contains("help.glossary.open"))
        #expect(!settingsPage.contains("openGlossary"))

        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("SPUStandardUserDriverDelegate"))
        #expect(appSource.contains("userDriverDelegate: self"))
        #expect(appSource.contains("standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool"))
        #expect(appSource.contains("semantic_newer_but_sparkle_rejected"))
    }

    @Test func settingsPageUsesAnInlineAppIconPickerWithoutUnavailablePlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/AppIconController.swift"),
            encoding: .utf8
        )
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("appIconPreferenceRow"))
        #expect(settingsSource.contains("ForEach(appIconCatalog.options)"))
        #expect(settingsSource.contains("settings.appIconIdentifier = option.id"))
        #expect(!settingsSource.contains("VStack(spacing: 5)"))
        #expect(settingsSource.contains(".accessibilityLabel(Text(LocalizedStringKey(option.titleKey)))"))
        #expect(!settingsSource.contains("Picker(\"about.preferences.app_icon\""))
        #expect(controllerSource.contains("struct AppIconIdentifier"))
        #expect(controllerSource.contains("let options: [AppIconOption]"))
        #expect(controllerSource.contains("subdirectory: \"AppIcons\""))
        #expect(controllerSource.contains("resourceName: \"faceted-duck\""))
        #expect(controllerSource.contains("contentScale: 0.92"))
        #expect(!controllerSource.contains("faceted-duck-intel"))
        #expect(buildSource.contains("Resources/AppIcons"))
        #expect(verifySource.contains("cmp -s"))
    }

    @Test func settingsPageOffersAnOptInLoginItemWithSystemApprovalRecovery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let serviceSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/LoginItemService.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("about.preferences.launch_at_login"))
        #expect(settingsSource.contains("loginItemService.setEnabled"))
        #expect(settingsSource.contains("loginItemService.openLoginItemsSettings"))
        #expect(settingsSource.contains("loginItemService.refresh()"))
        #expect(serviceSource.contains("SMAppService.mainApp"))
        #expect(serviceSource.contains("SMAppService.openSystemSettingsLoginItems()"))
        #expect(!serviceSource.contains("UserDefaults"))
    }

    @Test func privateFeatureUIIsDelegatedAndHiddenByDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("privateFeature.isFeatureVisible"))
        #expect(source.contains("privateFeature.shouldShowEnrollment"))
        #expect(source.contains("privateFeature.settingsView()"))
        #expect(source.contains("privateFeature.enrollmentView()"))
        #expect(!source.contains("deepSeek"))
        #expect(!source.contains("postDictation"))

        let versionSummary = try #require(
            source.components(separatedBy: "Text(currentVersionWithBuild)").last?
                .components(separatedBy: "if case let .available(update)").first
        )
        #expect(!versionSummary.contains(".onTapGesture"))
        #expect(!versionSummary.contains(".gesture"))
    }

    @Test func settingsPageDisplaysBuildAfterTheVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let englishLocalization = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let chineseLocalization = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )

        let sidebar = try #require(
            settingsSource.components(separatedBy: "private var sidebar").last?
                .components(separatedBy: "private var aboutPage").first
        )
        let aboutPage = try #require(settingsSource.components(separatedBy: "private var aboutPage").last)
        #expect(sidebar.contains("Text(currentVersion)"))
        #expect(!sidebar.contains("Text(currentVersionWithBuild)"))
        #expect(aboutPage.contains("Text(currentVersionWithBuild)"))
        #expect(settingsSource.contains("private var currentVersionWithBuild: String"))
        #expect(aboutPage.contains("about.version.current_with_build"))
        #expect(settingsSource.contains("CFBundleVersion"))
        #expect(englishLocalization.contains(
            "about.version.current_with_build\" = \"Version %1$@ (Build %2$@)\""
        ))
        #expect(chineseLocalization.contains(
            "about.version.current_with_build\" = \"版本 %1$@（Build %2$@）\""
        ))
    }

    @Test func macroFeatureUIIsDelegatedWithoutPublishingItsImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MacroFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent(
                "Resources/zh-Hans.lproj/Localizable.strings"
            ),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent(
                "Resources/en.lproj/Localizable.strings"
            ),
            encoding: .utf8
        )

        #expect(integration.contains("#if canImport(SayAllMacroRemoteMic)"))
        #expect(integration.contains("feature.executeBoundMacro"))
        #expect(integration.contains("feature.hasActiveBinding"))
        #expect(integration.contains("feature.noteButtonInteraction"))
        #expect(integration.contains("onBindingEditorActivityChanged"))
        #expect(integration.contains("@Published private(set) var isEditorActive"))
        #expect(settings.contains("macroFeature.settingsView"))
        #expect(!settings.contains("macro.integration.focus_mcp_boundary"))
        #expect(settings.contains(".font(.system(size: 12))"))
        #expect(settings.contains("macroFeature.enrollmentView"))
        #expect(settings.contains("macroFeature.setEditorActive(false)"))
        #expect(settings.contains("if section != .macros"))
        #expect(model.contains("!self.macroFeature.isEditorActive && !suppressConfiguredAction"))
        #expect(model.contains("if macroFeature.isEditorActive"))
        #expect(chinese.contains("输入框"))
        #expect(chinese.contains("MCP / TOML"))
        #expect(english.contains("Select Input Field"))
        #expect(english.contains("MCP settings"))
        #expect(!settings.contains("macro_buttons"))
        #expect(!settings.contains("EarlyAccessController"))
    }

    @Test func sidebarKeepsTheProductPriorityOrder() {
        #expect(SettingsPageBehavior.sidebarSections(
            privateFeatureVisible: true,
            macroFeatureVisible: true,
            buttonProfilesVisible: true,
            membershipVisible: true
        ) == [
            .mapping,
            .macros,
            .buttonProfiles,
            .membership,
            .connection,
            .transcripts,
            .privateFeature,
            .about,
            .statistics,
        ])
    }

    @Test func updateBadgeBelongsOnlyToTheSettingsSidebarEntry() throws {
        for section in SettingsSection.allCases {
            #expect(SettingsPageBehavior.showsUpdateBadge(
                for: section,
                hasUnseenUpdate: true
            ) == (section == .about))
            #expect(SettingsPageBehavior.marksUpdateAsSeen(
                whenSelecting: section
            ) == (section == .about))
        }
        #expect(!SettingsPageBehavior.showsUpdateBadge(
            for: .about,
            hasUnseenUpdate: false
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("selectSidebarSection(section)"))
        #expect(source.contains("updateInformation.markAvailableUpdateSeen()"))
    }

    @Test func profileSidebarUsesTheLoginFallbackAndSanitizedAccountDisplayName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let integration = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MembershipFeatureIntegration.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "accountDisplayName: membershipFeature.accountDisplayName"
        ))
        #expect(integration.contains("@Published private(set) var accountDisplayName: String?"))
        #expect(integration.contains("adapter.$accountDisplayName"))
    }

    @Test func defaultSettingsPageTracksTheFirstVisibleSidebarSection() throws {
        let visibleSections = SettingsPageBehavior.sidebarSections(
            privateFeatureVisible: false,
            macroFeatureVisible: false,
            buttonProfilesVisible: false,
            membershipVisible: false
        )
        #expect(SettingsPageBehavior.initialSection(
            requestedSection: nil,
            privateFeatureVisible: false,
            macroFeatureVisible: false,
            buttonProfilesVisible: false,
            membershipVisible: false
        ) == visibleSections.first)
        #expect(SettingsPageBehavior.initialSection(
            requestedSection: .about,
            privateFeatureVisible: false,
            macroFeatureVisible: false,
            buttonProfilesVisible: false,
            membershipVisible: false
        ) == .about)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let rootViewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicRootView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("initialSection: SettingsSection? = nil"))
        #expect(settingsSource.contains("SettingsPageBehavior.initialSection("))
        #expect(settingsSource.contains("SettingsPageBehavior.sidebarSections("))
        #expect(rootViewSource.contains("initialSettingsSection: SettingsSection? = nil"))
        #expect(appSource.contains("showSettingsWindow()"))
        #expect(!appSource.contains("showSettingsWindow(initialSection: .connection)"))
    }

    @Test func settingsScreenshotGateCoversEveryReleaseVisiblePage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/SettingsScreenshotRenderer.swift"
            ),
            encoding: .utf8
        )
        let sectionsStart = try #require(source.range(of: "private static let sections"))
        let listStart = try #require(source.range(
            of: "= [",
            range: sectionsStart.upperBound..<source.endIndex
        ))
        let listEnd = try #require(source.range(
            of: "]",
            range: listStart.upperBound..<source.endIndex
        ))
        let sections = source[listStart.lowerBound...listEnd.lowerBound]

        for section in [
            ".mapping",
            ".macros",
            ".buttonProfiles",
            ".membership",
            ".statistics",
            ".transcripts",
            ".connection",
            ".about",
        ] {
            #expect(sections.contains(section))
        }
        #expect(!sections.contains(".privateFeature"))
        #expect(source.contains(
            "model.privateFeature.updateLocaleIdentifier(localization.locale.identifier)"
        ))
        #expect(source.contains(
            "model.macroFeature.updateLocaleIdentifier(localization.locale.identifier)"
        ))
        #expect(source.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_ACTION_EDITOR"))
        #expect(source.contains(
            "model.membershipFeature.updateLocaleIdentifier(localization.locale.identifier)"
        ))
        #expect(source.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_SHORTCUT_EDITOR"))
        #expect(source.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_SHORTCUT_MODE"))
    }

    @Test func transcriptHistoryHasDedicatedSidebarPageAndUsesThePublicVoiceLifecycle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let historySource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/TranscriptHistorySection.swift"
            ),
            encoding: .utf8
        )
        let agentAccessSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/TranscriptAgentAccessSection.swift"
            ),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let captureSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/TranscriptCaptureCoordinator.swift"
            ),
            encoding: .utf8
        )

        let statisticsPage = try #require(
            settingsSource.components(separatedBy: "private var statisticsPage").last?
                .components(separatedBy: "private var transcriptHistoryPage").first
        )
        let transcriptPage = try #require(
            settingsSource.components(separatedBy: "private var transcriptHistoryPage").last?
                .components(separatedBy: "private var voiceSessionRankingCard").first
        )
        #expect(!statisticsPage.contains("TranscriptHistorySection(model: model, settings: settings)"))
        #expect(settingsSource.contains("static let transcripts = SettingsSection"))
        #expect(settingsSource.contains("case .transcripts: return \"settings.section.transcripts\""))
        #expect(transcriptPage.contains("TranscriptHistorySection(model: model, settings: settings)"))
        #expect(transcriptPage.contains(
            "PageHeader(title: localization.text(\"statistics.transcripts.title\"))\n"
                + "                    .fixedSize(horizontal: true, vertical: false)\n"
                + "                    .layoutPriority(2)"
        ))
        let titlePosition = try #require(transcriptPage.range(
            of: "PageHeader(title: localization.text(\"statistics.transcripts.title\"))"
        ))
        let privacyPosition = try #require(transcriptPage.range(
            of: "Text(localization.text(\"statistics.transcripts.privacy\"))"
        ))
        let spacerPosition = try #require(transcriptPage.range(of: "Spacer(minLength: 16)"))
        let togglePosition = try #require(transcriptPage.range(
            of: "Toggle(\n                    \"statistics.transcripts.enable\""
        ))
        #expect(titlePosition.lowerBound < privacyPosition.lowerBound)
        #expect(privacyPosition.lowerBound < spacerPosition.lowerBound)
        #expect(spacerPosition.lowerBound < togglePosition.lowerBound)
        #expect(transcriptPage.contains("$settings.localTranscriptHistoryEnabled"))
        #expect(transcriptPage.contains(".lineLimit(2)"))
        #expect(transcriptPage.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(!transcriptPage.contains("StatusPill("))
        #expect(historySource.contains("model.transcriptRecords.map(\\.applicationKey)"))
        #expect(historySource.contains("Dictionary(grouping: entries"))
        #expect(historySource.contains("allApplicationsButton"))
        #expect(historySource.contains("selectedApplicationKey = nil"))
        #expect(historySource.contains("applicationKey: activeApplicationKey"))
        #expect(historySource.contains("applicationKey: nil"))
        #expect(historySource.contains(".sorted { $0.id > $1.id }"))
        #expect(historySource.contains("latestEndedAt: max("))
        #expect(historySource.contains("private var isApplicationSwitcherExpanded = false"))
        #expect(historySource.contains("ScrollViewReader { proxy in"))
        #expect(historySource.contains("LazyVGrid("))
        #expect(historySource.contains("private var expandedDayKeys: Set<String> = []"))
        #expect(!historySource.contains("ForEach(recordingDayGroups)"))
        #expect(historySource.contains("recordingAssetsBySessionID"))
        #expect(historySource.contains("statistics.transcripts.view_more_by_application"))
        #expect(historySource.contains("static let recentWindow: TimeInterval"))
        #expect(historySource.contains("private func toggleDay(_ dayKey: String)"))
        #expect(historySource.contains("dayGroupView(group)"))
        #expect(!historySource.contains(".frame(width: 250, alignment: .topLeading)"))
        #expect(historySource.contains("private var deleteAllRow"))
        let agentAccessPosition = try #require(
            historySource.range(of: "TranscriptAgentAccessSection()")
        )
        let deleteAllPosition = try #require(historySource.range(of: "deleteAllRow"))
        #expect(agentAccessPosition.lowerBound < deleteAllPosition.lowerBound)
        #expect(historySource.contains(".buttonStyle(.borderless)"))
        #expect(!historySource.contains("private var overviewPanel"))
        #expect(!historySource.contains("private var privacyPanel"))
        #expect(historySource.contains("settings.localTranscriptHistoryEnabled"))
        #expect(historySource.contains("NSWorkspace.shared.urlForApplication"))
        #expect(historySource.contains("NSWorkspace.shared.icon(forFile:"))
        #expect(historySource.contains("applicationDisplayName"))
        #expect(historySource.contains("model.copyTranscript(record)"))
        #expect(!historySource.contains("model.revealRecording"))
        #expect(historySource.contains("model.deleteTranscriptRecord(record)"))
        #expect(historySource.contains("model.deleteTranscriptRecordAndRecording"))
        #expect(!historySource.contains("waveform.badge.minus"))
        #expect(historySource.contains("recordingPlaybackButton"))
        #expect(historySource.contains("recordingStopButton"))
        #expect(historySource.contains("model.deleteTranscriptApplication(applicationKey: key)"))
        #expect(historySource.contains("model.deleteAllTranscripts()"))
        #expect(historySource.contains("model.recordingPlaybackError"))
        #expect(historySource.contains("TRANSCRIPT HISTORY display_failed"))
        #expect(historySource.contains("reason = \"date_groups_collapsed\""))
        #expect(historySource.contains("displayed_count=\\(displayedCount)"))
        #expect(agentAccessSource.contains("statistics.transcripts.agent_access.enable"))
        #expect(agentAccessSource.contains("model.copyStandardConfiguration()"))
        #expect(agentAccessSource.contains("model.copyCodexConfiguration()"))
        #expect(agentAccessSource.contains("model.revoke(authorization)"))
        #expect(agentAccessSource.contains("ForEach(MCPClientKind.allCases)"))
        #expect(agentAccessSource.contains("LazyVGrid("))
        #expect(agentAccessSource.contains("model.connect(client)"))
        #expect(agentAccessSource.contains("model.removeConnection(client)"))
        #expect(agentAccessSource.contains("client.displayName"))
        #expect(!agentAccessSource.contains(".sheet("))
        #expect(!agentAccessSource.contains("Popover"))

        #expect(modelSource.contains(
            "transcriptCaptureCoordinator.startSession(sessionID: sessionID, startedAt: startedAt, source: source)"
        ))
        #expect(modelSource.contains(
            "transcriptCaptureCoordinator.finishSession(endedAt: endedAt)"
        ))
        #expect(modelSource.contains("RECORDING ASSET playback_failed"))
        #expect(modelSource.contains("record_id=\\(asset.id.uuidString)"))
        #expect(modelSource.contains("session_id=\\(asset.sessionID.uuidString)"))
        #expect(modelSource.contains("AppLogger.stableToken(asset.applicationKey"))
        #expect(modelSource.contains("reason=\\(failure.logReason)"))
        #expect(modelSource.contains("stage=\\(stage.rawValue)"))
        #expect(modelSource.contains("RECORDING ASSET playback_integrity"))
        #expect(modelSource.contains("byte_count_match=\\(diagnostics.byteCountMatches)"))
        #expect(modelSource.contains("sha256_match=\\(diagnostics.sha256Matches)"))
        #expect(modelSource.contains("transcriptCaptureCoordinator.cancel()"))
        #expect(modelSource.contains("FrontmostApplicationMetadata.current()"))
        #expect(modelSource.contains("self?.settings.localTranscriptHistoryEnabled ?? false"))
        #expect(modelSource.contains("recordingPlaybackAssetID"))
        #expect(modelSource.contains("isRecordingPlaybackPlaying"))
        #expect(modelSource.contains("audioPlayerDidFinishPlaying"))
        #expect(!captureSource.contains("PrivateFeatureIntegration"))
        #expect(!captureSource.contains("API"))
    }

    @Test func profileOwnsSharingAboveStatisticsWithoutASidebarEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("sharePanel(for: .about)"))
        #expect(!source.contains("Text(\"share.action\")"))
        #expect(!source.contains("share.sidebar.accessibility_label"))
        #expect(source.contains("if visibleSections.contains(.statistics)"))
        #expect(source.contains("sidebarButton(.statistics)"))
        #expect(source.contains("ShareCard(url: shareURL)"))
        #expect(!source.contains(".popover"))

        let profileStart = try #require(source.range(of: "private var statisticsPage"))
        let summaryStart = try #require(source.range(of: "private var statisticsSummaryGrid"))
        let profileSource = source[profileStart.lowerBound..<summaryStart.lowerBound]
        let sharePosition = try #require(profileSource.range(of: "sharePanel(for: .statistics)"))
        let metricsPosition = try #require(profileSource.range(of: "statisticsSummaryGrid"))
        #expect(sharePosition.lowerBound < metricsPosition.lowerBound)
    }

    @MainActor
    @Test(arguments: 0..<7)
    func calendarEndsAtBottomRightForEveryWeekday(offset: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10)))
        let today = try #require(calendar.date(byAdding: .day, value: offset, to: reference))
        let suite = "RemoteMicTests.Calendar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.recordButtonPress(at: today, calendar: calendar)
        let days = StatisticsCalendarDay.recentDays(settings: settings, endingAt: today, calendar: calendar)
        #expect(days.count == 26 * 7)
        let dates = try days.map { try #require($0.date) }
        #expect(dates.first == calendar.date(byAdding: .day, value: -181, to: today))
        #expect(dates.last == today)
        #expect(days.last?.buttonPressCount == 1)
        for index in 1..<dates.count {
            #expect(calendar.date(byAdding: .day, value: 1, to: dates[index - 1]) == dates[index])
        }
        for locale in [Locale(identifier: "zh_Hans"), Locale(identifier: "en")] {
            let labels = StatisticsCalendarDay.weekdaySymbols(firstDate: dates.first, calendar: calendar, locale: locale)
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            for row in 0..<7 {
                let weekday = calendar.component(.weekday, from: dates[row]) - 1
                #expect(labels[row] == formatter.shortWeekdaySymbols[weekday])
                #expect(calendar.component(.weekday, from: dates[25 * 7 + row]) - 1 == weekday)
            }
        }
    }

    @Test(arguments: [CGFloat(260), 320, 500, 900])
    func calendarHeightFitsAllRowsWithoutReservedBlankSpace(width: CGFloat) {
        let metrics = StatisticsHeatmapMetrics(width: width, columns: 26)
        #expect(metrics.cellSize >= 14 && metrics.cellSize <= 28)
        #expect(metrics.height == 18 + 8 + 7 * metrics.cellSize + 6 * 3)
        #expect(metrics.gridWidth == 26 * metrics.cellSize + 25 * 3)
        if width < 400 {
            #expect(metrics.height == 142)
            #expect(metrics.gridWidth > width) // End anchoring is required here.
        }
    }

    @MainActor
    @Test func calendarCountsReflectionsOnceAndAdvancesAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let yesterday = today.addingTimeInterval(-60)
        let record = TranscriptRecord(sessionID: UUID(), startedAt: yesterday, endedAt: yesterday,
            applicationName: "Fixture", bundleIdentifier: "com.sayall.fixture", source: .unknown,
            originalTranscript: "fixture", calendar: calendar)
        func asset(sessionID: UUID) -> RecordingAssetManifest {
            RecordingAssetManifest(schemaVersion: 1, id: UUID(), sessionID: sessionID,
                startedAt: record.startedAt, endedAt: record.endedAt,
                localDateKey: record.localDateKey, timeZoneIdentifier: record.timeZoneIdentifier,
                source: .unknown, applicationKey: record.applicationKey,
                applicationName: record.applicationName, bundleIdentifier: record.bundleIdentifier,
                relativeMediaPath: "fixture.m4a", durationMilliseconds: 1_000,
                byteCount: 0, sha256: "", format: "m4a")
        }
        let suite = "RemoteMicTests.CalendarCounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let assets = [asset(sessionID: record.sessionID), asset(sessionID: UUID())]
        let before = StatisticsCalendarDay.recentDays(settings: settings, endingAt: yesterday,
            calendar: calendar, records: [record], assets: assets)
        let after = StatisticsCalendarDay.recentDays(settings: settings, endingAt: today,
            calendar: calendar, records: [record], assets: assets)
        #expect(before.last?.date == calendar.startOfDay(for: yesterday))
        #expect(before.last?.reflectionCount == 2)
        #expect(after.last?.date == today)
        #expect(after.last?.reflectionCount == 0)
        #expect(after[180].reflectionCount == 2)
        #expect(after.reduce(0) { $0 + $1.reflectionCount } == 2)
    }

    @Test func profileMetricsKeepApprovedWideSingleRowLayout() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let summary = try #require(source.range(of: "private var statisticsSummaryGrid"))
        let metrics = try #require(source.range(
            of: "private var statisticsMetrics",
            range: summary.upperBound..<source.endIndex
        ))
        let summarySource = source[summary.lowerBound..<metrics.lowerBound]

        #expect(summarySource.contains("ViewThatFits(in: .horizontal)"))
        #expect(summarySource.contains(".frame(minWidth: 170, maxWidth: .infinity)"))
        #expect(summarySource.contains("GridItem(.flexible()), GridItem(.flexible())"))
        #expect(source.contains("approved layout as one row at the default width"))

        let heatmap = try #require(source.range(of: "private struct StatisticsHeatmap: View"))
        let heatmapEnd = try #require(source.range(of: "private struct UsageStatisticCard", range: heatmap.upperBound..<source.endIndex))
        let heatmapSource = source[heatmap.lowerBound..<heatmapEnd.lowerBound]
        #expect(heatmapSource.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(heatmapSource.contains("weekdayLabels"))
        #expect(heatmapSource.contains("StatisticsHeatmapMetrics(width: proxy.size.width"))
        #expect(heatmapSource.contains("scrollProxy.scrollTo(\"calendar-trailing\", anchor: .trailing)"))
        #expect(heatmapSource.contains(".help(summary(for: day))"))
        #expect(source.contains("TimelineView(.everyMinute)"))
        #expect(heatmapSource.contains("height: cellSize"))
        #expect(heatmapSource.contains("let index = column * 7 + row"))
        #expect(heatmapSource.contains("StatisticsCalendarDay.weekdaySymbols("))
        #expect(!heatmapSource.contains("Array(symbols.dropFirst()) + [symbols[0]]"))
        #expect(source.contains("dailyUsageStatistics(endingAt: date, days: 26 * 7, calendar: calendar)"))
        #expect(!source.contains("Array(repeating: StatisticsCalendarDay.empty"))
        #expect(source.contains("let rankingWidth = max(360, availableWidth * 0.42)"))
        #expect(source.contains("ProposedViewSize(width: rankingWidth, height: nil)"))
        #expect(source.contains("statisticsVoiceSessionRankingPanel"))
        #expect(source.contains("statisticsCalendarPanel\n                        statisticsVoiceSessionRankingPanel"))
        #expect(source.contains("entries.prefix(10)"))
        #expect(source.contains("settings.voiceSessionRanking.prefix(10)"))
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .top)"))
        #expect(!heatmapSource.contains(".frame(height: 250"))
        #expect(source.contains("ForEach(0..<7, id: \\.self)"))
    }

    @Test func profileStatisticsReportsIntrinsicHeightForBottomContent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let layoutStart = try #require(source.range(of: "private struct StatisticsColumnsLayout"))
        let settingsStart = try #require(source.range(of: "struct SettingsView"))
        let layoutSource = source[layoutStart.lowerBound..<settingsStart.lowerBound]
        let statisticsStart = try #require(source.range(of: "private var statisticsPage"))
        let summaryStart = try #require(source.range(
            of: "private var statisticsSummaryGrid",
            range: statisticsStart.upperBound..<source.endIndex
        ))
        let statisticsSource = source[statisticsStart.lowerBound..<summaryStart.lowerBound]

        #expect(layoutSource.contains("max(leftSize.height, rightSize.height)"))
        #expect(layoutSource.contains("ProposedViewSize(width: rankingWidth, height: nil)"))
        #expect(statisticsSource.contains("StatisticsColumnsLayout"))
        #expect(!statisticsSource.contains("GeometryReader"))
        #expect(!statisticsSource.contains(".frame(minHeight: 648)"))
        #expect(source.contains("statistics.ranking.view_all"))
    }

    @Test func corruptedSettingsBannerIsInlineAndNeverShrinksChineseBelowTwelvePoints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        // The two interface rules this banner has to satisfy are a rendered-pixel property and
        // a presentation-style property. Neither is observable from the notice's return value,
        // and asserting them by snapshot would need a running window, so this is the one part
        // of the feature that has to be checked against the declaration itself. The wording and
        // the show/hide decision are covered behaviourally in CorruptedSettingsNoticeTests.
        let bannerStart = try #require(
            settingsSource.range(of: "private var corruptedSettingsBanner: some View {")
        )
        let bannerEnd = try #require(settingsSource.range(
            of: "private var mappingHeaderToggle",
            range: bannerStart.upperBound..<settingsSource.endIndex
        ))
        let banner = settingsSource[bannerStart.upperBound..<bannerEnd.lowerBound]

        // Semantic styles are banned here: .caption and .caption2 render at 10pt and
        // .subheadline at 11pt, all of which break the 12pt floor for Chinese text.
        for bannedStyle in [
            ".font(.caption)",
            ".font(.caption2)",
            ".font(.subheadline)",
            ".font(.footnote)",
            "minimumScaleFactor",
        ] {
            #expect(!banner.contains(bannedStyle), Comment(rawValue: bannedStyle))
        }

        // Every font must be an explicit size, and no explicit size may be below 12.
        let sizes = try NSRegularExpression(pattern: #"\.system\(size: (\d+)"#)
        let bannerText = String(banner)
        let range = NSRange(bannerText.startIndex..., in: bannerText)
        let matches = sizes.matches(in: bannerText, range: range)
        #expect(matches.count == banner.components(separatedBy: ".font(").count - 1)
        #expect(!matches.isEmpty)
        for match in matches {
            let digits = try #require(Range(match.range(at: 1), in: bannerText))
            let size = try #require(Int(bannerText[digits]))
            #expect(size >= 12, Comment(rawValue: "font size \(size)"))
        }

        // Inline on the page: a dismissible container would hide the warning after one look.
        for bannedContainer in [".popover(", ".sheet(", ".alert(", ".confirmationDialog("] {
            #expect(!banner.contains(bannedContainer), Comment(rawValue: bannedContainer))
        }
        // ... and it has to be mounted on the mapping page, where the lost mappings live.
        let mappingPage = try #require(settingsSource.range(of: "private var mappingPage"))
        let mappingPageEnd = try #require(settingsSource.range(
            of: "private var corruptedSettingsBanner",
            range: mappingPage.upperBound..<settingsSource.endIndex
        ))
        #expect(
            settingsSource[mappingPage.upperBound..<mappingPageEnd.lowerBound]
                .contains("corruptedSettingsBanner")
        )
    }

    @Test func mappingPageResetsEditorAndScrollsToTopWhenRemoteChanges() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".id(\"mapping-page-top\")"))
        #expect(source.contains(".onChange(of: settings.selectedRemoteProfileID)"))
        #expect(source.contains("mappingEditingTarget = nil"))
        #expect(source.contains("proxy.scrollTo(\"mapping-page-top\", anchor: .top)"))
        #expect(source.contains("Group {\n                    ScrollView(.vertical, showsIndicators: false)"))
    }

    @Test func macroLibraryNavigationKeepsSelectionAndClearsOnlySearch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let choices = try #require(source.components(separatedBy: "private func mappingMacroChoices(").last)
            .components(separatedBy: "private var mappingPageHeader")[0]
        #expect(choices.contains("let searchQuery = mappingMacroSearch.trimmingCharacters(in: .whitespacesAndNewlines)"))
        #expect(choices.contains("$0.name.localizedCaseInsensitiveContains(searchQuery)"))
        #expect(choices.contains("$0.id.localizedCaseInsensitiveContains(searchQuery)"))
        #expect(choices.contains("Array(matchingActions.prefix(10))"))
        #expect(choices.contains("frame(maxWidth: 280)"))
        #expect(choices.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(choices.contains("frame(width: 180, alignment: .leading)"))
        #expect(choices.contains(".lineLimit(2)"))
        #expect(!choices.contains("VStack(spacing: 6)"))
        let manage = try #require(choices.components(separatedBy: "button_mapping.manage_macros\")) {").last)
        #expect(manage.contains("mappingMacroSearch = \"\""))
        #expect(!source.contains("button_mapping.return_choose_macro"))
        #expect(source.contains("onBindToButton: {"))
        #expect(source.contains("mappingEditingTarget = nil"))
    }
}
