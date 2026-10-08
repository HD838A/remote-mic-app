import CoreAudio
import Foundation
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func virtualAudioLevelPolicyRepairsMuteAndVolumesBelowMinimum() {
        #expect(VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: true))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: false))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: nil))

        #expect(VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 0))
        #expect(VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 0.19))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 0.2))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 0.21))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 1))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: nil))
        #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: .nan))
    }

    @Test func virtualAudioAudibilityTreatsUnknownPropertiesAsNonBlocking() {
        let unknown = VirtualAudioDeviceAudibilitySnapshot()
        #expect(!unknown.requiresAudibilityRepair)

        let muted = VirtualAudioDeviceAudibilitySnapshot(
            output: VirtualAudioDeviceLevelObservation(mute: true, volume: nil)
        )
        #expect(muted.requiresAudibilityRepair)

        let zeroInput = VirtualAudioDeviceAudibilitySnapshot(
            input: VirtualAudioDeviceLevelObservation(mute: nil, volume: 0)
        )
        #expect(zeroInput.requiresAudibilityRepair)

        let lowOutput = VirtualAudioDeviceAudibilitySnapshot(
            output: VirtualAudioDeviceLevelObservation(mute: false, volume: 0.19)
        )
        #expect(lowOutput.requiresAudibilityRepair)
        #expect(lowOutput.diagnostic.contains("output_volume_scalar=0.19"))
        #expect(lowOutput.diagnostic.contains("output_volume_low=true"))
        #expect(lowOutput.diagnostic.contains("minimum_volume_scalar=0.2"))
    }

    @Test func virtualAudioRepairRequiresAReadableUsableResult() {
        let silent = VirtualAudioDeviceAudibilitySnapshot(
            output: VirtualAudioDeviceLevelObservation(mute: true, volume: 0)
        )
        let audible = VirtualAudioDeviceAudibilitySnapshot(
            output: VirtualAudioDeviceLevelObservation(mute: false, volume: 1),
            input: VirtualAudioDeviceLevelObservation(mute: false, volume: 1)
        )

        #expect(VirtualAudioDeviceAudibilityRepairResult(
            applicable: true,
            before: silent,
            after: audible,
            unmuteAttempted: true,
            volumeRestoreAttempted: true
        ).isReady)
        #expect(!VirtualAudioDeviceAudibilityRepairResult(
            applicable: true,
            before: silent,
            after: silent,
            unmuteAttempted: true,
            volumeRestoreAttempted: true,
            writeFailed: true
        ).isReady)
        #expect(!VirtualAudioDeviceAudibilityRepairResult(
            applicable: true,
            before: silent,
            after: .init(),
            unmuteAttempted: true,
            volumeRestoreAttempted: true,
            writeFailed: true
        ).isReady)
        #expect(VirtualAudioDeviceAudibilityRepairResult().isReady)
    }

    @Test func installedMiRemoteVCanRecoverFromMuteAndLowVolume() throws {
        guard ProcessInfo.processInfo.environment["SAYALL_TEST_MUTATE_VIRTUAL_AUDIO_LEVEL"] == "1"
        else { return }
        let device = try #require(
            CoreAudioDeviceCatalog.outputDevices().first { $0.uid == "MiRemoteV2ch_UID" }
        )
        let original = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: device)
        defer {
            Self.restoreDeviceLevel(original.output, deviceID: device.id, scope: kAudioDevicePropertyScopeOutput)
            Self.restoreDeviceLevel(original.input, deviceID: device.id, scope: kAudioDevicePropertyScopeInput)
        }

        #expect(Self.setDeviceUInt32(
            1,
            deviceID: device.id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput
        ))
        #expect(Self.setDeviceFloat32(
            0,
            deviceID: device.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput
        ))
        #expect(Self.setDeviceUInt32(
            1,
            deviceID: device.id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput
        ))
        #expect(Self.setDeviceFloat32(
            0,
            deviceID: device.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeInput
        ))
        #expect(CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: device).requiresAudibilityRepair)

        let repair = CoreAudioDeviceCatalog.ensureVirtualAudioDeviceAudible(device)

        #expect(repair.applicable)
        #expect(repair.unmuteAttempted)
        #expect(repair.volumeRestoreAttempted)
        #expect(!repair.writeFailed)
        #expect(repair.isReady)
        #expect(repair.after.output.mute == false)
        #expect(repair.after.output.volume == 1)
        #expect(repair.after.input.mute == false)
        #expect(repair.after.input.volume == 1)

        #expect(Self.setDeviceFloat32(
            0.19,
            deviceID: device.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput
        ))
        #expect(Self.setDeviceFloat32(
            0.19,
            deviceID: device.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeInput
        ))

        let lowVolumeRepair = CoreAudioDeviceCatalog.ensureVirtualAudioDeviceAudible(device)

        #expect(lowVolumeRepair.applicable)
        #expect(!lowVolumeRepair.unmuteAttempted)
        #expect(lowVolumeRepair.volumeRestoreAttempted)
        #expect(lowVolumeRepair.isReady)
        #expect(lowVolumeRepair.after.output.volume == 1)
        #expect(lowVolumeRepair.after.input.volume == 1)
    }

    private static func restoreDeviceLevel(
        _ observation: VirtualAudioDeviceLevelObservation,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) {
        if let mute = observation.mute {
            _ = setDeviceUInt32(
                mute ? 1 : 0,
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: scope
            )
        }
        if let volume = observation.volume {
            _ = setDeviceFloat32(
                volume,
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope
            )
        }
    }

    private static func setDeviceUInt32(
        _ value: UInt32,
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        ) == noErr
    }

    private static func setDeviceFloat32(
        _ value: Float32,
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableValue
        ) == noErr
    }

    @Test func reconfiguringTheOutputMidDrainStillReportsTheDrainExactlyOnce() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var completionCount = 0
        // A long fallback keeps the audio side's own timer out of this test: the only way
        // the completion can arrive is through the interrupting path below.
        output.endSessionAfterDraining(maximumDelay: 60) { completionCount += 1 }
        #expect(completionCount == 0)

        output.endSession()

        #expect(completionCount == 1)
        #expect(output.pendingVoiceBufferCountForDiagnostics == 0)
        output.stop()
        #expect(completionCount == 1)
    }

    @Test func tearingTheEngineDownMidDrainStillReportsTheDrainExactlyOnce() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var completionCount = 0
        output.endSessionAfterDraining(maximumDelay: 60) { completionCount += 1 }

        output.stop()

        #expect(completionCount == 1)
        output.endSession()
        #expect(completionCount == 1)
    }

    @Test func aDrainCompletionThatTearsTheOutputDownAgainReportsOnlyOnce() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var completionCount = 0
        // Mirrors the release path, whose completion calls `stop()` on the same output.
        output.endSessionAfterDraining(maximumDelay: 60) { [weak output] in
            completionCount += 1
            output?.stop()
        }

        output.endSession()

        #expect(completionCount == 1)
    }

    @Test func multipleDrainRequestsWaitForTheSameActualDrain() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var firstCount = 0
        var secondCount = 0
        output.endSessionAfterDraining(maximumDelay: 60) { firstCount += 1 }

        output.endSessionAfterDraining(maximumDelay: 60) { secondCount += 1 }

        #expect(firstCount == 0)
        #expect(secondCount == 0)
        output.endSession()
        #expect(firstCount == 1)
        #expect(secondCount == 1)
    }

    @Test func interruptedDrainReportsForcedOutcome() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var outcome: VirtualAudioDrainOutcome?

        output.endSessionAfterDraining(maximumDelay: 60) { value in
            outcome = value
        }
        output.stop()

        #expect(outcome == .forced)
    }

    @Test func anAlreadyEmptyDrainReportsNormalOutcome() {
        let output = VirtualAudioOutput()
        var outcome: VirtualAudioDrainOutcome?

        output.endSessionAfterDraining(maximumDelay: 60) { value in
            outcome = value
        }

        #expect(outcome == .normal)
    }

    @Test func drainLogsCorrelateRequestWithOneForcedTerminalOutcome() {
        var logs: [String] = []
        var uptime: TimeInterval = 10
        let output = VirtualAudioOutput(
            logger: { logs.append($0) },
            uptime: { uptime }
        )
        output.registerPendingVoiceBuffer()

        output.endSessionAfterDraining(
            source: "voice_fn_tap",
            operationID: 42,
            maximumDelay: 60
        ) { _ in }
        uptime = 10.25
        output.stop()

        #expect(logs.contains { $0.contains(
            "AUDIO DRAIN operation_id=42 source=voice_fn_tap phase=requested result=pending"
        ) })
        let terminalLogs = logs.filter {
            $0.contains("AUDIO DRAIN operation_id=42 source=voice_fn_tap phase=completed")
        }
        #expect(terminalLogs.count == 1)
        #expect(terminalLogs.first?.contains("result=forced reason=output_stop") == true)
        #expect(terminalLogs.first?.contains("elapsed_ms=250") == true)
        #expect(terminalLogs.first?.contains("interrupted_buffers=1") == true)
    }

    @Test func cancellingDrainLogsOneExplicitCancelledTerminalOutcome() {
        var logs: [String] = []
        let output = VirtualAudioOutput(logger: { logs.append($0) })
        output.registerPendingVoiceBuffer()

        output.endSessionAfterDraining(
            source: "audio_release",
            operationID: 7,
            maximumDelay: 60
        ) { _ in }
        output.cancelPendingDrain()
        output.stop()

        let terminalLogs = logs.filter {
            $0.contains("AUDIO DRAIN operation_id=7 source=audio_release") &&
                ($0.contains("phase=completed") || $0.contains("phase=cancelled"))
        }
        #expect(terminalLogs.count == 1)
        #expect(terminalLogs.first?.contains(
            "phase=cancelled result=cancelled reason=explicit_cancel"
        ) == true)
    }

    @Test func normalDrainPathsDoNotFlushThePlayer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/AudioOutput.swift"),
            encoding: .utf8
        )

        let immediateStart = try #require(source.range(of: "if shouldCompleteImmediately && !wasWaiting {"))
        let timeoutStart = try #require(source.range(of: "if let maximumDelay, let generation {", range: immediateStart.upperBound..<source.endIndex))
        let immediatePath = source[immediateStart.lowerBound..<timeoutStart.lowerBound]
        #expect(!immediatePath.contains("flushPlayer()"))

        let naturalStart = try #require(source.range(of: "private func finishDrainedSessionIfNeeded("))
        let forcedStart = try #require(source.range(of: "private func finishDrainIfNeeded(", range: naturalStart.upperBound..<source.endIndex))
        let naturalPath = source[naturalStart.lowerBound..<forcedStart.lowerBound]
        #expect(!naturalPath.contains("flushPlayer()"))
    }

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

        state.recordEvent(reason: "engine_configuration_change")
        state.recordEvent(reason: "engine_configuration_change")
        state.recordEvent(reason: "engine_configuration_change")

        let first = state.consumePendingEvents()
        #expect(first.count == 3)
        #expect(!first.includesHardwareChange)
        #expect(state.consumePendingEvents().count == 0)
        state.recordEvent(reason: "hardware_change")
        state.recordEvent(reason: "engine_configuration_change")
        let mixed = state.consumePendingEvents()
        #expect(mixed.count == 2)
        #expect(mixed.includesHardwareChange)
        state.reset()
        #expect(state.consumePendingEvents().count == 0)
        #expect(!state.consumePendingEvents().includesHardwareChange)
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
        #expect(source.contains(
            "AUDIO RECOVERY operation_id=\\(generation) phase=started result=pending"
        ))
        #expect(source.contains(
            "AUDIO RECOVERY operation_id=\\(generation) phase=completed result=ignored"
        ))
        #expect(source.contains("result=\\(ready ? \"ready\" : \"degraded\")"))
        #expect(source.contains("coalesced_events=\\(coalesced.count)"))
        #expect(source.contains("includes_hardware_change=\\(coalesced.includesHardwareChange)"))
        #expect(source.contains("engine_running=\\(completedSnapshot.engineRunning)"))
        #expect(source.contains("bound_to_selected=\\(self.optionalDiagnosticBool"))
        #expect(source.contains("elapsed_ms=\\(self.elapsedMilliseconds"))
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

    @Test func audioEngineConfigurationRunsOffTheMainThread() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let outputSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/AudioOutput.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(outputSource.contains("label: \"RemoteMic.audioOutput.engine\""))
        #expect(!outputSource.contains("func configure(deviceUID: String)"))
        #expect(outputSource.contains("func configureAsync(deviceUID: String"))
        #expect(outputSource.contains("engineQueue.async { [weak self] in"))
        #expect(outputSource.contains("configureOnEngineQueue(deviceUID: deviceUID, operationID: operationID)"))
        #expect(outputSource.contains("dispatchPrecondition(condition: .onQueue(engineQueue))"))
        #expect(outputSource.contains("engine.connect(player, to: engine.mainMixerNode"))
        #expect(modelSource.contains("audioOutput.configureAsync(deviceUID: deviceUID)"))
        #expect(modelSource.contains("self.audioOutput.configureAsync(deviceUID: selection.uid ?? \"\")"))
        #expect(!modelSource.contains("audioOutput.configure(deviceUID:"))
    }

    @Test @MainActor func blockedAudioQueueDoesNotBlockMainThreadConfigurationStopOrDiagnostics() async {
        let queue = DispatchQueue(label: "test.blocked_audio_engine")
        let gate = DispatchSemaphore(value: 0)
        let logs = ConfigurationLogRecorder()
        let output = VirtualAudioOutput(logger: logs.append, engineQueue: queue)
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
                _ = gate.wait(timeout: .now() + 30)
            }
        }
        defer { gate.signal() }
        let response = AsyncStream<(Bool, Bool)>.makeStream()
        let startedAt = ProcessInfo.processInfo.systemUptime
        output.configureAsync(deviceUID: "") { configured in
            response.continuation.yield((configured, Thread.isMainThread))
            response.continuation.finish()
        }
        output.stop()
        output.endSession()
        #expect(!output.isReadyForTestTone)
        #expect(!output.isConfigurationHealthyForDiagnostics)
        #expect(output.diagnosticSnapshot().pendingSamples == 0)
        #expect(output.diagnosticState().contains("bound_to_selected=unknown"))
        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 0.5)
        // A main-queue event must run while the audio queue is still blocked.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(logs.values.filter { $0.contains("phase=started") }.isEmpty)
        #expect(logs.values.filter { $0.contains("phase=completed") }.isEmpty)
        gate.signal()
        var responses: [(Bool, Bool)] = []
        for await value in response.stream { responses.append(value) }
        #expect(responses.count == 1)
        #expect(responses.first?.0 == false)
        #expect(responses.first?.1 == false)
    }

    @Test @MainActor func consecutiveConfigurationsHaveOrderedUniqueCompletionLogs() async {
        let logs = ConfigurationLogRecorder()
        let output = VirtualAudioOutput(logger: logs.append)
        let first = AsyncStream<Bool>.makeStream()
        let second = AsyncStream<Bool>.makeStream()
        output.configureAsync(deviceUID: "") {
            first.continuation.yield($0)
            first.continuation.finish()
        }
        output.configureAsync(deviceUID: "") {
            second.continuation.yield($0)
            second.continuation.finish()
        }
        var firstResponses: [Bool] = []
        var secondResponses: [Bool] = []
        for await value in first.stream { firstResponses.append(value) }
        for await value in second.stream { secondResponses.append(value) }
        #expect(firstResponses == [false])
        #expect(secondResponses == [false])
        let phases = logs.values.filter {
            $0.contains("operation_id=") && ($0.contains("phase=started") || $0.contains("phase=completed"))
        }
        #expect(phases.count == 4)
        #expect(phases[0].contains("operation_id=1 phase=started result=pending"))
        #expect(phases[1].contains("operation_id=1 phase=completed result=failed"))
        #expect(phases[2].contains("operation_id=2 phase=started result=pending"))
        #expect(phases[3].contains("operation_id=2 phase=completed result=failed"))
        #expect(phases.allSatisfy { $0.contains("queue=audio_output") })
        #expect(phases.filter { $0.contains("phase=completed") }.allSatisfy {
            $0.contains("reason=configure_failed") &&
                $0.contains("status_key=audio.output.none_selected") &&
                $0.contains("elapsed_ms=")
        })
        #expect(phases.filter { $0.contains("phase=started") }.allSatisfy { $0.contains("queue_wait_ms=") })
        #expect(!logs.values.contains { $0.contains("AUDIO READY") })
    }

    @Test @MainActor func installedVirtualOutputPreservesFirstPlaybackAfterQueuedPlayerRestart() async throws {
        guard ProcessInfo.processInfo.environment["SAYALL_TEST_VIRTUAL_AUDIO_CONFIGURATION"] == "1"
        else { return }
        let device = try #require(await Task.detached {
            CoreAudioDeviceCatalog.outputDevices().first { $0.uid == "MiRemoteV2ch_UID" }
        }.value)
        let queue = DispatchQueue(label: "test.virtual_audio_restart")
        let logs = ConfigurationLogRecorder()
        let output = VirtualAudioOutput(logger: logs.append, engineQueue: queue)
        defer { output.stop() }
        let configured = await withCheckedContinuation { continuation in
            output.configureAsync(deviceUID: device.uid) { continuation.resume(returning: $0) }
        }
        try #require(configured)
        let loopback = try VirtualLoopbackObservation(deviceID: device.id)
        defer { loopback.stop() }

        for generation in 1...3 {
            let gate = DispatchSemaphore(value: 0)
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume()
                    _ = gate.wait(timeout: .now() + 3)
                }
            }
            let signalFramesBefore = loopback.signalFrames
            // Force the restart to stay queued while the first voice buffer is submitted.
            // Both operations must later reach AVAudioPlayerNode in the caller's order.
            output.endSession()
            #expect(output.enqueue(samples: Array(repeating: 1_000, count: 1_600), deliveryGeneration: generation))
            let drained = AsyncStream<VirtualAudioDrainOutcome>.makeStream()
            output.endSessionAfterDraining(source: "configuration_regression", operationID: UInt64(generation), maximumDelay: 2) {
                drained.continuation.yield($0)
                drained.continuation.finish()
            }
            try await Task.sleep(for: .milliseconds(150))
            #expect(output.diagnosticSnapshot(deliveryGeneration: generation).counters.playedSamples == 0)
            #expect(loopback.signalFrames == signalFramesBefore)
            gate.signal()
            var outcomes: [VirtualAudioDrainOutcome] = []
            for await outcome in drained.stream { outcomes.append(outcome) }
            #expect(outcomes == [.normal])
            let snapshot = output.diagnosticSnapshot(deliveryGeneration: generation)
            #expect(snapshot.counters.playedSamples == 1_600)
            #expect(snapshot.counters.interruptedSamples == 0)
            #expect(snapshot.pendingSamples == 0)
            try await Task.sleep(for: .milliseconds(100))
            #expect(loopback.signalFrames - signalFramesBefore >= Int(loopback.sampleRate * 0.095))
        }
    }

    /// Counts synthetic signal frames on the explicitly selected virtual loopback only.
    /// No PCM or user content is retained or written to disk.
    private final class VirtualLoopbackObservation: @unchecked Sendable {
        private let deviceID: AudioDeviceID
        private var ioProcID: AudioDeviceIOProcID?
        private let lock = NSLock()
        private var observedSignalFrames = 0
        let sampleRate: Double

        init(deviceID: AudioDeviceID) throws {
            self.deviceID = deviceID
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            try #require(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format) == noErr)
            try #require(format.mFormatID == kAudioFormatLinearPCM)
            try #require(format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32)
            sampleRate = format.mSampleRate
            let creationResult = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { [weak self] _, input, _, _, _ in
                guard let self,
                      let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                      let data = buffer.mData
                else { return }
                let channelCount = max(1, Int(buffer.mNumberChannels))
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                var signalFrames = 0
                for index in stride(from: 0, to: count, by: channelCount) {
                    if abs(samples[index]) > 0.005 { signalFrames += 1 }
                }
                self.lock.lock()
                self.observedSignalFrames += signalFrames
                self.lock.unlock()
            }
            try #require(creationResult == noErr)
            if AudioDeviceStart(deviceID, ioProcID) != noErr {
                stop()
                throw NSError(domain: "virtual_loopback_test", code: 1)
            }
        }

        var signalFrames: Int {
            lock.lock()
            defer { lock.unlock() }
            return observedSignalFrames
        }

        func stop() {
            guard let ioProcID else { return }
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            self.ioProcID = nil
        }
    }

    private final class ConfigurationLogRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
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

    @Test func fallbackPrefersRememberedUserInputBeforeBuiltIn() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let builtIn = AudioDeviceInfo(id: 2, uid: "built-in", name: "MacBook Microphone")
        let remembered = AudioDeviceInfo(id: 3, uid: "wave-xlr", name: "Elgato Wave XLR")
        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, builtIn, remembered],
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id],
            preferredUID: remembered.uid
        )
        #expect(fallback == remembered)
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

    @Test func userChoiceDuringManagedFallbackIsRememberedAndClearsTheTransition() {
        #expect(DefaultInputFallbackPolicy.observationDecision(
            currentUID: "built-in-fallback",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in-fallback",
            lastRememberedUID: "old-usb"
        ) == .ignore)
        #expect(DefaultInputFallbackPolicy.observationDecision(
            currentUID: "new-wave-xlr",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in-fallback",
            lastRememberedUID: "old-usb"
        ) == .remember(uid: "new-wave-xlr", clearManagedTransition: true))
        #expect(DefaultInputFallbackPolicy.observationDecision(
            currentUID: "old-usb",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in-fallback",
            lastRememberedUID: "old-usb"
        ) == .clearManagedTransition)
    }
}
