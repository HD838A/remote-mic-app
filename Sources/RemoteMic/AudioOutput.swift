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

struct VirtualAudioDeviceLevelObservation: Equatable {
    var mute: Bool?
    var volume: Float32?

    var requiresAudibilityRepair: Bool {
        VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: mute) ||
            VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: volume)
    }
}

struct VirtualAudioDeviceAudibilitySnapshot: Equatable {
    var output = VirtualAudioDeviceLevelObservation()
    var input = VirtualAudioDeviceLevelObservation()

    var requiresAudibilityRepair: Bool {
        output.requiresAudibilityRepair || input.requiresAudibilityRepair
    }

    var hasObservation: Bool {
        output.mute != nil || output.volume != nil || input.mute != nil || input.volume != nil
    }

    var diagnostic: String {
        "output_mute=\(Self.optionalBoolean(output.mute)) " +
            "output_volume_scalar=\(Self.optionalScalar(output.volume)) " +
            "output_volume_low=\(Self.optionalBoolean(output.volume.map { VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: $0) })) " +
            "input_mute=\(Self.optionalBoolean(input.mute)) " +
            "input_volume_scalar=\(Self.optionalScalar(input.volume)) " +
            "input_volume_low=\(Self.optionalBoolean(input.volume.map { VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: $0) })) " +
            "minimum_volume_scalar=\(VirtualAudioDeviceLevelPolicy.minimumUsableVolume)"
    }

    private static func optionalBoolean(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private static func optionalScalar(_ value: Float32?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        let rounded = (Double(value) * 1_000).rounded() / 1_000
        return String(rounded)
    }
}

struct VirtualAudioDeviceAudibilityRepairResult: Equatable {
    var applicable = false
    var before = VirtualAudioDeviceAudibilitySnapshot()
    var after = VirtualAudioDeviceAudibilitySnapshot()
    var unmuteAttempted = false
    var volumeRestoreAttempted = false
    var writeFailed = false

    var isReady: Bool {
        !applicable || (
            !after.requiresAudibilityRepair &&
                (!before.requiresAudibilityRepair || after.hasObservation)
        )
    }
}

enum VirtualAudioDeviceLevelPolicy {
    static let minimumUsableVolume: Float32 = 0.2

    static func requiresUnmute(mute: Bool?) -> Bool {
        mute == true
    }

