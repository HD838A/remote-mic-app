import AppKit
import Combine
import CoreAudio
import Foundation

private enum MobileVoiceSource {
    case nearby
    case web
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
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var isAudioOutputReady = false
    @Published private(set) var isPhoneRemoteConnectionEnabled = false
    @Published private(set) var webRemoteState: WebRemoteSessionState = .disabled
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")

    private let audioOutput = VirtualAudioOutput()
    private let phoneRemoteServer = PhoneRemoteServer()
    private let webRemoteClient = WebRemoteRelayClient()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
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
    private lazy var bluetoothBridge = XiaomiBluetoothBridge(settings: settings, delegate: self)
    private lazy var hidMonitor: HIDRemoteMonitor = {
        let monitor = HIDRemoteMonitor(settings: settings)
        monitor.onStatus = { [weak self] value in
            self?.hidStatus = value
        }
        monitor.onActiveButtons = { [weak self] buttons in
            self?.activeRemoteButtons = buttons
        }
        monitor.onButtonPressed = { [weak self] button in
            self?.settings.recordButtonPress(
                control: .remoteButton(button),
                source: .bluetoothRemote
            )
        }
        monitor.onInternalAction = { [weak self] action in
            self?.performInternalAction(action)
        }
        return monitor
    }()
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
        bluetoothBridge.stop()
        phoneRemoteServer.stop()
        webRemoteClient.stop()
        isPhoneRemoteConnectionEnabled = false
        webRemoteState = .disabled
        bluetoothVoiceActive = false
        activeMobileVoiceSource = nil
        voiceSessionUsageSource = nil
        updatePhoneVoiceFunctionKeyState(streaming: false)
        hidMonitor.stop()
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
        bluetoothBridge.reconnectNow()
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
                self.bluetoothBridge.start()
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
        hidMonitor.start(powerKeySuppressed: powerKeySuppressed)
        hidStatus = hidMonitor.status
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
            hidMonitor.start(powerKeySuppressed: powerKeySuppressed)
            hidStatus = hidMonitor.status
            return
        }
        settings.voiceFnTapModeEnabled = true
        voiceFnTapSession.setEnabled(true)
        hidMonitor.start(powerKeySuppressed: powerKeySuppressed)
        hidStatus = hidMonitor.status
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

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didChange state: BluetoothBridgeState
    ) {
        connectionStatus = state.message
        isConnected = {
            if case .ready = state { return true }
            return false
        }()
        if case .ready = state {
            voiceFnTapSession.resume()
            applyHIDSettings()
        } else {
            let voiceWasActive = bluetoothVoiceActive
            bluetoothVoiceActive = false
            voiceFnTapSession.suspend()
            if voiceWasActive {
                endVoiceSessionIfNeeded(flushAudio: false)
            }
            if longRecordingRequested {
                finishLongRecording(reason: "bluetooth_not_ready")
            }
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        bluetoothVoiceActive = true
        if longRecordingRequested {
            scheduleLongRecordingTimers(generation: longRecordingGeneration)
            AppLogger.shared.write("LONG RECORDING started")
        }
        _ = voiceFnTapSession.startVoice()
        beginVoiceSessionIfNeeded()
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        bluetoothVoiceActive = false
        if longRecordingRequested {
            finishLongRecording(reason: "remote_stop")
        } else if longRecordingCloseTimer != nil {
            longRecordingCloseTimer?.cancel()
            longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_confirmed")
        }
        let handledByFnTapMode = voiceFnTapSession.stopVoice()
        endVoiceSessionIfNeeded(flushAudio: !handledByFnTapMode)
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        if !voiceFnTapSession.receive(samples) {
            audioOutput.enqueue(samples: samples)
        }
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
        let action = settings.action(for: button)
        if action.isAppInternal {
            let handled = performInternalAction(action)
            if handled {
                settings.recordButtonPress(control: .remoteButton(button), source: source)
            }
            AppLogger.shared.write(
                "PHONE REMOTE button=\(button.rawValue) action=\(action.rawValue) handled=\(handled)"
            )
            return handled
        }
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        guard KeyboardInjector.send(action, shortcut: settings.shortcut(for: button)) else {
            return false
        }
        settings.recordButtonPress(control: .remoteButton(button), source: source)
        AppLogger.shared.write(
            "PHONE REMOTE button=\(button.rawValue) action=\(action.rawValue)"
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
        guard bluetoothBridge.requestMicrophoneOpen() else {
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
            guard self.bluetoothBridge.requestMicrophoneExtend() else {
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
        let closeWritten = bluetoothBridge.requestMicrophoneClose()
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
            self.bluetoothBridge.reconnectNow()
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
