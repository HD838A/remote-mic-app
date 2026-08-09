import AppKit
import Combine
import CoreAudio
import Foundation

private enum MobileVoiceSource {
    case nearby
    case web
}

private struct MobileButtonGestureKey: Hashable {
    let source: UsageEventSource
    let button: RemoteButton
}

enum BluetoothVoiceStopPolicy {
    /// Remote stop ends capture but must not discard PCM already scheduled for playback.
    static func shouldFlushAudio(handledByFnTapMode _: Bool) -> Bool {
        false
    }
}

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    private static let longRecordingOpenTimeout: TimeInterval = 5
    private static let longRecordingCloseTimeout: TimeInterval = 2
    private static let longRecordingKeepAliveInterval: TimeInterval = 10
    private static let longRecordingMaximumDuration: TimeInterval = 60

    let settings = AppSettings()

    @Published private(set) var connectionStatus = LocalizedMessage("bluetooth.status.initializing")
    @Published private(set) var hidStatus = LocalizedMessage("button_mapping.status.disabled")
    @Published private(set) var audioStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var doubaoAudioStatus = LocalizedMessage("audio.compatibility.checking")
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    @Published private(set) var isVoiceTriggerEnabled = false
    @Published private(set) var activeRemoteButtons = Set<RemoteButton>()
    @Published private(set) var connectedRemoteProfileIDs = Set<UUID>()
    @Published private(set) var remoteBatteryLevels: [UUID: Int] = [:]
    @Published private(set) var remotePowerStates: [UUID: RemotePowerState] = [:]
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var isAudioOutputReady = false
    @Published private(set) var isPhoneRemoteConnectionEnabled = false
    @Published private(set) var webRemoteState: WebRemoteSessionState = .disabled
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")
    @Published private(set) var postDictationStatus = LocalizedMessage("post_dictation.status.ready")
    @Published private(set) var postDictationState: PostDictationPolishState = .idle
    @Published private(set) var isDeepSeekAPIKeyConfigured = false
    @Published private(set) var programmingTerms: [ProgrammingTerm] = []
    @Published private(set) var copyablePostDictationResult: String?

    private let audioOutput = VirtualAudioOutput()
    private let phoneRemoteServer = PhoneRemoteServer()
    private let webRemoteClient = WebRemoteRelayClient()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private let deepSeekCredentialStore = DeepSeekCredentialStore()
    private let programmingTermStore = ProgrammingTermStore()
    private lazy var postDictationCoordinator = PostDictationPolishCoordinator(
        isEnabled: { [weak self] in
            self?.settings.deepSeekPostDictationEnabled == true
        },
        loadAPIKey: { [weak self] in
            try self?.deepSeekCredentialStore.loadAPIKey()
        },
        enabledTerms: { [weak self] in
            self?.programmingTerms.filter(\.isEnabled) ?? []
        },
        statusChanged: { [weak self] state, message in
            self?.postDictationState = state
            self?.postDictationStatus = message
        },
        resultChanged: { [weak self] result in
            self?.copyablePostDictationResult = result
        }
    )
    private lazy var voiceFnTapSession = VoiceFnTapSessionController(
        setFunctionKeyPressed: { KeyboardInjector.setFunctionKeyPressed($0) },
        enqueueAudio: { [weak self] samples in
            _ = self?.audioOutput.enqueue(samples: samples)
        },
        drainAudio: { [weak self] completion in
            guard let self else {
                completion()
                return
            }
            self.audioOutput.endSessionAfterDraining(completion: completion)
        },
        onFailure: { [weak self] failure in
            self?.handleVoiceFnTapFailure(failure)
        }
    )
    private var testToneGeneration = 0
    private var phoneVoiceFunctionKeyLatch = VoiceFunctionKeyLatch()
    private var voiceSessionStartedAt: Date?
    private var voiceSessionUsageSource: UsageEventSource?
    private var bluetoothVoiceActive = false
    private var loggedBluetoothVoiceAudioDeviceIdentifier: UUID?
    private var activeMobileVoiceSource: MobileVoiceSource?
    private var longRecordingRequested = false
    private var longRecordingGeneration: UInt64 = 0
    private var longRecordingOpenTimer: DispatchSourceTimer?
    private var longRecordingCloseTimer: DispatchSourceTimer?
    private var longRecordingKeepAliveTimer: DispatchSourceTimer?
    private var longRecordingLimitTimer: DispatchSourceTimer?
    private var phoneApprovalAlert: NSAlert?
    private var webApprovalAlert: NSAlert?
    private var remoteButtonTitles: [String: String] = [:]
    private var mobileButtonGestureRecognizers: [UsageEventSource: RemoteButtonGestureRecognizer] = [:]
    private var mobileDoubleClickTimers: [MobileButtonGestureKey: DispatchSourceTimer] = [:]
    private var mobileLongPressTimers: [MobileButtonGestureKey: DispatchSourceTimer] = [:]
    private var bluetoothBridges: [UUID: XiaomiBluetoothBridge] = [:]
    private var bluetoothBridgeStates: [ObjectIdentifier: BluetoothBridgeState] = [:]
    private var discoveryBluetoothBridge: XiaomiBluetoothBridge?
    private var activeBluetoothVoiceDeviceIdentifier: UUID?
    private var bluetoothVoiceTraceCounter: UInt64 = 0
    private var activeBluetoothVoiceTraceID: UInt64?
    private var bluetoothVoiceTraceStartedAt: Date?
    private var bluetoothVoiceTraceModel: XiaomiRemoteModel = .unknown
    private var bluetoothVoiceDecodedBatchCount = 0
    private var bluetoothVoiceDecodedSampleCount = 0
    private var bluetoothVoiceEnqueueFailureCount = 0
    private var bluetoothVoiceTraceRoute = "none"
    private let hidEventSuppressor = KeyboardEventSuppressor()
    private var hidMonitors: [String: HIDRemoteMonitor] = [:]
    private var discoveryHIDMonitor: HIDRemoteMonitor?
    private var hidPowerKeySuppressed = false
    private var started = false
    private var terminationObserver: NSObjectProtocol?
    private let audioPreparationQueue = DispatchQueue(label: "RemoteMic.audioPreparation", qos: .userInitiated)
    private var audioStartupGeneration: UInt64 = 0
    private var audioDeviceRefreshGeneration: UInt64 = 0
    private var audioStartupPending = false
    private let audioHardwareListenerQueue = DispatchQueue(label: "RemoteMic.audioHardware")
    private var observedAudioHardwareAddresses: [AudioObjectPropertyAddress] = []
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var audioRecoveryGeneration: UInt64 = 0
    private lazy var audioHardwareListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        let properties = Self.audioHardwarePropertyNames(count: count, addresses: addresses)
        self?.scheduleAudioRecovery(reason: "hardware_change", details: "properties=\(properties)")
    }

    init() {
        isDeepSeekAPIKeyConfigured = ((try? deepSeekCredentialStore.loadAPIKey()) ?? nil) != nil
        programmingTerms = programmingTermStore.terms
        audioOutput.onConfigurationChange = { [weak self] in
            self?.scheduleAudioRecovery(reason: "engine_configuration_change")
        }
        phoneRemoteServer.isIdentityTrusted = { [weak self] fingerprint in
            self?.settings.isPhoneIdentityTrusted(fingerprint) ?? false
        }
        phoneRemoteServer.onApprovalCancelled = { [weak self] in
            self?.cancelPhoneApproval()
        }
        phoneRemoteServer.onApprovalRequested = { [weak self] deviceName, pairingCode, fingerprint, completion in
            guard let self else {
                completion(false)
                return
            }
            requestPhoneApproval(
                deviceName: deviceName,
                pairingCode: pairingCode,
                identityFingerprint: fingerprint,
                completion: completion
            )
        }
        phoneRemoteServer.onCommand = { [weak self] button, completion in
            DispatchQueue.main.async {
                completion(self?.performPhoneCommand(button, source: .nearbyPhone) ?? false)
            }
        }
        phoneRemoteServer.onButtonEvent = { [weak self] button, phase, completion in
            DispatchQueue.main.async {
                completion(self?.handleMobileButtonEvent(
                    button,
                    phase: phase,
                    source: .nearbyPhone
                ) ?? false)
            }
        }
        phoneRemoteServer.onButtonEventsReset = { [weak self] in
            DispatchQueue.main.async {
                self?.resetMobileButtonGestures(source: .nearbyPhone)
            }
        }
        phoneRemoteServer.onVoiceStart = { [weak self] completion in
            DispatchQueue.main.async {
                completion(self?.startPhoneVoice(source: .nearby) ?? false)
            }
        }
        phoneRemoteServer.onVoiceStop = { [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .nearby)
            }
        }
        phoneRemoteServer.onAudio = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .nearby)
            }
        }
        webRemoteClient.onStateChange = { [weak self] state in
            self?.webRemoteState = state
        }
        webRemoteClient.onApprovalCancelled = { [weak self] in
            self?.cancelWebApproval()
        }
        webRemoteClient.onApprovalRequested = { [weak self] deviceName, pairingCode, completion in
            guard let self else {
                completion(false)
                return
            }
            requestWebApproval(
                deviceName: deviceName,
                pairingCode: pairingCode,
                completion: completion
            )
        }
        webRemoteClient.onCommand = { [weak self] button, completion in
            DispatchQueue.main.async {
                completion(self?.performPhoneCommand(button, source: .webRemote) ?? false)
            }
        }
        webRemoteClient.onButtonEvent = { [weak self] button, phase, completion in
            DispatchQueue.main.async {
                completion(self?.handleMobileButtonEvent(
                    button,
                    phase: phase,
                    source: .webRemote
                ) ?? false)
            }
        }
        webRemoteClient.onButtonEventsReset = { [weak self] in
            DispatchQueue.main.async {
                self?.resetMobileButtonGestures(source: .webRemote)
            }
        }
        webRemoteClient.onVoiceStart = { [weak self] completion in
            DispatchQueue.main.async {
                completion(self?.startPhoneVoice(source: .web) ?? false)
            }
        }
        webRemoteClient.onVoiceStop = { [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .web)
            }
        }
        webRemoteClient.onAudio = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .web)
            }
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        startAudioSubsystem()
        applyHIDSettings()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        AppLogger.shared.write("APP START version=\(version)")
    }

    func stop() {
        guard started else { return }
        started = false
        if settings.deepSeekPostDictationEnabled {
            postDictationCoordinator.cancel()
        }
        audioStartupGeneration &+= 1
        audioDeviceRefreshGeneration &+= 1
        let shouldStopAudioOnPreparationQueue = audioStartupPending
        audioStartupPending = false
        audioRecoveryGeneration &+= 1
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        stopObservingAudioHardware()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("app.status.stopped"),
            logReason: "app_stop"
        )
        stopLongRecording(reason: "app_stop")
        voiceFnTapSession.shutdown()
        bluetoothBridges.values.forEach { $0.stop() }
        discoveryBluetoothBridge?.stop()
        bluetoothBridges.removeAll()
        bluetoothBridgeStates.removeAll()
        discoveryBluetoothBridge = nil
        activeBluetoothVoiceDeviceIdentifier = nil
        phoneRemoteServer.stop()
        webRemoteClient.stop()
        isPhoneRemoteConnectionEnabled = false
        webRemoteState = .disabled
        bluetoothVoiceActive = false
        activeMobileVoiceSource = nil
        voiceSessionUsageSource = nil
        updatePhoneVoiceFunctionKeyState(streaming: false)
        stopHIDMonitors()
        isAudioOutputReady = false
        if shouldStopAudioOnPreparationQueue {
            audioPreparationQueue.async { [weak self] in
                self?.audioOutput.stop()
            }
        } else {
            audioOutput.stop()
        }
        voiceFunctionMapper.restore()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        AppLogger.shared.write("APP STOP")
    }

    func reconnect() {
        if let selectedBluetoothBridge {
            selectedBluetoothBridge.reconnectNow()
        } else {
            bluetoothBridges.values.forEach { $0.reconnectNow() }
            discoveryBluetoothBridge?.reconnectNow()
        }
    }

    func enablePhoneRemoteConnection() {
        guard started, !isPhoneRemoteConnectionEnabled else { return }
        isPhoneRemoteConnectionEnabled = true
        phoneRemoteServer.start()
        AppLogger.shared.write("PHONE REMOTE enabled_by_user")
    }

    func enableWebRemoteConnection() {
        guard started else { return }
        guard let relayURL = WebRemoteConfiguration.relayURL() else {
            webRemoteState = .unavailable
            AppLogger.shared.write("WEB REMOTE unavailable_missing_configuration")
            return
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        webRemoteState = .connecting
        webRemoteClient.start(
            relayURL: relayURL,
            macName: Host.current().localizedName ?? "Mac",
            appVersion: version,
            buttonTitles: remoteButtonTitles
        )
        AppLogger.shared.write("WEB REMOTE enabled_by_user")
    }

    func disableWebRemoteConnection() {
        webRemoteClient.stop()
        AppLogger.shared.write("WEB REMOTE disabled_by_user")
    }

    func updatePhoneRemoteButtonTitles(
        bindings: [RemoteButton: ButtonAction],
        shortcuts: [RemoteButton: CustomKeyboardShortcut],
        localization: LocalizationStore
    ) {
        var titles: [String: String] = [:]
        for button in RemoteButton.allCases {
            let action = bindings[button] ?? .disabled
            guard action != AppSettings.defaultBindings[button] else { continue }
            let fullTitle = action == .customShortcut
                ? shortcuts[button]?.displayName(using: localization)
                    ?? action.displayName(using: localization)
                : action.displayName(using: localization)
            titles[button.rawValue] = String(fullTitle.prefix(10))
        }
        remoteButtonTitles = titles
        phoneRemoteServer.updateButtonTitles(titles)
        webRemoteClient.updateButtonTitles(titles)
    }

    func refreshAudioDevices() {
        audioDeviceRefreshGeneration &+= 1
        let generation = audioDeviceRefreshGeneration
        AppLogger.shared.write("AUDIO DEVICES refresh_requested id=\(generation)")
        audioPreparationQueue.async { [weak self] in
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let diagnostic = Self.audioDevicesDiagnostic(devices)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.started,
                      self.audioDeviceRefreshGeneration == generation
                else { return }
                self.publishAudioDevices(devices)
                AppLogger.shared.write("AUDIO DEVICES refreshed id=\(generation) \(diagnostic)")
            }
        }
    }

    private func startAudioSubsystem() {
        audioStartupGeneration &+= 1
        let generation = audioStartupGeneration
        let selectedDeviceUID = settings.selectedAudioDeviceUID
        audioStartupPending = true
        AppLogger.shared.write("AUDIO STARTUP scheduled id=\(generation)")
        audioPreparationQueue.async { [weak self] in
            guard let self else { return }
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let devicesDiagnostic = Self.audioDevicesDiagnostic(devices)
            AppLogger.shared.write("AUDIO DEVICES startup id=\(generation) \(devicesDiagnostic)")
            AppLogger.shared.write(
                "AUDIO REBIND begin reason=startup state={\(self.audioOutput.diagnosticState())}"
            )
            let configured = self.audioOutput.configure(deviceUID: selectedDeviceUID)
            let audioStatus = self.audioOutput.status
            let isAudioOutputReady = self.audioOutput.isReadyForTestTone
            let testToneStatus = isAudioOutputReady
                ? LocalizedMessage("audio.test_tone.ready")
                : LocalizedMessage("audio.output.none_or_unavailable")
            let outputState = self.audioOutput.diagnosticState()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.started, self.audioStartupGeneration == generation else {
                    self.audioPreparationQueue.async { [weak self] in
                        self?.audioOutput.stop()
                    }
                    return
                }
                self.audioStartupPending = false
                self.publishAudioDevices(devices)
                self.audioStatus = audioStatus
                self.isAudioOutputReady = isAudioOutputReady
                self.testToneStatus = testToneStatus
                self.startObservingAudioHardware()
                self.startBluetoothConnections()
                AppLogger.shared.write(
                    "AUDIO REBIND finished reason=startup success=\(configured) status=\(audioStatus.key) " +
                        "state={\(outputState)}"
                )
            }
        }
    }

    private func publishAudioDevices(_ devices: [AudioDeviceInfo]) {
        audioDevices = devices
        doubaoAudioStatus = DoubaoAudioDevicePolicy.status(in: devices)
    }

    private static func audioDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        "outputs={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(devices))} " +
            CoreAudioDeviceCatalog.routeDiagnostic()
    }

    var hasDoubaoAudioDevice: Bool {
        DoubaoAudioDevicePolicy.device(in: audioDevices) != nil
    }

    func selectDoubaoAudioDevice() {
        guard let device = DoubaoAudioDevicePolicy.device(in: audioDevices) else {
            doubaoAudioStatus = LocalizedMessage(
                "audio.compatibility.device_missing",
                arguments: [DoubaoAudioDevicePolicy.deviceName]
            )
            return
        }
        settings.selectedAudioDeviceUID = device.uid
        applyAudioSettings(reason: "doubao_device_selected")
        doubaoAudioStatus = LocalizedMessage(
            "audio.compatibility.device_selected",
            arguments: [device.name]
        )
    }

    func openDoubaoDriverInstructions(using localization: LocalizationStore) {
        guard let instructions = localization.localizedURL(
            forResource: "DoubaoInputMethodCompatibility",
            withExtension: "md"
        ) else {
            return
        }
        NSWorkspace.shared.open(instructions)
    }

    func applyAudioSettings(reason: String = "settings_change") {
        stopLongRecording(reason: "audio_reconfigure")
        AppLogger.shared.write("AUDIO REBIND begin reason=\(reason) state={\(audioOutput.diagnosticState())}")
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.cancelled_device_changed"),
            logReason: "device_reconfigure"
        )
        let configured = audioOutput.configure(deviceUID: settings.selectedAudioDeviceUID)
        audioStatus = audioOutput.status
        isAudioOutputReady = audioOutput.isReadyForTestTone
        testToneStatus = isAudioOutputReady
            ? LocalizedMessage("audio.test_tone.ready")
            : LocalizedMessage("audio.output.none_or_unavailable")
        AppLogger.shared.write(
            "AUDIO REBIND finished reason=\(reason) success=\(configured) status=\(audioStatus.key) " +
                "state={\(audioOutput.diagnosticState())}"
        )
    }

    private func startObservingAudioHardware() {
        guard observedAudioHardwareAddresses.isEmpty else { return }
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let result = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioHardwareListenerQueue,
                audioHardwareListener
            )
            if result == noErr {
                observedAudioHardwareAddresses.append(address)
            } else {
                AppLogger.shared.write("AUDIO RECOVERY listener_failed selector=\(selector) error=\(result)")
            }
        }
        AppLogger.shared.write("AUDIO ROUTE_MONITOR started properties=\(Self.audioHardwarePropertyNames(for: observedAudioHardwareAddresses))")
    }

    private func stopObservingAudioHardware() {
        for var address in observedAudioHardwareAddresses {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioHardwareListenerQueue,
                audioHardwareListener
            )
        }
        if !observedAudioHardwareAddresses.isEmpty {
            AppLogger.shared.write("AUDIO ROUTE_MONITOR stopped properties=\(Self.audioHardwarePropertyNames(for: observedAudioHardwareAddresses))")
        }
        observedAudioHardwareAddresses.removeAll()
    }

    private func scheduleAudioRecovery(reason: String, details: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            guard !self.settings.selectedAudioDeviceUID.isEmpty else {
                AppLogger.shared.write("AUDIO RECOVERY ignored reason=\(reason) detail=\(details) no_selected_device")
                return
            }
            self.audioRecoveryGeneration &+= 1
            let generation = self.audioRecoveryGeneration
            let replacedPendingRecovery = self.audioRecoveryWorkItem != nil
            self.audioRecoveryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.started,
                      self.audioRecoveryGeneration == generation
                else { return }
                AppLogger.shared.write(
                    "AUDIO RECOVERY begin id=\(generation) reason=\(reason) detail=\(details) " +
                        "state={\(self.audioOutput.diagnosticState())}"
                )
                self.refreshAudioDevices()
                self.applyAudioSettings(reason: "recovery_\(reason)")
                AppLogger.shared.write(
                    "AUDIO RECOVERY completed id=\(generation) reason=\(reason) " +
                        "state={\(self.audioOutput.diagnosticState())}"
                )
                self.audioRecoveryWorkItem = nil
            }
            self.audioRecoveryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            AppLogger.shared.write(
                "AUDIO RECOVERY scheduled id=\(generation) reason=\(reason) detail=\(details) " +
                    "replaced_pending=\(replacedPendingRecovery) state={\(self.audioOutput.diagnosticState())}"
            )
        }
    }

    private static func audioHardwarePropertyNames(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> String {
        guard count > 0 else { return "none" }
        return (0..<Int(count))
            .map { audioHardwarePropertyName(addresses[$0].mSelector) }
            .joined(separator: ",")
    }

    private static func audioHardwarePropertyNames(
        for addresses: [AudioObjectPropertyAddress]
    ) -> String {
        addresses.map { audioHardwarePropertyName($0.mSelector) }.joined(separator: ",")
    }

    private static func audioHardwarePropertyName(
        _ selector: AudioObjectPropertySelector
    ) -> String {
        switch selector {
        case kAudioHardwarePropertyDevices:
            return "devices"
        case kAudioHardwarePropertyDefaultInputDevice:
            return "default_input"
        case kAudioHardwarePropertyDefaultOutputDevice:
            return "default_output"
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            return "default_system_output"
        default:
            return "selector_\(selector)"
        }
    }

    var canSendTestTone: Bool {
        TestToneGate.canPlay(
            hasSelectedDevice: isAudioOutputReady,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: isAudioOutputReady,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        ) else {
            if isStreaming {
                testToneStatus = LocalizedMessage("audio.test_tone.blocked_voice_active")
                AppLogger.shared.write("AUDIO TEST_TONE rejected_streaming")
            } else if isPlayingTestTone {
                testToneStatus = LocalizedMessage("audio.test_tone.already_playing")
            } else {
                testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            }
            return
        }

        testToneGeneration &+= 1
        let generation = testToneGeneration
        let started = audioOutput.playTestTone { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTestToneCompletion(generation: generation, finished: finished)
            }
        }
        guard started else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            return
        }
        isPlayingTestTone = true
        testToneStatus = LocalizedMessage("audio.test_tone.playing")
        AppLogger.shared.write("AUDIO TEST_TONE played")
    }

    private func handleTestToneCompletion(generation: Int, finished: Bool) {
        guard generation == testToneGeneration, isPlayingTestTone else { return }
        isPlayingTestTone = false
        testToneStatus = LocalizedMessage(finished ? "audio.test_tone.completed" : "audio.test_tone.cancelled")
        AppLogger.shared.write("AUDIO TEST_TONE \(finished ? "finished" : "cut_short")")
    }

    private func cancelTestToneIfNeeded(statusMessage: LocalizedMessage, logReason: String) {
        guard isPlayingTestTone else { return }
        testToneGeneration &+= 1
        isPlayingTestTone = false
        audioOutput.cancelTestTone()
        testToneStatus = statusMessage
        AppLogger.shared.write("AUDIO TEST_TONE cancelled reason=\(logReason)")
    }

    func applyHIDSettings() {
        if !settings.customMappingEnabled {
            stopLongRecording(reason: "mapping_disabled")
        }
        if !settings.experimentalContinuousRecordingEnabled {
            stopLongRecording(reason: "feature_disabled")
        }

        let requestedFnTapMode = settings.voiceFnTapModeEnabled
        if !requestedFnTapMode, voiceFnTapSession.requiresCleanupBeforeMapping {
            voiceFnTapSession.setEnabled(false) { [weak self] in
                self?.applyHIDSettings()
            }
            return
        }
        requestNextHIDPermissionIfNeeded(voiceFnTapModeRequested: requestedFnTapMode)
        var powerKeySuppressed: Bool
        if requestedFnTapMode, KeyboardInjector.isAccessibilityTrusted {
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if voiceFunctionMapper.isVoiceKeyNeutralized {
                voiceFnTapSession.setEnabled(true)
            } else {
                settings.voiceFnTapModeEnabled = false
                voiceFnTapSession.setEnabled(false)
                powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            }
        } else {
            if requestedFnTapMode {
                settings.voiceFnTapModeEnabled = false
            }
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
        }
        startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
    }

    private func startHIDMonitors(powerKeySuppressed: Bool) {
        stopHIDMonitors()
        hidPowerKeySuppressed = powerKeySuppressed
        guard settings.customMappingEnabled else {
            hidStatus = LocalizedMessage("button_mapping.status.system_managed")
            return
        }
        _ = hidEventSuppressor.start()
        for profile in settings.remoteDeviceProfiles {
            guard let fingerprint = profile.hidFingerprint else { continue }
            let monitor = makeHIDMonitor(
                profileID: profile.id,
                targetFingerprint: fingerprint
            )
            hidMonitors[fingerprint] = monitor
            monitor.start(powerKeySuppressed: powerKeySuppressed)
        }
        startHIDDiscoveryIfNeeded()
    }

    private func stopHIDMonitors() {
        hidMonitors.values.forEach { $0.stop() }
        discoveryHIDMonitor?.stop()
        hidMonitors.removeAll()
        discoveryHIDMonitor = nil
        hidEventSuppressor.stop()
        activeRemoteButtons = []
    }

    private func startHIDDiscoveryIfNeeded() {
        guard settings.customMappingEnabled, discoveryHIDMonitor == nil else { return }
        let monitor = makeHIDMonitor(
            profileID: nil,
            targetFingerprint: nil,
            excludedFingerprints: { [weak self] in
                guard let self else { return [] }
                return Set(self.hidMonitors.keys)
            }
        )
        discoveryHIDMonitor = monitor
        monitor.start(powerKeySuppressed: hidPowerKeySuppressed)
    }

    private func makeHIDMonitor(
        profileID: UUID?,
        targetFingerprint: String?,
        excludedFingerprints: @escaping () -> Set<String> = { [] }
    ) -> HIDRemoteMonitor {
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints,
            eventSuppressor: hidEventSuppressor,
            ownsEventSuppressor: false
        )
        monitor.onStatus = { [weak self, weak monitor] value in
            guard let self, let monitor else { return }
            if monitor.profileID == self.settings.selectedRemoteProfileID || monitor.profileID == nil {
                self.hidStatus = value
            }
        }
        monitor.onActiveButtons = { [weak self] profileID, buttons in
            guard let self, profileID == self.settings.selectedRemoteProfileID else { return }
            self.activeRemoteButtons = buttons
        }
        monitor.onButtonPressed = { [weak self, weak monitor] profileID, fingerprint, button in
            guard let self, let monitor else {
                return profileID.map { ($0, true) }
            }
            let existingProfileID = profileID
                ?? self.settings.profileID(forHIDFingerprint: fingerprint)
            let resolvedProfileID = existingProfileID
                ?? self.settings.registerHIDRemote(fingerprint: fingerprint)
            let isNewBinding = existingProfileID == nil
            if isNewBinding {
                monitor.assignProfileID(resolvedProfileID)
                self.hidMonitors[fingerprint] = monitor
                if self.discoveryHIDMonitor === monitor {
                    self.discoveryHIDMonitor = nil
                    self.startHIDDiscoveryIfNeeded()
                }
            }
            self.selectRemoteProfile(resolvedProfileID)
            self.settings.recordButtonPress(
                control: .remoteButton(button),
                source: .bluetoothRemote
            )
            return (resolvedProfileID, true)
        }
        monitor.onInternalAction = { [weak self] profileID, action in
            guard let self else { return }
            if let profileID { self.selectRemoteProfile(profileID) }
            self.performInternalAction(action)
        }
        return monitor
    }

    func setExperimentalContinuousRecordingEnabled(_ enabled: Bool) {
        if !enabled {
            stopLongRecording(reason: "feature_disabled")
        }
        settings.setExperimentalContinuousRecordingEnabled(enabled)
        applyHIDSettings()
    }

    func setVoiceFnTapModeEnabled(_ enabled: Bool) {
        if enabled {
            enableVoiceFnTapMode()
            return
        }
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false) { [weak self] in
            self?.applyHIDSettings()
        }
    }

    func setDeepSeekPostDictationEnabled(_ enabled: Bool) {
        settings.deepSeekPostDictationEnabled = enabled
        if enabled {
            postDictationStatus = isDeepSeekAPIKeyConfigured
                ? LocalizedMessage("post_dictation.status.ready")
                : LocalizedMessage("post_dictation.status.missing_key")
            postDictationState = isDeepSeekAPIKeyConfigured ? .idle : .failed
        } else {
            postDictationCoordinator.cancel()
        }
    }

    func saveDeepSeekAPIKey(_ apiKey: String) {
        do {
            try deepSeekCredentialStore.saveAPIKey(apiKey)
            isDeepSeekAPIKeyConfigured = true
            postDictationState = .idle
            postDictationStatus = LocalizedMessage("post_dictation.status.key_saved")
        } catch {
            postDictationState = .failed
            postDictationStatus = LocalizedMessage("post_dictation.status.key_save_failed")
        }
    }

    func deleteDeepSeekAPIKey() {
        do {
            try deepSeekCredentialStore.deleteAPIKey()
            isDeepSeekAPIKeyConfigured = false
            settings.deepSeekPostDictationEnabled = false
            postDictationCoordinator.cancel(resetStatus: false)
            postDictationState = .idle
            postDictationStatus = LocalizedMessage("post_dictation.status.key_deleted")
        } catch {
            postDictationState = .failed
            postDictationStatus = LocalizedMessage("post_dictation.status.key_delete_failed")
        }
    }

    func testDeepSeekConnection() {
        guard let apiKey = try? deepSeekCredentialStore.loadAPIKey() else {
            postDictationState = .failed
            postDictationStatus = LocalizedMessage("post_dictation.status.missing_key")
            return
        }
        postDictationState = .requesting
        postDictationStatus = LocalizedMessage("post_dictation.status.testing")
        let input = DeepSeekPolishInput(
            applicationName: "RemoteMic",
            bundleIdentifier: "com.hd838a.RemoteMic",
            contextBefore: "",
            contextAfter: "",
            currentDictation: "这是一次连接测试，请保持原意。",
            programmingTerms: []
        )
        Task { @MainActor [weak self] in
            do {
                _ = try await DeepSeekTextPolishingClient().polish(input: input, apiKey: apiKey)
                self?.postDictationState = .completed
                self?.postDictationStatus = LocalizedMessage("post_dictation.status.test_succeeded")
            } catch {
                self?.postDictationState = .failed
                self?.postDictationStatus = LocalizedMessage("post_dictation.status.test_failed")
            }
        }
    }

    func addProgrammingTerm(
        canonicalText: String,
        aliases: [String],
        kind: ProgrammingTermKind
    ) {
        let canonical = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !canonical.isEmpty, !normalizedAliases.isEmpty else { return }
        do {
            try programmingTermStore.add(ProgrammingTerm(
                canonicalText: canonical,
                spokenAliases: normalizedAliases,
                kind: kind
            ))
            programmingTerms = programmingTermStore.terms
        } catch {
            postDictationState = .failed
            postDictationStatus = LocalizedMessage("post_dictation.status.term_save_failed")
        }
    }

    func removeProgrammingTerm(id: UUID) {
        do {
            try programmingTermStore.remove(id: id)
            programmingTerms = programmingTermStore.terms
        } catch {
            postDictationState = .failed
            postDictationStatus = LocalizedMessage("post_dictation.status.term_save_failed")
        }
    }

    func setProgrammingTermEnabled(_ enabled: Bool, id: UUID) {
        do {
            try programmingTermStore.setEnabled(enabled, id: id)
            programmingTerms = programmingTermStore.terms
        } catch {
            postDictationState = .failed
            postDictationStatus = LocalizedMessage("post_dictation.status.term_save_failed")
        }
    }

    func copyPostDictationResult() {
        guard let copyablePostDictationResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyablePostDictationResult, forType: .string)
        postDictationStatus = LocalizedMessage("post_dictation.status.result_copied")
    }

    private func enableVoiceFnTapMode() {
        guard KeyboardInjector.isAccessibilityTrusted else {
            settings.voiceFnTapModeEnabled = false
            requestNextHIDPermissionIfNeeded(voiceFnTapModeRequested: true)
            applyHIDSettings()
            return
        }

        var powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
        guard voiceFunctionMapper.isVoiceKeyNeutralized else {
            settings.voiceFnTapModeEnabled = false
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
            return
        }
        settings.voiceFnTapModeEnabled = true
        voiceFnTapSession.setEnabled(true)
        startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
    }

    private func handleVoiceFnTapFailure(_ failure: VoiceFnTapFailure) {
        AppLogger.shared.write("VOICE FN TAP failed reason=\(failure.rawValue) fallback=hardware_fn")
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false)
        applyHIDSettings()
    }

    private func requestNextHIDPermissionIfNeeded(
        voiceFnTapModeRequested: Bool? = nil
    ) {
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeRequested ?? settings.voiceFnTapModeEnabled,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        switch request {
        case .none:
            break
        case .inputMonitoring:
            _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        case .accessibility:
            _ = KeyboardInjector.requestAccessibilityAccess()
        }
    }

    func requestInputMonitoringPermission() {
        _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func requestAccessibilityPermission() {
        _ = KeyboardInjector.requestAccessibilityAccess()
        openPrivacyPane("Privacy_Accessibility")
    }

    func openLogFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.logURL])
    }

    func openProjectFolder() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        if candidate.path.contains(".app/Contents/MacOS") {
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(candidate)
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var selectedBluetoothBridge: XiaomiBluetoothBridge? {
        guard let identifier = settings.selectedRemoteProfile?.bluetoothIdentifier else { return nil }
        return bluetoothBridges[identifier]
    }

    private func startBluetoothConnections() {
        let identifiers = Set(settings.remoteDeviceProfiles.compactMap(\.bluetoothIdentifier))
        for identifier in identifiers where bluetoothBridges[identifier] == nil {
            let bridge = XiaomiBluetoothBridge(
                settings: settings,
                delegate: self,
                targetIdentifier: identifier
            )
            bluetoothBridges[identifier] = bridge
            bridge.start()
        }
        startBluetoothDiscoveryIfNeeded()
    }

    private func startBluetoothDiscoveryIfNeeded() {
        guard started, discoveryBluetoothBridge == nil else { return }
        let bridge = XiaomiBluetoothBridge(
            settings: settings,
            delegate: self,
            excludedIdentifiers: { [weak self] in
                guard let self else { return [] }
                return Set(self.bluetoothBridges.keys)
            }
        )
        discoveryBluetoothBridge = bridge
        bridge.start()
    }

    private func registerBluetoothBridgeIfNeeded(_ bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        let profileID = settings.profileID(forBluetoothIdentifier: identifier)
            ?? settings.registerBluetoothRemote(identifier: identifier)
        if discoveryBluetoothBridge === bridge {
            discoveryBluetoothBridge = nil
            bluetoothBridges[identifier] = bridge
            startBluetoothDiscoveryIfNeeded()
        } else if bluetoothBridges[identifier] == nil {
            bluetoothBridges[identifier] = bridge
        }
        return profileID
    }

    private func bluetoothIdentifier(for bridge: XiaomiBluetoothBridge) -> UUID? {
        bridge.deviceIdentifier ?? bluetoothBridges.first(where: { $0.value === bridge })?.key
    }

    private func remoteProfileID(for bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        return settings.profileID(forBluetoothIdentifier: identifier)
            ?? settings.registerBluetoothRemote(identifier: identifier)
    }

    func selectRemoteProfile(_ profileID: UUID) {
        settings.selectRemoteProfile(profileID)
        refreshBluetoothPresentation()
    }

    private func activateRemoteProfile(for bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let profileID = registerBluetoothBridgeIfNeeded(bridge) else { return nil }
        selectRemoteProfile(profileID)
        return profileID
    }

    private func refreshBluetoothPresentation() {
        let allStates = bluetoothBridgeStates.values
        connectedRemoteProfileIDs = Set(bluetoothBridges.compactMap { identifier, bridge in
            guard let profileID = settings.profileID(forBluetoothIdentifier: identifier),
                  let state = bluetoothBridgeStates[ObjectIdentifier(bridge)],
                  case .ready = state
            else { return nil }
            return profileID
        })
        isConnected = allStates.contains { state in
            if case .ready = state { return true }
            return false
        }
        if let selectedBluetoothBridge,
           let state = bluetoothBridgeStates[ObjectIdentifier(selectedBluetoothBridge)] {
            connectionStatus = state.message
        } else if let ready = allStates.first(where: { state in
            if case .ready = state { return true }
            return false
        }) {
            connectionStatus = ready.message
        } else if let state = allStates.first {
            connectionStatus = state.message
        } else {
            connectionStatus = LocalizedMessage("connection.status.searching")
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didChange state: BluetoothBridgeState
    ) {
        let hadReadyBridge = bluetoothBridgeStates.values.contains { existingState in
            if case .ready = existingState { return true }
            return false
        }
        bluetoothBridgeStates[ObjectIdentifier(bridge)] = state
        if case .ready = state {
            _ = registerBluetoothBridgeIfNeeded(bridge)
            voiceFnTapSession.resume()
            if !hadReadyBridge {
                applyHIDSettings()
            }
        } else {
            let identifier = bluetoothIdentifier(for: bridge)
            if let identifier,
               let profileID = settings.profileID(forBluetoothIdentifier: identifier) {
                remoteBatteryLevels.removeValue(forKey: profileID)
                remotePowerStates.removeValue(forKey: profileID)
            }
            let voiceWasActive = identifier == activeBluetoothVoiceDeviceIdentifier
            if voiceWasActive {
                bluetoothVoiceActive = false
                activeBluetoothVoiceDeviceIdentifier = nil
                endVoiceSessionIfNeeded(flushAudio: false)
            }
            if longRecordingRequested {
                finishLongRecording(reason: "bluetooth_not_ready")
            }
        }
        refreshBluetoothPresentation()
        if isConnected {
            voiceFnTapSession.resume()
        } else {
            voiceFnTapSession.suspend()
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        guard let identifier = bridge.deviceIdentifier else { return }
        let profileID = activateRemoteProfile(for: bridge)
        if let activeBluetoothVoiceDeviceIdentifier,
           activeBluetoothVoiceDeviceIdentifier != identifier {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected_busy")
            return
        }
        activeBluetoothVoiceDeviceIdentifier = identifier
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = true
        let model = profileID
            .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
            ?? .unknown
        bluetoothVoiceTraceCounter &+= 1
        activeBluetoothVoiceTraceID = bluetoothVoiceTraceCounter
        bluetoothVoiceTraceStartedAt = Date()
        bluetoothVoiceTraceModel = model
        bluetoothVoiceDecodedBatchCount = 0
        bluetoothVoiceDecodedSampleCount = 0
        bluetoothVoiceEnqueueFailureCount = 0
        bluetoothVoiceTraceRoute = "none"
        AppLogger.shared.write(
            "ATVV STREAM accepted trace=\(bluetoothVoiceTraceCounter) model=\(model.rawValue)"
        )
        if longRecordingRequested {
            scheduleLongRecordingTimers(generation: longRecordingGeneration)
            AppLogger.shared.write("LONG RECORDING started")
        }
        _ = voiceFnTapSession.startVoice()
        beginVoiceSessionIfNeeded()
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        guard bridge.deviceIdentifier == activeBluetoothVoiceDeviceIdentifier else { return }
        activeBluetoothVoiceDeviceIdentifier = nil
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = false
        if longRecordingRequested {
            finishLongRecording(reason: "remote_stop")
        } else if longRecordingCloseTimer != nil {
            longRecordingCloseTimer?.cancel()
            longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_confirmed")
        }
        let handledByFnTapMode = voiceFnTapSession.stopVoice()
        let shouldFlushAudio = BluetoothVoiceStopPolicy.shouldFlushAudio(
            handledByFnTapMode: handledByFnTapMode
        )
        let traceID = activeBluetoothVoiceTraceID ?? 0
        let durationMilliseconds = bluetoothVoiceTraceStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0) * 1_000))
        } ?? 0
        let pendingBuffers = audioOutput.pendingVoiceBufferCountForDiagnostics
        AppLogger.shared.write(
            "ATVV STREAM summary trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue) " +
                "duration_ms=\(durationMilliseconds) batches=\(bluetoothVoiceDecodedBatchCount) " +
                "samples=\(bluetoothVoiceDecodedSampleCount) " +
                "enqueue_failures=\(bluetoothVoiceEnqueueFailureCount) " +
                "route=\(bluetoothVoiceTraceRoute) pending_buffers=\(pendingBuffers) " +
                "flush=\(shouldFlushAudio)"
        )
        audioOutput.logWhenPendingVoiceAudioDrains(
            context: "trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue)"
        )
        activeBluetoothVoiceTraceID = nil
        bluetoothVoiceTraceStartedAt = nil
        endVoiceSessionIfNeeded(flushAudio: shouldFlushAudio)
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        guard let identifier = bridge.deviceIdentifier,
              identifier == activeBluetoothVoiceDeviceIdentifier
        else { return }
        let handledByFnTapMode = voiceFnTapSession.receive(samples)
        let enqueued = handledByFnTapMode || audioOutput.enqueue(samples: samples)
        bluetoothVoiceDecodedBatchCount += 1
        bluetoothVoiceDecodedSampleCount += samples.count
        if !enqueued {
            bluetoothVoiceEnqueueFailureCount += 1
        }
        bluetoothVoiceTraceRoute = handledByFnTapMode ? "fn_tap" : "virtual_audio"
        if loggedBluetoothVoiceAudioDeviceIdentifier != identifier {
            loggedBluetoothVoiceAudioDeviceIdentifier = identifier
            let model = settings.profileID(forBluetoothIdentifier: identifier)
                .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
                ?? .unknown
            AppLogger.shared.write(
                "ATVV AUDIO routed trace=\(activeBluetoothVoiceTraceID ?? 0) " +
                    "model=\(model.rawValue) route=\(bluetoothVoiceTraceRoute) " +
                    "accepted=\(enqueued) first_batch_samples=\(samples.count) " +
                    "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
            )
        }
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel level: Int?) {
        guard let profileID = remoteProfileID(for: bridge) else { return }
        if let level {
            remoteBatteryLevels[profileID] = min(100, max(0, level))
        } else {
            remoteBatteryLevels.removeValue(forKey: profileID)
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didIdentifyRemoteModel model: XiaomiRemoteModel
    ) {
        guard let profileID = remoteProfileID(for: bridge) else { return }
        settings.updateRemoteProfileModel(profileID, model: model)
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didUpdatePowerState state: RemotePowerState?
    ) {
        guard let profileID = remoteProfileID(for: bridge) else { return }
        if let state {
            remotePowerStates[profileID] = state
        } else {
            remotePowerStates.removeValue(forKey: profileID)
        }
    }

    func batteryLevel(for profileID: UUID) -> Int? {
        remoteBatteryLevels[profileID]
    }

    func powerState(for profileID: UUID) -> RemotePowerState? {
        remotePowerStates[profileID]
    }

    func isRemoteConnected(_ profileID: UUID) -> Bool {
        connectedRemoteProfileIDs.contains(profileID)
    }

    private func requestPhoneApproval(
        deviceName: String,
        pairingCode: String,
        identityFingerprint: String?,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "允许“\(deviceName)”连接无线麦？"
            alert.informativeText = "这台 iPhone 将连接“无线麦”App，代替实体遥控器发送按键和按住说话音频。请确认 iPhone 上显示的 2 位校验码与下方一致。允许后，本次安装会成为受信任设备。"
            let codeLabel = NSTextField(labelWithString: pairingCode.map(String.init).joined(separator: " "))
            codeLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
            codeLabel.alignment = .center
            codeLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
            codeLabel.textColor = .controlAccentColor
            codeLabel.setAccessibilityLabel("校验码 \(pairingCode)")
            alert.accessoryView = codeLabel
            alert.addButton(withTitle: "允许连接")
            alert.addButton(withTitle: "拒绝")
            self.phoneApprovalAlert = alert
            let allowed = alert.runModal() == .alertFirstButtonReturn
            guard self.phoneApprovalAlert === alert else {
                completion(false)
                return
            }
            self.phoneApprovalAlert = nil
            if allowed, let identityFingerprint {
                self.settings.trustPhoneIdentity(identityFingerprint)
            }
            completion(allowed)
        }
    }

    private func cancelPhoneApproval() {
        DispatchQueue.main.async {
            guard let alert = self.phoneApprovalAlert else { return }
            self.phoneApprovalAlert = nil
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
    }

    private func requestWebApproval(
        deviceName: String,
        pairingCode: String,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "允许“\(deviceName)”连接网页版？"
            alert.informativeText = "手机浏览器将通过一次性会话控制无线麦。请确认手机上显示的 4 位校验码与下方一致。本次允许不会保存为长期受信任设备。"
            let codeLabel = NSTextField(
                labelWithString: pairingCode.map(String.init).joined(separator: " ")
            )
            codeLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
            codeLabel.alignment = .center
            codeLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
            codeLabel.textColor = .controlAccentColor
            codeLabel.setAccessibilityLabel("校验码 \(pairingCode)")
            alert.accessoryView = codeLabel
            alert.addButton(withTitle: "允许连接")
            alert.addButton(withTitle: "拒绝")
            self.webApprovalAlert = alert
            let allowed = alert.runModal() == .alertFirstButtonReturn
            guard self.webApprovalAlert === alert else {
                completion(false)
                return
            }
            self.webApprovalAlert = nil
            completion(allowed)
        }
    }

    private func cancelWebApproval() {
        DispatchQueue.main.async {
            guard let alert = self.webApprovalAlert else { return }
            self.webApprovalAlert = nil
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
    }

    private func performPhoneCommand(
        _ button: RemoteButton,
        source: UsageEventSource
    ) -> Bool {
        performMobileConfiguredAction(for: button, trigger: .singleClick, source: source)
    }

    private func handleMobileButtonEvent(
        _ button: RemoteButton,
        phase: RemoteButtonPhase,
        source: UsageEventSource
    ) -> Bool {
        let recognizesDoubleClick = settings.configuredAction(
            for: button,
            trigger: .doubleClick
        ).action != .disabled
        let recognizesLongPress = settings.configuredAction(
            for: button,
            trigger: .longPress
        ).action != .disabled

        var recognizer = mobileButtonGestureRecognizers[source] ?? RemoteButtonGestureRecognizer()
        if phase == .press,
           !recognizesDoubleClick,
           !recognizesLongPress,
           !recognizer.isTracking(button) {
            return performMobileConfiguredAction(
                for: button,
                trigger: .singleClick,
                source: source
            )
        }

        let commands = recognizer.handle(
            phase,
            button: button,
            recognizesDoubleClick: recognizesDoubleClick,
            recognizesLongPress: recognizesLongPress
        )
        mobileButtonGestureRecognizers[source] = recognizer
        return processMobileGestureCommands(commands, source: source)
    }

    private func processMobileGestureCommands(
        _ commands: [RemoteButtonGestureRecognizer.Command],
        source: UsageEventSource
    ) -> Bool {
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                scheduleMobileDoubleClickTimeout(for: button, source: source)
            case let .cancelDoubleClickTimeout(button):
                mobileDoubleClickTimers.removeValue(forKey: .init(
                    source: source,
                    button: button
                ))?.cancel()
            case let .scheduleLongPressTimeout(button):
                scheduleMobileLongPressTimeout(for: button, source: source)
            case let .cancelLongPressTimeout(button):
                mobileLongPressTimers.removeValue(forKey: .init(
                    source: source,
                    button: button
                ))?.cancel()
            case let .trigger(button, trigger):
                guard performMobileConfiguredAction(
                    for: button,
                    trigger: trigger,
                    source: source
                ) else { return false }
            }
        }
        return true
    }

    private func scheduleMobileDoubleClickTimeout(
        for button: RemoteButton,
        source: UsageEventSource
    ) {
        let key = MobileButtonGestureKey(source: source, button: button)
        mobileDoubleClickTimers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            mobileDoubleClickTimers.removeValue(forKey: key)
            guard var recognizer = mobileButtonGestureRecognizers[source] else { return }
            let commands = recognizer.doubleClickTimedOut(button)
            mobileButtonGestureRecognizers[source] = recognizer
            _ = processMobileGestureCommands(commands, source: source)
        }
        mobileDoubleClickTimers[key] = timer
        timer.resume()
    }

    private func scheduleMobileLongPressTimeout(
        for button: RemoteButton,
        source: UsageEventSource
    ) {
        let key = MobileButtonGestureKey(source: source, button: button)
        mobileLongPressTimers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(550))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            mobileLongPressTimers.removeValue(forKey: key)
            guard var recognizer = mobileButtonGestureRecognizers[source] else { return }
            let commands = recognizer.longPressTimedOut(button)
            mobileButtonGestureRecognizers[source] = recognizer
            _ = processMobileGestureCommands(commands, source: source)
        }
        mobileLongPressTimers[key] = timer
        timer.resume()
    }

    private func resetMobileButtonGestures(source: UsageEventSource) {
        let doubleClickKeys = mobileDoubleClickTimers.keys.filter { $0.source == source }
        doubleClickKeys.forEach {
            mobileDoubleClickTimers.removeValue(forKey: $0)?.cancel()
        }
        let longPressKeys = mobileLongPressTimers.keys.filter { $0.source == source }
        longPressKeys.forEach {
            mobileLongPressTimers.removeValue(forKey: $0)?.cancel()
        }
        mobileButtonGestureRecognizers.removeValue(forKey: source)
    }

    private func performMobileConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        source: UsageEventSource
    ) -> Bool {
        let configured = settings.configuredAction(for: button, trigger: trigger)
        if configured.action.isAppInternal {
            let handled = performInternalAction(configured.action)
            if handled {
                settings.recordButtonPress(control: .remoteButton(button), source: source)
            }
            AppLogger.shared.write(
                "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                    "action=\(configured.action.rawValue) handled=\(handled)"
            )
            return handled
        }
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        guard KeyboardInjector.send(
            configured.action,
            shortcut: configured.shortcut
        ) else {
            return false
        }
        settings.recordButtonPress(control: .remoteButton(button), source: source)
        AppLogger.shared.write(
            "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "action=\(configured.action.rawValue)"
        )
        return true
    }

    @discardableResult
    private func performInternalAction(_ action: ButtonAction) -> Bool {
        guard action == .toggleLongRecording else { return false }
        guard action.isEnabled(
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ) else {
            AppLogger.shared.write("LONG RECORDING ignored feature_enabled=false")
            return false
        }
        return toggleLongRecording()
    }

    private func toggleLongRecording() -> Bool {
        if longRecordingRequested {
            stopLongRecording(reason: "button_toggle")
            return true
        }
        guard isConnected,
              isAudioOutputReady,
              !bluetoothVoiceActive,
              activeMobileVoiceSource == nil
        else {
            AppLogger.shared.write(
                "LONG RECORDING rejected connected=\(isConnected) audio_ready=\(isAudioOutputReady) " +
                    "bluetooth_voice=\(bluetoothVoiceActive) mobile_voice=\(activeMobileVoiceSource != nil)"
            )
            return false
        }

        longRecordingGeneration &+= 1
        let generation = longRecordingGeneration
        longRecordingRequested = true
        guard let selectedBluetoothBridge,
              selectedBluetoothBridge.requestMicrophoneOpen()
        else {
            finishLongRecording(reason: "open_rejected")
            return false
        }
        scheduleLongRecordingOpenTimeout(generation: generation)
        AppLogger.shared.write("LONG RECORDING opening generation=\(generation)")
        return true
    }

    private func scheduleLongRecordingOpenTimeout(generation: UInt64) {
        longRecordingOpenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingOpenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingRequested,
                  self.longRecordingGeneration == generation,
                  !self.bluetoothVoiceActive
            else { return }
            self.stopLongRecording(reason: "open_timeout")
        }
        longRecordingOpenTimer = timer
        timer.resume()
    }

    private func scheduleLongRecordingTimers(generation: UInt64) {
        longRecordingOpenTimer?.cancel()
        longRecordingOpenTimer = nil
        longRecordingKeepAliveTimer?.cancel()
        longRecordingLimitTimer?.cancel()

        let keepAlive = DispatchSource.makeTimerSource(queue: .main)
        keepAlive.schedule(
            deadline: .now() + Self.longRecordingKeepAliveInterval,
            repeating: Self.longRecordingKeepAliveInterval
        )
        keepAlive.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingRequested,
                  self.longRecordingGeneration == generation,
                  self.bluetoothVoiceActive
            else { return }
            guard self.selectedBluetoothBridge?.requestMicrophoneExtend() == true else {
                self.stopLongRecording(reason: "extend_failed")
                return
            }
        }
        longRecordingKeepAliveTimer = keepAlive
        keepAlive.resume()

        let limit = DispatchSource.makeTimerSource(queue: .main)
        limit.schedule(deadline: .now() + Self.longRecordingMaximumDuration)
        limit.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingRequested,
                  self.longRecordingGeneration == generation
            else { return }
            self.stopLongRecording(reason: "one_minute_limit")
        }
        longRecordingLimitTimer = limit
        limit.resume()
    }

    private func stopLongRecording(reason: String) {
        guard longRecordingRequested else { return }
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        let closeWritten = selectedBluetoothBridge?.requestMicrophoneClose() ?? false
        if bluetoothVoiceActive {
            scheduleLongRecordingCloseTimeout(generation: longRecordingGeneration)
        }
        AppLogger.shared.write(
            "LONG RECORDING stopping reason=\(reason) close_written=\(closeWritten)"
        )
    }

    private func scheduleLongRecordingCloseTimeout(generation: UInt64) {
        longRecordingCloseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingCloseTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingGeneration == generation,
                  !self.longRecordingRequested,
                  self.bluetoothVoiceActive
            else { return }
            self.longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_timeout reconnecting=true")
            self.selectedBluetoothBridge?.reconnectNow()
        }
        longRecordingCloseTimer = timer
        timer.resume()
    }

    private func finishLongRecording(reason: String) {
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        AppLogger.shared.write("LONG RECORDING finished reason=\(reason)")
    }

    private func cancelLongRecordingTimers() {
        longRecordingOpenTimer?.cancel()
        longRecordingOpenTimer = nil
        longRecordingCloseTimer?.cancel()
        longRecordingCloseTimer = nil
        longRecordingKeepAliveTimer?.cancel()
        longRecordingKeepAliveTimer = nil
        longRecordingLimitTimer?.cancel()
        longRecordingLimitTimer = nil
    }

    private func startPhoneVoice(source: MobileVoiceSource) -> Bool {
        guard activeMobileVoiceSource == nil,
              isAudioOutputReady,
              updatePhoneVoiceFunctionKeyState(streaming: true)
        else { return false }
        activeMobileVoiceSource = source
        beginVoiceSessionIfNeeded()
        return true
    }

    private func stopPhoneVoice(source: MobileVoiceSource) {
        guard activeMobileVoiceSource == source else { return }
        audioOutput.endSessionAfterDraining { [weak self] in
            guard let self, self.activeMobileVoiceSource == source else { return }
            self.activeMobileVoiceSource = nil
            self.updatePhoneVoiceFunctionKeyState(streaming: false)
            self.endVoiceSessionIfNeeded()
        }
    }

    private func receivePhoneAudio(_ samples: [Int16], source: MobileVoiceSource) {
        guard activeMobileVoiceSource == source else { return }
        audioOutput.enqueue(samples: samples)
    }

    private func beginVoiceSessionIfNeeded() {
        guard !isStreaming else { return }
        if settings.deepSeekPostDictationEnabled {
            postDictationCoordinator.startSession()
        }
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.blocked_voice_active"),
            logReason: "voice_start"
        )
        let startedAt = Date()
        let source = currentVoiceUsageSource
        settings.recordButtonPress(control: .voice, source: source, at: startedAt)
        voiceSessionStartedAt = startedAt
        voiceSessionUsageSource = source
        isStreaming = true
    }

    private func endVoiceSessionIfNeeded(flushAudio: Bool = true) {
        guard !bluetoothVoiceActive, activeMobileVoiceSource == nil, isStreaming else { return }
        if let voiceSessionStartedAt {
            let endedAt = Date()
            settings.recordVoiceDuration(
                endedAt.timeIntervalSince(voiceSessionStartedAt),
                startedAt: voiceSessionStartedAt,
                source: voiceSessionUsageSource ?? .unknown,
                at: endedAt
            )
            self.voiceSessionStartedAt = nil
        }
        voiceSessionUsageSource = nil
        isStreaming = false
        if flushAudio {
            audioOutput.endSession()
        }
        if settings.deepSeekPostDictationEnabled {
            postDictationCoordinator.finishSession()
        }
    }

    private var currentVoiceUsageSource: UsageEventSource {
        if bluetoothVoiceActive { return .bluetoothRemote }
        switch activeMobileVoiceSource {
        case .nearby: return .nearbyPhone
        case .web: return .webRemote
        case nil: return .unknown
        }
    }

    @discardableResult
    private func applyVoiceFunctionMapping(neutralizeVoiceKey: Bool) -> Bool {
        let applied = voiceFunctionMapper.apply(
            suppressPowerKey: settings.customMappingEnabled,
            neutralizeVoiceKey: neutralizeVoiceKey
        )
        if !isStreaming {
            isVoiceTriggerEnabled = applied
            voiceShortcutStatus = LocalizedMessage(
                applied ? "voice_button.status.fn_enabled" : "voice_button.status.waiting"
            )
        }
        return !settings.customMappingEnabled || voiceFunctionMapper.isPowerKeySuppressed
    }

    @discardableResult
    private func updatePhoneVoiceFunctionKeyState(streaming: Bool) -> Bool {
        guard let transition = phoneVoiceFunctionKeyLatch.transition(streaming: streaming) else {
            return true
        }
        let shouldHold = transition == .press
        guard KeyboardInjector.setFunctionKeyPressed(shouldHold) else {
            phoneVoiceFunctionKeyLatch.rollback(transition)
            AppLogger.shared.write(
                "PHONE VOICE FN \(shouldHold ? "DOWN" : "UP") failed"
            )
            return false
        }
        isVoiceTriggerEnabled = !shouldHold
        voiceShortcutStatus = LocalizedMessage(
            shouldHold ? "voice_button.status.fn_pressed" : "voice_button.status.fn_released"
        )
        AppLogger.shared.write(
            "PHONE VOICE FN \(shouldHold ? "DOWN" : "UP")"
        )
        return true
    }
}