    static func requiresVolumeRestore(volume: Float32?) -> Bool {
        guard let volume, volume.isFinite else { return false }
        return volume < minimumUsableVolume
    }
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

enum VirtualAudioSelectionRecoverySource: String, Equatable {
    case currentSelection = "current_selection"
    case rememberedSelection = "remembered_selection"
    case uniqueHistoricalCandidate = "unique_historical_candidate"
    case none
}

enum VirtualAudioSelectionRecoveryReason: String, Equatable {
    case noHistory = "no_history"
    case rememberedDeviceUnavailable = "remembered_device_unavailable"
    case noSupportedCandidate = "no_supported_candidate"
    case multipleSupportedCandidates = "multiple_supported_candidates"
}

struct VirtualAudioSelectionRecoveryDecision: Equatable {
    let uid: String?
    let source: VirtualAudioSelectionRecoverySource
    let reason: VirtualAudioSelectionRecoveryReason?
    let kind: VirtualAudioDeviceDiagnosticKind
    let supportedCandidateCount: Int
}

enum VirtualAudioSelectionRecoveryPolicy {
    static func resolve(
        selectedUID: String,
        rememberedUID: String,
        availableDevices: [AudioDeviceInfo],
        hasHistoricalConfiguration: Bool
    ) -> VirtualAudioSelectionRecoveryDecision {
        let supported = availableDevices.filter {
            switch VirtualAudioDeviceDiagnosticKind.classify($0) {
            case .miRemoteV2ch, .blackHole2ch: return true
            case .other, .unavailable: return false
            }
        }

        if !selectedUID.isEmpty {
            let selectedDevice = availableDevices.first { $0.uid == selectedUID }
            return VirtualAudioSelectionRecoveryDecision(
                uid: selectedUID,
                source: .currentSelection,
                reason: nil,
                kind: VirtualAudioDeviceDiagnosticKind.classify(selectedDevice),
                supportedCandidateCount: supported.count
            )
        }

        if !rememberedUID.isEmpty {
            let rememberedDevice = availableDevices.first { $0.uid == rememberedUID }
            return VirtualAudioSelectionRecoveryDecision(
                uid: rememberedDevice?.uid,
                source: rememberedDevice == nil ? .none : .rememberedSelection,
                reason: rememberedDevice == nil ? .rememberedDeviceUnavailable : nil,
                kind: VirtualAudioDeviceDiagnosticKind.classify(rememberedDevice),
                supportedCandidateCount: supported.count
            )
        }

        guard hasHistoricalConfiguration else {
            return VirtualAudioSelectionRecoveryDecision(
                uid: nil,
                source: .none,
                reason: .noHistory,
                kind: .unavailable,
                supportedCandidateCount: supported.count
            )
        }
        guard supported.count == 1, let candidate = supported.first else {
            return VirtualAudioSelectionRecoveryDecision(
                uid: nil,
                source: .none,
                reason: supported.isEmpty ? .noSupportedCandidate : .multipleSupportedCandidates,
                kind: .unavailable,
                supportedCandidateCount: supported.count
            )
        }
        return VirtualAudioSelectionRecoveryDecision(
            uid: candidate.uid,
            source: .uniqueHistoricalCandidate,
            reason: nil,
            kind: VirtualAudioDeviceDiagnosticKind.classify(candidate),
            supportedCandidateCount: supported.count
        )
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

enum VirtualAudioDrainOutcome: String, Equatable {
    case normal
    case forced
}

enum CoreAudioDeviceCatalog {
    private static let propertyLock = NSRecursiveLock()

    private static let virtualAudioScopes: [AudioObjectPropertyScope] = [
        kAudioDevicePropertyScopeOutput,
        kAudioDevicePropertyScopeInput,
    ]

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
        .filter(shouldPresentToUser)
        .filter { seenUIDs.insert($0.uid).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// AVAudioEngine can publish a process-private aggregate while an engine is
    /// alive. It is a routing implementation detail, not a user-selectable
    /// device. Keep it out of settings and onboarding lists.
    static func shouldPresentToUser(_ device: AudioDeviceInfo) -> Bool {
        !device.uid.hasPrefix("CADefaultDeviceAggregate-")
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

    static func preferredFallbackInput(
        excludingUID excludedUID: String,
        preferredUID: String? = nil
    ) -> AudioDeviceInfo? {
        let devices = inputDevices()
        let builtInDeviceIDs = Set(devices.compactMap { device in
            transportType(for: device.id) == kAudioDeviceTransportTypeBuiltIn ? device.id : nil
        })
        return DefaultInputFallbackPolicy.preferredFallback(
            in: devices,
            excludingUID: excludedUID,
            builtInDeviceIDs: builtInDeviceIDs,
            preferredUID: preferredUID
        )
    }

    static func outputDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        devices.map(deviceDiagnostic).joined(separator: " | ")
    }

    static func deviceDiagnostic(_ device: AudioDeviceInfo?) -> String {
        guard let device else { return "none" }
        return "name=\(device.name) id=\(device.id)"
    }

    static func virtualAudioAudibilitySnapshot(
        for device: AudioDeviceInfo?
    ) -> VirtualAudioDeviceAudibilitySnapshot {
        guard let device else { return .init() }
        let kind = VirtualAudioDeviceDiagnosticKind.classify(device)
        guard kind == .miRemoteV2ch || kind == .blackHole2ch else { return .init() }
        return withPropertyLock {
            virtualAudioAudibilitySnapshotLocked(for: device.id)
        }
    }

    static func ensureVirtualAudioDeviceAudible(
        _ device: AudioDeviceInfo
    ) -> VirtualAudioDeviceAudibilityRepairResult {
        let kind = VirtualAudioDeviceDiagnosticKind.classify(device)
        guard kind == .miRemoteV2ch || kind == .blackHole2ch else {
            return .init()
        }

        return withPropertyLock {
            let before = virtualAudioAudibilitySnapshotLocked(for: device.id)
            var result = VirtualAudioDeviceAudibilityRepairResult(
                applicable: true,
                before: before,
                after: before
            )

            for scope in virtualAudioScopes {
                let observation = deviceLevelObservationLocked(for: device.id, scope: scope)
                if VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: observation.mute) {
                    result.unmuteAttempted = true
                    if !setUInt32PropertyLocked(
                        device.id,
                        selector: kAudioDevicePropertyMute,
                        scope: scope,
                        value: 0
                    ) {
                        result.writeFailed = true
                    }
                }
                if VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: observation.volume) {
                    result.volumeRestoreAttempted = true
                    if !setFloat32PropertyLocked(
                        device.id,
                        selector: kAudioDevicePropertyVolumeScalar,
                        scope: scope,
                        value: 1
                    ) {
                        result.writeFailed = true
                    }
                }
            }

            result.after = virtualAudioAudibilitySnapshotLocked(for: device.id)
            return result
        }
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

    private static func virtualAudioAudibilitySnapshotLocked(
        for deviceID: AudioDeviceID
    ) -> VirtualAudioDeviceAudibilitySnapshot {
        VirtualAudioDeviceAudibilitySnapshot(
            output: deviceLevelObservationLocked(
                for: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            ),
            input: deviceLevelObservationLocked(
                for: deviceID,
                scope: kAudioDevicePropertyScopeInput
            )
        )
    }

    private static func deviceLevelObservationLocked(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> VirtualAudioDeviceLevelObservation {
        VirtualAudioDeviceLevelObservation(
            mute: uint32PropertyLocked(
                deviceID,
                selector: kAudioDevicePropertyMute,
                scope: scope
            ).map { $0 != 0 },
            volume: float32PropertyLocked(
                deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope
            )
        )
    }

    private static func uint32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func float32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func setUInt32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(objectID, &address),
              AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var mutableValue = value
        return AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        ) == noErr
    }

    private static func setFloat32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: Float32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(objectID, &address),
              AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var mutableValue = value
        return AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableValue
        ) == noErr
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

/// Whether a debounced `AVAudioEngineConfigurationChange` still needs recovery.
///
/// Reconfiguring the engine emits the same notification as a real route failure. A correctly
/// bound but idle output can therefore create a self-sustaining rebind loop if the stopped engine
/// alone is treated as damage. Active delivery and queued tail audio are different: when either
/// exists, an unhealthy engine still has user audio to protect and must retain the existing
/// recovery behavior.
enum AudioEngineConfigurationChangePolicy {
    static func needsRecovery(
        boundToSelectedDevice: Bool?,
        configurationHealthy: Bool,
        hasActiveAudioSource: Bool,
        pendingVoiceBufferCount: Int
    ) -> Bool {
        guard boundToSelectedDevice == true else { return true }
        if configurationHealthy { return false }
        return hasActiveAudioSource || pendingVoiceBufferCount > 0
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
    enum ObservationDecision: Equatable {
        case ignore
        case clearManagedTransition
        case remember(uid: String, clearManagedTransition: Bool)
    }

    static func preferredFallback(
        in devices: [AudioDeviceInfo],
        excludingUID excludedUID: String,
        builtInDeviceIDs: Set<AudioDeviceID>,
        preferredUID: String? = nil
    ) -> AudioDeviceInfo? {
        let candidates = devices.filter { $0.uid != excludedUID }
        if let preferredUID,
           let preferred = candidates.first(where: { $0.uid == preferredUID }) {
            return preferred
        }
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

    static func observationDecision(
        currentUID: String?,
        selectedVirtualUID: String,
        managedFallbackUID: String?,
        lastRememberedUID: String?
    ) -> ObservationDecision {
        guard let currentUID,
              currentUID != selectedVirtualUID,
              currentUID != managedFallbackUID
        else { return .ignore }
        if currentUID == lastRememberedUID {
            return managedFallbackUID == nil ? .ignore : .clearManagedTransition
        }
        return .remember(
            uid: currentUID,
            clearManagedTransition: managedFallbackUID != nil
        )
    }
}

final class VirtualAudioOutput {
    private struct OutputState {
        var ready = false
        var healthy = false
        var engineRunning = false
        var playerPlaying = false
        var selectedDevice: AudioDeviceInfo?
        var actualDevice: AudioDeviceInfo?
        var status = LocalizedMessage("audio.output.none_selected")
        var route = "default_input={unknown} default_output={unknown} default_system_output={unknown}"
    }

    private struct PendingDeliveryCounters {
        var buffers = 0
        var samples = 0
    }

    private struct DrainRequest {
        let source: String
        let operationID: UInt64
        let startedAtUptime: TimeInterval
        let requestedOnMainThread: Bool
        let completion: (VirtualAudioDrainOutcome) -> Void
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
    private var drainRequests: [DrainRequest] = []
    private var drainGeneration: UInt64 = 0
    private var nextDrainOperationID: UInt64 = 0
    private let logger: (String) -> Void
    private let uptime: () -> TimeInterval
    private let engineQueue: DispatchQueue
    private let engineQueueKey = DispatchSpecificKey<Void>()
    private var nextConfigurationOperationID: UInt64 = 0
    private let outputStateLock = NSLock()
    private var outputState = OutputState()
    private var cachedOutputState: OutputState {
        outputStateLock.lock()
        defer { outputStateLock.unlock() }
        return outputState
    }

    // This lock protects values only. Never hold it across AVAudioEngine or HAL calls.
    private func updateOutputState(_ update: (inout OutputState) -> Void) {
        outputStateLock.lock()
        update(&outputState)
        outputStateLock.unlock()
    }
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    var selectedDevice: AudioDeviceInfo? { cachedOutputState.selectedDevice }
    private(set) var status: LocalizedMessage {
        get { cachedOutputState.status }
        set { updateOutputState { $0.status = newValue } }
    }
    var onConfigurationChange: (() -> Void)?

    init(
        logger: @escaping (String) -> Void = { AppLogger.shared.write($0) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        engineQueue: DispatchQueue = DispatchQueue(
            label: "RemoteMic.audioOutput.engine",
            qos: .userInitiated
        )
    ) {
        self.logger = logger
        self.uptime = uptime
        self.engineQueue = engineQueue
        engineQueue.setSpecific(key: engineQueueKey, value: ())
    }

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
        cachedOutputState.selectedDevice != nil
    }

    var isConfigurationHealthyForDiagnostics: Bool {
        cachedOutputState.healthy
    }

    func configureAsync(deviceUID: String, completion: @escaping (Bool) -> Void) {
        playbackLock.lock()
        nextConfigurationOperationID &+= 1
        let operationID = nextConfigurationOperationID
        playbackLock.unlock()
        let requestedAt = uptime()
        logger("AUDIO CONFIGURE operation_id=\(operationID) phase=requested result=pending queue=audio_output")
        engineQueue.async { [weak self] in
            guard let self else { return }
            let startedAt = self.uptime()
            self.logger(
                "AUDIO CONFIGURE operation_id=\(operationID) phase=started result=pending queue=audio_output " +
                    "queue_wait_ms=\(max(0, Int((startedAt - requestedAt) * 1_000)))"
            )
            let configured = self.configureOnEngineQueue(deviceUID: deviceUID, operationID: operationID)
            self.logger(
                "AUDIO CONFIGURE operation_id=\(operationID) phase=completed " +
                    "result=\(configured ? "ready" : "failed") reason=\(configured ? "ready" : "configure_failed") " +
                    "status_key=\(self.status.key) queue=audio_output " +
                    "elapsed_ms=\(max(0, Int((self.uptime() - requestedAt) * 1_000)))"
            )
            completion(configured)
        }
    }

    @discardableResult
    private func configureOnEngineQueue(deviceUID: String, operationID: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let startedAtUptime = uptime()
        let elapsedMilliseconds = {
            max(0, Int((self.uptime() - startedAtUptime) * 1_000))
        }
        let logStage = { (stage: String) in
            self.logger(
                "AUDIO CONFIGURE operation_id=\(operationID) phase=applying result=pending " +
                    "stage=\(stage) queue=audio_output elapsed_ms=\(elapsedMilliseconds())"
            )
        }
        let previousState = diagnosticState()
        logStage("stop_previous")
        stopOnEngineQueue()
        guard !deviceUID.isEmpty else {
            status = LocalizedMessage("audio.output.none_selected")
            logger(
                "AUDIO CONFIGURE skipped reason=no_selected_device queue=audio_output " +
                    "elapsed_ms=\(elapsedMilliseconds()) previous={\(previousState)}"
            )
            return false
        }
        logStage("enumerate_devices")
        let availableDevices = CoreAudioDeviceCatalog.outputDevices()
        guard let device = availableDevices.first(where: { $0.uid == deviceUID }) else {
            status = LocalizedMessage("audio.output.selected_unavailable")
            logger(
                "AUDIO CONFIGURE failed reason=selected_device_unavailable " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "available={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(availableDevices))}"
            )
            return false
        }
        logger(
            "AUDIO CONFIGURE begin queue=audio_output target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                "elapsed_ms=\(elapsedMilliseconds()) " +
                "previous={\(previousState)}"
        )

        logStage("repair_audibility")
        let audibilityRepair = CoreAudioDeviceCatalog.ensureVirtualAudioDeviceAudible(device)
        if audibilityRepair.applicable {
            logger(
                "AUDIO AUDIBILITY repair " +
                    "device_kind=\(VirtualAudioDeviceDiagnosticKind.classify(device).rawValue) " +
                    "unmute_attempted=\(audibilityRepair.unmuteAttempted) " +
                    "volume_restore_attempted=\(audibilityRepair.volumeRestoreAttempted) " +
                    "write_failed=\(audibilityRepair.writeFailed) " +
                    "before={\(audibilityRepair.before.diagnostic)} " +
                    "after={\(audibilityRepair.after.diagnostic)} " +
                    "result=\(audibilityRepair.isReady ? "ready" : "below_minimum")"
            )
        }
        guard audibilityRepair.isReady else {
            status = LocalizedMessage("audio.output.selected_unavailable")
            logger(
                "AUDIO CONFIGURE failed reason=virtual_device_level_below_minimum " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "device_kind=\(VirtualAudioDeviceDiagnosticKind.classify(device).rawValue)"
            )
            return false
        }

        logStage("connect_mixer")
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)

        logStage("open_output_unit")
        guard let outputUnit = engine.outputNode.audioUnit else {
            status = LocalizedMessage("audio.output.core_audio_open_failed")
            logger(
                "AUDIO CONFIGURE failed reason=no_output_unit queue=audio_output " +
                    "elapsed_ms=\(elapsedMilliseconds()) target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
            )
            return false
        }
        var deviceID = device.id
        logStage("select_device")
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
            logger(
                "AUDIO CONFIGURE failed reason=set_current_device " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                    AppLogger.errorFields(domain: "os_status", code: Int(result))
            )
            return false
        }

        do {
            logStage("prepare_engine")
            engine.prepare()
            logStage("start_engine")
            try engine.start()
            logStage("start_player")
            guard AudioPlayerNodeSafety.play(player) else {
                player.stop()
                engine.stop()
                status = LocalizedMessage("audio.output.selected_unavailable")
                logger(
                    "AUDIO ERROR player_start_exception " +
                        "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                        "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
                )
                return false
            }
            self.engine = engine
            self.player = player
            updateOutputState { $0.selectedDevice = device }
            logStage("verify_output")
            refreshOutputStateOnEngineQueue()
            guard isReadyForTestTone else {
                status = LocalizedMessage("audio.output.selected_unavailable")
                return false
            }
            observeConfigurationChanges(for: engine)
            status = LocalizedMessage("audio.output.current_format", arguments: [device.name])
            logger(
                "AUDIO READY target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                    "elapsed_ms=\(elapsedMilliseconds()) " +
                    "queue=audio_output state={\(diagnosticState())}"
            )
            return true
        } catch {
            status = LocalizedMessage(
                "audio.output.start_failed",
                arguments: [error.localizedDescription]
            )
            logger(
                "AUDIO ERROR start_failed " + AppLogger.errorFields(error) + " " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} state={\(diagnosticState())}"
            )
            return false
        }
    }

