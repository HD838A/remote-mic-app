import Testing
@testable import RemoteMic

struct AudioDeviceCatalogTests {
    @Test
    func processPrivateDefaultAggregateIsNotUserSelectable() {
        #expect(!CoreAudioDeviceCatalog.shouldPresentToUser(
            AudioDeviceInfo(
                id: 1,
                uid: "CADefaultDeviceAggregate-79424-2",
                name: "CADefaultDeviceAggregate-79424-2"
            )
        ))
    }

    @Test
    func physicalAndSayAllDevicesRemainUserSelectable() {
        #expect(CoreAudioDeviceCatalog.shouldPresentToUser(
            AudioDeviceInfo(id: 2, uid: "MiRemoteV2ch_UID", name: "SayAll")
        ))
        #expect(CoreAudioDeviceCatalog.shouldPresentToUser(
            AudioDeviceInfo(id: 3, uid: "BuiltInSpeakerDevice", name: "MacBook Pro 扬声器")
        ))
    }

    @Test
    func compatibleVoiceOutputRequiresSayAllOrBlackHole() {
        let sayAll = AudioDeviceInfo(id: 4, uid: "MiRemoteV2ch_UID", name: "SayAll")
        let legacy = AudioDeviceInfo(id: 5, uid: "unknown", name: "MiRemoteV 2ch")
        let blackHole = AudioDeviceInfo(id: 6, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        let physicalSayAll = AudioDeviceInfo(id: 7, uid: "physical", name: "SayAll")
        let speaker = AudioDeviceInfo(id: 8, uid: "BuiltInSpeakerDevice", name: "MacBook Pro 扬声器")

        #expect(VoiceOutputDevicePolicy.hasCompatibleDevice(in: [sayAll]))
        #expect(VoiceOutputDevicePolicy.hasCompatibleDevice(in: [legacy]))
        #expect(VoiceOutputDevicePolicy.hasCompatibleDevice(in: [blackHole]))
        #expect(!VoiceOutputDevicePolicy.hasCompatibleDevice(in: [physicalSayAll]))
        #expect(!VoiceOutputDevicePolicy.hasCompatibleDevice(in: [speaker]))
        #expect(!VoiceOutputDevicePolicy.hasCompatibleDevice(in: []))
    }
}
