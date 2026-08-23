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

        let noInvite = try #require(settingsSource.range(
            of: "Text(\"connection.phone.qr_badge\")"
        ))
        let noInviteBlock = settingsSource[noInvite.lowerBound...]
            .prefix(180)
        #expect(noInviteBlock.contains(".font(.system(size: 12, weight: .semibold))"))

        let statusPill = try #require(settingsSource.range(of: "private struct StatusPill"))
        let statusPillBlock = settingsSource[statusPill.lowerBound...]
            .prefix(420)
        #expect(statusPillBlock.contains(".font(.system(size: 12, weight: .semibold))"))
        #expect(appSource.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"))
        #expect(rendererSource.contains("width >= 800"))
        #expect(rendererSource.contains("height >= 650"))
        for section in ["connection", "mapping", "statistics", "permissions", "about"] {
            #expect(rendererSource.contains(".\(section)"))
        }
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

        let mappingPage = try #require(settingsSource.range(of: "private var mappingPage"))
        let editorPanel = try #require(settingsSource.range(
            of: "private func mappingEditorPanel",
            range: mappingPage.upperBound..<settingsSource.endIndex
        ))
        let mappingSource = settingsSource[mappingPage.lowerBound..<editorPanel.lowerBound]

        #expect(mappingSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(mappingSource.contains("private var mappingHeaderToggle"))
        #expect(mappingSource.contains(".frame(width: 320)"))
        #expect(mappingSource.contains(".fixedSize(horizontal: true, vertical: false)"))
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

        #expect(appSource.contains("window.isMovableByWindowBackground = false"))
        #expect(!appSource.contains("window.isMovableByWindowBackground = true"))
        #expect(settingsSource.contains("WindowDragArea()"))
        #expect(settingsSource.contains("window?.performDrag(with: event)"))
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
            "model.sendTestTone()",
            "model.selectDoubaoAudioDevice()",
            "model.openDoubaoDriverInstructions(using: localization)",
            "model.setVoiceFnTapModeEnabled",
            "model.togglePhoneRemoteConnection()",
            "model.toggleWatchRemoteConnection()",
            "copyTestFlightPublicBetaLink()",
            "requestWebRemoteSession()",
            "settings.clearTrustedPhoneIdentities()",
            "settings.setAction(",
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
        #expect(mobileEntrySource.contains("tint: model.isPhoneRemoteConnected"))
        #expect(mobileEntrySource.contains("tint: model.isWatchRemoteConnected"))
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
        #expect(source.contains(".focusEffectDisabled()"))
        #expect(source.contains(".frame(height: 56)"))
        #expect(source.contains(".ignoresSafeArea(.container, edges: .top)"))
        #expect(source.contains("showsAnchor: activeButtons.contains(placement.button)"))
        #expect(source.contains(".toggleStyle(.switch)"))
        #expect(source.contains("button_mapping.permission_prompt.open"))
        #expect(source.contains("button_mapping.selection_lock_hint_short"))
        #expect(source.contains("connection.voice_fn_tap.hint_short"))
        #expect(source.contains("ButtonActionCategory.allCases"))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains("button_mapping.action.disable_switch"))
        #expect(source.contains("$0 != .disabled"))
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

        let voiceFnToggle = "Toggle(\"connection.voice_fn_tap.enabled\""
        #expect(source.components(separatedBy: voiceFnToggle).count == 2)
        #expect(
            source.range(of: voiceFnToggle)!.lowerBound >
                source.range(of: "private var mappingPage")!.lowerBound
        )
        #expect(!source.contains("connection.voice_key.mode"))
        #expect(!source.contains("VoiceKeyMode.fnGlobe.displayName"))
        #expect(!source.contains("ForEach(VoiceKeyMode.allCases)"))
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
        #expect(!panelSource.contains("StatusPill(text: connectionBadge"))

        #expect(appSource.contains(
            "fileMenu.addItem(menuItem(\"menu.open_log_folder\", action: #selector(showLog)))"
        ))
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

        let aboutPage = try #require(source.components(separatedBy: "private var aboutPage").last)
        #expect(aboutPage.contains("updateInformationContent"))
        #expect(aboutPage.contains("about.version.history"))
        #expect(aboutPage.contains("about.version.check_prerelease"))
        #expect(aboutPage.contains("about.version.update_to"))
        #expect(aboutPage.contains("ForEach(AppLanguage.allCases)"))
        #expect(aboutPage.contains(".pickerStyle(.segmented)"))
        #expect(!aboutPage.contains("help.glossary.open"))
        #expect(!aboutPage.contains("openGlossary"))
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
        #expect(integration.contains("@Published private(set) var isEditorActive"))
        #expect(settings.contains("macroFeature.settingsView"))
        #expect(settings.contains("macro.integration.focus_mcp_boundary"))
        #expect(settings.contains(".font(.system(size: 12))"))
        #expect(settings.contains("macroFeature.enrollmentView"))
        #expect(settings.contains("macroFeature.setEditorActive(selectedSection == .macros)"))
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
        #expect(historySource.contains("Dictionary(grouping: model.transcriptRecords"))
        #expect(historySource.contains("Dictionary(grouping: records"))
        #expect(historySource.contains("allApplicationsButton"))
        #expect(historySource.contains("selectedApplicationKey = nil"))
        #expect(historySource.contains("if let activeApplicationKey"))
        #expect(historySource.contains("records = model.transcriptRecords"))
        #expect(historySource.contains("($0.records.first?.endedAt ?? .distantPast) >"))
        #expect(historySource.contains("latestEndedAt: records.map(\\.endedAt).max()"))
        #expect(historySource.contains("private var isApplicationSwitcherExpanded = false"))
        #expect(historySource.contains("ScrollViewReader { proxy in"))
        #expect(historySource.contains("LazyVGrid("))
        #expect(historySource.contains("private var expandedDayKeys: Set<String> = []"))
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
        #expect(historySource.contains("model.copyTranscript(record)"))
        #expect(historySource.contains("model.deleteTranscriptRecord(record)"))
        #expect(historySource.contains("model.deleteTranscriptApplication(applicationKey: key)"))
        #expect(historySource.contains("model.deleteAllTranscripts()"))
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
            "transcriptCaptureCoordinator.startSession(startedAt: startedAt, source: source)"
        ))
        #expect(modelSource.contains(
            "transcriptCaptureCoordinator.finishSession(endedAt: endedAt)"
        ))
        #expect(modelSource.contains("transcriptCaptureCoordinator.cancel()"))
        #expect(!captureSource.contains("PrivateFeatureIntegration"))
        #expect(!captureSource.contains("API"))
    }

    @Test func sharingUsesOneInlinePanelAcrossAboutStatisticsAndSidebar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("sharePanel(for: .about)"))
        #expect(source.contains("sharePanel(for: .statistics)"))
        #expect(source.contains("selectedSection = .about"))
        #expect(source.contains("expandedShareSection = .about"))
        #expect(source.contains("ShareCard(url: shareURL)"))
        #expect(!source.contains(".popover"))
    }
}
