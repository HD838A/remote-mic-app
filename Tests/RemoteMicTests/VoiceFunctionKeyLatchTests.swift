import Testing
@testable import RemoteMic

@Suite("Voice Fn hold")
struct VoiceFunctionKeyLatchTests {
    @Test func pendingDownRejectsANewOwnerButKeepsTheExistingOwnerIdempotent() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .bluetooth) == .press)
        #expect(!VoiceKeyPendingDownPolicy.shouldRejectStart(
            streaming: true,
            pendingDown: true,
            ownerAlreadyRegistered: latch.contains(.bluetooth)
        ))
        #expect(latch.transition(streaming: true, owner: .bluetooth) == nil)
        #expect(VoiceKeyPendingDownPolicy.shouldRejectStart(
            streaming: true,
            pendingDown: true,
            ownerAlreadyRegistered: latch.contains(.mobile)
        ))

        latch.rollback(.press, owner: .bluetooth)
        #expect(!latch.isHeld)
        #expect(!latch.contains(.mobile))
    }

    @Test func confirmedDownStillAllowsMultipleOwnersToShareOneKeyHold() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .bluetooth) == .press)
        #expect(!VoiceKeyPendingDownPolicy.shouldRejectStart(
            streaming: true,
            pendingDown: false,
            ownerAlreadyRegistered: latch.contains(.mobile)
        ))
        #expect(latch.transition(streaming: true, owner: .mobile) == nil)
        #expect(latch.transition(streaming: false, owner: .bluetooth) == nil)
        #expect(latch.transition(streaming: false, owner: .mobile) == .release)
        #expect(!latch.isHeld)
    }
    @Test func emitsOnePressAndOneReleasePerStream() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .mobile) == .press)
        #expect(latch.transition(streaming: true, owner: .mobile) == nil)
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .mobile) == .release)
        #expect(latch.transition(streaming: false, owner: .mobile) == nil)
        #expect(!latch.isHeld)
    }

    @Test func releasesOnlyAfterTheLastOwnerStops() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .bluetooth) == .press)
        #expect(latch.transition(streaming: true, owner: .mobile) == nil)
        #expect(latch.transition(streaming: false, owner: .bluetooth) == nil)
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .mobile) == .release)
        #expect(!latch.isHeld)
    }

    @Test func rollsBackFailedTransitions() {
        var latch = VoiceFunctionKeyLatch()

        let press = latch.transition(streaming: true, owner: .bluetooth)
        #expect(press == .press)
        latch.rollback(.press, owner: .bluetooth)
        #expect(!latch.isHeld)

        #expect(latch.transition(streaming: true, owner: .mobile) == .press)
        let release = latch.transition(streaming: false, owner: .mobile)
        #expect(release == .release)
        latch.rollback(.release, owner: .mobile)
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .bluetooth) == nil)
        #expect(latch.transition(streaming: false, owner: .mobile) == .release)
    }

    @Test func resetClearsEveryOwnerAfterAForcedRelease() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .bluetooth) == .press)
        #expect(latch.transition(streaming: true, owner: .mobile) == nil)
        latch.reset()
        #expect(!latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .bluetooth) == nil)
        #expect(latch.transition(streaming: false, owner: .mobile) == nil)
        #expect(latch.transition(streaming: true, owner: .mobile) == .press)
    }
}
