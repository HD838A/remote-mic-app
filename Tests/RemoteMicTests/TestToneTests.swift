import AVFAudio
import Testing
@testable import RemoteMic

@Suite("Test tone")
struct TestToneTests {
    @Test func sampleCountFollowsDurationAndSampleRate() {
        #expect(TestToneGenerator.samples(sampleRate: 16_000).count == 16_000)
        #expect(TestToneGenerator.samples(sampleRate: 8_000).count == 8_000)
        #expect(TestToneGenerator.samples(sampleRate: 0).isEmpty)
        #expect(TestToneGenerator.samples(sampleRate: -1).isEmpty)
    }

    @Test func durationAndFrequencyStayWithinSafeBounds() {
        #expect(TestToneGenerator.duration >= 0.8 && TestToneGenerator.duration <= 1.2)
        #expect(TestToneGenerator.frequency >= 200 && TestToneGenerator.frequency <= 2_000)
        #expect(TestToneGenerator.amplitude > 0 && TestToneGenerator.amplitude <= 0.2)
    }

    @Test func samplesNeverExceedLowVolumeSafetyLimit() {
        let samples = TestToneGenerator.samples(sampleRate: 16_000)
        let limit = Int((Double(Int16.max) * TestToneGenerator.amplitude).rounded()) + 1
        #expect(samples.allSatisfy { abs(Int($0)) <= limit })
    }

    @Test func safetyGateRejectsMissingDeviceActiveVoiceOrInFlightPlayback() {
        #expect(!TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: false, isPlaying: false))
        #expect(!TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: true, isPlaying: false))
        #expect(!TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: true, isPlaying: false))
        #expect(!TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: false, isPlaying: true))
        #expect(!TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: true, isPlaying: true))
        #expect(!TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: false, isPlaying: true))
        #expect(!TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: true, isPlaying: true))
        #expect(TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: false, isPlaying: false))
    }

    @Test func audioOutputFailsClosedWithoutAConfiguredDevice() {
        let output = VirtualAudioOutput()
        #expect(!output.isReadyForTestTone)
        #expect(!output.enqueue(samples: [1, 2, 3]))

        var completionCalled = false
        let started = output.playTestTone { _ in completionCalled = true }
        #expect(!started)
        #expect(!completionCalled)

        output.cancelTestTone()
        output.endSession()
    }

    @Test func disconnectedAudioPlayerFailsClosedInsteadOfCrashing() {
        let player = AVAudioPlayerNode()

        #expect(!AudioPlayerNodeSafety.play(player))
    }

    @Test func productionModelRejectsTestToneWithoutAReadyDevice() {
        let model = BridgeAppModel()
        #expect(!model.canSendTestTone)

        model.sendTestTone()

        #expect(!model.isPlayingTestTone)
        #expect(model.testToneStatus.key == "audio.output.none_or_unavailable")
    }
}
