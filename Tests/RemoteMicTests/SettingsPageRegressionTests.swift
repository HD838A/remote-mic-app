import Foundation
import SwiftUI
import Testing
@testable import RemoteMic

@Suite("Settings page regression")
struct SettingsPageRegressionTests {
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
        #expect(RemoteMappingLayout.cardWidth(for: canvasWidth) == 285)

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
        let source = settingsSource + mappingCanvasSource

        for requiredAction in [
            "model.reconnect()",
            "model.applyAudioSettings()",
            "model.refreshAudioDevices()",
            "model.sendTestTone()",
            "model.selectDoubaoAudioDevice()",
            "model.openDoubaoDriverInstructions(using: localization)",
            "model.setVoiceFnTapModeEnabled",
            "model.setDeepSeekPostDictationEnabled",
            "model.saveDeepSeekAPIKey",
            "model.deleteDeepSeekAPIKey()",
            "model.testDeepSeekConnection()",
            "model.addProgrammingTerm(",
            "model.removeProgrammingTerm",
            "model.enablePhoneRemoteConnection()",
            "copyTestFlightPublicBetaLink()",
            "requestWebRemoteSession()",
            "settings.clearTrustedPhoneIdentities()",
            "settings.setAction(action, for: button, trigger: trigger)",
            "settings.setShortcut(",
            "settings.resetBindings()",
        ] {
            #expect(source.contains(requiredAction), Comment(rawValue: requiredAction))
        }

        #expect(source.contains("AppLinks.testFlightPublicBeta"))
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
        #expect(source.contains("case postDictation"))
        #expect(source.contains("case .postDictation:"))
        #expect(source.contains("postDictationPage"))
        #expect(source.contains("settings.section.ai_polish"))
        #expect(source.contains("post_dictation.status.section_title"))
        #expect(source.contains("DeepSeek V4 Flash"))
        let connectionPageStart = try #require(source.range(of: "private var connectionPage"))
        let postDictationPageStart = try #require(source.range(of: "private var postDictationPage"))
        let connectionPageSource = source[connectionPageStart.lowerBound..<postDictationPageStart.lowerBound]
        #expect(!connectionPageSource.contains("postDictationPanel"))
        #expect(source.range(of: "MappingRemotePhoto()")!.lowerBound < source.range(of: "connectionLines(metrics: metrics)")!.lowerBound)

        let voiceFnToggle = "Toggle(\"connection.voice_fn_tap.enabled\""
        #expect(source.components(separatedBy: voiceFnToggle).count == 2)
        #expect(
            source.range(of: voiceFnToggle)!.lowerBound >
                source.range(of: "private var mappingPage")!.lowerBound
        )
    }
}
