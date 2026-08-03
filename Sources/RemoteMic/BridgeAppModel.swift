import AppKit
import Combine
import CoreAudio
import Foundation

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
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
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")

    private let audioOutput = VirtualAudioOutput()
    private let phoneRemoteServer = PhoneRemoteServer()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private var testToneGeneration = 0
    private var phoneVoiceFunctionKeyLatch = VoiceFunctionKeyLatch()
    private var voiceSessionStartedAt: Date?
    private var bluetoothVoiceActive = false
    private var phoneVoiceActive = false
    private var phoneApprovalAlert: NSAlert?
    private lazy var bluetoothBridge = XiaomiBluetoothBridge(settings: settings, delegate: self)
    private lazy var hidMonitor: HIDRemoteMonitor = {
        let monitor = HIDRemoteMonitor(settings: settings)
        monitor.onStatus = { [weak self] value in
            self?.hidStatus = value
        }
        monitor.onActiveButtons = { [weak self] buttons in
            self?.activeRemoteButtons = buttons
        }
        monitor.onButtonPressed = { [weak self] _ in
            self?.settings.recordButtonPress()
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
                completion(self?.performPhoneCommand(button) ?? false)
            }
        }
        phoneRemoteServer.onVoiceStart = { [weak self] completion in
            DispatchQueue.main.async {
                completion(self?.startPhoneVoice() ?? false)
            }
        }
        phoneRemoteServer.onVoiceStop = { [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice()
            }
        }
        phoneRemoteServer.onAudio = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples)
            }
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        startAudioSubsystem()
        applyHIDSettings()
        applyVoiceFunctionMapping()
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
        bluetoothBridge.stop()
        phoneRemoteServer.stop()
        isPhoneRemoteConnectionEnabled = false
        bluetoothVoiceActive = false
        phoneVoiceActive = false
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
        requestNextHIDPermissionIfNeeded()
        hidMonitor.start()
        hidStatus = hidMonitor.status
    }

    private func requestNextHIDPermissionIfNeeded() {
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
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
            applyVoiceFunctionMapping()
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        bluetoothVoiceActive = true
        beginVoiceSessionIfNeeded()
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        bluetoothVoiceActive = false
        endVoiceSessionIfNeeded()
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        audioOutput.enqueue(samples: samples)
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

    private func performPhoneCommand(_ button: RemoteButton) -> Bool {
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        let action = settings.action(for: button)
        guard KeyboardInjector.send(action, shortcut: settings.shortcut(for: button)) else {
            return false
        }
        settings.recordButtonPress()
        AppLogger.shared.write(
            "PHONE REMOTE button=\(button.rawValue) action=\(action.rawValue)"
        )
        return true
    }

    private func startPhoneVoice() -> Bool {
        guard isAudioOutputReady,
              updatePhoneVoiceFunctionKeyState(streaming: true)
        else { return false }
        phoneVoiceActive = true
        beginVoiceSessionIfNeeded()
        return true
    }

    private func stopPhoneVoice() {
        phoneVoiceActive = false
        updatePhoneVoiceFunctionKeyState(streaming: false)
        endVoiceSessionIfNeeded()
    }

    private func receivePhoneAudio(_ samples: [Int16]) {
        guard phoneVoiceActive else { return }
        audioOutput.enqueue(samples: samples)
    }

    private func beginVoiceSessionIfNeeded() {
        guard !isStreaming else { return }
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.blocked_voice_active"),
            logReason: "voice_start"
        )
        settings.recordButtonPress()
        voiceSessionStartedAt = Date()
        isStreaming = true
    }

    private func endVoiceSessionIfNeeded() {
        guard !bluetoothVoiceActive, !phoneVoiceActive, isStreaming else { return }
        if let voiceSessionStartedAt {
            settings.recordVoiceDuration(Date().timeIntervalSince(voiceSessionStartedAt))
            self.voiceSessionStartedAt = nil
        }
        isStreaming = false
        audioOutput.endSession()
    }

    private func applyVoiceFunctionMapping() {
        let applied = voiceFunctionMapper.apply()
        guard !isStreaming else { return }
        isVoiceTriggerEnabled = applied
        voiceShortcutStatus = LocalizedMessage(
            applied ? "voice_button.status.fn_enabled" : "voice_button.status.waiting"
        )
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
