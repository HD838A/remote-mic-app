import CoreAudio
import Foundation
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func healthyExplicitOutputIgnoresDefaultSystemOutputOnlyChanges() {
        #expect(VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
            details: "properties=default_system_output",
            configurationHealthy: true
        ))
        #expect(!VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
            details: "properties=default_system_output",
            configurationHealthy: false
        ))
        #expect(!VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
            details: "properties=devices",
            configurationHealthy: true
        ))
    }

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

    @Test func voiceDeliveryRequiresTheSelectedRouteAndPlayedSampleCounts() {
        let startCounters = VirtualAudioPlaybackCounters(
            scheduledBuffers: 10,
            scheduledSamples: 1_600,
            playedBuffers: 10,
            playedSamples: 1_600
        )
        let start = VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .miRemoteV2ch,
            actualDeviceKind: .miRemoteV2ch,
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            counters: startCounters
        )
        var observation = start
        observation.counters.scheduledBuffers += 2
        observation.counters.scheduledSamples += 320
        observation.counters.playedBuffers += 2
        observation.counters.playedSamples += 320
        var diagnostic = VoiceAudioDeliveryDiagnostic(
            generation: 4,
            source: UsageEventSource.bluetoothRemote.rawValue,
            route: .virtualAudioDirect,
            sessionEnded: true,
            receivedBatches: 2,
            receivedSamples: 320,
            outputAtStart: start,
            outputAtObservation: observation,
            countersAtStart: startCounters
        )

        #expect(diagnostic.result == .deliveredToSelectedDevice)

        diagnostic.enqueueFailures = 1
        #expect(diagnostic.result == .enqueueFailed)
        diagnostic.enqueueFailures = 0
        diagnostic.outputAtObservation.counters.interruptedSamples = 80
        #expect(diagnostic.result == .playbackInterrupted)
        diagnostic.outputAtObservation.counters.interruptedSamples = 0
        diagnostic.outputAtObservation.pendingSamples = 80
        #expect(diagnostic.result == .playbackPending)

        diagnostic.outputAtObservation.pendingSamples = 0
        diagnostic.outputAtStart.boundToSelectedDevice = false
        #expect(diagnostic.result == .routeMismatch)
    }

    @Test func virtualAudioDeviceDiagnosticsUseOnlyApprovedStableKinds() {
        #expect(VirtualAudioDeviceDiagnosticKind.classify(AudioDeviceInfo(
            id: 1,
            uid: "MiRemoteV2ch_UID",
            name: "Renamed by user"
        )) == .miRemoteV2ch)
        #expect(VirtualAudioDeviceDiagnosticKind.classify(AudioDeviceInfo(
            id: 2,
            uid: "private-device-uid",
            name: "Private custom name"
        )) == .other)
        #expect(VirtualAudioDeviceDiagnosticKind.classify(nil) == .unavailable)
    }

    @Test func fnTapAndDirectVoicePathsRecordTheActualVirtualAudioEnqueue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("enqueueAudio: { [weak self] samples in\n            self?.enqueueVoiceFnTapAudio(samples)"))
        #expect(source.contains("deliveryGeneration: deliveryGeneration"))
        #expect(source.contains("route: handledByFnTapMode ? .virtualAudioViaFnTap : .virtualAudioDirect"))
        #expect(source.contains("route: .virtualAudioDirect"))
        #expect(!source.contains("accepted: handledByFnTapMode ||"))
    }

    @Test func consecutiveVoiceGenerationsUseIndependentPlaybackCounters() {
        let healthy = VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .miRemoteV2ch,
            actualDeviceKind: .miRemoteV2ch,
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true
        )
        var firstObservation = healthy
        firstObservation.counters = VirtualAudioPlaybackCounters(
            scheduledBuffers: 1,
            scheduledSamples: 160,
            playedBuffers: 1,
            playedSamples: 160
        )
        let first = VoiceAudioDeliveryDiagnostic(
            generation: 1,
            source: UsageEventSource.bluetoothRemote.rawValue,
            route: .virtualAudioViaFnTap,
            sessionEnded: true,
            receivedBatches: 1,
            receivedSamples: 160,
            outputAtStart: healthy,
            outputAtObservation: firstObservation
        )

        var secondObservation = healthy
        secondObservation.pendingBuffers = 1
        secondObservation.pendingSamples = 320
        secondObservation.counters = VirtualAudioPlaybackCounters(
            scheduledBuffers: 1,
            scheduledSamples: 320
        )
        let second = VoiceAudioDeliveryDiagnostic(
            generation: 2,
            source: UsageEventSource.bluetoothRemote.rawValue,
            route: .virtualAudioViaFnTap,
            sessionEnded: true,
            receivedBatches: 1,
            receivedSamples: 320,
            outputAtStart: healthy,
            outputAtObservation: secondObservation
        )

        #expect(first.result == .deliveredToSelectedDevice)
        #expect(second.result == .playbackPending)
        #expect(second.playedSamples == 0)
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
            systemSuspended: false,
            keepAliveWhileConnected: true
        ))
    }

    @Test func anotherReadyBluetoothBridgeKeepsAudioActive() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false,
            keepAliveWhileConnected: true
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 2,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false,
            keepAliveWhileConnected: true
        ))
    }

    @Test func connectedIdleBridgeReleasesAudioWhileSystemIsSuspended() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: true,
            keepAliveWhileConnected: true
        ))
    }

    @Test func activeVoiceIsNotInterruptedBySystemSuspension() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: true,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: true,
            keepAliveWhileConnected: true
        ))
    }

    @Test func mobileVoiceOrTestToneKeepsAudioActiveWithoutBluetooth() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: true,
            testToneActive: false,
            systemSuspended: true,
            keepAliveWhileConnected: true
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: true,
            systemSuspended: true,
            keepAliveWhileConnected: true
        ))
    }

    @Test func onDemandModeKeepsIdleConnectedBridgeInactive() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false,
            keepAliveWhileConnected: false
        ))
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 2,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false,
            keepAliveWhileConnected: false
        ))
    }

    @Test func onDemandModeActivatesOnlyWhileAVoiceSourceOrTestToneRuns() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: true,
            mobileVoiceActive: false,
            testToneActive: false,
            systemSuspended: false,
            keepAliveWhileConnected: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: true,
            testToneActive: false,
            systemSuspended: false,
            keepAliveWhileConnected: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            bluetoothVoiceActive: false,
            mobileVoiceActive: false,
            testToneActive: true,
            systemSuspended: false,
            keepAliveWhileConnected: false
        ))
    }

    @Test func onDemandVoiceStopSchedulesDelayedReleaseAndEveryEntryCancelsIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains(
            "scheduleOnDemandVirtualAudioRelease(reason: \"bluetooth_voice_stopped\")"
        ))
        #expect(source.contains(
            "cancelScheduledOnDemandVirtualAudioRelease(trigger: \"ensure_\\(reason)\")"
        ))
        #expect(source.contains(
            "cancelScheduledOnDemandVirtualAudioRelease(trigger: \"rebind_\\(reason)\")"
        ))
        #expect(BridgeAppModel.onDemandVirtualAudioReleaseDelay >= 1.0)
        #expect(BridgeAppModel.onDemandVirtualAudioReleaseDelay <= 5.0)
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