    var isReadyForTestTone: Bool {
        cachedOutputState.ready
    }

    /// Schedules the test tone and reports actual playback completion via `scheduleBuffer`'s
    /// `.dataPlayedBack` callback rather than a fixed timer. `completion` receives `true` only
    /// when the tone finished sounding; `false` if it was cut short (device torn down, real
    /// voice preempted it, etc.). Returns `false` immediately if scheduling never happened.
    @discardableResult
    func playTestTone(completion: @escaping (Bool) -> Void) -> Bool {
        guard isReadyForTestTone else { return false }
        engineQueue.async { [weak self] in
            guard let self,
                  let player = self.player,
                  let buffer = self.makeBuffer(samples: TestToneGenerator.samples(sampleRate: self.sourceFormat.sampleRate))
            else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack
            ) { callbackType in
                completion(callbackType == .dataPlayedBack)
            }
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
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.playbackLock.lock()
            let isCurrent = generation == self.playbackGeneration
            self.playbackLock.unlock()
            // A preceding stop or explicit flush already accounted for an interrupted buffer.
            guard isCurrent, let player = self.player else { return }
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
        }
        return true
    }

    func endSession() {
        flushPlayer()
    }

    func endSessionAfterDraining(
        source: String = "unspecified",
        operationID: UInt64? = nil,
        maximumDelay: TimeInterval? = 0.75,
        completion: @escaping () -> Void
    ) {
        endSessionAfterDraining(
            source: source,
            operationID: operationID,
            maximumDelay: maximumDelay
        ) { _ in
            completion()
        }
    }

