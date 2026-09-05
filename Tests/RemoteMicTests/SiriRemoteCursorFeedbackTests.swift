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
}
