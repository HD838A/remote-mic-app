import Testing
@testable import RemoteMic

@Suite("Voice audio level meter")
struct VoiceAudioLevelMeterTests {
    @Test func waitsForOneAnalysisWindowBeforePublishing() {
        var meter = VoiceAudioLevelMeter()
        let partial = Array(
            repeating: Int16(4_000),
            count: VoiceAudioLevelMeter.updateWindowSampleCount - 1
        )
        #expect(meter.append(partial) == nil)
        #expect(meter.append([4_000]) != nil)
    }

    @Test func silenceAndInvalidRMSStayAtZero() {
        var meter = VoiceAudioLevelMeter()
        let silence = Array(
            repeating: Int16(0),
            count: VoiceAudioLevelMeter.updateWindowSampleCount
        )
        #expect(meter.append(silence) == 0)
        #expect(VoiceAudioLevelMeter.normalizedLevel(rms: .nan) == 0)
        #expect(VoiceAudioLevelMeter.normalizedLevel(rms: -.infinity) == 0)
    }

    @Test func louderPCMProducesHigherDisplayedLevel() throws {
        var quietMeter = VoiceAudioLevelMeter()
        var loudMeter = VoiceAudioLevelMeter()
        let sampleCount = VoiceAudioLevelMeter.updateWindowSampleCount
        let quiet = try #require(quietMeter.append(Array(repeating: Int16(500), count: sampleCount)))
        let loud = try #require(loudMeter.append(Array(repeating: Int16(12_000), count: sampleCount)))
        #expect(quiet > 0)
        #expect(loud > quiet)
        #expect(loud <= 1)
    }

    @Test func handlesFullScaleInt16EdgesWithoutOverflow() throws {
        var meter = VoiceAudioLevelMeter()
        let edges = (0..<VoiceAudioLevelMeter.updateWindowSampleCount).map {
            $0.isMultiple(of: 2) ? Int16.min : Int16.max
        }
        let level = try #require(meter.append(edges))
        #expect(level.isFinite)
        #expect(level > 0.7)
        #expect(level <= 1)
    }

    @Test func releaseIsSlowerThanAttackAndResetClearsState() throws {
        var meter = VoiceAudioLevelMeter()
        let sampleCount = VoiceAudioLevelMeter.updateWindowSampleCount
        let loud = Array(repeating: Int16(12_000), count: sampleCount)
        let silence = Array(repeating: Int16(0), count: sampleCount)
        let attacked = try #require(meter.append(loud))
        let released = try #require(meter.append(silence))
        #expect(released > 0)
        #expect(released < attacked)
        meter.reset()
        #expect(meter.level == 0)
        #expect(meter.append(Array(repeating: Int16(2_000), count: sampleCount - 1)) == nil)
    }
}
