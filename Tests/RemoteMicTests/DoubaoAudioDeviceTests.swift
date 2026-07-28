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
        #expect(DoubaoAudioDevicePolicy.status(in: [device]).key == "已检测到 %@（豆包兼容）")
    }

    @Test func reportsWhenTheCompatibilityDriverIsMissing() {
        let physicalDevice = AudioDeviceInfo(id: 3, uid: "BuiltIn", name: "MacBook 麦克风")

        #expect(DoubaoAudioDevicePolicy.device(in: [physicalDevice]) == nil)
        #expect(DoubaoAudioDevicePolicy.status(in: [physicalDevice]).key == "未检测到 %@")
    }
}
