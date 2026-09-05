import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Siri Remote cursor feedback")
struct SiriRemoteCursorFeedbackTests {
    @Test func pointerScaleIsBoundedAndGrowsWithSpeed() {
        let slow = SiriRemoteCursorFeedbackState.pointerScale(forSpeed: 0)
        let medium = SiriRemoteCursorFeedbackState.pointerScale(forSpeed: 30)
        let fast = SiriRemoteCursorFeedbackState.pointerScale(forSpeed: 500)

        #expect(slow == 1.0)
        #expect(slow < medium)
        #expect(medium < fast)
        #expect(abs(Double(fast) - 2.2) < 0.0001)
    }

    @Test func scrollFeedbackUsesDirectionOnly() {
        #expect(SiriRemoteCursorFeedbackState.scrollSymbol(forPixels: 4) == "↑")
        #expect(SiriRemoteCursorFeedbackState.scrollSymbol(forPixels: -4) == "↓")
        #expect(SiriRemoteCursorFeedbackState.scrollSymbol(forPixels: 0) == "↑")
    }

    @Test func feedbackFrameIsPlacedToTheRightAndFlipsAtTheScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = SiriRemoteCursorFeedbackLayout.frame(
            for: CGPoint(x: 400, y: 300),
            visibleFrame: screen
        )
        #expect(right.minX > 400)
        #expect(right.midY == 300)

        let edge = SiriRemoteCursorFeedbackLayout.frame(
            for: CGPoint(x: 980, y: 300),
            visibleFrame: screen
        )
        #expect(edge.maxX <= screen.maxX)
        #expect(edge.maxX < 980)
    }
}
