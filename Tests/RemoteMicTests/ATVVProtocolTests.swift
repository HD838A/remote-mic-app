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

    @Test func asyncAudioConfigurationPreservesBluetoothStartStopAndFirstAudioOrder() throws {
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
        let decode = try #require(source.range(
            of: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16])",
            range: stop.upperBound..<source.endIndex
        ))
        let startSource = source[start.lowerBound..<stop.lowerBound]
        let stopSource = source[stop.lowerBound..<decode.lowerBound]
        let decodeSource = source[decode.lowerBound...]

        #expect(startSource.contains("pendingBluetoothVoiceStartIdentifier"))
        #expect(startSource.contains("pendingBluetoothVoiceAudio.drain()"))
        #expect(startSource.contains("flush_after_configuration"))
        #expect(startSource.contains("voiceFnTapSession.startVoice()"))
        #expect(startSource.contains("SYSTEM AUDIO voice_start_recovery configured=pending"))
        let voiceStart = try #require(startSource.range(of: "voiceFnTapSession.startVoice()"))
        let asyncConfiguration = try #require(startSource.range(
            of: "ensureVirtualAudioOutputReady(reason: \"bluetooth_voice_start\")",
            range: voiceStart.upperBound..<startSource.endIndex
        ))
        #expect(voiceStart.lowerBound < asyncConfiguration.lowerBound)
        #expect(stopSource.contains("stop_before_audio_ready"))
        #expect(stopSource.contains("stop_deferred_until_audio_ready"))
        #expect(decodeSource.contains("buffered_during_configuration"))
    }

    @Test func asyncAudioConfigurationCancelsPendingVoiceStartsOnRelease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("cancelled_before_audio_ready"))
        #expect(source.contains("pendingAppleRemoteVoiceStarts.remove(device)"))
        #expect(source.contains("pendingChromecastVoiceStart = false"))
        #expect(source.contains("start_pending_audio_configuration"))
    }

    @Test func everyVoiceInputPathStartsBeforeAudioConfigurationAndPreservesPendingTail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        let appleStart = try #require(source.range(of: "private func beginAppleRemoteVoice"))
        let appleStop = try #require(source.range(
            of: "private func endAppleRemoteVoice",
            range: appleStart.upperBound..<source.endIndex
        ))
        let apple = source[appleStart.lowerBound..<appleStop.lowerBound]
        let appleCapture = try #require(apple.range(of: "siriRemoteFeature.beginCapture()"))
        let appleConfigure = try #require(apple.range(of: "ensureVirtualAudioOutputReady(reason: \"apple_remote_voice_start\")"))
        #expect(appleCapture.lowerBound < appleConfigure.lowerBound)
        #expect(source.contains("pendingAppleRemoteVoiceAudio.appendIfWaiting(samples)"))
        #expect(apple.contains("flush_after_configuration"))
        #expect(source.contains("APPLE REMOTE VOICE phase=deferred result=pending_tail"))

        let chromecastStart = try #require(source.range(of: "private func beginChromecastVoice"))
        let chromecastStop = try #require(source.range(
            of: "private func endChromecastVoice",
            range: chromecastStart.upperBound..<source.endIndex
        ))
        let chromecast = source[chromecastStart.lowerBound..<chromecastStop.lowerBound]
        let chromecastKey = try #require(chromecast.range(of: "beginChromecastFunctionKeyDrive()"))
        let chromecastConfigure = try #require(chromecast.range(
            of: "ensureVirtualAudioOutputReady(reason: \"chromecast_voice_start\")",
            range: chromecastKey.upperBound..<chromecast.endIndex
        ))
        #expect(chromecastKey.lowerBound < chromecastConfigure.lowerBound)
        #expect(source.contains("pendingChromecastVoiceAudio.appendIfWaiting(samples)"))
        #expect(chromecast.contains("flush_after_configuration"))
        #expect(source.contains("CHROMECAST VOICE phase=deferred result=pending_tail"))
        #expect(source.contains(
            "chromecastVoiceActive || chromecastVoiceStopping || pendingChromecastVoiceStart"
        ))

        let mobileStart = try #require(source.range(of: "private func startPhoneVoiceAfterAudioReady"))
        let mobileStop = try #require(source.range(
            of: "private func stopPhoneVoice",
            range: mobileStart.upperBound..<source.endIndex
        ))
        let mobile = source[mobileStart.lowerBound..<mobileStop.lowerBound]
        let mobileSession = try #require(mobile.range(of: "startPhoneVoice(source: source)"))
        let mobileConfigure = try #require(mobile.range(of: "ensureVirtualAudioOutputReady(reason: \"mobile_voice_start\")"))
        #expect(mobileSession.lowerBound < mobileConfigure.lowerBound)
        #expect(source.contains("pendingMobileVoiceAudio.appendIfWaiting(samples)"))
        #expect(mobile.contains("flush_after_configuration"))
        #expect(source.contains("stop_deferred_until_audio_ready"))
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
