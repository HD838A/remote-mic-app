import AppKit
import Combine
import CoreAudio
import Foundation

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    let settings = AppSettings()

    @Published private(set) var connectionStatus = LocalizedMessage("正在初始化蓝牙")
    @Published private(set) var hidStatus = LocalizedMessage("按键映射未启用")
    @Published private(set) var audioStatus = LocalizedMessage("未选择语音输出设备")
    @Published private(set) var doubaoAudioStatus = LocalizedMessage("正在检查豆包兼容音频设备")
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    @Published private(set) var isVoiceTriggerEnabled = false
    @Published private(set) var activeRemoteButtons = Set<RemoteButton>()
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = LocalizedMessage("未选择语音输出设备")
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("正在准备遥控器 Fn 硬件映射")

    private let audioOutput = VirtualAudioOutput()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private var testToneGeneration = 0
    private var voiceFunctionKeyLatch = VoiceFunctionKeyLatch()
    private lazy var bluetoothBridge = XiaomiBluetoothBridge(settings: settings, delegate: self)
    private lazy var hidMonitor: HIDRemoteMonitor = {
        let monitor = HIDRemoteMonitor(settings: settings)
        monitor.onStatus = { [weak self] value in
            self?.hidStatus = value
        }
        monitor.onActiveButtons = { [weak self] buttons in
            self?.activeRemoteButtons = buttons
        }
        return monitor
    }()
    private var started = false
    private var terminationObserver: NSObjectProtocol?
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
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        refreshAudioDevices()
        applyAudioSettings(reason: "startup")
        startObservingAudioHardware()
        applyHIDSettings()
        applyVoiceFunctionMapping()
        bluetoothBridge.start()
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
        audioRecoveryGeneration &+= 1
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        stopObservingAudioHardware()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("应用已停止"),
            logReason: "app_stop"
        )
        bluetoothBridge.stop()
        updateVoiceFunctionKeyState(streaming: false)
        hidMonitor.stop()
        audioOutput.stop()
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

    func refreshAudioDevices() {
        audioDevices = CoreAudioDeviceCatalog.outputDevices()
        doubaoAudioStatus = DoubaoAudioDevicePolicy.status(in: audioDevices)
        AppLogger.shared.write(
            "AUDIO DEVICES refreshed outputs={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(audioDevices))} " +
                "\(CoreAudioDeviceCatalog.routeDiagnostic())"
        )
    }

    var hasDoubaoAudioDevice: Bool {
        DoubaoAudioDevicePolicy.device(in: audioDevices) != nil
    }

    func selectDoubaoAudioDevice() {
        guard let device = DoubaoAudioDevicePolicy.device(in: audioDevices) else {
            doubaoAudioStatus = LocalizedMessage(
                "未检测到 %@，请先安装兼容驱动",
                arguments: [DoubaoAudioDevicePolicy.deviceName]
            )
            return
        }
        settings.selectedAudioDeviceUID = device.uid
        applyAudioSettings(reason: "doubao_device_selected")
        doubaoAudioStatus = LocalizedMessage(
            "已选择 %@ 作为遥控器语音输出",
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
            statusMessage: LocalizedMessage("设备已更新，测试音已取消"),
            logReason: "device_reconfigure"
        )
        let configured = audioOutput.configure(deviceUID: settings.selectedAudioDeviceUID)
        audioStatus = audioOutput.status
        testToneStatus = audioOutput.isReadyForTestTone
            ? LocalizedMessage("可发送测试音")
            : LocalizedMessage("未选择语音输出设备或设备不可用")
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
            hasSelectedDevice: audioOutput.isReadyForTestTone,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: audioOutput.isReadyForTestTone,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        ) else {
            if isStreaming {
                testToneStatus = LocalizedMessage("RC003 语音进行中，已拒绝测试音")
                AppLogger.shared.write("AUDIO TEST_TONE rejected_streaming")
            } else if isPlayingTestTone {
                testToneStatus = LocalizedMessage("测试音正在播放中")
            } else {
                testToneStatus = LocalizedMessage("未选择语音输出设备或设备不可用")
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
            testToneStatus = LocalizedMessage("测试音发送失败：设备未就绪")
            return
        }
        isPlayingTestTone = true
        testToneStatus = LocalizedMessage("正在播放约 1 秒测试音")
        AppLogger.shared.write("AUDIO TEST_TONE played")
    }

    private func handleTestToneCompletion(generation: Int, finished: Bool) {
        guard generation == testToneGeneration, isPlayingTestTone else { return }
        isPlayingTestTone = false
        testToneStatus = LocalizedMessage(finished ? "测试音已完成" : "测试音已取消")
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
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("RC003 语音进行中，已拒绝测试音"),
            logReason: "voice_start"
        )
        updateVoiceFunctionKeyState(streaming: true)
        isStreaming = true
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        updateVoiceFunctionKeyState(streaming: false)
        isStreaming = false
        audioOutput.endSession()
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        audioOutput.enqueue(samples: samples)
    }

    private func applyVoiceFunctionMapping() {
        let applied = voiceFunctionMapper.apply()
        guard !isStreaming else { return }
        isVoiceTriggerEnabled = applied
        voiceShortcutStatus = LocalizedMessage(
            applied ? "遥控器语音键已硬件映射为 Fn" : "等待遥控器 Fn 硬件映射"
        )
    }

    private func updateVoiceFunctionKeyState(streaming: Bool) {
        guard let transition = voiceFunctionKeyLatch.transition(streaming: streaming) else { return }
        let shouldHold = transition == .press
        isVoiceTriggerEnabled = !shouldHold
        voiceShortcutStatus = LocalizedMessage(
            shouldHold ? "硬件 Fn 已按下；松开语音键即释放" : "硬件 Fn 已释放"
        )
        AppLogger.shared.write(
            "VOICE FN HARDWARE \(shouldHold ? "DOWN" : "UP") " +
                "mapping=\(voiceFunctionMapper.isApplied)"
        )
    }
}
