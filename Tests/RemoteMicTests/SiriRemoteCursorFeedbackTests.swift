import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Siri Remote cursor feedback")
struct SiriRemoteCursorFeedbackTests {
    @Test func pointerScaleIsBoundedAndGrowsWithSpeed() {
        let slow = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: 0)
        let medium = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: 30)
        let fast = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: 500)

        #expect(slow == 1.0)
        #expect(slow < medium)
        #expect(medium < fast)
        #expect(abs(Double(fast) - 2.2) < 0.0001)
    }

    @Test func pointerAndScrollUseTheSameSpeedScaleAndBaseSize() {
        let speed = 30.0
        let scale = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: speed)

        #expect(SiriRemoteCursorFeedbackState.presentation(
            for: .pointerMoved(deltaX: speed, deltaY: 0, speed: speed)
        ) == .pointer(scale: scale))
        #expect(SiriRemoteCursorFeedbackState.presentation(
            for: .scrolled(pixels: 4, speed: speed)
        ) == .scroll(direction: .up, scale: scale))
        #expect(SiriRemoteCursorFeedbackState.baseIndicatorDiameter == 14)
    }

    @Test func hoverClickRejectsAnElementAfterTheCursorMovesAway() {
        #expect(SiriRemoteCursorFeedbackState.cursorRemainsAtTarget(
            current: CGPoint(x: 101, y: 99),
            target: CGPoint(x: 100, y: 100)
        ))
        #expect(!SiriRemoteCursorFeedbackState.cursorRemainsAtTarget(
            current: CGPoint(x: 104, y: 100),
            target: CGPoint(x: 100, y: 100)
        ))
    }

    @Test func scrollFeedbackUsesDirectionOnly() {
        #expect(SiriRemoteCursorFeedbackState.scrollDirection(forPixels: 4) == .up)
        #expect(SiriRemoteCursorFeedbackState.scrollDirection(forPixels: -4) == .down)
        #expect(SiriRemoteCursorFeedbackState.scrollSymbolName(for: .up) == "arrow.up.circle.fill")
        #expect(SiriRemoteCursorFeedbackState.scrollSymbolName(for: .down) == "arrow.down.circle.fill")
    }

    @Test func preferredFeedbackFrameIsRightBelowAndNeverOverlapsTheCursorBody() {
        let point = CGPoint(x: 400, y: 300)
        let layout = SiriRemoteCursorFeedbackLayout.layout(
            for: point,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let cursorBody = SiriRemoteCursorFeedbackLayout.cursorProtectionFrame(for: point)

        #expect(layout.placement == .rightBelow)
        #expect(layout.frame.minX - cursorBody.maxX == 4)
        #expect(layout.frame.minX > cursorBody.maxX)
        #expect(!layout.frame.intersects(cursorBody))
        #expect(!layout.frame.contains(point))
    }

    @Test func clickablePointerTargetExtendsVisibilityAndConsumesOnlyOneOKPress() {
        var interaction = SiriRemoteCursorFeedbackInteractionState()

        #expect(interaction.pointerBecameIdle(hasClickableTarget: false) == .hide)
        let unavailableConsumed = interaction.consumeOK()
        #expect(!unavailableConsumed)
        #expect(interaction.pointerBecameIdle(hasClickableTarget: true) == .holdForClick(
            SiriRemoteCursorFeedbackInteractionState.clickableTargetHoldDelay
        ))
        let firstConsumed = interaction.consumeOK()
        let duplicateConsumed = interaction.consumeOK()
        #expect(firstConsumed)
        #expect(!duplicateConsumed)

        _ = interaction.pointerBecameIdle(hasClickableTarget: true)
        interaction.scrolled()
        let consumedAfterScroll = interaction.consumeOK()
        #expect(!consumedAfterScroll)
    }

    @Test func clickableTargetResolverChecksOnlyTheBoundedAncestorChain() {
        let parents = [10: 20, 20: 30, 30: 40, 40: 50, 50: 60]

        let direct = SiriRemotePressableTargetResolver.resolve(
            startingAt: 10,
            supportsPress: { $0 == 10 },
            parent: { parents[$0] }
        )
        #expect(direct?.element == 10)
        #expect(direct?.depth == 0)

        let ancestor = SiriRemotePressableTargetResolver.resolve(
            startingAt: 10,
            supportsPress: { $0 == 40 },
            parent: { parents[$0] }
        )
        #expect(ancestor?.element == 40)
        #expect(ancestor?.depth == 3)

        let beyondLimit = SiriRemotePressableTargetResolver.resolve(
            startingAt: 10,
            supportsPress: { $0 == 60 },
            parent: { parents[$0] }
        )
        #expect(beyondLimit == nil)
    }

    @Test func feedbackFlipsAwayFromScreenEdgesWithoutCoveringTheCursor() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        for point in [
            CGPoint(x: 998, y: 2),
            CGPoint(x: 998, y: 798),
            CGPoint(x: 2, y: 2),
        ] {
            let layout = SiriRemoteCursorFeedbackLayout.layout(
                for: point,
                visibleFrame: screen
            )
            let cursorBody = SiriRemoteCursorFeedbackLayout.cursorProtectionFrame(for: point)
            #expect(screen.contains(layout.frame))
            #expect(!layout.frame.intersects(cursorBody))
        }
    }

    @Test func hostWiresPrivateTouchFeedbackIntoTheVisibleController() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/SiriRemoteFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(integration.contains("feature.onTouchFeedback ="))
        #expect(model.contains("siriRemoteFeature.onTouchFeedback ="))
        #expect(model.contains("siriRemoteCursorFeedback.handle(feedback)"))
        #expect(model.contains("siriRemoteCursorFeedback.stop()"))
        #expect(model.contains("siriRemoteCursorFeedback.activateHoveredElementIfAvailable()"))
        #expect(model.contains("appleRemoteHoverClickDevices.insert(event.device)"))
        #expect(model.contains("appleRemoteHoverClickDevices.remove(event.device)"))
        #expect(model.contains("siriRemoteCursorFeedback.cancelInteraction(reason: \"device_reset\")"))
        #expect(model.contains("APPLE REMOTE HOVER_CLICK phase=ended result=consumed"))
    }
}
