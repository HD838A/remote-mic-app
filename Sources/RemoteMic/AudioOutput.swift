import AVFoundation
import AudioExceptionGuard
import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioPlayerNodeSafety {
    static func play(_ player: AVAudioPlayerNode) -> Bool {
        RemoteMicTryPlayAudioPlayerNode(player)
    }
}

enum CoreAudioDeviceCatalog {
    private static let propertyLock = NSRecursiveLock()

    static func outputDevices() -> [AudioDeviceInfo] {
        withPropertyLock {
            devicesLocked(scope: kAudioDevicePropertyScopeOutput)
        }
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        withPropertyLock {
            devicesLocked(scope: kAudioDevicePropertyScopeInput)
        }
    }

    private static func devicesLocked(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        let result = deviceIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard result == noErr else { return [] }

        var seenUIDs = Set<String>()
        return deviceIDs.compactMap { deviceID in
            guard channelCount(for: deviceID, scope: scope) > 0 else { return nil }
            return deviceInfo(for: deviceID)
        }
        .filter { seenUIDs.insert($0.uid).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func deviceInfo(for deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        withPropertyLock {
            guard deviceID != kAudioObjectUnknown,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name)
        }
    }

    static func routeDiagnostic() -> String {
        withPropertyLock {
            let input = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
            let output = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
            let systemOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            return "default_input={\(deviceDiagnostic(input))} " +
                "default_output={\(deviceDiagnostic(output))} " +
                "default_system_output={\(deviceDiagnostic(systemOutput))}"
        }
    }

    static func defaultInputDevice() -> AudioDeviceInfo? {
        withPropertyLock {
            defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        }
    }

    static func setDefaultInputDevice(_ device: AudioDeviceInfo) -> OSStatus {
        withPropertyLock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID = device.id
            return AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &deviceID
            )
        }
    }

    static func preferredFallbackInput(excludingUID excludedUID: String) -> AudioDeviceInfo? {
        let devices = inputDevices()
        let builtInDeviceIDs = Set(devices.compactMap { device in
            transportType(for: device.id) == kAudioDeviceTransportTypeBuiltIn ? device.id : nil
        })
        return DefaultInputFallbackPolicy.preferredFallback(
            in: devices,
            excludingUID: excludedUID,
            builtInDeviceIDs: builtInDeviceIDs
        )
    }

    static func outputDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        devices.map(deviceDiagnostic).joined(separator: " | ")
    }

    static func deviceDiagnostic(_ device: AudioDeviceInfo?) -> String {
        guard let device else { return "none" }
        return "name=\(device.name) id=\(device.id)"
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceInfo(for: deviceID)
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(for deviceID: AudioDeviceID) -> AudioDevicePropertyID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType = AudioDevicePropertyID(0)
        var size = UInt32(MemoryLayout<AudioDevicePropertyID>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transportType
        ) == noErr else { return nil }
        return transportType
    }

    private static func withPropertyLock<T>(_ operation: () -> T) -> T {
        propertyLock.lock()
        defer { propertyLock.unlock() }
        return operation()
    }
}

enum SystemAudioSuspensionReason: String, Hashable {
    case screenSleeping = "screen_sleeping"
    case sessionInactive = "session_inactive"
    case systemSleeping = "system_sleeping"
}

enum SystemAudioLifecycleEvent: String {
    case screenDidSleep = "screen_did_sleep"
    case screenDidWake = "screen_did_wake"
    case sessionDidResignActive = "session_did_resign_active"
    case sessionDidBecomeActive = "session_did_become_active"
    case systemWillSleep = "system_will_sleep"
    case systemDidWake = "system_did_wake"

    var suspensionReason: SystemAudioSuspensionReason {
        switch self {
        case .screenDidSleep, .screenDidWake:
            return .screenSleeping
        case .sessionDidResignActive, .sessionDidBecomeActive:
            return .sessionInactive
        case .systemWillSleep, .systemDidWake:
            return .systemSleeping
        }
    }

    var isSuspending: Bool {
        switch self {
        case .screenDidSleep, .sessionDidResignActive, .systemWillSleep:
            return true
        case .screenDidWake, .sessionDidBecomeActive, .systemDidWake:
            return false
        }
    }
}

struct SystemAudioSuspensionState {
    private(set) var reasons = Set<SystemAudioSuspensionReason>()

    var isSuspended: Bool {
        !reasons.isEmpty
    }