    func endSessionAfterDraining(
        source: String = "unspecified",
        operationID: UInt64? = nil,
        maximumDelay: TimeInterval? = 0.75,
        completion: @escaping (VirtualAudioDrainOutcome) -> Void
    ) {
        playbackLock.lock()
        nextDrainOperationID &+= 1
        let resolvedOperationID = operationID ?? nextDrainOperationID
        let request = DrainRequest(
            source: source,
            operationID: resolvedOperationID,
            startedAtUptime: uptime(),
            requestedOnMainThread: Thread.isMainThread,
            completion: completion
        )
        let shouldCompleteImmediately = pendingVoiceBufferCount == 0
        let wasWaiting = !drainRequests.isEmpty
        let pendingBuffers = pendingVoiceBufferCount
        let pendingSamples = pendingVoiceSampleCount
        let generation: UInt64?
        if shouldCompleteImmediately {
            // A completion already waiting for the main queue owns the zero-pending transition.
            // Append to it instead of flushing a newly queued session or invoking early.
            drainRequests.append(request)
            generation = nil
        } else {
            if !wasWaiting {
                drainGeneration &+= 1
            }
            drainRequests.append(request)
            generation = drainGeneration
        }
        playbackLock.unlock()

        logger(
            "AUDIO DRAIN operation_id=\(resolvedOperationID) source=\(source) " +
                "phase=requested result=pending pending_buffers=\(pendingBuffers) " +
                "pending_samples=\(pendingSamples) timeout_ms=\(Self.milliseconds(maximumDelay)) " +
                "joined_existing=\(wasWaiting)"
        )

        if shouldCompleteImmediately && !wasWaiting {
            playbackLock.lock()
            let requests = drainRequests
            drainRequests.removeAll(keepingCapacity: true)
            drainGeneration &+= 1
            playbackLock.unlock()
            completeDrainRequests(
                requests,
                outcome: .normal,
                phase: "completed",
                result: "normal",
                reason: "no_pending",
                pendingBuffers: 0,
                pendingSamples: 0
            )
            return
        }
        if let maximumDelay, let generation {
            DispatchQueue.main.asyncAfter(deadline: .now() + maximumDelay) { [weak self] in
                self?.finishDrainIfNeeded(generation: generation)
            }
        }
    }

