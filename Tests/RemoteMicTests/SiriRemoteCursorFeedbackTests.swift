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
        #expect(SiriRemoteCursorFeedbackState.scrollDirection(forPixels: 4) == .up)
        #expect(SiriRemoteCursorFeedbackState.scrollDirection(forPixels: -4) == .down)
        #expect(SiriRemoteCursorFeedbackState.scrollDirection(forPixels: 0) == .up)
        #expect(SiriRemoteCursorFeedbackState.scrollSymbolName(for: .up) == "arrow.up.circle.fill")
        #expect(SiriRemoteCursorFeedbackState.scrollSymbolName(for: .down) == "arrow.down.circle.fill")
    }

    @Test func feedbackFrameStaysOnTheCursorBodyAndClampsAtScreenEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let centered = SiriRemoteCursorFeedbackLayout.frame(
            for: CGPoint(x: 400, y: 300),
            visibleFrame: screen
        )
        #expect(centered.width == 48)
        #expect(centered.height == 48)
        #expect(centered.midX == 408)
        #expect(centered.midY == 292)
        #expect(centered.contains(CGPoint(x: 400, y: 300)))

        let edge = SiriRemoteCursorFeedbackLayout.frame(
            for: CGPoint(x: 998, y: 2),
            visibleFrame: screen
        )
        #expect(edge.maxX <= screen.maxX)
        #expect(edge.minY >= screen.minY)
    }
}
