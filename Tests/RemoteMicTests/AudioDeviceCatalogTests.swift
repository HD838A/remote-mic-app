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
}
