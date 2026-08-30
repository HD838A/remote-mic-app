import Foundation
import SwiftUI
import Testing
@testable import RemoteMic

@Suite("Settings page regression")
struct SettingsPageRegressionTests {
    @Test func grantedPermissionsDoNotKeepShowingRequestButtons() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if state != .granted"))
        #expect(source.contains("settings.isOnboardingComplete"))
        #expect(source.contains("permissions.upgrade_identity_help"))
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
        #expect(source.contains("LocalizedMessage(\"connection.phone.cancel_waiting\")"))
        #expect(source.contains("response == .alertThirdButtonReturn"))
        #expect(source.contains("guard let self, self.isPhoneRemoteConnectionEnabled else"))
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

        let optionLabel = try #require(settingsSource.range(of: "private func connectionOptionLabel"))
        let optionLabelBlock = settingsSource[optionLabel.lowerBound...]
            .prefix(900)
        #expect(optionLabelBlock.contains(".font(.callout)"))
        #expect(optionLabelBlock.contains(".font(.body.weight(.medium))"))

        let statusLabel = try #require(settingsSource.range(of: "private func connectionStatusLabel"))
        let statusLabelBlock = settingsSource[statusLabel.lowerBound...]
            .prefix(420)
        #expect(statusLabelBlock.contains(".font(.callout.weight(.medium))"))
        #expect(appSource.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"))
        #expect(rendererSource.contains("width >= 800"))
        #expect(rendererSource.contains("height >= 650"))
        #expect(rendererSource.contains("window.appearance = appearance"))
        #expect(rendererSource.contains(".fullSizeContentView"))
        #expect(rendererSource.contains("window.toolbarStyle = .unified"))
        #expect(rendererSource.contains("NSApp.activate(ignoringOtherApps: true)"))
        for section in ["connection", "mapping", "statistics", "permissions", "about"] {
            #expect(rendererSource.contains(".\(section)"))
        }
    }

    @Test func mappingPageUsesGroupedFormSpacingAndKeepsRemoteCardFullWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let mappingPage = try #require(settingsSource.range(of: "private var mappingPage"))
        let editorPanel = try #require(settingsSource.range(
            of: "private func mappingEditorPanel",
            range: mappingPage.upperBound..<settingsSource.endIndex
        ))
        let mappingSource = settingsSource[mappingPage.lowerBound..<editorPanel.lowerBound]

        #expect(mappingSource.contains("Form {"))
        #expect(mappingSource.contains("Section {"))
        #expect(mappingSource.contains(".formStyle(.grouped)"))
        #expect(!mappingSource.contains(".compatibilityScrollEdgeEffect()"))
        #expect(!settingsSource.contains("CompatibilityScrollEdgeEffectModifier"))
        #expect(!settingsSource.contains(".scrollEdgeEffectStyle("))
        #expect(!mappingSource.contains(".contentMargins("))
        #expect(!mappingSource.contains("ScrollView(.vertical"))
        #expect(!mappingSource.contains("GroupBox {"))
        #expect(!mappingSource.contains(".padding(.horizontal, 20)"))
        #expect(!mappingSource.contains(".padding(.vertical, 16)"))
        #expect(mappingSource.contains("Toggle(\"button_mapping.toggle.enabled\""))
        #expect(!mappingSource.contains("LabeledContent(\"button_mapping.toggle.enabled\")"))
        #expect(!mappingSource.contains("LabeledContent(\"remote.device.selector\")"))
        #expect(mappingSource.contains("mappingRemoteDeviceBlock"))
        #expect(mappingSource.contains("private var mappingRemoteDeviceBlock"))
        #expect(mappingSource.contains("VStack(alignment: .leading, spacing: 8)"))
        #expect(mappingSource.contains("Text(\"remote.device.selector\")"))
        #expect(mappingSource.contains("remoteDeviceSelector(vertical: true)"))
        #expect(mappingSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!mappingSource.contains(".frame(maxWidth: 420"))
        #expect(mappingSource.contains(".listRowInsets(EdgeInsets())"))
        #expect(mappingSource.contains(".listRowBackground(Color.clear)"))

        let mappingFooter = try #require(settingsSource.range(of: "private var mappingFooter"))
        let deviceSelector = try #require(settingsSource.range(
            of: "private func remoteDeviceSelector",
            range: mappingFooter.upperBound..<settingsSource.endIndex
        ))
        let footerSource = settingsSource[mappingFooter.lowerBound..<deviceSelector.lowerBound]
        #expect(footerSource.contains("VStack(spacing: 0)"))
        #expect(footerSource.components(separatedBy: "HStack(alignment: .top, spacing: 20)").count == 4)
        #expect(!footerSource.contains("LabeledContent {"))
        #expect(footerSource.contains("Text(\"button_mapping.selection_lock_hint_short\")"))
        #expect(footerSource.contains("Text(\"connection.voice_key_mode.title\")"))
        #expect(footerSource.contains("Text(\"connection.voice_fn_tap.hint_short\")"))
        #expect(!footerSource.contains("Divider().frame(height: 28)"))
    }

    @Test func mappingFooterUsesCompactLayoutAtMinimumWindowWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let footer = try #require(settingsSource.range(of: "private var mappingFooter"))
        let selector = try #require(settingsSource.range(
            of: "private func remoteDeviceSelector",
            range: footer.upperBound..<settingsSource.endIndex
        ))
        let footerSource = settingsSource[footer.lowerBound..<selector.lowerBound]

        #expect(footerSource.contains("VStack(spacing: 0)"))
        #expect(
            footerSource.components(separatedBy: "HStack(alignment: .top, spacing: 20)").count == 4
        )
        #expect(footerSource.contains("Text(\"connection.voice_key_mode.title\")"))
        #expect(footerSource.contains("Text(\"connection.voice_fn_tap.enabled\")"))
        #expect(!footerSource.contains("mappingVoiceShortTapFocusControl"))
        #expect(footerSource.contains("Button(\"common.action.restore_defaults\")"))
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

    @Test func settingsWindowUsesTheNativeTitlebarDragRegion() throws {
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

        #expect(appSource.contains("window.isMovableByWindowBackground = false"))
        #expect(!appSource.contains("window.isMovableByWindowBackground = true"))
        #expect(appSource.contains("window.titleVisibility = .visible"))
        #expect(!appSource.contains("window.titlebarAppearsTransparent = true"))
        #expect(!appSource.contains("window.titlebarSeparatorStyle = .none"))
        #expect(appSource.contains("window.toolbarStyle = .unified"))
        #expect(!settingsSource.contains("WindowDragArea"))
        #expect(!settingsSource.contains("performDrag(with:"))
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
            of: "window.setContentSize(NSSize(width: 920, height: 700))"
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
        #expect(appSource.contains("window.minSize = NSSize(width: 800, height: 650)"))
    }

    @Test func settingsWindowKeepsTheDockIconUntilItCloses() throws {
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
        #expect(appSource.contains("isSettingsWindowOpen = false"))
        #expect(!appSource.contains("window.canHide = false"))
        #expect(appSource.contains("NSApp.keyWindow?.performClose(nil)"))

        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: false,
            isSettingsWindowOpen: true
        ) == .regular)
        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: false,
            isSettingsWindowOpen: false
        ) == .accessory)
        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: true,
            isSettingsWindowOpen: false
        ) == .regular)
    }

    @Test func mappingSelectionStaysOnTheEditedButtonWhileLocked() {
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [.menu],
            isLocked: true
        ) == .home)
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [.menu],
            isLocked: false
        ) == .menu)
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [],
            isLocked: false
        ) == .home)
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
        #expect(placements.count == RemoteButton.allCases.count)
        #expect(Set(placements.map(\.button)) == Set(RemoteButton.allCases))

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
        #expect(RemoteMappingLayout.cardWidth(for: canvasWidth) == 250)
        #expect(RemoteMappingLayout.cardWidth(for: 600) == 215)

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

    @Test func remoteMappingCardsKeepNativeVerticalRhythmAndStayInsideCanvas() {
        let placements = RemoteMappingLayout.buttonPlacements
        let targetGroups = [
            placements
                .filter { $0.side == .left }
                .map(\.targetY)
                .sorted(),
            ([RemoteMappingLayout.voiceTargetY] + placements
                .filter { $0.side == .right }
                .map(\.targetY))
                .sorted(),
        ]

        for targets in targetGroups {
            for (upperTarget, lowerTarget) in zip(targets, targets.dropFirst()) {
                let gap = (lowerTarget - upperTarget) * RemoteMappingLayout.canvasHeight
                    - RemoteMappingLayout.cardHeight
                #expect(gap >= RemoteMappingLayout.minimumCardGap)
            }

            for target in targets {
                let centerY = target * RemoteMappingLayout.canvasHeight
                #expect(centerY - RemoteMappingLayout.cardHeight / 2 >= 0)
                #expect(centerY + RemoteMappingLayout.cardHeight / 2 <= RemoteMappingLayout.canvasHeight)
            }
        }
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
            "model.sendTestTone()",
            "model.selectDoubaoAudioDevice()",
            "model.openDoubaoDriverInstructions(using: localization)",
            "model.setVoiceFnTapModeEnabled",
            "model.togglePhoneRemoteConnection()",
            "model.toggleWatchRemoteConnection()",
            "copyTestFlightPublicBetaLink()",
            "requestWebRemoteSession()",
            "settings.clearTrustedPhoneIdentities()",
            "settings.setAction(action, for: button, trigger: trigger)",
            "settings.setShortcut(",
            "chooseCustomApplication(for:",
            "recordCustomApplicationInput(profileID:",
            "settings.setApplicationProfileID(",
            ".openCustomApplication",
            "settings.resetBindings()",
        ] {
            #expect(source.contains(requiredAction), Comment(rawValue: requiredAction))
        }

        #expect(source.contains("AppLinks.testFlightPublicBeta"))
        let phonePanel = try #require(source.range(of: "private var phoneConnectionsPanel"))
        let phoneEntry = try #require(source.range(
            of: "connection.phone.ios_title",
            range: phonePanel.upperBound..<source.endIndex
        ))
        let watchEntry = try #require(source.range(
            of: "connection.watch.title",
            range: phoneEntry.upperBound..<source.endIndex
        ))
        let webEntry = try #require(source.range(
            of: "connection.web.title",
            range: watchEntry.upperBound..<source.endIndex
        ))
        #expect(phoneEntry.lowerBound < watchEntry.lowerBound)
        #expect(watchEntry.lowerBound < webEntry.lowerBound)
        let phoneEntrySource = source[phoneEntry.lowerBound..<watchEntry.lowerBound]
        let mobileEntrySource = source[phoneEntry.lowerBound..<webEntry.lowerBound]
        #expect(phoneEntrySource.contains("auxiliaryActions: {"))
        #expect(phoneEntrySource.contains("connection.web.invite.testflight_open"))
        #expect(phoneEntrySource.contains("copyTestFlightPublicBetaLink()"))
        #expect(source.contains("private func connectionOptionRow<Actions: View, AuxiliaryActions: View>"))
        #expect(source.contains("auxiliaryActions()"))
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
        #expect(mobileEntrySource.contains("statusTint: model.isPhoneRemoteConnected"))
        #expect(mobileEntrySource.contains("statusTint: model.isWatchRemoteConnected"))
        #expect(mobileEntrySource.contains("? .green"))
        #expect(mobileEntrySource.contains("model.isPhoneRemoteConnectionEnabled ? .orange"))
        #expect(mobileEntrySource.contains("model.isWatchRemoteConnectionEnabled ? .orange"))
        #expect(bridgeSource.contains("@Published private(set) var isPhoneRemoteConnected = false"))
        #expect(bridgeSource.contains("@Published private(set) var isWatchRemoteConnected = false"))
        #expect(bridgeSource.contains("phoneRemoteServer.onConnectionStateChange"))
        #expect(bridgeSource.contains("watchBluetoothServer.onConnectionStateChange"))
        #expect(mobileEntrySource.contains("PhoneRemoteInvitationCard"))
        #expect(source.contains("ButtonTrigger.allCases"))
        #expect(source.contains("isMappingSelectionLocked"))
        #expect(!source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(!source.contains("remoteDeviceBindingPanel"))
        #expect(!source.contains("SidebarGlassModifier"))
        #expect(source.contains("NavigationSplitView"))
        #expect(source.contains(".listStyle(.sidebar)"))
        #expect(source.contains(".searchable("))
        #expect(source.contains("placement: .sidebar"))
        #expect(source.contains("private struct SettingsSidebarIcon"))
        #expect(source.contains("private struct SettingsSidebarRow"))
        #expect(source.contains("SettingsSidebarIcon("))
        #expect(source.contains(".fill(color.gradient)"))
        let sidebarIcon = try #require(
            source.components(separatedBy: "private struct SettingsSidebarIcon").last?
                .components(separatedBy: "extension BridgeAppModel").first
        )
        #expect(sidebarIcon.contains(".font(.system(size: 12, weight: .semibold))"))
        #expect(sidebarIcon.contains(".frame(width: 20, height: 20)"))
        #expect(sidebarIcon.contains("cornerRadius: 5"))
        #expect(sidebarIcon.contains(
            ".shadow(color: .black.opacity(0.16), radius: 0.75, y: 0.5)"
        ))
        #expect(!sidebarIcon.contains(".stroke("))
        let sidebarStart = try #require(source.range(of: "    private var sidebar: some View"))
        let visibleSectionsStart = try #require(source.range(
            of: "    private var visibleSections: [SettingsSection]",
            range: sidebarStart.upperBound..<source.endIndex
        ))
        let sidebarSource = source[sidebarStart.lowerBound..<visibleSectionsStart.lowerBound]
        #expect(sidebarSource.contains("SettingsSidebarRow("))
        #expect(sidebarSource.contains(".listRowInsets(sidebarRowInsets)"))
        #expect(sidebarSource.contains("private var searchResultList"))
        #expect(sidebarSource.contains("ContentUnavailableView.search"))
        #expect(sidebarSource.contains(".font(.body)"))
        #expect(sidebarSource.contains(".font(.callout)"))
        let settingsBodyStart = try #require(source.range(of: "    var body: some View {"))
        let settingsSidebarStart = try #require(source.range(
            of: "    private var sidebar: some View",
            range: settingsBodyStart.upperBound..<source.endIndex
        ))
        let settingsBodySource = source[
            settingsBodyStart.lowerBound..<settingsSidebarStart.lowerBound
        ]
        #expect(settingsBodySource.contains(".searchable("))
        #expect(settingsBodySource.contains(
            "prompt: Text(localization.text(\"settings.search.placeholder\"))\n"
                + "                )\n"
                + "                .searchFocusedWhenAvailable($isSearchFocused)\n"
                + "                .onSubmit(of: .search) {"
        ))
        #expect(settingsBodySource.contains("                }\n                .controlSize(.large)"))
        #expect(settingsBodySource.contains(".toolbar(removing: .sidebarToggle)"))
        #expect(settingsBodySource.contains(
            ".toolbar(removing: .sidebarToggle)\n"
                + "                .navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)"
        ))
        #expect(settingsBodySource.contains("ToolbarItem(placement: .navigation)"))
        #expect(settingsBodySource.contains("navigationControlGroup"))
        #expect(!settingsBodySource.contains("sidebarToggleButton"))
        #expect(!settingsBodySource.contains("NSSplitViewController.toggleSidebar"))
        #expect(settingsBodySource.contains(
            ".navigationSplitViewStyle(.balanced)\n"
                + "        .controlSize(.regular)"
        ))
        #expect(!settingsBodySource.contains(
            ".navigationSplitViewStyle(.balanced)\n"
                + "        .searchable("
        ))
        #expect(source.contains(
            "selectedPage\n"
                + "                .navigationTitle(sectionTitle(selectedSection))\n"
                + "                .controlSize(.regular)"
        ))
        #expect(source.contains(".navigationTitle(sectionTitle(selectedSection))"))
        #expect(source.contains(".navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)"))
        #expect(source.contains("private var navigationControlGroup"))
        #expect(source.contains("if #available(macOS 26.0, *)"))
        #expect(source.contains("nativeNavigationControlGroup"))
        #expect(source.contains("ControlGroup {"))
        #expect(source.contains(".controlGroupStyle(.navigation)"))
        #expect(source.contains(".controlSize(.extraLarge)"))
        #expect(source.contains(".buttonStyle(.glass)"))
        #expect(source.contains(".controlSize(.large)"))
        #expect(source.contains("primaryAction:"))
        #expect(!source.contains("SettingsNavigationControl: NSViewRepresentable"))
        #expect(!source.contains(".glassEffect(.regular.interactive(), in: .capsule)"))
        #expect(source.contains("settings.navigation.back"))
        #expect(source.contains("settings.navigation.forward"))
        #expect(source.contains("private var backwardHistoryIndices"))
        #expect(source.contains("private var settingsSearchItems"))
        #expect(source.contains("activateSearchResult"))
        #expect(source.contains("scrollToSearchResult"))
        #expect(source.contains("flashSearchResultHighlight"))
        #expect(source.contains("List(searchResults, selection: $selectedSearchResultID)"))
        #expect(source.contains(".onKeyPress(.return)"))
        #expect(source.contains("func searchAnchor(_ anchor: String, highlighted: String?)"))
        #expect(source.contains("\"mapping.voice-fn\""))
        #expect(source.contains("\"mapping.restore-defaults\""))
        #expect(!source.contains("\"statistics.share\""))
        #expect(source.contains("\"about.share\""))
        #expect(source.contains("\"transcripts.delete-all\""))
        #expect(source.contains("\"about.website\""))
        #expect(source.contains("\"about.github\""))
        #expect(!source.contains("localizedShareTitle.localizedCaseInsensitiveContains"))
        #expect(!source.contains("WindowDragArea"))
        #expect(source.contains("showsAnchor: activeButtons.contains(placement.button)"))
        #expect(source.contains(".toggleStyle(.switch)"))
        #expect(source.contains("button_mapping.permission_prompt.open"))
        #expect(source.contains("button_mapping.selection_lock_hint_short"))
        #expect(source.contains("Toggle(\"button_mapping.rapid_press\""))
        #expect(source.contains("button_mapping.rapid_press_hint_short"))
        #expect(source.contains("button_mapping.rapid_press_help"))
        #expect(source.contains("!configured.action.allowsRepeat"))
        #expect(source.contains("connection.voice_fn_tap.hint_short"))
        #expect(source.contains("ButtonActionCategory.allCases"))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains("button_mapping.action.disable_switch"))
        #expect(source.contains(").filter { $0 != .disabled }"))
        #expect(source.contains("DisclosureGroup(isExpanded: $isPresetApplicationActionsExpanded)"))
        #expect(source.contains("isPresetApplicationActionsExpanded = false"))
        #expect(source.contains("custom_application.accessibility.learn_help"))
        #expect(!source.contains(".popover(item: $mappingEditingTarget)"))
        #expect(!source.contains(".sheet(item: $shortcutEditingTarget)"))
        #expect(!source.contains("ApplicationShortcutEditorSheet"))
        #expect(source.contains("shortcut.editor.click_first_help"))
        #expect(source.contains("shortcut.editor.recording_prompt"))
        #expect(source.contains("shortcut.editor.success"))
        #expect(source.contains("KeyboardShortcutPicker("))
        #expect(source.contains("KeyboardShortcutPreset.allCases"))
        #expect(source.contains("StandardKeyboardKey.mainRows"))
        #expect(source.contains("StandaloneKeyboardModifier.allCases"))
        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(!source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(!mappingCanvasSource.contains("size: 8"))
        #expect(!mappingCanvasSource.contains("size: 9"))
        #expect(!mappingCanvasSource.contains("size: 10"))
        #expect(!mappingCanvasSource.contains("size: 11"))
        #expect(!mappingCanvasSource.contains("minimumScaleFactor"))
        #expect(source.range(of: "MappingRemotePhoto()")!.lowerBound < source.range(of: "connectionLines(metrics: metrics)")!.lowerBound)

        let voiceFnToggle = "\"connection.voice_fn_tap.enabled\",\n                    isOn: Binding("
        #expect(source.components(separatedBy: voiceFnToggle).count == 2)
        #expect(
            source.range(of: voiceFnToggle)!.lowerBound >
                source.range(of: "private var mappingPage")!.lowerBound
        )
    }

    @Test func settingsUseNativeSidebarAndGroupedConnectionForm() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("NavigationSplitView"))
        #expect(source.contains("List(selection:"))
        #expect(source.contains(".listStyle(.sidebar)"))
        #expect(source.contains(".searchable("))
        #expect(source.contains("placement: .sidebar"))
        #expect(source.contains(".navigationTitle(sectionTitle(selectedSection))"))
        #expect(source.contains(".navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)"))
        #expect(!source.contains("private func sidebarButton"))
        #expect(!source.contains("WindowDragArea"))

        let connectionStart = try #require(source.range(of: "private var connectionPage"))
        let mappingStart = try #require(source.range(
            of: "private var mappingPage",
            range: connectionStart.upperBound..<source.endIndex
        ))
        let connectionSource = source[connectionStart.lowerBound..<mappingStart.lowerBound]
        #expect(connectionSource.contains("Form {"))
        #expect(connectionSource.contains(".formStyle(.grouped)"))
        #expect(connectionSource.contains("Section {"))
        #expect(connectionSource.contains("LabeledContent"))
        #expect(connectionSource.contains(".pickerStyle(.radioGroup)"))
        #expect(connectionSource.contains("model.isStreaming ? Color.orange : Color.secondary"))
        #expect(!connectionSource.contains("model.isStreaming ? .orange : Color.accentColor"))
        #expect(!connectionSource.contains("model.voiceShortcutStatus.text(using: localization),\n                    systemImage: \"mic.fill\"\n                )\n                .foregroundStyle(Color.accentColor)"))
        #expect(!connectionSource.contains("GlassPanel"))
        #expect(!connectionSource.contains("CompatibilityGlassContainer"))

        let permissionsStart = try #require(source.range(of: "private var permissionsPage"))
        let statisticsStart = try #require(source.range(
            of: "private var statisticsPage",
            range: permissionsStart.upperBound..<source.endIndex
        ))
        let permissionsSource = source[permissionsStart.lowerBound..<statisticsStart.lowerBound]
        #expect(permissionsSource.contains("Form {"))
        #expect(permissionsSource.contains(".formStyle(.grouped)"))
        #expect(!permissionsSource.contains("PermissionStepRow"))

        let permissionRowStart = try #require(source.range(of: "private func permissionRow"))
        let permissionRowEnd = try #require(source.range(
            of: "private var webRemoteStatusText",
            range: permissionRowStart.upperBound..<source.endIndex
        ))
        let permissionRowSource = source[permissionRowStart.lowerBound..<permissionRowEnd.lowerBound]
        #expect(permissionRowSource.contains(") -> some View {\n        LabeledContent {"))
    }

    @Test func audioGainHelpRemainsInsideItsOwningFormRow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let audioPanelStart = try #require(source.range(of: "private var audioSettingsPanel"))
        let gainRowStart = try #require(source.range(
            of: "private var audioGainSettingsRow",
            range: audioPanelStart.upperBound..<source.endIndex
        ))
        let compatibilityStart = try #require(source.range(
            of: "private var audioCompatibilityPanel",
            range: gainRowStart.upperBound..<source.endIndex
        ))
        let audioPanelSource = source[audioPanelStart.lowerBound..<gainRowStart.lowerBound]
        let gainRowSource = source[gainRowStart.lowerBound..<compatibilityStart.lowerBound]

        #expect(audioPanelSource.contains("audioGainSettingsRow"))
        #expect(!audioPanelSource.contains("Text(\"audio.gain.help\")"))
        #expect(gainRowSource.contains("VStack(alignment: .leading, spacing: 8)"))
        #expect(gainRowSource.contains("LabeledContent(\"audio.gain.title\")"))
        #expect(gainRowSource.contains("Text(\"audio.gain.help\")"))
    }

    @Test func aboutVersionStatusAndReleaseNotesUseSeparateRows() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let statusViewStart = try #require(source.range(of: "private var aboutUpdateStatusView"))
        let currentRowStart = try #require(source.range(
            of: "private var aboutCurrentVersionRow",
            range: statusViewStart.upperBound..<source.endIndex
        ))
        let releaseRowStart = try #require(source.range(
            of: "private var aboutReleaseNotesRow",
            range: currentRowStart.upperBound..<source.endIndex
        ))
        let releaseNotesStart = try #require(source.range(
            of: "private var aboutReleaseNotesView",
            range: releaseRowStart.upperBound..<source.endIndex
        ))
        let statusViewSource = source[statusViewStart.lowerBound..<currentRowStart.lowerBound]
        let currentRowSource = source[currentRowStart.lowerBound..<releaseRowStart.lowerBound]
        let releaseRowSource = source[releaseRowStart.lowerBound..<releaseNotesStart.lowerBound]

        #expect(statusViewSource.contains("case let .available(update)"))
        #expect(statusViewSource.contains("Text(\"about.version.latest\")"))
        #expect(currentRowSource.contains("LabeledContent {"))
        #expect(currentRowSource.contains("Text(\"about.version.current\")"))
        #expect(currentRowSource.contains("aboutUpdateStatusView"))
        let currentRowLabelStart = try #require(currentRowSource.range(of: "} label: {"))
        let currentRowStatus = try #require(currentRowSource.range(of: "aboutUpdateStatusView"))
        #expect(currentRowStatus.lowerBound > currentRowLabelStart.lowerBound)
        #expect(currentRowSource.contains("if case .available = updateInformation.state"))
        #expect(currentRowSource.contains("checkForUpdates()"))
        #expect(currentRowSource.contains("refreshUpdateInformation()"))
        #expect(currentRowSource.contains("case .upToDate, .unavailable:"))
        #expect(currentRowSource.contains("\"about.version.recheck\""))
        #expect(!currentRowSource.contains("Button(\"about.version.recheck\""))
        #expect(!currentRowSource.contains(
            ".frame(maxWidth: .infinity, alignment: .leading)"
        ))
        #expect(!statusViewSource.contains("about.version.up_to_date_description"))
        #expect(releaseRowSource.contains("LabeledContent(\"about.version.information_title\")"))
        #expect(releaseRowSource.contains("aboutReleaseNotesView"))
        #expect(releaseRowSource.contains("if case .available = updateInformation.state"))
        #expect(!releaseRowSource.contains("aboutUpdateStatusView"))
    }

    @Test func everyNonConnectionPageKeepsDescriptionsWithItsOwningSection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let permissionsStart = try #require(source.range(of: "private var permissionsPage"))
        let statisticsStart = try #require(source.range(
            of: "private var statisticsPage",
            range: permissionsStart.upperBound..<source.endIndex
        ))
        let transcriptsStart = try #require(source.range(
            of: "private var transcriptHistoryPage",
            range: statisticsStart.upperBound..<source.endIndex
        ))
        let aboutStart = try #require(source.range(
            of: "private var aboutPage",
            range: transcriptsStart.upperBound..<source.endIndex
        ))
        let shareStart = try #require(source.range(
            of: "private var aboutShareSectionContent",
            range: aboutStart.upperBound..<source.endIndex
        ))

        let permissionsSource = source[permissionsStart.lowerBound..<statisticsStart.lowerBound]
        #expect(permissionsSource.contains("} footer: {"))
        #expect(permissionsSource.contains("Text(\"permissions.upgrade_identity_help\")"))
        #expect(!permissionsSource.contains("Label(\"permissions.upgrade_identity_help\""))

        let statisticsSource = source[statisticsStart.lowerBound..<transcriptsStart.lowerBound]
        #expect(statisticsSource.contains("Form {"))
        #expect(statisticsSource.contains(".formStyle(.grouped)"))
        #expect(!statisticsSource.contains(".safeAreaBar("))
        #expect(!statisticsSource.contains(".safeAreaInset("))
        #expect(!statisticsSource.contains("LabeledContent(\"statistics.page.title\")"))
        #expect(statisticsSource.contains(".frame(maxWidth: .infinity)"))
        let periodPickerStart = try #require(statisticsSource.range(
            of: "private var statisticsPeriodPicker"
        ))
        let periodPickerEnd = try #require(statisticsSource.range(
            of: "private var statisticsPrivacyLabel",
            range: periodPickerStart.upperBound..<statisticsSource.endIndex
        ))
        let periodPickerSource = statisticsSource[
            periodPickerStart.lowerBound..<periodPickerEnd.lowerBound
        ]
        #expect(periodPickerSource.contains("Picker("))
        #expect(periodPickerSource.contains("ForEach(UsageStatisticsPeriod.allCases)"))
        #expect(periodPickerSource.contains(".labelsHidden()"))
        #expect(periodPickerSource.contains(".pickerStyle(.segmented)"))
        #expect(periodPickerSource.contains("if #available(macOS 26.0, *)"))
        #expect(periodPickerSource.contains(".controlSize(.extraLarge)"))
        #expect(periodPickerSource.contains(".controlSize(.large)"))
        #expect(periodPickerSource.contains(".frame(width: 480)"))
        #expect(!periodPickerSource.contains("height: 32"))
        #expect(!periodPickerSource.contains("Button {"))
        #expect(statisticsSource.contains("statisticsPeriodPicker"))
        #expect(statisticsSource.contains("private var statisticsForm"))
        #expect(!statisticsSource.contains("private var statisticsPeriodControls"))
        #expect(statisticsSource.contains("VStack(alignment: .leading, spacing: 16)"))
        #expect(statisticsSource.contains("statisticsPrivacyLabel"))
        #expect(statisticsSource.contains("\"statistics-period\""))
        #expect(!statisticsSource.contains(".listRowBackground(Color.clear)"))
        #expect(!source.contains("private struct StatisticsPeriodSegmentedControl"))
        #expect(!source.contains("selectedSegmentBezelColor"))
        #expect(statisticsSource.contains("statisticsPrivacyLabel"))
        let voiceRankingStart = try #require(source.range(
            of: "private var voiceSessionRankingCard"
        ))
        let voiceRankingEnd = try #require(source.range(
            of: "private var statisticsPeriodContent",
            range: voiceRankingStart.upperBound..<source.endIndex
        ))
        let voiceRankingSource = source[
            voiceRankingStart.lowerBound..<voiceRankingEnd.lowerBound
        ]
        #expect(voiceRankingSource.contains(
            "Text(localization.text(\"statistics.voice_ranking.title\"))"
        ))
        #expect(voiceRankingSource.contains(
            "Text(localization.text(\"statistics.voice_ranking.description\"))"
        ))
        #expect(voiceRankingSource.contains(
            "Text(localization.text(\"statistics.voice_ranking.empty\"))"
        ))
        #expect(!statisticsSource.contains("aboutShareSectionContent"))
        #expect(!statisticsSource.contains("settingsPage("))
        #expect(!statisticsSource.contains("GroupBox {"))

        let transcriptSource = source[transcriptsStart.lowerBound..<aboutStart.lowerBound]
        #expect(transcriptSource.contains("Form {"))
        #expect(transcriptSource.contains("Toggle("))
        #expect(transcriptSource.contains("\"statistics.transcripts.enable\""))
        #expect(!transcriptSource.contains("LabeledContent(\"statistics.transcripts.enable\")"))
        #expect(transcriptSource.contains("Text(\"statistics.transcripts.description\")"))
        #expect(transcriptSource.contains("Text(\"statistics.transcripts.privacy\")"))
        #expect(!transcriptSource.contains("settingsPage("))
        #expect(!transcriptSource.contains("GroupBox {"))

        let aboutSource = source[aboutStart.lowerBound..<shareStart.lowerBound]
        let currentVersionRow = try #require(aboutSource.range(
            of: "private var aboutCurrentVersionRow"
        ))
        let newestContentRow = try #require(aboutSource.range(
            of: "LabeledContent(\"about.version.information_title\")",
            range: currentVersionRow.upperBound..<aboutSource.endIndex
        ))
        let currentVersionSource = aboutSource[currentVersionRow.lowerBound..<newestContentRow.lowerBound]
        #expect(currentVersionSource.contains("if case .available = updateInformation.state"))
        #expect(currentVersionSource.contains("checkForUpdates()"))
        #expect(currentVersionSource.contains("refreshUpdateInformation()"))
        #expect(!currentVersionSource.contains("Button(\"about.version.recheck\""))
        #expect(!aboutSource.contains("about.version.history"))
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

        let cardStart = try #require(settingsSource.range(of: "private func remoteDeviceCard"))
        let cardEnd = try #require(settingsSource.range(
            of: "private func batterySymbol",
            range: cardStart.upperBound..<settingsSource.endIndex
        ))
        let cardSource = settingsSource[cardStart.lowerBound..<cardEnd.lowerBound]
        #expect(cardSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(cardSource.contains("fillsWidth ? nil : 232"))
        #expect(cardSource.contains("remoteBatteryLabel("))
        #expect(cardSource.contains("powerState: model.powerState(for: profile.id)"))
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
        #expect(!settingsSource.contains("private struct StatusPill"))
        #expect(!settingsSource.contains("private struct DeviceStatusStep"))
        #expect(!settingsSource.contains("private var connectionBadge"))
        #expect(!settingsSource.contains("private var voiceTriggerBadge"))

        #expect(appSource.contains(
            "fileMenu.addItem(menuItem(\"menu.open_log_folder\", action: #selector(showLog)))"
        ))
        #expect(appSource.contains("NSApp.windowsMenu = windowMenu"))
        #expect(appSource.contains("settingsNavigationCoordinator"))
        #expect(appSource.contains("#selector(goBackInSettings)"))
        #expect(appSource.contains("#selector(goForwardInSettings)"))
        #expect(appSource.contains("#selector(focusSettingsSearch)"))
        #expect(appSource.contains("setFrameUsingName(window.frameAutosaveName)"))
        #expect(appSource.contains("hideOtherApplications:"))
        #expect(appSource.contains("performMiniaturize:"))
        #expect(appSource.contains("showSettingsWindow(initialSection: .about)"))
        #expect(!appSource.contains("about.alert.description_with_version"))
    }

    @Test func remoteSelectorsOnlyShowConnectedProfilesAndKeepDiscoveryFallback() throws {
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

        #expect(selectorSource.contains("model.isRemoteConnected($0.id)"))
        #expect(selectorSource.contains("ForEach(connectedProfiles)"))
        #expect(selectorSource.contains("remoteDeviceEmptyState(vertical: vertical)"))
        #expect(!selectorSource.contains("ForEach(settings.remoteDeviceProfiles)"))
        #expect(source.contains("Button(\"connection.action.reconnect\")"))
    }

    @Test func aboutPageKeepsVersionFeaturesTogetherAndLanguagesVisible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let aboutPage = try #require(
            source.components(separatedBy: "private var aboutPage").last?
                .components(separatedBy: "private func shareSectionContent").first
        )
        #expect(aboutPage.contains("Form {"))
        #expect(aboutPage.contains(".formStyle(.grouped)"))
        #expect(aboutPage.contains("LabeledContent"))
        #expect(aboutPage.contains("aboutCurrentVersionRow"))
        #expect(aboutPage.contains("aboutReleaseNotesRow"))
        #expect(aboutPage.contains("aboutUpdateStatusView"))
        #expect(aboutPage.contains("aboutReleaseNotesView"))
        #expect(aboutPage.contains("about.version.check_prerelease"))
        #expect(aboutPage.contains("about.version.update_to"))
        #expect(!aboutPage.contains("about.version.history"))
        #expect(aboutPage.contains("ForEach(AppLanguage.allCases)"))
        #expect(aboutPage.contains(".pickerStyle(.segmented)"))
        #expect(!aboutPage.contains(".frame(width: 280)"))
        #expect(!aboutPage.contains(".font(.system(size: 28"))
        #expect(!aboutPage.contains(".frame(width: 34)"))
        #expect(!aboutPage.contains("help.glossary.open"))
        #expect(!aboutPage.contains("openGlossary"))

        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("SPUStandardUserDriverDelegate"))
        #expect(appSource.contains("userDriverDelegate: self"))
        #expect(appSource.contains("standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool"))
        #expect(appSource.contains("semantic_newer_but_sparkle_rejected"))
    }

    @Test func aboutPageOffersAnOptInLoginItemWithSystemApprovalRecovery() throws {
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
            source.components(separatedBy: "Text(currentVersion)").last?
                .components(separatedBy: "if case let .available(update)").first
        )
        #expect(!versionSummary.contains(".onTapGesture"))
        #expect(!versionSummary.contains(".gesture"))
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
        #expect(settings.contains("macro.integration.focus_mcp_boundary"))
        #expect(settings.contains(".font(.callout)"))
        #expect(settings.contains("macroFeature.enrollmentView"))
        #expect(settings.contains("macroFeature.setEditorActive(false)"))
        #expect(settings.contains("if section != .macros"))
        #expect(model.contains("return (resolvedProfileID, !self.macroFeature.isEditorActive)"))
        #expect(model.contains("if macroFeature.isEditorActive"))
        #expect(chinese.contains("输入框"))
        #expect(chinese.contains("MCP / TOML"))
        #expect(english.contains("Learn Input Field"))
        #expect(english.contains("MCP / TOML"))
        #expect(!settings.contains("macro_buttons"))
        #expect(!settings.contains("EarlyAccessController"))
    }

    @Test func sidebarKeepsTheProductPriorityOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let orderStart = try #require(source.range(of: "private static let sidebarSectionOrder"))
        let listStart = try #require(source.range(
            of: "= [",
            range: orderStart.upperBound..<source.endIndex
        ))
        let orderEnd = try #require(source.range(
            of: "]",
            range: listStart.upperBound..<source.endIndex
        ))
        let orderSource = source[listStart.lowerBound...orderEnd.lowerBound]
        var cursor = orderSource.startIndex

        for section in [
            ".mapping",
            ".macros",
            ".statistics",
            ".transcripts",
            ".connection",
            ".permissions",
            ".about",
        ] {
            let range = try #require(orderSource.range(
                of: section,
                range: cursor..<orderSource.endIndex
            ))
            cursor = range.upperBound
        }

        #expect(source.contains("Self.sidebarSectionOrder.filter"))
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
            ".statistics",
            ".transcripts",
            ".connection",
            ".permissions",
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
        #expect(source.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_SHORTCUT_EDITOR"))
        #expect(source.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_SHORTCUT_MODE"))
        #expect(source.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_UPDATE_STATE"))
        #expect(!source.contains("window.titlebarAppearsTransparent = true"))
        #expect(!source.contains("window.titlebarSeparatorStyle = .none"))
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
        #expect(settingsSource.contains("case transcripts"))
        #expect(settingsSource.contains("case .transcripts: return \"settings.section.transcripts\""))
        #expect(transcriptPage.contains("TranscriptHistorySection(model: model, settings: settings)"))
        #expect(transcriptPage.contains("Form {"))
        #expect(transcriptPage.contains("Section {"))
        #expect(transcriptPage.contains("Toggle("))
        #expect(transcriptPage.contains("\"statistics.transcripts.enable\""))
        #expect(!transcriptPage.contains("LabeledContent(\"statistics.transcripts.enable\")"))
        #expect(transcriptPage.contains("Text(\"statistics.transcripts.privacy\")"))
        #expect(transcriptPage.contains(".toggleStyle(.switch)"))
        #expect(transcriptPage.contains(".formStyle(.grouped)"))
        #expect(!transcriptPage.contains("GroupBox {"))
        #expect(!transcriptPage.contains("PageHeader"))
        #expect(transcriptPage.contains("$settings.localTranscriptHistoryEnabled"))
        #expect(transcriptPage.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(!transcriptPage.contains("StatusPill("))
        #expect(historySource.contains("model.transcriptRecords.map(\\.applicationKey)"))
        #expect(historySource.contains("Dictionary(grouping: records"))
        #expect(historySource.contains("allApplicationsButton"))
        #expect(historySource.contains("selectedApplicationKey = nil"))
        #expect(historySource.contains("applicationKey: activeApplicationKey"))
        #expect(historySource.contains("applicationKey: nil"))
        #expect(historySource.contains("($0.records.first?.endedAt ?? .distantPast) >"))
        #expect(historySource.contains("latestEndedAt: max("))
        #expect(historySource.contains("private var isApplicationSwitcherExpanded = false"))
        #expect(historySource.contains("ScrollViewReader { proxy in"))
        #expect(historySource.contains("LazyVGrid("))
        #expect(historySource.contains("private var expandedDayKeys: Set<String> = []"))
        #expect(historySource.contains("id: \"recording-\\(key)\""))
        #expect(historySource.contains("recordingAssetsBySessionID"))
        #expect(historySource.contains("statistics.transcripts.view_more_by_application"))
        #expect(historySource.contains("static let recentWindow: TimeInterval"))
        #expect(historySource.contains("private func toggleDay(_ dayKey: String)"))
        #expect(historySource.contains("dayGroupView(group)"))
        #expect(!historySource.contains(".frame(width: 250, alignment: .topLeading)"))
        #expect(historySource.contains("private var deleteAllRow"))
        #expect(historySource.contains("Section {"))
        #expect(!historySource.contains("Text(\"statistics.transcripts.description\")"))
        #expect(!historySource.contains("GroupBox {\n                    emptyState"))
        let agentAccessPosition = try #require(
            historySource.range(of: "TranscriptAgentAccessSection()")
        )
        let deleteAllPosition = try #require(historySource.range(of: "deleteAllRow"))
        #expect(agentAccessPosition.lowerBound < deleteAllPosition.lowerBound)
        #expect(historySource.contains(".buttonStyle(.borderless)"))
        #expect(!historySource.contains("private var overviewPanel"))
        #expect(!historySource.contains("private var privacyPanel"))
        #expect(historySource.contains("settings.localTranscriptHistoryEnabled"))
        #expect(historySource.contains("HStack(alignment: .top, spacing: 12)"))
        #expect(historySource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!historySource.contains("minHeight: 116"))
        #expect(historySource.contains("NSWorkspace.shared.urlForApplication"))
        #expect(historySource.contains("NSWorkspace.shared.icon(forFile:"))
        #expect(historySource.contains("model.copyTranscript(record)"))
        #expect(historySource.contains("model.deleteTranscriptRecord(record)"))
        #expect(historySource.contains("model.deleteTranscriptApplication(applicationKey: key)"))
        #expect(historySource.contains("model.deleteAllTranscripts()"))
        #expect(historySource.contains("model.recordingPlaybackError"))
        #expect(historySource.contains("TRANSCRIPT HISTORY display_failed"))
        #expect(historySource.contains("reason = \"date_groups_collapsed\""))
        #expect(historySource.contains("displayed_count=\\(displayedCount)"))
        #expect(agentAccessSource.contains("statistics.transcripts.agent_access.enable"))
        #expect(agentAccessSource.contains("Section {"))
        #expect(agentAccessSource.contains("} header: {"))
        #expect(agentAccessSource.contains("Text(\"statistics.transcripts.agent_access.title\")"))
        #expect(agentAccessSource.contains("} footer: {"))
        #expect(!agentAccessSource.contains("GroupBox {\n            VStack"))
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
        #expect(!captureSource.contains("PrivateFeatureIntegration"))
        #expect(!captureSource.contains("API"))
    }

    @Test func systemSettingsInteractionAlignmentRound() throws {
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
        let transcriptSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/TranscriptHistorySection.swift"),
            encoding: .utf8
        )

        // The misleading version-history action remains absent from About.
        #expect(!settingsSource.contains("case releaseHistory"))
        #expect(!settingsSource.contains("private var releaseHistoryPage"))
        #expect(!settingsSource.contains("navigate(to: .releaseHistory)"))
        #expect(!settingsSource.contains("ReleaseHistoryContent()"))
        #expect(!settingsSource.contains("isReleaseHistoryPresented"))
        #expect(!settingsSource.contains("ReleaseHistorySheet"))

        // The single stateful update action cannot be re-triggered while a check is in flight.
        #expect(settingsSource.contains("private var isCheckingForUpdates"))
        #expect(settingsSource.components(separatedBy: ".disabled(isCheckingForUpdates)").count == 2)

        // Waiting connection states expose a system spinner.
        #expect(settingsSource.contains("isWaiting: Bool = false"))
        #expect(settingsSource.contains("isWaiting: model.isPhoneRemoteConnectionEnabled && !model.isPhoneRemoteConnected"))
        #expect(settingsSource.contains("isWaiting: model.isWatchRemoteConnectionEnabled && !model.isWatchRemoteConnected"))
        #expect(settingsSource.contains("isWaiting: isWebRemoteWaiting"))
        #expect(!settingsSource.contains("Spacer(minLength: 42)"))

        // Card-style pickers share one selectable button with hover and focus ring.
        #expect(settingsSource.contains("private struct SelectableCardButton<Label: View>: View"))
        #expect(settingsSource.contains("SelectableCardButton(isSelected: selected, cornerRadius: 10)"))
        #expect(settingsSource.components(separatedBy: "SelectableCardButton(").count >= 5)

        // Statistics values use semantic sizing instead of scale-factor shrinking.
        #expect(!settingsSource.contains("minimumScaleFactor(0.75)"))
        #expect(settingsSource.contains(".font(.system(.title2, design: .rounded).weight(.semibold))"))

        // Transcript page drops the deprecated alert API and names its icon buttons.
        #expect(!transcriptSource.contains(".alert(item:"))
        #expect(transcriptSource.contains("presenting: deletionRequest"))
        #expect(transcriptSource.contains(".accessibilityLabel(Text(localization.text(\"statistics.transcripts.copy\")))"))
        #expect(transcriptSource.contains(".accessibilityLabel(Text(localization.text(\"statistics.transcripts.delete_record\")))"))
        #expect(!transcriptSource.contains(".font(.system(size: 22, weight: .semibold))"))

        // The main menu carries the standard window and navigation shortcuts.
        #expect(appSource.contains("NSApp.windowsMenu = windowMenu"))
        #expect(appSource.contains("setFrameUsingName(window.frameAutosaveName)"))
        #expect(appSource.contains("settingsNavigationCoordinator"))
    }

    @Test func settingsAvoidDuplicateHealthyStatusAndActionLabels() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
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

        #expect(!source.contains("Text(\"audio.voice_output.section_title\")"))
        #expect(source.contains("if model.audioStatus.key != \"audio.output.current_format\""))
        #expect(source.contains(
            "model.testToneStatus.key != \"audio.test_tone.ready\""
        ))
        #expect(source.contains("testToneStatusText != audioStatusText"))
        #expect(source.contains("if shouldShowTestToneStatus"))
        #expect(!source.contains("if !testToneStatusText.isEmpty,"))
        #expect(source.contains("Button(\"about.configuration.export\""))
        #expect(!source.contains("Text(\"about.configuration.export\")"))
        #expect(source.contains("Button(\"about.configuration.import\""))
        #expect(!source.contains("Text(\"about.configuration.import\")"))
        #expect(chinese.contains(
            "\"statistics.voice_ranking.description\" = \"展示时长最长的 10 次语音。\";"
        ))
        #expect(english.contains(
            "\"statistics.voice_ranking.description\" = \"Shows your 10 longest voice sessions.\";"
        ))
    }

    @Test func sharingUsesOneInlinePanelOnlyInAbout() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("aboutShareSectionContent"))
        #expect(source.contains("private var aboutShareSectionContent"))
        #expect(!source.contains("shareSectionContent(for: .statistics)"))
        #expect(!source.contains("\"statistics.share\""))
        #expect(!source.contains("share.sidebar.accessibility_label"))
        #expect(!source.contains("initialShareSection"))
        #expect(!source.contains("private func sharePanel"))
        #expect(source.contains("isAboutShareExpanded.toggle()"))
        #expect(source.contains("ShareCard(url: shareURL)"))
        #expect(!source.contains(".popover"))
    }
}
