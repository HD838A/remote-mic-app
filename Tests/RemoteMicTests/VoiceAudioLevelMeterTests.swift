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
        let partialLevel = meter.append(partial)
        let completedLevel = meter.append([4_000])
        #expect(partialLevel == nil)
        #expect(completedLevel != nil)
    }

    @Test func silenceAndInvalidRMSStayAtZero() {
        var meter = VoiceAudioLevelMeter()
        let silence = Array(
            repeating: Int16(0),
            count: VoiceAudioLevelMeter.updateWindowSampleCount
        )
        let silenceLevel = meter.append(silence)
        #expect(silenceLevel == 0)
        #expect(VoiceAudioLevelMeter.normalizedLevel(rms: .nan) == 0)
        #expect(VoiceAudioLevelMeter.normalizedLevel(rms: -.infinity) == 0)
    }

    @Test func louderPCMProducesHigherDisplayedLevel() throws {
        var quietMeter = VoiceAudioLevelMeter()
        var loudMeter = VoiceAudioLevelMeter()
        let sampleCount = VoiceAudioLevelMeter.updateWindowSampleCount
        let quietResult = quietMeter.append(Array(repeating: Int16(500), count: sampleCount))
        let loudResult = loudMeter.append(Array(repeating: Int16(12_000), count: sampleCount))
        let quiet = try #require(quietResult)
        let loud = try #require(loudResult)
        #expect(quiet > 0)
        #expect(loud > quiet)
        #expect(loud <= 1)
    }

    @Test func handlesFullScaleInt16EdgesWithoutOverflow() throws {
        var meter = VoiceAudioLevelMeter()
        let edges = (0..<VoiceAudioLevelMeter.updateWindowSampleCount).map {
            $0.isMultiple(of: 2) ? Int16.min : Int16.max
        }
        let levelResult = meter.append(edges)
        let level = try #require(levelResult)
        #expect(level.isFinite)
        #expect(level > 0.7)
        #expect(level <= 1)
    }

    @Test func releaseIsSlowerThanAttackAndResetClearsState() throws {
        var meter = VoiceAudioLevelMeter()
        let sampleCount = VoiceAudioLevelMeter.updateWindowSampleCount
        let loud = Array(repeating: Int16(12_000), count: sampleCount)
        let silence = Array(repeating: Int16(0), count: sampleCount)
        let attackedResult = meter.append(loud)
        let releasedResult = meter.append(silence)
        let attacked = try #require(attackedResult)
        let released = try #require(releasedResult)
        #expect(released > 0)
        #expect(released < attacked)
        meter.reset()
        #expect(meter.level == 0)
        let resetPartialLevel = meter.append(
            Array(repeating: Int16(2_000), count: sampleCount - 1)
        )
        #expect(resetPartialLevel == nil)
    }
}
