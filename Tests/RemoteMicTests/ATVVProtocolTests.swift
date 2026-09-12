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

    @Test func commandActivationWiresEarlyBluetoothAudioBufferingBeforeRouting() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "func bluetoothBridgeDidStartVoice"))
        let stop = try #require(source.range(
            of: "func bluetoothBridgeDidStopVoice",
            range: start.upperBound..<source.endIndex
        ))
        let startSource = source[start.lowerBound..<stop.lowerBound]
        let decode = try #require(source.range(of: "didDecode samples: [Int16]"))
        let battery = try #require(source.range(
            of: "didUpdateBatteryLevel",
            range: decode.upperBound..<source.endIndex
        ))
        let decodeSource = source[decode.lowerBound..<battery.lowerBound]

        #expect(decodeSource.contains("pendingCommandVoiceAudio.appendIfWaiting(samples)"))
        let sessionStart = try #require(startSource.range(of: "voiceFnTapSession.startVoice()"))
        let flush = try #require(startSource.range(of: "flushPendingCommandVoiceAudio(for: bridge)"))
        #expect(sessionStart.lowerBound < flush.lowerBound)
    }

    @Test func commandVoiceJourneyFlushesPreRollBeforeRemainingAudioAndClearsOnStop() {
        var buffer = CommandVoiceActivationAudioBuffer(maximumSampleCount: 4)
        var routedSamples: [Int16] = []
        var events: [String] = []

        // STREAM_START → early AUDIO while the Command DOWN is pending.
        events.append("stream_start")
        buffer.begin()
        let bufferedEarlyAudio = buffer.appendIfWaiting([1, 2])
        events.append("early_audio_buffered")
        #expect(bufferedEarlyAudio)
        #expect(routedSamples.isEmpty)

        // Confirmed DOWN → session start → flush pre-roll → remaining AUDIO routes directly.
        events.append("command_down_confirmed")
        events.append("session_started")
        routedSamples.append(contentsOf: buffer.drain())
        events.append("pre_roll_routed")
        let bufferedRemainingAudio = buffer.appendIfWaiting([3, 4])
        #expect(!bufferedRemainingAudio)
        routedSamples.append(contentsOf: [3, 4])
        events.append("remaining_audio_routed")

        // STREAM_STOP leaves no buffered audio for a later session.
        buffer.cancel()
        events.append("stream_stop")
        #expect(routedSamples == [1, 2, 3, 4])
        #expect(buffer.drain().isEmpty)
        #expect(events == [
            "stream_start",
            "early_audio_buffered",
            "command_down_confirmed",
            "session_started",
            "pre_roll_routed",
            "remaining_audio_routed",
            "stream_stop"
        ])
    }

    @Test func commandActivationPreRollEnforcesCapacityAndCancellation() {
        var buffer = CommandVoiceActivationAudioBuffer(maximumSampleCount: 4)

        buffer.begin()
        let acceptedFirst = buffer.appendIfWaiting([1, 2])
        let acceptedSecond = buffer.appendIfWaiting([3, 4, 5])
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(buffer.drain() == [2, 3, 4, 5])

        buffer.begin()
        let acceptedCancelled = buffer.appendIfWaiting([7, 8])
        #expect(acceptedCancelled)
        buffer.cancel()
        #expect(buffer.drain().isEmpty)
    }
}

@Suite("Bluetooth voice tail diagnostics")
struct BluetoothVoiceTailDiagnosticsTests {
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
