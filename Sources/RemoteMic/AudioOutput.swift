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

extension VirtualAudioDeviceDiagnosticKind {
    static func classify(_ device: AudioDeviceInfo?) -> Self {
        guard let device else { return .unavailable }
        if device.uid == "MiRemoteV2ch_UID" || device.name == "MiRemoteV 2ch" {
            return .miRemoteV2ch
        }
        if device.uid == "BlackHole2ch_UID" || device.name == "BlackHole 2ch" {
            return .blackHole2ch
        }
        return .other
    }
}

extension VirtualAudioOutputDiagnosticSnapshot {
    var configurationHealthy: Bool {
        VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: selectedDeviceKind != .unavailable,
            engineRunning: engineRunning,
            playerPlaying: playerPlaying,
            boundToSelectedDevice: boundToSelectedDevice == true
        )
    }
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

enum VirtualAudioRecoveryPolicy {
    static func shouldIgnoreDefaultSystemOutputChange(
        details: String,
        configurationHealthy: Bool
    ) -> Bool {
        details == "properties=default_system_output" && configurationHealthy
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
}

final class VirtualAudioOutput {
    private struct PendingDeliveryCounters {
        var buffers = 0
        var samples = 0
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var engineConfigurationGeneration: UInt64 = 0
    private var rejectedWriteCount = 0
    private var lastRejectedWriteLogDate = Date.distantPast
    private let playbackLock = NSLock()
    private var pendingVoiceBufferCount = 0
    private var pendingVoiceSampleCount = 0
    private var playbackGeneration: UInt64 = 0
    private var playbackCounters = VirtualAudioPlaybackCounters()
    private var playbackCountersByDeliveryGeneration: [Int: VirtualAudioPlaybackCounters] = [:]
    private var pendingByDeliveryGeneration: [Int: PendingDeliveryCounters] = [:]
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

    /// Counts one buffer as queued for playback. Together with
    /// `scheduledVoiceBufferDidFinish` this drives the pending-buffer count that
    /// draining waits on, so it is the single seam a test can use to arm drain
    /// bookkeeping without a live output device.
    func registerPendingVoiceBuffer() {
        playbackLock.lock()
        pendingVoiceBufferCount += 1
        playbackLock.unlock()
    }

    var pendingVoiceBufferCountForDiagnostics: Int {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        return pendingVoiceBufferCount
    }

    var hasAllocatedOutputResources: Bool {
        engine != nil || player != nil || selectedDevice != nil
    }

    var isConfigurationHealthyForDiagnostics: Bool {
        isConfigurationHealthy
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
    func enqueue(samples: [Int16], deliveryGeneration: Int = 0) -> Bool {
        guard !samples.isEmpty else {
            logRejectedWrite(reason: "empty_samples")
            return false
        }
        guard let player else {
            logRejectedWrite(reason: "player_missing")
            return false
        }
        guard isPlaybackReady else {
            logRejectedWrite(reason: "playback_not_ready")
            return false
        }
        guard let buffer = makeBuffer(samples: samples) else {
            logRejectedWrite(reason: "buffer_creation_failed")
            return false
        }
        if rejectedWriteCount > 0 {
            AppLogger.shared.write("AUDIO WRITE resumed rejected_count=\(rejectedWriteCount) state={\(basicDiagnosticState())}")
            rejectedWriteCount = 0
        }
        playbackLock.lock()
        let generation = playbackGeneration
        let sampleCount = samples.count
        pendingVoiceBufferCount += 1
        pendingVoiceSampleCount += sampleCount
        playbackCounters.scheduledBuffers += 1
        playbackCounters.scheduledSamples += sampleCount
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].scheduledBuffers += 1
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].scheduledSamples += sampleCount
        pendingByDeliveryGeneration[deliveryGeneration, default: .init()].buffers += 1
        pendingByDeliveryGeneration[deliveryGeneration, default: .init()].samples += sampleCount
        playbackLock.unlock()
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.scheduledVoiceBufferDidFinish(
                sampleCount: sampleCount,
                generation: generation,
                deliveryGeneration: deliveryGeneration
            )
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
        // One slot only, so a new request must hand the previous waiter back rather than
        // overwrite (and silently lose) it. Invoked after the new drain is armed.
        let displacedCompletion = drainCompletion
        drainCompletion = shouldCompleteImmediately ? nil : completion
        playbackLock.unlock()
        defer { displacedCompletion?() }

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
        playbackCounters.interruptedBuffers += pendingVoiceBufferCount
        playbackCounters.interruptedSamples += pendingVoiceSampleCount
        recordPendingDeliveriesAsInterrupted()
        pendingVoiceBufferCount = 0
        pendingVoiceSampleCount = 0
        playbackGeneration &+= 1
        pendingDrainLogContexts.removeAll()
        // Taken before the teardown below so a nested `stop()` cannot pick it up a second
        // time, and invoked afterwards so it never runs against a half-restarted player.
        // An interruption is an outcome and must answer the waiter exactly once: dropping
        // it here strands the caller on a drain that can never report back, because the
        // fallback timer armed by `endSessionAfterDraining` is invalidated by the
        // generation bump below.
        let interruptedDrain = drainCompletion
        drainCompletion = nil
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        defer { interruptedDrain?() }
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
        playbackCounters.interruptedBuffers += pendingVoiceBufferCount
        playbackCounters.interruptedSamples += pendingVoiceSampleCount
        recordPendingDeliveriesAsInterrupted()
        pendingVoiceBufferCount = 0
        pendingVoiceSampleCount = 0
        playbackGeneration &+= 1
        pendingDrainLogContexts.removeAll()
        // Same contract as flushPlayer: stopping answers the drain waiter exactly
        // once, after the teardown below, instead of dropping it with the
        // generation bump.
        let interruptedDrain = drainCompletion
        drainCompletion = nil
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        defer { interruptedDrain?() }
        removeEngineConfigurationObserver()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        selectedDevice = nil
    }

