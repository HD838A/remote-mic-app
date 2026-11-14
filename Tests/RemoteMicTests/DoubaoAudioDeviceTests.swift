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
            name: DoubaoAudioDevicePolicy.legacyDeviceName
        )

        #expect(DoubaoAudioDevicePolicy.device(in: [device])?.id == device.id)
    }

    @Test func brandNameRequiresStableUID() {
        let unrelated = AudioDeviceInfo(id: 4, uid: "physical", name: "SayAll")
        let brand = AudioDeviceInfo(id: 5, uid: DoubaoAudioDevicePolicy.deviceUID, name: "SayAll")
        let legacy = AudioDeviceInfo(id: 6, uid: "unknown", name: "MiRemoteV 2ch")
        #expect(DoubaoAudioDevicePolicy.device(in: [unrelated]) == nil)
        #expect(DoubaoAudioDevicePolicy.device(in: [legacy, unrelated, brand]) == brand)
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(uid: brand.uid, name: brand.name))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: unrelated.uid, name: unrelated.name))
        #expect(VirtualAudioDeviceDiagnosticKind.classify(brand) == .miRemoteV2ch)
        let recovered = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: brand.uid, rememberedUID: "", availableDevices: [brand],
            hasHistoricalConfiguration: true
        )
        #expect(recovered.uid == brand.uid)
        #expect(recovered.source == .currentSelection)
    }

    @Test func reportsWhenTheCompatibilityDriverIsMissing() {
        let physicalDevice = AudioDeviceInfo(id: 3, uid: "BuiltIn", name: "MacBook 麦克风")

        #expect(DoubaoAudioDevicePolicy.device(in: [physicalDevice]) == nil)
    }
}
