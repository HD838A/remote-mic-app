import CoreAudio
import Foundation
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func recoveryEventsAreCountedUntilTheDebouncedExecutionConsumesThem() {
        var state = AudioRecoveryCoalescingState()

        state.recordEvent()
        state.recordEvent()
        state.recordEvent()

        #expect(state.consumePendingEventCount() == 3)
        #expect(state.consumePendingEventCount() == 0)
        state.recordEvent()
        state.reset()
        #expect(state.consumePendingEventCount() == 0)
    }

    @Test func releaseRequiresResourcesOrPendingBuffersAndNoExistingRelease() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldScheduleRelease(
            hasPendingRelease: false,
            hasAllocatedOutputResources: false,
            pendingVoiceBufferCount: 0
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldScheduleRelease(
            hasPendingRelease: false,
            hasAllocatedOutputResources: true,
            pendingVoiceBufferCount: 0
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldScheduleRelease(
            hasPendingRelease: false,
            hasAllocatedOutputResources: false,
            pendingVoiceBufferCount: 1
        ))
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldScheduleRelease(
            hasPendingRelease: true,
            hasAllocatedOutputResources: true,
            pendingVoiceBufferCount: 1
        ))
    }

    @Test func recoveryLoggingMatchesTheExecutionDebounceBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("AUDIO RECOVERY scheduled"))
        #expect(source.contains("coalesced_events=\\(coalescedEvents)"))
        #expect(source.contains("hasAllocatedOutputResources: audioOutput.hasAllocatedOutputResources"))
    }

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
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false
        ))
    }

    @Test func anotherReadyBluetoothBridgeKeepsAudioActive() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 2,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false
        ))
    }

    @Test func connectedIdleBridgeReleasesAudioWhileSystemIsSuspended() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: true
        ))
    }

    @Test func activeVoiceIsNotInterruptedBySystemSuspension() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: true,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: true
        ))
    }

    @Test func mobileVoiceOrTestToneKeepsAudioActiveWithoutBluetooth() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: true,
            testToneActive: false,
            systemSuspended: true
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: true,
            systemSuspended: true
        ))
    }

    @Test func overlappingWorkspaceEventsDoNotResumeAudioPrematurely() {
        var state = SystemAudioSuspensionState()

        let addedScreenSleep = state.apply(.screenDidSleep)
        let addedSessionInactive = state.apply(.sessionDidResignActive)
        #expect(addedScreenSleep)
        #expect(addedSessionInactive)
        #expect(state.isSuspended)
        #expect(state.diagnostic == "screen_sleeping,session_inactive")

        let removedScreenSleep = state.apply(.screenDidWake)
        #expect(removedScreenSleep)
        #expect(state.isSuspended)
        #expect(state.diagnostic == "session_inactive")

        let removedSessionInactive = state.apply(.sessionDidBecomeActive)
        #expect(removedSessionInactive)
        #expect(!state.isSuspended)
        #expect(state.diagnostic == "none")
    }

    @Test func duplicateWorkspaceEventsAreIdempotent() {
        var state = SystemAudioSuspensionState()

        let firstSleep = state.apply(.systemWillSleep)
        let duplicateSleep = state.apply(.systemWillSleep)
        let firstWake = state.apply(.systemDidWake)
        let duplicateWake = state.apply(.systemDidWake)
        #expect(firstSleep)
        #expect(!duplicateSleep)
        #expect(firstWake)
        #expect(!duplicateWake)
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
