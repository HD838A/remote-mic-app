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

@Suite("Bluetooth voice tail diagnostics")
struct BluetoothVoiceTailDiagnosticsTests {
    @Test func staleBluetoothStopCompletionCannotReleaseARestartedVoiceLatch() {
        let coordinator = BluetoothVoiceStopCoordinator()
        var latch = VoiceFunctionKeyLatch()
        var drainCompletion: (() -> Void)?
        var cancelledDrainCount = 0
        var finishedStopCount = 0

        #expect(!coordinator.didStart(cancelPendingDrain: { cancelledDrainCount += 1 }))
        #expect(latch.transition(streaming: true, owner: .bluetooth) == .press)
        coordinator.stop(
            requiresDrain: true,
            drainAudio: { drainCompletion = $0 }
        ) {
            _ = latch.transition(streaming: false, owner: .bluetooth)
            finishedStopCount += 1
        }

        #expect(coordinator.didStart(cancelPendingDrain: { cancelledDrainCount += 1 }))
        #expect(latch.transition(streaming: true, owner: .bluetooth) == nil)
        drainCompletion?()

        #expect(cancelledDrainCount == 1)
        #expect(latch.isHeld)
        #expect(finishedStopCount == 0)
    }

    @Test func bluetoothVoiceStopDrainsPlaybackBeforeReleasingSoftwareVoiceKey() {
        let coordinator = BluetoothVoiceStopCoordinator()
        var drainCompletion: (() -> Void)?
        var events: [String] = []

        coordinator.stop(
            requiresDrain: true,
            drainAudio: {
                events.append("drain_started")
                drainCompletion = $0
            }
        ) {
            events.append("voice_key_released")
        }

        #expect(events == ["drain_started"])
        drainCompletion?()
        #expect(events == ["drain_started", "voice_key_released"])
    }

    @Test func keepsOnlyTheLatestThreeHundredMillisecondsWithoutAudioContentLogging() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        diagnostics.append(Array(repeating: 1, count: 4_000), at: 10)
        diagnostics.append(Array(repeating: 2, count: 2_000), at: 10.25)

        let snapshot = diagnostics.snapshot(at: 10.30)

        #expect(snapshot.sampleCount == 4_800)
        #expect(snapshot.durationMilliseconds == 300)
        #expect(snapshot.nonZeroSampleCount == 4_800)
        #expect(snapshot.peak == 2)
        #expect(snapshot.rms == 1)
        #expect(snapshot.finalWindowSampleCount == 1_600)
        #expect(snapshot.finalWindowDurationMilliseconds == 100)
        #expect(snapshot.finalWindowNonZeroSampleCount == 1_600)
        #expect(snapshot.finalWindowPeak == 2)
        #expect(snapshot.finalWindowRMS == 2)
        #expect(snapshot.lastAudioAgeMilliseconds == 50)
    }

    @Test func distinguishesTheFinalHundredMillisecondsFromEarlierTailSignal() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        diagnostics.append(Array(repeating: 10, count: 3_200), at: 10)
        diagnostics.append(Array(repeating: 0, count: 1_600), at: 10.20)

        let snapshot = diagnostics.snapshot(at: 10.30)

        #expect(snapshot.peak == 10)
        #expect(snapshot.nonZeroSampleCount == 3_200)
        #expect(snapshot.finalWindowSampleCount == 1_600)
        #expect(snapshot.finalWindowNonZeroSampleCount == 0)
        #expect(snapshot.finalWindowPeak == 0)
        #expect(snapshot.finalWindowRMS == 0)
    }

    @Test func resetRemovesPriorSessionSignalAndTiming() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        diagnostics.append([1, 2, 3], at: 10)
        diagnostics.reset()

        let snapshot = diagnostics.snapshot(at: 20)

        #expect(snapshot.sampleCount == 0)
        #expect(snapshot.durationMilliseconds == 0)
        #expect(snapshot.finalWindowSampleCount == 0)
        #expect(snapshot.finalWindowDurationMilliseconds == 0)
        #expect(snapshot.lastAudioAgeMilliseconds == nil)
    }
}