    func cancelPendingDrain() {
        playbackLock.lock()
        let cancelledRequests = drainRequests
        let pendingBuffers = pendingVoiceBufferCount
        let pendingSamples = pendingVoiceSampleCount
        drainRequests.removeAll(keepingCapacity: true)
        drainGeneration &+= 1
        playbackLock.unlock()
        logDrainRequests(
            cancelledRequests,
            phase: "cancelled",
            result: "cancelled",
            reason: "explicit_cancel",
            pendingBuffers: pendingBuffers,
            pendingSamples: pendingSamples
        )
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
        let interruptedBuffers = pendingVoiceBufferCount
        let interruptedSamples = pendingVoiceSampleCount
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
        let interruptedDrains = drainRequests
        drainRequests.removeAll(keepingCapacity: true)
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        defer {
            completeDrainRequests(
                interruptedDrains,
                outcome: .forced,
                phase: "completed",
                result: "forced",
                reason: "player_flush",
                pendingBuffers: 0,
                pendingSamples: 0,
                interruptedBuffers: interruptedBuffers,
                interruptedSamples: interruptedSamples
            )
        }
        let restartPlayer = { [weak self] in
            guard let self,
                  let player = self.player,
                  self.engine?.isRunning == true
            else { return }
            player.stop()
            player.reset()
            guard AudioPlayerNodeSafety.play(player) else {
                AppLogger.shared.write("AUDIO ERROR player_restart_exception state={\(self.diagnosticState())}")
                self.stopOnEngineQueue()
                self.onConfigurationChange?()
                return
            }
        }
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil {
            restartPlayer()
        } else {
            engineQueue.async(execute: restartPlayer)
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil {
            stopOnEngineQueue()
        } else if Thread.isMainThread {
            updateOutputState {
                $0.ready = false
                $0.healthy = false
                $0.engineRunning = false
                $0.playerPlaying = false
            }
            engineQueue.async { [weak self] in
                self?.stopOnEngineQueue()
            }
        } else {
            engineQueue.sync {
                stopOnEngineQueue()
            }
        }
    }

    private func stopOnEngineQueue() {
        playbackLock.lock()
        let interruptedContexts = pendingVoiceBufferCount > 0 ? pendingDrainLogContexts : []
        let interruptedBuffers = pendingVoiceBufferCount
        let interruptedSamples = pendingVoiceSampleCount
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
        let interruptedDrains = drainRequests
        drainRequests.removeAll(keepingCapacity: true)
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        defer {
            completeDrainRequests(
                interruptedDrains,
                outcome: .forced,
                phase: "completed",
                result: "forced",
                reason: "output_stop",
                pendingBuffers: 0,
                pendingSamples: 0,
                interruptedBuffers: interruptedBuffers,
                interruptedSamples: interruptedSamples
            )
        }
        removeEngineConfigurationObserver()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        updateOutputState {
            $0.selectedDevice = nil
            $0.actualDevice = nil
            $0.ready = false
            $0.healthy = false
            $0.engineRunning = false
            $0.playerPlaying = false
        }
    }

    private func scheduledVoiceBufferDidFinish(
        sampleCount: Int,
        generation: UInt64,
        deliveryGeneration: Int
    ) {
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
            if !drainRequests.isEmpty {
                completionGeneration = drainGeneration
            }
        }
        playbackLock.unlock()
        for context in drainedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK drained \(context) pending_buffers=0")
        }
        guard let completionGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            self?.finishDrainedSessionIfNeeded(
                generation: completionGeneration
            )
        }
    }

