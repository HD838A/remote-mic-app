import Foundation
import Testing
@testable import RemoteMic

@Suite("Mobile Web remote protocol")
struct WebRemoteProtocolTests {
    @Test func productionRelayRequiresSecureWebSocketAndFixedPath() throws {
        #expect(WebRemoteConfiguration.validatedRelayURL("wss://example.com/ws") != nil)
        #expect(WebRemoteConfiguration.validatedRelayURL("https://example.com/ws") == nil)
        #expect(WebRemoteConfiguration.validatedRelayURL("ws://example.com/ws") == nil)
        #expect(WebRemoteConfiguration.validatedRelayURL("wss://example.com/other") == nil)
        #expect(WebRemoteConfiguration.validatedRelayURL("wss://example.com/ws?token=value") == nil)
        #expect(WebRemoteConfiguration.validatedRelayURL("ws://127.0.0.1/ws") != nil)
    }

    @Test func environmentConfigurationTakesPriorityOverBundleConfiguration() throws {
        let url = try #require(WebRemoteConfiguration.relayURL(
            environment: [WebRemoteConfiguration.environmentKey: "wss://environment.example/ws"],
            infoDictionary: [WebRemoteConfiguration.infoDictionaryKey: "wss://bundle.example/ws"]
        ))
        #expect(url.host == "environment.example")
    }

    @Test func missingProductionConfigurationDoesNotCreateARelayURL() {
        #expect(WebRemoteConfiguration.relayURL(
            environment: [:],
            infoDictionary: [:]
        ) == nil)
    }

    @Test func audioFrameDecodesSequenceAndLittleEndianSamples() throws {
        let data = Data([
            WebRemoteAudioFrame.type,
            0x01, 0x02, 0x03, 0x04,
            0x01, 0x00,
            0xFE, 0xFF,
        ])
        let frame = try #require(WebRemoteAudioFrame.decode(data))
        #expect(frame.sequence == 0x0102_0304)
        #expect(frame.samples == [1, -2])
    }

    @Test func audioFrameRejectsMalformedPayloads() {
        #expect(WebRemoteAudioFrame.decode(Data()) == nil)
        #expect(WebRemoteAudioFrame.decode(Data([2, 0, 0, 0, 1, 0, 0])) == nil)
        #expect(WebRemoteAudioFrame.decode(Data([1, 0, 0, 0, 1, 0])) == nil)
    }

    @Test func jitterBufferWaitsForInitialFramesAndPlaysInSequence() throws {
        var buffer = WebRemoteAudioJitterBuffer(startFrameCount: 2, maximumFrameCount: 4)
        buffer.append(sequence: 10, samples: [10])
        #expect(buffer.nextFrame(finishing: false) == nil)
        buffer.append(sequence: 11, samples: [11])
        #expect(buffer.nextFrame(finishing: false) == [10])
        #expect(buffer.nextFrame(finishing: false) == [11])
    }

    @Test func jitterBufferDrainsShortVoiceWhenFinishing() {
        var buffer = WebRemoteAudioJitterBuffer(startFrameCount: 8, maximumFrameCount: 40)
        buffer.append(sequence: 1, samples: [1, 2])
        #expect(buffer.nextFrame(finishing: true) == [1, 2])
        #expect(buffer.hasPendingFrames == false)
    }
}
