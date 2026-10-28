import Testing
@testable import RemoteMic

@Suite("Software PTT release after playback")
struct VoiceKeyReleaseDrainTests {
    @Test func finalSyntheticSamplesReachConsumerBeforeKeyRelease() {
        let gate = VoiceKeyReleaseDrain()
        var latch = VoiceFunctionKeyLatch()
        #expect(latch.transition(streaming: true, owner: .bluetooth) == .press)
        let tail: [Int16] = [3, 1, 4, 1, 5]
        var received: [Int16] = []
        var completePlayback: (() -> Void)?
        gate.wait(drain: { completePlayback = $0 }, release: {
            #expect(latch.transition(streaming: false, owner: .bluetooth) == .release)
        })
        #expect(gate.isPending)
        #expect(latch.isHeld)
        // A real PTT consumer stops accepting samples when its key is released.
        if latch.isHeld { received += tail }
        completePlayback?()
        #expect(received == tail)
        #expect(!latch.isHeld)
        #expect(!gate.isPending)
    }

    @Test func emptyQueueReleasesImmediatelyWithoutFixedTailDelay() {
        let gate = VoiceKeyReleaseDrain()
        var releases = 0
        gate.wait(drain: { $0() }, release: { releases += 1 })
        #expect(releases == 1)
        #expect(!gate.isPending)
    }

    @Test func rapidRepressInvalidatesOldCompletionWithoutStoppingPlayback() {
        let gate = VoiceKeyReleaseDrain()
        var completions: [() -> Void] = []
        var releases = 0
        gate.wait(drain: { completions.append($0) }, release: { releases += 1 })
        gate.cancel() // The same Bluetooth owner presses again and keeps its key hold.
        gate.wait(drain: { completions.append($0) }, release: { releases += 1 })
        completions[0]()
        #expect(gate.isPending)
        #expect(releases == 0)
        completions[1]()
        #expect(releases == 1)
        #expect(!gate.isPending)
    }

    @Test func disconnectOrAppStopInvalidatesLateCallback() {
        let gate = VoiceKeyReleaseDrain()
        var completePlayback: (() -> Void)?
        var releases = 0
        gate.wait(drain: { completePlayback = $0 }, release: { releases += 1 })
        gate.cancel() // Existing disconnect/stop cleanup owns the forced key release.
        completePlayback?()
        #expect(releases == 0)
        #expect(!gate.isPending)
    }

    @Test func duplicateDrainAnswerReleasesExactlyOnce() {
        let gate = VoiceKeyReleaseDrain()
        var completePlayback: (() -> Void)?
        var releases = 0
        gate.wait(drain: { completePlayback = $0 }, release: { releases += 1 })
        completePlayback?()
        completePlayback?()
        #expect(releases == 1)
    }

    @Test func drainingBluetoothOwnerDoesNotReleaseMobileOwner() {
        let gate = VoiceKeyReleaseDrain()
        var latch = VoiceFunctionKeyLatch()
        _ = latch.transition(streaming: true, owner: .bluetooth)
        _ = latch.transition(streaming: true, owner: .mobile)
        var completePlayback: (() -> Void)?
        gate.wait(drain: { completePlayback = $0 }, release: {
            #expect(latch.transition(streaming: false, owner: .bluetooth) == nil)
        })
        completePlayback?()
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .mobile) == .release)
    }
}