    private func finishDrainedSessionIfNeeded(
        generation: UInt64
    ) {
        playbackLock.lock()
        let shouldFinish = generation == drainGeneration && pendingVoiceBufferCount == 0
        let requests = shouldFinish ? drainRequests : []
        if shouldFinish {
            drainRequests.removeAll(keepingCapacity: true)
            drainGeneration &+= 1
        }
        playbackLock.unlock()
        guard shouldFinish else { return }
        completeDrainRequests(
            requests,
            outcome: .normal,
            phase: "completed",
            result: "normal",
            reason: "buffers_drained",
            pendingBuffers: 0,
            pendingSamples: 0
        )
    }

    private func finishDrainIfNeeded(generation: UInt64) {
        playbackLock.lock()
        let shouldFinish = generation == drainGeneration && !drainRequests.isEmpty
        let requests = shouldFinish ? drainRequests : []
        let pendingBuffers = pendingVoiceBufferCount
        let pendingSamples = pendingVoiceSampleCount
        if shouldFinish {
            drainRequests.removeAll(keepingCapacity: true)
            drainGeneration &+= 1
        }
        playbackLock.unlock()
        guard shouldFinish else { return }
        flushPlayer()
        completeDrainRequests(
            requests,
            outcome: .forced,
            phase: "completed",
            result: "forced",
            reason: "deadline",
            pendingBuffers: 0,
            pendingSamples: 0,
            interruptedBuffers: pendingBuffers,
            interruptedSamples: pendingSamples
        )
    }