    private func scheduledVoiceBufferDidFinish(
        sampleCount: Int,
        generation: UInt64,
        deliveryGeneration: Int
    ) {
        var completion: (() -> Void)?
        var completionGeneration: UInt64?
        var drainedContexts: [String] = []
        playbackLock.lock()
        guard generation == playbackGeneration else {
            playbackLock.unlock()
            return
        }
        pendingVoiceBufferCount = max(0, pendingVoiceBufferCount - 1)
        pendingVoiceSampleCount = max(0, pendingVoiceSampleCount - sampleCount)
        playbackCounters.playedBuffers += 1
        playbackCounters.playedSamples += sampleCount
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].playedBuffers += 1
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].playedSamples += sampleCount
        if var pending = pendingByDeliveryGeneration[deliveryGeneration] {
            pending.buffers = max(0, pending.buffers - 1)
            pending.samples = max(0, pending.samples - sampleCount)
            if pending.buffers == 0 && pending.samples == 0 {
                pendingByDeliveryGeneration.removeValue(forKey: deliveryGeneration)
            } else {
                pendingByDeliveryGeneration[deliveryGeneration] = pending
            }
        }
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

    func diagnosticSnapshot(deliveryGeneration: Int? = nil) -> VirtualAudioOutputDiagnosticSnapshot {
        let actualOutput = currentOutputDevice()
        let boundToSelected: Bool?
        if let selectedDevice, let actualOutput {
            boundToSelected = selectedDevice.id == actualOutput.id
        } else {
            boundToSelected = nil
        }
        playbackLock.lock()
        let pendingBuffers: Int
        let pendingSamples: Int
        let counters: VirtualAudioPlaybackCounters
        if let deliveryGeneration {
            let pending = pendingByDeliveryGeneration[deliveryGeneration] ?? .init()
            pendingBuffers = pending.buffers
            pendingSamples = pending.samples
            counters = playbackCountersByDeliveryGeneration[deliveryGeneration] ?? .init()
            pruneDeliveryDiagnostics(keeping: deliveryGeneration)
        } else {
            pendingBuffers = pendingVoiceBufferCount
            pendingSamples = pendingVoiceSampleCount
            counters = playbackCounters
        }
        playbackLock.unlock()
        return VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .classify(selectedDevice),
            actualDeviceKind: .classify(actualOutput),
            engineRunning: engine?.isRunning == true,
            playerPlaying: player?.isPlaying == true,
            boundToSelectedDevice: boundToSelected,
            pendingBuffers: pendingBuffers,
            pendingSamples: pendingSamples,
            counters: counters
        )
    }

    private func recordPendingDeliveriesAsInterrupted() {
        for (generation, pending) in pendingByDeliveryGeneration {
            playbackCountersByDeliveryGeneration[generation, default: .init()].interruptedBuffers += pending.buffers
            playbackCountersByDeliveryGeneration[generation, default: .init()].interruptedSamples += pending.samples
        }
        pendingByDeliveryGeneration.removeAll(keepingCapacity: true)
    }

    private func pruneDeliveryDiagnostics(keeping generation: Int) {
        guard playbackCountersByDeliveryGeneration.count > 32 else { return }
        let minimumGeneration = max(0, generation - 16)
        playbackCountersByDeliveryGeneration = playbackCountersByDeliveryGeneration.filter {
            $0.key >= minimumGeneration || pendingByDeliveryGeneration[$0.key] != nil
        }
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

    private func logRejectedWrite(reason: String) {
        rejectedWriteCount += 1
        let now = Date()
        guard now.timeIntervalSince(lastRejectedWriteLogDate) >= 1 else { return }
        lastRejectedWriteLogDate = now
        AppLogger.shared.write(
            "AUDIO WRITE rejected count=\(rejectedWriteCount) reason=\(reason) " +
                "state={\(diagnosticState())}"
        )
    }
}
