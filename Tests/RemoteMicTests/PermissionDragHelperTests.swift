import Foundation
import Testing
@testable import RemoteMic

@Suite("Permission drag helper")
struct PermissionDragHelperTests {
    @Test func inputMonitoringCardSitsBelowTheList() {
        let result = PermissionDragHelperPlacementCalculator.place(
            windowFrame: CGRect(x: 947, y: 108, width: 754, height: 873),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            pane: .inputMonitoring
        )

        #expect(result.placement == .belowList)
        #expect(result.cardOrigin.x == 1210)
        #expect(result.cardOrigin.y == 536)
        let panelOrigin = PermissionDragHelperPlacementCalculator.panelOrigin(
            for: result.cardOrigin
        )
        #expect(panelOrigin.x == 1204)
        #expect(panelOrigin.y == 530)
    }

    @Test func accessibilityUsesTheRightSidecarWhenSpaceExists() {
        let result = PermissionDragHelperPlacementCalculator.place(
            windowFrame: CGRect(x: 200, y: 108, width: 754, height: 873),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            pane: .accessibility
        )

        #expect(result.placement == .sidecarRight)
        #expect(result.cardOrigin.x == 970)
        #expect(result.cardOrigin.y == 760)
    }

    @Test func accessibilityUsesTheLeftSidecarWhenTheRightEdgeIsClamped() {
        let result = PermissionDragHelperPlacementCalculator.place(
            windowFrame: CGRect(x: 1100, y: 108, width: 754, height: 873),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            pane: .accessibility
        )

        #expect(result.placement == .sidecarLeft)
        #expect(result.cardOrigin.x == 766)
        #expect(result.cardOrigin.y == 760)
    }

    @Test func aWideWindowFallsBackToTheSafeArea() {
        let result = PermissionDragHelperPlacementCalculator.place(
            windowFrame: CGRect(x: 100, y: 108, width: 1700, height: 873),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            pane: .accessibility
        )

        #expect(result.placement == .safeArea)
        #expect(result.cardOrigin.x == 1586)
        #expect(result.cardOrigin.y == 16)
    }

    @Test func aShortVisibleFrameFallsBackToTheSafeArea() {
        let result = PermissionDragHelperPlacementCalculator.place(
            windowFrame: CGRect(x: 100, y: 0, width: 754, height: 873),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 400),
            pane: .inputMonitoring
        )

        #expect(result.placement == .safeArea)
        #expect(result.cardOrigin.x == 1586)
        #expect(result.cardOrigin.y == 16)
    }

    @Test func paneAndSourceTokensStayStableForLogs() {
        #expect(PermissionDragHelperPane.inputMonitoring.rawValue == "input_monitoring")
        #expect(PermissionDragHelperPane.accessibility.rawValue == "accessibility")
        #expect(PermissionDragHelperSource.onboarding.rawValue == "onboarding")
        #expect(PermissionDragHelperSource.settings.rawValue == "settings")
        #expect(PermissionDragHelperPlacement.belowList.rawValue == "below_list")
        #expect(PermissionDragHelperPlacement.sidecarRight.rawValue == "sidecar_right")
        #expect(PermissionDragHelperPlacement.sidecarLeft.rawValue == "sidecar_left")
        #expect(PermissionDragHelperPlacement.safeArea.rawValue == "safe_area")
    }

    @Test func helperUsesTheRealBundleAndSystemThemeColors() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = try source(root, "Sources/RemoteMic/PermissionDragHelper.swift")
        let card = try source(root, "Sources/RemoteMic/PermissionDragCardView.swift")

        #expect(helper.contains("Bundle.main.bundleURL"))
        #expect(helper.contains("CGWindowListCopyWindowInfo"))
        #expect(helper.contains("\"System Settings\""))
        #expect(helper.contains("\"系统设置\""))
        #expect(helper.contains("PERMISSION_HELPER"))
        #expect(helper.contains("action=hidden reason=system_modal"))
        #expect(helper.contains("action=permission_granted"))
        #expect(card.contains("NSWorkspace.shared.icon(forFile:"))
        #expect(card.contains("bundleURL as NSURL"))
        #expect(card.contains("NSDraggingItem"))
        #expect(card.contains("controlAccentColor"))
        #expect(card.contains("NSVisualEffectView"))
        #expect(card.contains("setLineDash"))
        #expect(card.contains("[3, 2]"))
    }

    @Test func permissionRequestsAreWiredFromBothSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try source(root, "Sources/RemoteMic/BridgeAppModel.swift")
        let onboarding = try source(root, "Sources/RemoteMic/OnboardingView.swift")

        #expect(model.contains("PermissionDragHelperController.shared.present"))
        #expect(model.contains("pane: .inputMonitoring"))
        #expect(model.contains("pane: .accessibility"))
        #expect(model.contains("source: source"))
        #expect(onboarding.contains("requestInputMonitoringPermission(source: .onboarding)"))
        #expect(onboarding.contains("requestAccessibilityPermission(source: .onboarding)"))
    }

    private func source(_ root: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