    private func completeDrainRequests(
        _ requests: [DrainRequest],
        outcome: VirtualAudioDrainOutcome,
        phase: String,
        result: String,
        reason: String,
        pendingBuffers: Int,
        pendingSamples: Int,
        interruptedBuffers: Int = 0,
        interruptedSamples: Int = 0
    ) {
        logDrainRequests(
            requests,
            phase: phase,
            result: result,
            reason: reason,
            pendingBuffers: pendingBuffers,
            pendingSamples: pendingSamples,
            interruptedBuffers: interruptedBuffers,
            interruptedSamples: interruptedSamples
        )
        requests.forEach { request in
            guard request.requestedOnMainThread, !Thread.isMainThread else {
                request.completion(outcome)
                return
            }
            DispatchQueue.main.async {
                request.completion(outcome)
            }
        }
    }

    private func logDrainRequests(
        _ requests: [DrainRequest],
        phase: String,
        result: String,
        reason: String,
        pendingBuffers: Int,
        pendingSamples: Int,
        interruptedBuffers: Int = 0,
        interruptedSamples: Int = 0
    ) {
        let now = uptime()
        for request in requests {
            let elapsedMilliseconds = max(0, Int((now - request.startedAtUptime) * 1_000))
            logger(
                "AUDIO DRAIN operation_id=\(request.operationID) source=\(request.source) " +
                    "phase=\(phase) result=\(result) reason=\(reason) " +
                    "elapsed_ms=\(elapsedMilliseconds) pending_buffers=\(pendingBuffers) " +
                    "pending_samples=\(pendingSamples) interrupted_buffers=\(interruptedBuffers) " +
                    "interrupted_samples=\(interruptedSamples)"
            )
        }
    }

