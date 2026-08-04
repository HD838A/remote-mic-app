import Foundation
import Testing
@testable import RemoteMic

@Suite("ATVV protocol")
struct ATVVProtocolTests {
    @Test func parsesVersionOneCapabilities() {
        let data = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])
        let capabilities = ATVVCapabilities.parse(data)

        #expect(capabilities?.version == 0x0100)
        #expect(capabilities?.selectedCodec == 0x02)
        #expect(capabilities?.sampleRate == 16_000)
        #expect(capabilities?.frameSize == 120)
    }

    @Test func acceptsLegacyCodecLayoutAdvertisedAsVersionOne() {
        let data = Data([0x0B, 0x01, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00])
        let capabilities = ATVVCapabilities.parse(data)

        #expect(capabilities?.selectedCodec == 0x02)
        #expect(capabilities?.interaction == 0x03)
    }

    @Test func rejectsMalformedCapabilities() {
        #expect(ATVVCapabilities.parse(Data()) == nil)
        #expect(ATVVCapabilities.parse(Data([0x0B, 0x01])) == nil)
        #expect(ATVVCapabilities.parse(Data([0x00, 0x01, 0x00, 0x02, 3, 0, 120])) == nil)
    }

    @Test func versionSpecificMicrophoneCommands() {
        #expect(ATVVProtocol.microphoneOpen(version: 0x0100, codec: 0x02) == Data([0x0C, 0x00]))
        #expect(ATVVProtocol.microphoneOpen(version: 0x0001, codec: 0x02) == Data([0x0C, 0x00, 0x02]))
        #expect(ATVVProtocol.microphoneClose(version: 0x0100, sessionID: 7) == Data([0x0D, 0x07]))
        #expect(ATVVProtocol.microphoneClose(version: 0x0001, sessionID: 7) == Data([0x0D]))
        #expect(ATVVProtocol.microphoneExtend(version: 0x0100, sessionID: 7) == Data([0x0E, 0x07]))
        #expect(ATVVProtocol.microphoneExtend(version: 0x0001, sessionID: 7) == nil)
    }

    @Test func audioRateGateOnlyAccepts16kHz() {
        #expect(ATVVProtocol.supportsAudio(sampleRate: 16_000))
        #expect(!ATVVProtocol.supportsAudio(sampleRate: 8_000))
    }

    @Test func decoderUsesHighNibbleBeforeLowNibble() {
        let decoder = IMAADPCMDecoder()
        #expect(decoder.decode(Data([0x11])) == [1, 2])

        decoder.reset()
        #expect(decoder.decode(Data([0x7F])) == [11, -19])
    }

    @Test func decoderClampsState() {
        let decoder = IMAADPCMDecoder()
        decoder.reset(predictor: 100_000, stepIndex: 1_000)
        #expect(decoder.predictor == 32_767)
        #expect(decoder.stepIndex == 88)
    }

    @Test func postprocessorAppliesSmoothingAndClampedGain() {
        let unchanged = PCMPostprocessor.process([0, 1000, 0], gainDB: 0)
        #expect(unchanged == [0, 500, 0])

        let clipped = PCMPostprocessor.process([20_000], gainDB: 24)
        #expect(clipped == [Int16.max])
        #expect(PCMPostprocessor.process([20_000], gainDB: .infinity) == [20_000])
    }

    @Test func frameAccumulatorPreservesPartialData() {
        var accumulator = FrameAccumulator()
        #expect(accumulator.append(Data([1, 2]), frameSize: 3).isEmpty)
        #expect(accumulator.pending == Data([1, 2]))

        let frames = accumulator.append(Data([3, 4, 5, 6, 7]), frameSize: 3)
        #expect(frames == [Data([1, 2, 3]), Data([4, 5, 6])])
        #expect(accumulator.pending == Data([7]))
    }
}
