import Foundation
import Testing
@testable import RemoteMic

@Suite("macOS Dictation bridge")
struct MacOSDictationBridgeTests {
    @Test func dictationRequiresRC003NeutralizedHardwareAndAnEnabledTapSession() {
        #expect(BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceMacOSDictationModeEnabled: true,
            voiceTapSessionEnabled: true,
            remoteModel: .rc003,
            isVoiceKeyNeutralized: true
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceMacOSDictationModeEnabled: true,
            voiceTapSessionEnabled: false,
            remoteModel: .rc003,
            isVoiceKeyNeutralized: true
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceMacOSDictationModeEnabled: true,
            voiceTapSessionEnabled: true,
            remoteModel: .rc003,
            isVoiceKeyNeutralized: false
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceTapCleanupPending: true,
            isVoiceKeyNeutralized: true
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceMacOSDictationModeEnabled: true,
            voiceTapSessionEnabled: true,
            voiceTapCleanupPending: true,
            remoteModel: .rc003,
            isVoiceKeyNeutralized: true
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceMacOSDictationModeEnabled: true,
            voiceTapSessionEnabled: true,
            remoteModel: .rc001,
            isVoiceKeyNeutralized: true
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceMacOSDictationModeEnabled: true,
            voiceTapSessionEnabled: true,
            remoteModel: .unknown,
            isVoiceKeyNeutralized: true
        ))
        #expect(BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            isVoiceKeyNeutralized: false
        ))
    }

    @Test func dictationPermissionChangesParticipateInRuntimeRecovery() {
        let granted = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )
        let denied = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: false
        )

        #expect(HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceMacOSDictationModeEnabled: true,
            previous: granted,
            current: denied
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceMacOSDictationModeEnabled: false,
            previous: granted,
            current: denied
        ))
    }

    @Test func modelReadinessBarrierOnlyBlocksUnknownDictationConnections() {
        #expect(BluetoothRemoteModelReadinessPolicy.shouldWaitBeforeReady(
            voiceMacOSDictationModeEnabled: true,
            persistedModel: .unknown,
            bluetoothName: "MI RC",
            modelReadPending: true
        ))
        #expect(!BluetoothRemoteModelReadinessPolicy.shouldWaitBeforeReady(
            voiceMacOSDictationModeEnabled: false,
            persistedModel: .unknown,
            bluetoothName: "MI RC",
            modelReadPending: true
        ))
        #expect(!BluetoothRemoteModelReadinessPolicy.shouldWaitBeforeReady(
            voiceMacOSDictationModeEnabled: true,
            persistedModel: .rc003,
            bluetoothName: "MI RC",
            modelReadPending: true
        ))
        #expect(!BluetoothRemoteModelReadinessPolicy.shouldWaitBeforeReady(
            voiceMacOSDictationModeEnabled: true,
            persistedModel: .unknown,
            bluetoothName: "Xiaomi Bluetooth Remote 2 Pro",
            modelReadPending: true
        ))
        #expect(BluetoothRemoteModelReadinessPolicy.shouldWaitBeforeReady(
            voiceMacOSDictationModeEnabled: true,
            persistedModel: .unknown,
            bluetoothName: "ARN9",
            modelReadPending: true
        ))
        #expect(!BluetoothRemoteModelReadinessPolicy.shouldWaitBeforeReady(
            voiceMacOSDictationModeEnabled: true,
            persistedModel: .unknown,
            bluetoothName: "MI RC",
            modelReadPending: false
        ))

        #expect(!BluetoothRemoteModelReadinessPolicy.canCompleteInitialization(
            capabilitiesConfirmed: true,
            waitsForModelIdentification: true,
            modelReadPending: true
        ))
        #expect(BluetoothRemoteModelReadinessPolicy.canCompleteInitialization(
            capabilitiesConfirmed: true,
            waitsForModelIdentification: true,
            modelReadPending: false
        ))
        #expect(BluetoothRemoteModelReadinessPolicy.canCompleteInitialization(
            capabilitiesConfirmed: true,
            waitsForModelIdentification: false,
            modelReadPending: true
        ))
        #expect(!BluetoothRemoteModelReadinessPolicy.canCompleteInitialization(
            capabilitiesConfirmed: false,
            waitsForModelIdentification: false,
            modelReadPending: false
        ))
        #expect(!BluetoothRemoteModelReadinessPolicy.canCompleteInitialization(
            capabilitiesConfirmed: false,
            waitsForModelIdentification: true,
            modelReadPending: false
        ))
    }

    @Test func runtimeEnableReconnectsOnlyUnidentifiedAmbiguousRemotes() {
        #expect(BridgeAppModel.shouldReconnectForMacOSDictationModelIdentification(
            enabling: true,
            remoteModel: .unknown,
            bluetoothName: "MI RC"
        ))
        #expect(BridgeAppModel.shouldReconnectForMacOSDictationModelIdentification(
            enabling: true,
            remoteModel: .unknown,
            bluetoothName: "ARN9"
        ))
        #expect(!BridgeAppModel.shouldReconnectForMacOSDictationModelIdentification(
            enabling: true,
            remoteModel: .rc003,
            bluetoothName: "MI RC"
        ))
        #expect(!BridgeAppModel.shouldReconnectForMacOSDictationModelIdentification(
            enabling: true,
            remoteModel: .unknown,
            bluetoothName: "Xiaomi Bluetooth Remote 2 Pro"
        ))
        #expect(!BridgeAppModel.shouldReconnectForMacOSDictationModelIdentification(
            enabling: false,
            remoteModel: .unknown,
            bluetoothName: "MI RC"
        ))
    }

    @Test func modelCallbackPersistsBeforeReadyAndFailuresReleaseTheBarrier() throws {
        let source = try bluetoothBridgeSource()
        let identifiedLog = try #require(source.range(
            of: #"AppLogger.shared.write("BLE MODEL identified=\(model.rawValue)")"#
        ))
        let delegate = try #require(source.range(
            of: "delegate?.bluetoothBridge(self, didIdentifyRemoteModel: model)",
            range: identifiedLog.upperBound..<source.endIndex
        ))
        let finish = try #require(source.range(
            of: "finishModelIdentification(generation: generation)",
            range: delegate.upperBound..<source.endIndex
        ))

        #expect(delegate.lowerBound < finish.lowerBound)
        #expect(source.contains("capabilitiesConfirmed = true"))
        #expect(source.contains("completeInitializationIfPossible(generation: generation)"))
        for reason in [
            "characteristic_discovery_failed",
            "characteristic_missing",
            "read_failed",
            "value_missing",
            "value_empty",
            "unreadable",
            "unrecognized_model",
        ] {
            #expect(source.contains("unavailableReason: \"\(reason)\""))
        }
        #expect(source.contains("model_unavailable reason=service_missing"))
        #expect(source.contains("model_unavailable reason=\\(unavailableReason)"))
    }

    @Test func disablingDictationReleasesEveryModelWaitWithoutCancellingTheRead() throws {
        let bluetoothSource = try bluetoothBridgeSource()
        let release = try sourceSection(
            bluetoothSource,
            from: "func releaseModelIdentificationWaitForDisabledDictation",
            to: "func recoverAfterSystemWake"
        )
        let modelSource = try bridgeSource()

        #expect(release.contains("waitsForModelIdentificationBeforeReady = false"))
        #expect(release.contains("completeInitializationIfPossible(generation: generation)"))
        #expect(!release.contains("modelIdentificationPending = false"))
        #expect(modelSource.contains("settings.$voiceMacOSDictationModeEnabled"))
        #expect(modelSource.contains("transition.previous, !transition.current"))
        #expect(modelSource.contains("DispatchQueue.main.async"))
        #expect(modelSource.contains(
            "settings.voiceMacOSDictationModeEnabled == false"
        ))
        #expect(modelSource.contains("releaseBluetoothModelWaitsForDisabledDictation()"))
        #expect(modelSource.contains(
            "$0.releaseModelIdentificationWaitForDisabledDictation()"
        ))
        #expect(modelSource.contains(
            "discoveryBluetoothBridge?.releaseModelIdentificationWaitForDisabledDictation()"
        ))
    }

    @Test func onlyThePhysicalBluetoothVoicePathStartsTheDictationTapSession() throws {
        let source = try bridgeSource()
        let bluetoothStart = try sourceSection(
            source,
            from: "func bluetoothBridgeDidStartVoice",
            to: "func bluetoothBridgeDidStopVoice"
        )
        let mobileStart = try sourceSection(
            source,
            from: "private func startPhoneVoice",
            to: "private func receivePhoneAudio"
        )

        #expect(
            source.components(separatedBy: "voiceFnTapSession.startVoice(").count - 1 == 1
        )
        #expect(bluetoothStart.contains(
            "voiceMacOSDictationModeEnabled: settings.voiceMacOSDictationModeEnabled"
        ))
        #expect(bluetoothStart.contains(
            "voiceTapSessionEnabled: voiceFnTapSession.isEnabled"
        ))
        #expect(bluetoothStart.contains(
            "let voiceTapCleanupPending = voiceFnTapSession.hasCleanupBlockingNewVoice"
        ))
        #expect(bluetoothStart.contains("voiceTapCleanupPending: voiceTapCleanupPending"))
        #expect(bluetoothStart.contains("remoteModel: model"))
        #expect(bluetoothStart.contains("pattern: trigger.tapPattern"))
        #expect(bluetoothStart.contains("operationID: traceID"))
        #expect(bluetoothStart.contains("!accepted,"))
        #expect(bluetoothStart.contains("phase=start_rejected"))
        #expect(bluetoothStart.contains("result=busy_or_cancelled"))
        #expect(bluetoothStart.contains("reason = \"unsupported_remote_model\""))
        #expect(bluetoothStart.contains("reason = \"voice_tap_cleanup_pending\""))
        #expect(bluetoothStart.contains("reason = \"voice_tap_session_disabled\""))
        let acceptedGate = try #require(
            bluetoothStart.range(of: "guard accepted, remainsActive")
        )
        let voiceSessionStart = try #require(
            bluetoothStart.range(of: "beginVoiceSessionIfNeeded()")
        )
        #expect(acceptedGate.lowerBound < voiceSessionStart.lowerBound)
        #expect(!mobileStart.contains("voiceFnTapSession.startVoice"))
        #expect(!mobileStart.contains("setControlKeyPressed"))
    }

    @Test func releaseAndDisconnectBothRequestControllerCleanup() throws {
        let source = try bridgeSource()
        let stateChange = try sourceSection(
            source,
            from: "func bluetoothBridge(\n        _ bridge:",
            to: "func bluetoothBridgeDidStartVoice"
        )
        let stop = try sourceSection(
            source,
            from: "func bluetoothBridgeDidStopVoice",
            to: "func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode"
        )

        #expect(stateChange.contains("voiceFnTapSession.stopVoice()"))
        #expect(stateChange.contains(
            "voiceFnTapSession.suspend(reason: .bluetoothNotReady)"
        ))
        #expect(stateChange.contains("reason=bluetooth_not_ready"))
        #expect(stop.contains("voiceFnTapSession.stopVoice()"))
        #expect(stop.contains("phase=stop_requested"))
    }

    @Test func everyAcceptedTapTraceHasAProductionTerminationPath() throws {
        let source = try bridgeSource()
        let initializer = try sourceSection(
            source,
            from: "private lazy var voiceFnTapSession",
            to: "private lazy var transcriptCaptureCoordinator"
        )
        let stop = try sourceSection(
            source,
            from: "func stop()",
            to: "func refreshTranscriptRecords"
        )
        let applySettings = try sourceSection(
            source,
            from: "func applyHIDSettings",
            to: "private func scheduleHIDMappingRecoveryIfNeeded"
        )
        let cancellation = try sourceSection(
            source,
            from: "private func handleVoiceTapCancellation",
            to: "private func handleVoiceTapTermination"
        )
        let termination = try sourceSection(
            source,
            from: "private func handleVoiceTapTermination",
            to: "private func requestNextHIDPermissionIfNeeded"
        )

        #expect(initializer.contains("onTermination:"))
        #expect(initializer.contains("handleVoiceTapTermination"))
        let controllerShutdown = try #require(stop.range(
            of: "voiceFnTapSession.shutdown(reason: .appShutdown)"
        ))
        let destinationShutdown = try #require(stop.range(
            of: "voiceInputDestinationCoordinator.shutdown()"
        ))
        #expect(controllerShutdown.lowerBound < destinationShutdown.lowerBound)
        #expect(applySettings.contains("cleanupTerminationReason = .modeChanged"))
        #expect(applySettings.contains("cleanupTerminationReason = .permissionRevoked"))
        #expect(applySettings.contains("reason: cleanupTerminationReason"))
        #expect(source.contains("setEnabled(false, reason: .modeChanged)"))
        #expect(source.contains("setEnabled(false, reason: .modeDisabled)"))
        #expect(cancellation.contains(
            "guard activeBluetoothVoiceTraceID == cancelledTraceID"
        ))
        #expect(termination.contains("phase=cancelled"))
        #expect(termination.contains("reason=\\(reason.rawValue)"))
        #expect(termination.contains(
            "guard activeBluetoothVoiceTraceID == terminatedTraceID"
        ))
        #expect(termination.contains("reason=voice_tap_\\(reason.rawValue)"))
    }

    @Test func diagnosticsNameTheRouteAndExternalObservationBoundary() throws {
        let source = try bridgeSource()

        #expect(source.contains(
            #"case .macOSDictation: return "macos_dictation_text_unobservable""#
        ))
        #expect(source.contains(
            #"activeVoiceTapTrigger == .macOSDictation ? "macos_dictation" : "fn_tap""#
        ))
        #expect(source.contains("phase=start_requested"))
        #expect(source.contains("phase=start_accepted"))
        #expect(source.contains("phase=stop_requested"))
        #expect(source.contains("phase=start_cancelled"))
        #expect(source.contains("reason=voice_tap_destination_\\(reason.rawValue)"))
        #expect(source.contains("phase=external_boundary"))
        #expect(source.contains("phase=failed"))
        #expect(source.contains("phase=recovery"))
        #expect(source.contains("target=hardware_fn"))
        #expect(source.contains(
            "let failedTraceID = operationID ?? activeBluetoothVoiceTraceID ?? 0"
        ))
        #expect(source.contains("origin_trace=\\(failedTraceID)"))
        #expect(source.contains("requestMicrophoneClose() ?? false"))
        #expect(source.contains("ATVV STREAM aborted trace="))
        #expect(source.contains("expected_effect=dictation_text_in_focused_field"))
    }

    @Test func targetReadinessAlsoAppliesToTheDictationMode() throws {
        let source = try bridgeSource()
        let externalAction = try sourceSection(
            source,
            from: "private func performExternalConfiguredAction",
            to: "private func handleVoiceInputDestinationState"
        )
        let destinationState = try sourceSection(
            source,
            from: "private func handleVoiceInputDestinationState",
            to: "private func performInternalAction"
        )

        #expect(externalAction.contains("let requestID = isVoiceTapModeEnabled"))
        #expect(destinationState.contains("guard isVoiceTapModeEnabled else"))
    }

    private func bridgeSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
    }

    private func bluetoothBridgeSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/XiaomiBluetoothBridge.swift"
            ),
            encoding: .utf8
        )
    }

    private func sourceSection(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> Substring {
        let start = try #require(source.range(of: startMarker))
        let end = try #require(source.range(
            of: endMarker,
            range: start.upperBound..<source.endIndex
        ))
        return source[start.lowerBound..<end.lowerBound]
    }
}
