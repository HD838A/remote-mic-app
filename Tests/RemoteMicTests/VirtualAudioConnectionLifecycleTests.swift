import CoreAudio
import Foundation
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func stoppedPlayerIsNotHealthyWhenEngineAndDeviceStillLookReady() {
        #expect(!VirtualAudioHealthPolicy.isPlaybackReady(
            hasSelectedDevice: true,
            engineRunning: true,
            playerPlaying: false
        ))
        #expect(!VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: true,
            engineRunning: true,
            playerPlaying: false,
            boundToSelectedDevice: true
        ))
    }

    @Test func healthyPlaybackRequiresRunningPlayerAndSelectedBinding() {
        #expect(VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: true,
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true
        ))
        #expect(!VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: true,
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: false
        ))
    }

    @Test func everyVoiceEntryChecksLiveAudioHealthInsteadOfCachedReadyState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        for reason in [
            "bluetooth_ready",
            "bluetooth_voice_start",
            "mobile_voice_start",
            "test_tone",
            "long_recording_start",
        ] {
            #expect(source.contains("ensureVirtualAudioOutputReady(reason: \"\(reason)\")"))
        }
        #expect(!source.contains("isAudioOutputReady || configureVirtualAudioOutput"))
    }

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
