import Testing
@testable import RemoteMic

@Suite("Voice Fn hold")
struct VoiceFunctionKeyLatchTests {
    @Test func emitsOnePressAndOneReleasePerStream() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true) == .press)
        #expect(latch.transition(streaming: true) == nil)
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false) == .release)
        #expect(latch.transition(streaming: false) == nil)
        #expect(!latch.isHeld)
    }

    @Test func rollsBackFailedTransitions() {
        var latch = VoiceFunctionKeyLatch()

        let press = latch.transition(streaming: true)
        #expect(press == .press)
        latch.rollback(.press)
        #expect(!latch.isHeld)

        #expect(latch.transition(streaming: true) == .press)
        let release = latch.transition(streaming: false)
        #expect(release == .release)
        latch.rollback(.release)
        #expect(latch.isHeld)
    }
}
