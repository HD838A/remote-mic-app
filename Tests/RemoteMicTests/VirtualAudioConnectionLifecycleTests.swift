import CoreAudio
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func lastReadyBluetoothBridgeDisconnectsAndReleasesAudio() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            mobileVoiceActive: false,
            testToneActive: false
        ))
    }

    @Test func anotherReadyBluetoothBridgeKeepsAudioActive() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            mobileVoiceActive: false,
            testToneActive: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 2,
            mobileVoiceActive: false,
            testToneActive: false
        ))
    }

    @Test func mobileVoiceOrTestToneKeepsAudioActiveWithoutBluetooth() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            mobileVoiceActive: true,
            testToneActive: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            mobileVoiceActive: false,
            testToneActive: true
        ))
    }

    @Test func fallbackPrefersBuiltInInputAndExcludesVirtualDevice() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb", name: "USB Microphone")
        let builtIn = AudioDeviceInfo(id: 3, uid: "built-in", name: "MacBook Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, usb, builtIn],
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id]
        )

        #expect(fallback == builtIn)
    }

    @Test func fallbackUsesAnotherInputWhenBuiltInInputIsUnavailable() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb", name: "USB Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, usb],
            excludingUID: virtual.uid,
            builtInDeviceIDs: []
        )

        #expect(fallback == usb)
    }

    @Test func reconnectRestoresOnlyTheFallbackManagedByTheApp() {
        #expect(DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "built-in"
        ))
        #expect(!DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "usb-user-choice"
        ))
        #expect(!DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "another-virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "built-in"
        ))
    }
}