    var diagnostic: String {
        let values = reasons.map(\.rawValue).sorted()
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    @discardableResult
    mutating func apply(_ event: SystemAudioLifecycleEvent) -> Bool {
        if event.isSuspending {
            return reasons.insert(event.suspensionReason).inserted
        }
        return reasons.remove(event.suspensionReason) != nil
    }
}

enum VirtualAudioConnectionLifecyclePolicy {
    static func shouldBeActive(
        readyBluetoothBridgeCount: Int,
        bluetoothVoiceActive: Bool,
        mobileVoiceActive: Bool,
        testToneActive: Bool,
        systemSuspended: Bool
    ) -> Bool {
        if bluetoothVoiceActive || mobileVoiceActive || testToneActive {
            return true
        }
        return readyBluetoothBridgeCount > 0 && !systemSuspended
    }

    static func shouldScheduleRelease(
        hasPendingRelease: Bool,
        hasAllocatedOutputResources: Bool,
        pendingVoiceBufferCount: Int
    ) -> Bool {
        !hasPendingRelease && (hasAllocatedOutputResources || pendingVoiceBufferCount > 0)
    }
}

enum VirtualAudioHealthPolicy {
    static func isPlaybackReady(
        hasSelectedDevice: Bool,
        engineRunning: Bool,
        playerPlaying: Bool
    ) -> Bool {
        hasSelectedDevice && engineRunning && playerPlaying
    }

    static func isConfigurationHealthy(
        hasSelectedDevice: Bool,
        engineRunning: Bool,
        playerPlaying: Bool,
        boundToSelectedDevice: Bool
    ) -> Bool {
        isPlaybackReady(
            hasSelectedDevice: hasSelectedDevice,
            engineRunning: engineRunning,
            playerPlaying: playerPlaying
        ) && boundToSelectedDevice
    }
}

enum DefaultInputFallbackPolicy {
    static func preferredFallback(
        in devices: [AudioDeviceInfo],
        excludingUID excludedUID: String,
        builtInDeviceIDs: Set<AudioDeviceID>
    ) -> AudioDeviceInfo? {
        let candidates = devices.filter { $0.uid != excludedUID }
        return candidates.first { builtInDeviceIDs.contains($0.id) } ?? candidates.first
    }

    static func shouldRestoreVirtualInput(
        managedVirtualUID: String,
        selectedVirtualUID: String,
        managedFallbackUID: String,
        currentDefaultUID: String?
    ) -> Bool {
        managedVirtualUID == selectedVirtualUID && currentDefaultUID == managedFallbackUID
    }

    static func shouldActivateQianwenInput(
        modeEnabled: Bool,
        managedVirtualUID: String,
        selectedVirtualUID: String,
        managedFallbackUID: String,
        currentDefaultUID: String?
    ) -> Bool {
        modeEnabled &&
            managedVirtualUID == selectedVirtualUID &&
            currentDefaultUID == managedFallbackUID
    }

    static func shouldRestoreQianwenFallback(
        managedVirtualUID: String,
        currentDefaultUID: String?
    ) -> Bool {
        currentDefaultUID == managedVirtualUID
    }

    static func shouldReleaseQianwenManagement(
        managedVirtualUID: String,
        managedFallbackUID: String,
        currentDefaultUID: String?,
        virtualAudioActive: Bool
    ) -> Bool {
        currentDefaultUID != managedVirtualUID &&
            (currentDefaultUID != managedFallbackUID || virtualAudioActive)
    }
}

final class VirtualAudioOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var engineConfigurationGeneration: UInt64 = 0
    private var rejectedWriteCount = 0
    private var lastRejectedWriteLogDate = Date.distantPast
    private let playbackLock = NSLock()
    private var pendingVoiceBufferCount = 0
    private var pendingDrainLogContexts: [String] = []
    private var drainCompletion: (() -> Void)?
    private var drainGeneration: UInt64 = 0
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var status = LocalizedMessage("audio.output.none_selected")
    var onConfigurationChange: (() -> Void)?

    var pendingVoiceBufferCountForDiagnostics: Int {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        return pendingVoiceBufferCount
    }

    var hasAllocatedOutputResources: Bool {
        engine != nil || player != nil || selectedDevice != nil
    }

    @discardableResult
    func configure(deviceUID: String) -> Bool {
        let previousState = diagnosticState()
        stop()
        guard !deviceUID.isEmpty else {
            status = LocalizedMessage("audio.output.none_selected")
            AppLogger.shared.write("AUDIO CONFIGURE skipped reason=no_selected_device previous={\(previousState)}")
            return false
        }
        let availableDevices = CoreAudioDeviceCatalog.outputDevices()
        guard let device = availableDevices.first(where: { $0.uid == deviceUID }) else {
            status = LocalizedMessage("audio.output.selected_unavailable")
            AppLogger.shared.write(
                "AUDIO CONFIGURE failed reason=selected_device_unavailable " +
                    "available={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(availableDevices))}"
            )
            return false
        }
        AppLogger.shared.write(
            "AUDIO CONFIGURE begin target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                "previous={\(previousState)}"
        )

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)

