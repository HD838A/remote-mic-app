import Foundation
import Testing
@testable import RemoteMic

@Suite("Doubao-compatible virtual audio device")
struct DoubaoAudioDeviceTests {
    @Test func recognizesTheDerivedBlackHoleDeviceByUID() {
        let device = AudioDeviceInfo(
            id: 1,
            uid: DoubaoAudioDevicePolicy.deviceUID,
            name: "renamed by user"
        )

        #expect(DoubaoAudioDevicePolicy.device(in: [device])?.id == device.id)
    }

    @Test func recognizesTheDerivedBlackHoleDeviceByName() {
        let device = AudioDeviceInfo(
            id: 2,
            uid: "unknown",
            name: DoubaoAudioDevicePolicy.deviceName
        )

        #expect(DoubaoAudioDevicePolicy.device(in: [device])?.id == device.id)
        #expect(DoubaoAudioDevicePolicy.status(in: [device]).key == "audio.compatibility.device_detected")
    }

    @Test func reportsWhenTheCompatibilityDriverIsMissing() {
        let physicalDevice = AudioDeviceInfo(id: 3, uid: "BuiltIn", name: "MacBook 麦克风")

        #expect(DoubaoAudioDevicePolicy.device(in: [physicalDevice]) == nil)
        #expect(DoubaoAudioDevicePolicy.status(in: [physicalDevice]).key == "audio.compatibility.device_not_detected")
    }

    @Test func qianwenModeLocksVoiceOutputToMiRemote() {
        let speaker = AudioDeviceInfo(id: 3, uid: "BuiltInSpeakerDevice", name: "MacBook Air Speakers")
        let miRemote = AudioDeviceInfo(
            id: 4,
            uid: DoubaoAudioDevicePolicy.deviceUID,
            name: DoubaoAudioDevicePolicy.deviceName
        )

        #expect(DoubaoAudioDevicePolicy.resolvedDeviceUID(
            requestedUID: speaker.uid,
            qianwenModeEnabled: true,
            devices: [speaker, miRemote]
        ) == miRemote.uid)
        #expect(DoubaoAudioDevicePolicy.resolvedDeviceUID(
            requestedUID: speaker.uid,
            qianwenModeEnabled: false,
            devices: [speaker, miRemote]
        ) == speaker.uid)
    }

    @Test func qianwenModeFailsClosedWhileMiRemoteIsMissing() {
        let speaker = AudioDeviceInfo(
            id: 3,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Air Speakers"
        )
        let resolvedDeviceUID = DoubaoAudioDevicePolicy.resolvedDeviceUID(
            requestedUID: speaker.uid,
            qianwenModeEnabled: true,
            devices: [speaker]
        )

        #expect(resolvedDeviceUID.isEmpty)
        #expect(DoubaoAudioDevicePolicy.persistedDeviceUID(
            resolvedDeviceUID: resolvedDeviceUID,
            qianwenModeEnabled: true
        ) == DoubaoAudioDevicePolicy.deviceUID)
        #expect(DoubaoAudioDevicePolicy.resolvedDeviceUID(
            requestedUID: speaker.uid,
            qianwenModeEnabled: false,
            devices: [speaker]
        ) == speaker.uid)
    }

    @Test func everyRuntimeRebindReappliesTheQianwenAudioPolicy() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private func configureVirtualAudioOutput"))
        let end = try #require(source.range(
            of: "private func ensureVirtualAudioOutputReady",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        let policy = try #require(body.range(
            of: "DoubaoAudioDevicePolicy.resolvedDeviceUID"
        ))
        let configure = try #require(body.range(
            of: "audioOutput.configure(deviceUID: selectedDeviceUID)"
        ))
        #expect(policy.lowerBound < configure.lowerBound)

        let importStart = try #require(source.range(
            of: "func importConfiguration(from data: Data) throws"
        ))
        let importEnd = try #require(source.range(
            of: "func setVoiceKeyMode",
            range: importStart.upperBound..<source.endIndex
        ))
        let importBody = String(source[importStart.lowerBound..<importEnd.lowerBound])
        #expect(importBody.contains("if settings.qianwenVoiceModeEnabled"))
        #expect(importBody.contains("selectAudioDevice("))
    }
}