    private static func milliseconds(_ interval: TimeInterval?) -> Int {
        guard let interval else { return -1 }
        return max(0, Int(interval * 1_000))
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        engineConfigurationGeneration &+= 1
        let generation = engineConfigurationGeneration
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            self?.engineQueue.async { [weak self, weak engine] in
                guard let self,
                      let engine,
                      self.engine === engine,
                      self.engineConfigurationGeneration == generation
                else { return }
                self.refreshOutputStateOnEngineQueue()
                self.logger(
                    "AUDIO ENGINE configuration_changed generation=\(generation) " +
                        "phase=observed result=pending queue=audio_output"
                )
                self.onConfigurationChange?()
            }
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
        let state = cachedOutputState
        let isBound: String
        if let selectedDevice = state.selectedDevice, let actualOutput = state.actualDevice {
            isBound = selectedDevice.id == actualOutput.id ? "true" : "false"
        } else {
            isBound = "unknown"
        }
        return "engine_running=\(state.engineRunning) player_playing=\(state.playerPlaying) " +
            "selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(state.selectedDevice))} " +
            "actual_output={\(CoreAudioDeviceCatalog.deviceDiagnostic(state.actualDevice))} " +
            "bound_to_selected=\(isBound) \(state.route)"
    }

    func diagnosticSnapshot(deliveryGeneration: Int? = nil) -> VirtualAudioOutputDiagnosticSnapshot {
        let state = cachedOutputState
        let boundToSelected: Bool?
        if let selectedDevice = state.selectedDevice, let actualOutput = state.actualDevice {
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
            selectedDeviceKind: .classify(state.selectedDevice),
            actualDeviceKind: .classify(state.actualDevice),
            engineRunning: state.engineRunning,
            playerPlaying: state.playerPlaying,
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
        let state = cachedOutputState
        return "engine_running=\(state.engineRunning) player_playing=\(state.playerPlaying) " +
            "selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(state.selectedDevice))}"
    }

    private var isPlaybackReady: Bool {
        let state = cachedOutputState
        return state.ready && VirtualAudioHealthPolicy.isPlaybackReady(
            hasSelectedDevice: state.selectedDevice != nil,
            engineRunning: state.engineRunning,
            playerPlaying: state.playerPlaying
        )
    }

    private func refreshOutputStateOnEngineQueue() {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let selected = selectedDevice
        let actual = currentOutputDevice()
        let running = engine?.isRunning == true
        let playing = player?.isPlaying == true
        let audibility = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: selected)
        let route = CoreAudioDeviceCatalog.routeDiagnostic()
        let healthy = VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: selected != nil,
            engineRunning: running,
            playerPlaying: playing,
            boundToSelectedDevice: selected?.id == actual?.id
        ) && !audibility.requiresAudibilityRepair
        updateOutputState {
            $0.actualDevice = actual
            $0.engineRunning = running
            $0.playerPlaying = playing
            $0.ready = healthy
            $0.healthy = healthy
            $0.route = route
        }
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