        guard let outputUnit = engine.outputNode.audioUnit else {
            status = LocalizedMessage("audio.output.core_audio_open_failed")
            AppLogger.shared.write("AUDIO CONFIGURE failed reason=no_output_unit target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}")
            return false
        }
        var deviceID = device.id
        let result = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard result == noErr else {
            status = LocalizedMessage("audio.output.select_failed", arguments: [String(result)])
            AppLogger.shared.write(
                "AUDIO CONFIGURE failed reason=set_current_device " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                    AppLogger.errorFields(domain: "os_status", code: Int(result))
            )
            return false
        }

        do {
            engine.prepare()
            try engine.start()
            guard AudioPlayerNodeSafety.play(player) else {
                player.stop()
                engine.stop()
                status = LocalizedMessage("audio.output.selected_unavailable")
                AppLogger.shared.write(
                    "AUDIO ERROR player_start_exception " +
                        "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
                )
                return false
            }
            self.engine = engine
            self.player = player
            selectedDevice = device
            observeConfigurationChanges(for: engine)
            status = LocalizedMessage("audio.output.current_format", arguments: [device.name])
            AppLogger.shared.write("AUDIO READY target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} state={\(diagnosticState())}")
            return true
        } catch {
            status = LocalizedMessage(
                "audio.output.start_failed",
                arguments: [error.localizedDescription]
            )
            AppLogger.shared.write(
                "AUDIO ERROR start_failed " + AppLogger.errorFields(error) + " " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} state={\(diagnosticState())}"
            )
            return false
        }
    }

    var isReadyForTestTone: Bool {
        isConfigurationHealthy
    }

    /// Schedules the test tone and reports actual playback completion via `scheduleBuffer`'s
    /// `.dataPlayedBack` callback rather than a fixed timer. `completion` receives `true` only
    /// when the tone finished sounding; `false` if it was cut short (device torn down, real
    /// voice preempted it, etc.). Returns `false` immediately if scheduling never happened.
    @discardableResult
    func playTestTone(completion: @escaping (Bool) -> Void) -> Bool {
        guard isReadyForTestTone,
              let player,
              let buffer = makeBuffer(samples: TestToneGenerator.samples(sampleRate: sourceFormat.sampleRate))
        else { return false }
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { callbackType in
            completion(callbackType == .dataPlayedBack)
        }
        return true
    }

    /// Flushes any buffer currently queued on the player node (including an in-flight test
    /// tone) so real RC003 voice audio scheduled right after this call is not delayed behind it.
    func cancelTestTone() {
        flushPlayer()
    }

    private func makeBuffer(samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        for index in samples.indices {
            channel[index] = Float(samples[index]) / Float(Int16.max)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    @discardableResult
    func enqueue(samples: [Int16]) -> Bool {
        guard isPlaybackReady,
              let player,
              let buffer = makeBuffer(samples: samples)
        else {
            logRejectedWrite()
            return false
        }
        if rejectedWriteCount > 0 {
            AppLogger.shared.write("AUDIO WRITE resumed rejected_count=\(rejectedWriteCount) state={\(basicDiagnosticState())}")
            rejectedWriteCount = 0
        }
        playbackLock.lock()
        pendingVoiceBufferCount += 1
        playbackLock.unlock()
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.scheduledVoiceBufferDidFinish()
        }
        return true
    }

    func endSession() {
        flushPlayer()
    }

    func endSessionAfterDraining(
        maximumDelay: TimeInterval = 0.75,
        completion: @escaping () -> Void
    ) {
        playbackLock.lock()
        drainGeneration &+= 1
        let generation = drainGeneration
        let shouldCompleteImmediately = pendingVoiceBufferCount == 0
        if !shouldCompleteImmediately {
            drainCompletion = completion
        }
        playbackLock.unlock()

        if shouldCompleteImmediately {
            flushPlayer()
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumDelay) { [weak self] in
            self?.finishDrainIfNeeded(generation: generation, completion: completion)
        }
    }

    func cancelPendingDrain() {
        playbackLock.lock()
        drainCompletion = nil
        drainGeneration &+= 1
        playbackLock.unlock()
    }

    func logWhenPendingVoiceAudioDrains(context: String) {
        playbackLock.lock()
        let alreadyDrained = pendingVoiceBufferCount == 0
        if !alreadyDrained {
            pendingDrainLogContexts.append(context)
        }
        playbackLock.unlock()
        if alreadyDrained {
            AppLogger.shared.write("AUDIO PLAYBACK drained \(context) pending_buffers=0")
        }
    }

    private func flushPlayer() {
        playbackLock.lock()
        let interruptedContexts = pendingVoiceBufferCount > 0 ? pendingDrainLogContexts : []
        pendingVoiceBufferCount = 0
        pendingDrainLogContexts.removeAll()
        drainCompletion = nil
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        guard let player, engine?.isRunning == true else { return }
        player.stop()
        player.reset()
        guard AudioPlayerNodeSafety.play(player) else {
            AppLogger.shared.write("AUDIO ERROR player_restart_exception state={\(diagnosticState())}")
            stop()
            onConfigurationChange?()
            return
        }
    }

    func stop() {
        playbackLock.lock()
        let interruptedContexts = pendingVoiceBufferCount > 0 ? pendingDrainLogContexts : []
        pendingVoiceBufferCount = 0
        pendingDrainLogContexts.removeAll()
        drainCompletion = nil
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        removeEngineConfigurationObserver()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        selectedDevice = nil
    }

    private func scheduledVoiceBufferDidFinish() {
        var completion: (() -> Void)?
        var completionGeneration: UInt64?
        var drainedContexts: [String] = []
        playbackLock.lock()
        pendingVoiceBufferCount = max(0, pendingVoiceBufferCount - 1)
        if pendingVoiceBufferCount == 0 {
            drainedContexts = pendingDrainLogContexts
            pendingDrainLogContexts.removeAll()
            completion = drainCompletion
            drainCompletion = nil
            if completion != nil {
                completionGeneration = drainGeneration
            }
        }
        playbackLock.unlock()
        for context in drainedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK drained \(context) pending_buffers=0")
        }
        guard let completion, let completionGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            self?.finishDrainedSessionIfNeeded(
                generation: completionGeneration,
                completion: completion
            )
        }
    }

    private func finishDrainedSessionIfNeeded(
        generation: UInt64,
        completion: @escaping () -> Void
    ) {
        playbackLock.lock()
        let shouldFinish = generation == drainGeneration
        if shouldFinish {
            drainGeneration &+= 1
        }
        playbackLock.unlock()
        guard shouldFinish else { return }
        flushPlayer()
        completion()
    }

    private func finishDrainIfNeeded(generation: UInt64, completion: @escaping () -> Void) {
        playbackLock.lock()
        let shouldFinish = generation == drainGeneration && drainCompletion != nil
        if shouldFinish {
            drainCompletion = nil
            pendingVoiceBufferCount = 0
            drainGeneration &+= 1
        }
        playbackLock.unlock()
        guard shouldFinish else { return }
        flushPlayer()
        completion()
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        engineConfigurationGeneration &+= 1
        let generation = engineConfigurationGeneration
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self,
                  let engine,
                  self.engine === engine,
                  self.engineConfigurationGeneration == generation
            else { return }
            if self.isConfigurationHealthy {
                AppLogger.shared.write(
                    "AUDIO ENGINE configuration_ignored generation=\(generation) reason=healthy"
                )
                return
            }
            AppLogger.shared.write("AUDIO ENGINE configuration_changed generation=\(generation)")
            self.onConfigurationChange?()
        }
    }

    private func removeEngineConfigurationObserver() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        engineConfigurationGeneration &+= 1
    }

    func diagnosticState() -> String {
        let actualOutput = currentOutputDevice()
        let isBound: String
        if let selectedDevice, let actualOutput {
            isBound = selectedDevice.id == actualOutput.id ? "true" : "false"
        } else {
            isBound = "unknown"
        }
        return "\(basicDiagnosticState()) " +
            "actual_output={\(CoreAudioDeviceCatalog.deviceDiagnostic(actualOutput))} " +
            "bound_to_selected=\(isBound) \(CoreAudioDeviceCatalog.routeDiagnostic())"
    }

    private func basicDiagnosticState() -> String {
        "engine_running=\(engine?.isRunning == true) player_playing=\(player?.isPlaying == true) " +
            "selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(selectedDevice))}"
    }

    private var isPlaybackReady: Bool {
        VirtualAudioHealthPolicy.isPlaybackReady(
            hasSelectedDevice: selectedDevice != nil,
            engineRunning: engine?.isRunning == true,
            playerPlaying: player?.isPlaying == true
        )
    }

    private var isConfigurationHealthy: Bool {
        let actualOutput = currentOutputDevice()
        return VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: selectedDevice != nil,
            engineRunning: engine?.isRunning == true,
            playerPlaying: player?.isPlaying == true,
            boundToSelectedDevice: selectedDevice?.id == actualOutput?.id
        )
    }

    private func currentOutputDevice() -> AudioDeviceInfo? {
        guard let outputUnit = engine?.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        ) == noErr else { return nil }
        return CoreAudioDeviceCatalog.deviceInfo(for: deviceID)
    }

    private func logRejectedWrite() {
        rejectedWriteCount += 1
        let now = Date()
        guard now.timeIntervalSince(lastRejectedWriteLogDate) >= 1 else { return }
        lastRejectedWriteLogDate = now
        AppLogger.shared.write("AUDIO WRITE rejected count=\(rejectedWriteCount) state={\(basicDiagnosticState())}")
    }
}
