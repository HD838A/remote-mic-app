import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Post-dictation global HUD")
struct PostDictationHUDControllerTests {
    @MainActor
    @Test func panelIsNonActivatingMousePassingAndAvailableAcrossSpaces() throws {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let localization = LocalizationStore(settings: AppSettings(), resourceBundle: .main)
        let controller = PostDictationHUDController(localization: localization)
        controller.setVisible(true)
        defer { controller.hideImmediately() }

        let panel = try #require(application.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        } as? NSPanel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(panel.isVisible)
    }

    @Test func onlyRealPolishingRequestsShowTheGlobalHUD() {
        #expect(PostDictationHUDPresentation.shouldShow(
            state: .requesting,
            statusKey: "post_dictation.status.requesting"
        ))
        #expect(!PostDictationHUDPresentation.shouldShow(
            state: .requesting,
            statusKey: "post_dictation.status.testing"
        ))
        #expect(!PostDictationHUDPresentation.shouldShow(
            state: .waitingForStability,
            statusKey: "post_dictation.status.waiting_for_stability"
        ))
        #expect(!PostDictationHUDPresentation.shouldShow(
            state: .completed,
            statusKey: "post_dictation.status.completed"
        ))
    }

    @Test func hudIsCenteredAboveTheVisibleScreenBottom() {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1440, height: 820)
        let frame = PostDictationHUDLayout.frame(in: visibleFrame)

        #expect(frame.size == PostDictationHUDLayout.windowSize)
        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.minY == visibleFrame.minY + PostDictationHUDLayout.bottomMargin)
    }

    @Test func hudStaysInsideAnOffsetExternalDisplay() {
        let visibleFrame = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        let frame = PostDictationHUDLayout.frame(in: visibleFrame)

        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
    }
}
