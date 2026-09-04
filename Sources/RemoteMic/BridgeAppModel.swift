import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import SayAllMacRemoteCore

enum MobileVoiceSource: Equatable {
    case nearbyPhone
    case nearbyWatch
    case web

    var logName: String {
        switch self {
        case .nearbyPhone: return "iphone"
        case .nearbyWatch: return "watch"
        case .web: return "web"
        }
    }
}

enum MobileVoiceStartDisposition: Equatable {
    case startNow
    case deferUntilStopped
    case busy
}

enum MobileVoiceRestartPolicy {
    static func startDisposition(
        requested: MobileVoiceSource,
        active: MobileVoiceSource?,
        stopping: MobileVoiceSource?
    ) -> MobileVoiceStartDisposition {
        guard let active else { return .startNow }
        if active == requested, stopping == requested { return .deferUntilStopped }
        return .busy
    }

    static func shouldCancelPendingRestart(
        stopped: MobileVoiceSource,
        pending: MobileVoiceSource?
    ) -> Bool {
        pending == stopped
    }
}

struct HIDPermissionSnapshot: Equatable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    static var current: HIDPermissionSnapshot {
        HIDPermissionSnapshot(
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
    }
}

enum HIDPermissionRecoveryPolicy {
    static func shouldReapplySettings(
        started: Bool,
        customMappingEnabled: Bool,
        voiceKeyMode: VoiceKeyMode = .function,
        voiceFnTapModeEnabled: Bool = false,
        softwareVoiceKeyHeld: Bool = false,
        previous: HIDPermissionSnapshot?,
        current: HIDPermissionSnapshot
    ) -> Bool {
        guard started,
              (
                  customMappingEnabled ||
                      voiceKeyMode.requiresAccessibility ||
                      voiceFnTapModeEnabled ||
                      softwareVoiceKeyHeld
              ),
              let previous
        else { return false }
        return previous != current
    }
}

enum HIDMappingRecoveryPolicy {
    static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    static func shouldPreserveFnTapPreferenceAfterMappingFailure(
        hasMatchingServices: Bool
    ) -> Bool {
        !hasMatchingServices
    }

    static func retryDelay(
        forAttempt attempt: Int,
        started: Bool,
        readyBridgeCount: Int,
        hasMatchingServices: Bool
    ) -> TimeInterval? {
        guard started,
              readyBridgeCount > 0,
              !hasMatchingServices,
              retryDelays.indices.contains(attempt)
        else { return nil }
        return retryDelays[attempt]
    }
}

enum MobileVoiceStopDisposition: Equatable {
    case ignoredInactive
    case ignoredAlreadyStopping(cancelledPendingRestart: Bool)
    case begin(generation: UInt64)
}

enum MobileVoiceStopCompletion: Equatable {
    case ignored
    case stopped
    case restart(MobileVoiceSource)
}

struct MobileVoiceLifecycleState {
    private(set) var activeSource: MobileVoiceSource?
    private(set) var stoppingSource: MobileVoiceSource?
    private(set) var pendingRestartSource: MobileVoiceSource?
    private(set) var stopGeneration: UInt64 = 0

    mutating func markStarted(_ source: MobileVoiceSource) {
        activeSource = source
    }

    mutating func requestStart(_ source: MobileVoiceSource) -> MobileVoiceStartDisposition {
        let disposition = MobileVoiceRestartPolicy.startDisposition(
            requested: source,
            active: activeSource,
            stopping: stoppingSource
        )
        guard disposition == .deferUntilStopped else { return disposition }
        guard pendingRestartSource == nil else { return .busy }
        pendingRestartSource = source
        return disposition
    }

    mutating func beginStop(_ source: MobileVoiceSource) -> MobileVoiceStopDisposition {
        guard activeSource == source else { return .ignoredInactive }
        guard stoppingSource != source else {
            let cancelledPendingRestart = MobileVoiceRestartPolicy.shouldCancelPendingRestart(
                stopped: source,
                pending: pendingRestartSource
            )
            if cancelledPendingRestart {
                pendingRestartSource = nil
            }
            return .ignoredAlreadyStopping(
                cancelledPendingRestart: cancelledPendingRestart
            )
        }
        stoppingSource = source
        stopGeneration &+= 1
        return .begin(generation: stopGeneration)
    }

    mutating func completeStop(
        _ source: MobileVoiceSource,
        generation: UInt64
    ) -> MobileVoiceStopCompletion {
        guard stopGeneration == generation,
              activeSource == source,
              stoppingSource == source
        else { return .ignored }
        activeSource = nil
        stoppingSource = nil
        guard pendingRestartSource == source else { return .stopped }
        pendingRestartSource = nil
        return .restart(source)
    }

    @discardableResult
    mutating func reset() -> Bool {
        stopGeneration &+= 1
        let cancelledPendingRestart = pendingRestartSource != nil
        activeSource = nil
        stoppingSource = nil
        pendingRestartSource = nil
        return cancelledPendingRestart
    }
}

private struct MobileButtonGestureKey: Hashable {
    let source: UsageEventSource
    let button: RemoteButton
}

struct MobileRemoteButtonObservation: Equatable {
    let source: UsageEventSource
    let button: RemoteButton
}

private struct ManagedDefaultInputTransition {
    let virtualUID: String
    let fallbackUID: String
}

enum BluetoothVoiceStopPolicy {
    /// Remote stop ends capture but must not discard PCM already scheduled for playback.
    static func shouldFlushAudio(handledByFnTapMode _: Bool) -> Bool {
        false
    }
}

enum VoiceSamplePresentationPolicy {
    static func shouldPublishReceipt(
        hasReceivedSamples: Bool,
        sampleCount: Int
    ) -> Bool {
        sampleCount > 0 && !hasReceivedSamples
    }
}

struct AudioRecoveryCoalescingState {
    private(set) var pendingEventCount = 0

    mutating func recordEvent() {
        pendingEventCount += 1
    }

    mutating func consumePendingEventCount() -> Int {
        let count = pendingEventCount
        pendingEventCount = 0
        return count
    }

    mutating func reset() {
        pendingEventCount = 0
    }
}

struct BluetoothVoiceTailSnapshot: Equatable {
    let sampleCount: Int
    let durationMilliseconds: Int
    let nonZeroSampleCount: Int
    let peak: Int
    let rms: Int
    let finalWindowSampleCount: Int
    let finalWindowDurationMilliseconds: Int
    let finalWindowNonZeroSampleCount: Int
    let finalWindowPeak: Int
    let finalWindowRMS: Int
    let lastAudioAgeMilliseconds: Int?
}

struct BluetoothVoiceTailDiagnostics {
    static let sampleRate = 16_000
    static let maximumSampleCount = 4_800

    private var recentSamples: [Int16] = []
    private var lastAudioUptime: TimeInterval?

    mutating func reset() {
        recentSamples.removeAll(keepingCapacity: true)
        lastAudioUptime = nil
    }

    mutating func append(_ samples: [Int16], at uptime: TimeInterval) {
        guard !samples.isEmpty else { return }
        lastAudioUptime = uptime
        if samples.count >= Self.maximumSampleCount {
            recentSamples = Array(samples.suffix(Self.maximumSampleCount))
            return
        }
        let overflow = max(0, recentSamples.count + samples.count - Self.maximumSampleCount)
        if overflow > 0 {
            recentSamples.removeFirst(overflow)
        }
        recentSamples.append(contentsOf: samples)
    }

    func snapshot(at stopUptime: TimeInterval) -> BluetoothVoiceTailSnapshot {
        var metrics = WatchBluetoothAudioSignalMetrics()
        metrics.append(recentSamples)
        let finalWindowSamples = Array(recentSamples.suffix(Self.sampleRate / 10))
        var finalWindowMetrics = WatchBluetoothAudioSignalMetrics()
        finalWindowMetrics.append(finalWindowSamples)
        return BluetoothVoiceTailSnapshot(
            sampleCount: metrics.sampleCount,
            durationMilliseconds: metrics.sampleCount * 1_000 / Self.sampleRate,
            nonZeroSampleCount: metrics.nonZeroSampleCount,
            peak: metrics.peak,
            rms: metrics.rms,
            finalWindowSampleCount: finalWindowMetrics.sampleCount,
            finalWindowDurationMilliseconds:
                finalWindowMetrics.sampleCount * 1_000 / Self.sampleRate,
            finalWindowNonZeroSampleCount: finalWindowMetrics.nonZeroSampleCount,
            finalWindowPeak: finalWindowMetrics.peak,
            finalWindowRMS: finalWindowMetrics.rms,
            lastAudioAgeMilliseconds: lastAudioUptime.map {
                max(0, Int(((stopUptime - $0) * 1_000).rounded()))
            }
        )
    }
}

private enum RecordingPlaybackOperationError: Error {
    case playerRejected
}

private enum RecordingPlaybackStage: String {
    case resolveAsset = "resolve_asset"
    case initializePlayer = "initialize_player"
    case preparePlayer = "prepare_player"
    case startPlayback = "start_playback"
}

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    private static let longRecordingOpenTimeout: TimeInterval = 5
    private static let longRecordingCloseTimeout: TimeInterval = 2
    private static let rc003VoiceExtensionOpenTimeout: TimeInterval = 5
    private static let rc003VoiceExtensionInterval: TimeInterval = 8
    private static let rc003VoiceExtensionMaximumDuration: TimeInterval = 120

    let settings: AppSettings
    let privateFeature: PrivateFeatureIntegration
    let macroFeature: MacroFeatureIntegration
    let membershipFeature: MembershipFeatureIntegration
    let loginItemService: LoginItemService

    @Published private(set) var connectionStatus = LocalizedMessage("bluetooth.status.initializing")
    @Published private(set) var hidStatus = LocalizedMessage("button_mapping.status.disabled")
    @Published private(set) var audioStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var doubaoAudioStatus = LocalizedMessage("audio.compatibility.checking")
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    @Published private(set) var isVoiceTriggerEnabled = false
    @Published private(set) var activeRemoteButtons = Set<RemoteButton>()
    @Published private(set) var lastRemoteButtonPress: RemoteButton?
    @Published private(set) var connectedRemoteProfileIDs = Set<UUID>()
    @Published private(set) var remoteBatteryLevels: [UUID: Int] = [:]
    @Published private(set) var remotePowerStates: [UUID: RemotePowerState] = [:]
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var isAudioOutputReady = false
    @Published private(set) var hasReceivedCurrentVoiceSamples = false
    @Published private(set) var activeVoiceSource: UsageEventSource?
    @Published private(set) var lastMobileRemoteButtonObservation: MobileRemoteButtonObservation?
    @Published private(set) var isPhoneRemoteConnectionEnabled = false
    @Published private(set) var isPhoneRemoteConnected = false
    @Published private(set) var isWatchRemoteConnected = false
    @Published private(set) var phoneRemoteInvitation: PhoneRemoteInvitation?
    @Published private(set) var webRemoteState: WebRemoteSessionState = .disabled
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")
    @Published private(set) var transcriptRecords: [TranscriptRecord] = []
    @Published private(set) var recordingAssets: [RecordingAssetManifest] = []
    @Published private(set) var recordingPlaybackError: RecordingPlaybackFailure?

    private let transcriptArchiveStore: TranscriptArchiveStore
    private let recordingAssetStore: RecordingAssetStore
    private let transcriptArchiveOperationQueue = DispatchQueue(
        label: "RemoteMic.transcriptArchive.operations",
        qos: .utility
    )
    private let recordingPlaybackDiagnosticQueue = DispatchQueue(
        label: "RemoteMic.recordingPlayback.diagnostics",
        qos: .utility
    )
    private let audioOutput = VirtualAudioOutput()
    private var recordingPlayback: AVAudioPlayer?
    private let phoneRemoteServer = PhoneRemoteServer(logger: { message in
        AppLogger.shared.write(message)
    })
    private let watchBluetoothServer = WatchBluetoothRemoteServer(logger: { message in
        AppLogger.shared.write(message)
    })
    private let webRemoteClient = WebRemoteRelayClient()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private lazy var preferredInputSourceMonitor = PreferredInputSourceMonitor(
        voiceTool: { [weak self] in
            self?.settings.onboardingVoiceTool ?? .unselected
        }
    )
    private lazy var voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
        onStateChange: { [weak self] state in
            self?.handleVoiceInputDestinationState(state)
        }
    )
    private lazy var voiceFnTapSession = VoiceFnTapSessionController(
        destinationReadiness: { [weak self] completion in
            self?.voiceInputDestinationCoordinator.waitUntilReady(completion: completion) ?? .immediate
        },
        setFunctionKeyPressed: { KeyboardInjector.setFunctionKeyPressed($0) },
        enqueueAudio: { [weak self] samples in
            self?.enqueueVoiceFnTapAudio(samples)
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
    private lazy var transcriptCaptureCoordinator = TranscriptCaptureCoordinator(
        isEnabled: { [weak self] in
            guard let self else { return false }
            return self.settings.localTranscriptHistoryEnabled
                || self.settings.localOriginalAudioRecordingEnabled
        },
        onCapture: { [weak self] capture in
            self?.archiveCapturedTranscript(capture)
        }
    )
    private lazy var recordingAssetCoordinator = RecordingAssetCoordinator(
        store: recordingAssetStore,
        isEnabled: { [weak self] in
            self?.settings.localOriginalAudioRecordingEnabled ?? false
        },
        onCommit: { [weak self] _ in
            self?.refreshRecordingAssets()
        }
    )
    private var transcriptHistoryToggleCancellable: AnyCancellable?
    private var recordingToggleCancellable: AnyCancellable?
    private var membershipAccessCancellable: AnyCancellable?
    private var testToneGeneration = 0
    private var voiceKeyLatch = VoiceFunctionKeyLatch()
    private var heldVoiceKeyMode: VoiceKeyMode?
    private var voiceSessionStartedAt: Date?
    private var voiceSessionID: UUID?
    private var voiceAudioDeliveryGeneration = 0
    private var voiceAudioDeliveryDiagnostic = VoiceAudioDeliveryDiagnostic()
    private var voiceSessionUsageSource: UsageEventSource?
    private var bluetoothVoiceActive = false
    private var loggedBluetoothVoiceAudioDeviceIdentifier: UUID?
    private var mobileVoiceLifecycle = MobileVoiceLifecycleState()
    private var pendingMobileVoiceRestartCompletion: ((RemoteVoiceStartResult) -> Void)?
    private var activeMobileVoiceSource: MobileVoiceSource? {
        mobileVoiceLifecycle.activeSource
    }
    private var stoppingMobileVoiceSource: MobileVoiceSource? {
        mobileVoiceLifecycle.stoppingSource
    }
    private var mobileVoiceAudioBatchCount = 0
    private var mobileVoiceAudioEnqueueFailureCount = 0
    private var mobileVoiceAudioSourceMismatchCount = 0
    private var mobileVoiceAudioSignalMetrics = WatchBluetoothAudioSignalMetrics()
    private var longRecordingRequested = false
    private var longRecordingGeneration: UInt64 = 0
    private var longRecordingOpenTimer: DispatchSourceTimer?
    private var longRecordingCloseTimer: DispatchSourceTimer?
    private let rc003VoiceExtensionTestEnabled: Bool
    private weak var rc003VoiceExtensionBridge: XiaomiBluetoothBridge?
    private var rc003VoiceExtensionActive = false
    private var rc003VoiceExtensionAwaitingReopen = false
    private var rc003VoiceExtensionGeneration: UInt64 = 0
    private var rc003VoiceExtensionDidReceiveAudio = false
    private var rc003VoiceExtensionTimer: DispatchSourceTimer?
    private var rc003VoiceExtensionOpenTimer: DispatchSourceTimer?
    private var rc003VoiceExtensionDeadlineTimer: DispatchSourceTimer?
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
    private var bluetoothVoiceTailDiagnostics = BluetoothVoiceTailDiagnostics()
    private let hidEventSuppressor = KeyboardEventSuppressor()
    private var hidMonitors: [String: HIDRemoteMonitor] = [:]
    private var discoveryHIDMonitor: HIDRemoteMonitor?
    private var hidPowerKeySuppressed = false
    private var hidAllowedLocationIDs: Set<UInt32>?
    private var started = false
    private var appliedHIDPermissionSnapshot: HIDPermissionSnapshot?
    private var terminationObserver: NSObjectProtocol?
    private var completedUpdateHIDRecoveryWorkItem: DispatchWorkItem?
    private var hidMappingRecoveryWorkItem: DispatchWorkItem?
    private var hidMappingRecoveryAttempt = 0
    private var hidMappingRecoveryGeneration: UInt64 = 0
    private let audioPreparationQueue = DispatchQueue(label: "RemoteMic.audioPreparation", qos: .userInitiated)
    private var audioStartupGeneration: UInt64 = 0
    private var audioDeviceRefreshGeneration: UInt64 = 0
    private var audioStartupPending = false
    private let audioHardwareListenerQueue = DispatchQueue(label: "RemoteMic.audioHardware")
    private var observedAudioHardwareAddresses: [AudioObjectPropertyAddress] = []
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var audioRecoveryGeneration: UInt64 = 0
    private var audioRecoveryCoalescingState = AudioRecoveryCoalescingState()
    private var virtualAudioReleaseGeneration: UInt64 = 0
    private var pendingVirtualAudioRelease: (generation: UInt64, reason: String)?
    private var systemAudioSuspensionState = SystemAudioSuspensionState()
    private var managedDefaultInputTransition: ManagedDefaultInputTransition?
    private lazy var audioHardwareListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        let properties = Self.audioHardwarePropertyNames(count: count, addresses: addresses)
        self?.scheduleAudioRecovery(reason: "hardware_change", details: "properties=\(properties)")
    }

    var isRC003VoiceExtensionTestEnabled: Bool {
        rc003VoiceExtensionTestEnabled
    }

    init(
        settings: AppSettings = AppSettings(),
        initialAudioDevices: [AudioDeviceInfo] = [],
        privateFeature: PrivateFeatureIntegration = PrivateFeatureIntegration(),
        macroFeature: MacroFeatureIntegration = MacroFeatureIntegration(),
        membershipFeature: MembershipFeatureIntegration = MembershipFeatureIntegration(),
        loginItemService: LoginItemService = LoginItemService(),
        transcriptArchiveStore: TranscriptArchiveStore = TranscriptArchiveStore(),
        rc003VoiceExtensionTestEnabled: Bool =
            ProcessInfo.processInfo.arguments.contains("--rc003-voice-extension-test") ||
            (Bundle.main.object(forInfoDictionaryKey: "RC003VoiceExtensionTestEnabled") as? Bool == true),
        recordingAssetStore: RecordingAssetStore = RecordingAssetStore()
    ) {
        self.settings = settings
        self.privateFeature = privateFeature
        self.macroFeature = macroFeature
        self.membershipFeature = membershipFeature
        self.loginItemService = loginItemService
        self.transcriptArchiveStore = transcriptArchiveStore
        self.rc003VoiceExtensionTestEnabled = rc003VoiceExtensionTestEnabled
        self.recordingAssetStore = recordingAssetStore
        audioDevices = initialAudioDevices
        membershipAccessCancellable = membershipFeature.$buttonProfilesAccessDecision
            .removeDuplicates()
            .sink { [weak macroFeature] decision in
                macroFeature?.updateButtonProfilesAccess(decision)
            }
        audioOutput.onConfigurationChange = { [weak self] in
            self?.scheduleAudioRecovery(reason: "engine_configuration_change")
        }
        phoneRemoteServer.isIdentityTrusted = { [weak self] fingerprint in
            self?.settings.isPhoneIdentityTrusted(fingerprint) ?? false
        }
        phoneRemoteServer.onConnectionStateChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isPhoneRemoteConnected = connected
            }
        }
        phoneRemoteServer.onInvitationChange = { [weak self] invitation in
            DispatchQueue.main.async {
                self?.phoneRemoteInvitation = invitation
            }
        }
        phoneRemoteServer.onApprovalCancelled = { [weak self] in
            self?.cancelPhoneApproval()
        }
        phoneRemoteServer.onApprovalRequested = { [weak self] deviceName, pairingCode, fingerprint, completion in
            guard let self, self.isPhoneRemoteConnectionEnabled else {
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
                guard let button = Self.appRemoteButton(rawValue: button.rawValue) else {
                    completion(false)
                    return
                }
                self?.observeMobileButton(button, source: .nearbyPhone)
                completion(self?.performPhoneCommand(button, source: .nearbyPhone) ?? false)
            }
        }
        phoneRemoteServer.onButtonEvent = { [weak self] button, phase, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue),
                      let phase = Self.appRemoteButtonPhase(rawValue: phase.rawValue)
                else {
                    completion(false)
                    return
                }
                if phase == .press {
                    self?.observeMobileButton(button, source: .nearbyPhone)
                }
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
        phoneRemoteServer.onVoiceStartResult = { [weak self] completion in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.unavailable)
                    return
                }
                self.requestPhoneVoiceStart(
                    source: .nearbyPhone,
                    completion: completion
                )
            }
        }
        phoneRemoteServer.onVoiceStop = { [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .nearbyPhone)
            }
        }
        phoneRemoteServer.onAudio = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .nearbyPhone)
            }
        }
        watchBluetoothServer.isIdentityTrusted = { [weak self] fingerprint in
            self?.settings.isPhoneIdentityTrusted(fingerprint) ?? false
        }
        watchBluetoothServer.onConnectionStateChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isWatchRemoteConnected = connected
            }
        }
        watchBluetoothServer.onApprovalCancelled = { [weak self] in
            self?.cancelPhoneApproval()
        }
        watchBluetoothServer.onApprovalRequested = { [weak self] deviceName, pairingCode, fingerprint, completion in
            guard let self, self.isPhoneRemoteConnectionEnabled else {
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
        watchBluetoothServer.onCommand = { [weak self] button, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue) else {
                    completion(false)
                    return
                }
                self?.observeMobileButton(button, source: .nearbyPhone)
                completion(self?.performPhoneCommand(button, source: .nearbyPhone) ?? false)
            }
        }
        watchBluetoothServer.onButtonEvent = { [weak self] button, phase, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue),
                      let phase = Self.appRemoteButtonPhase(rawValue: phase.rawValue)
                else {
                    completion(false)
                    return
                }
                if phase == .press {
                    self?.observeMobileButton(button, source: .nearbyPhone)
                }
                completion(self?.handleMobileButtonEvent(
                    button,
                    phase: phase,
                    source: .nearbyPhone
                ) ?? false)
            }
        }
        watchBluetoothServer.onButtonEventsReset = { [weak self] in
            DispatchQueue.main.async {
                self?.resetMobileButtonGestures(source: .nearbyPhone)
            }
        }
        watchBluetoothServer.onVoiceStartResult = { [weak self] completion in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.unavailable)
                    return
                }
                self.requestPhoneVoiceStart(
                    source: .nearbyWatch,
                    completion: completion
                )
            }
        }
        watchBluetoothServer.onVoiceStop = { [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .nearbyWatch)
            }
        }
        watchBluetoothServer.onAudio = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .nearbyWatch)
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
                guard let button = Self.appRemoteButton(rawValue: button.rawValue) else {
                    completion(false)
                    return
                }
                self?.observeMobileButton(button, source: .webRemote)
                completion(self?.performPhoneCommand(button, source: .webRemote) ?? false)
            }
        }
        webRemoteClient.onButtonEvent = { [weak self] button, phase, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue),
                      let phase = Self.appRemoteButtonPhase(rawValue: phase.rawValue)
                else {
                    completion(false)
                    return
                }
                if phase == .press {
                    self?.observeMobileButton(button, source: .webRemote)
                }
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
                guard let self else {
                    completion(false)
                    return
                }
                self.requestPhoneVoiceStart(source: .web) {
                    completion($0 == .started)
                }
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
        transcriptHistoryToggleCancellable = settings.$localTranscriptHistoryEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled || self.settings.localOriginalAudioRecordingEnabled {
                    refreshTranscriptRecords()
                } else {
                    transcriptCaptureCoordinator.cancel()
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
        AppLogger.shared.write(
            "APP START version=\(version) rc003_test=\(rc003VoiceExtensionTestEnabled)"
        )
    }

    func stop() {
        privateFeature.stop()
        macroFeature.stop()
        preferredInputSourceMonitor.stop()
        transcriptCaptureCoordinator.cancel()
        recordingAssetCoordinator.cancel(reason: "app_stop")
        stopRecordingPlayback()
        guard started else { return }
        started = false
        cancelHIDMappingRecovery(reason: "app_stop")
        completedUpdateHIDRecoveryWorkItem?.cancel()
        completedUpdateHIDRecoveryWorkItem = nil
        audioStartupGeneration &+= 1
        audioDeviceRefreshGeneration &+= 1
        let shouldStopAudioOnPreparationQueue = audioStartupPending
        audioStartupPending = false
        audioRecoveryGeneration &+= 1
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        audioRecoveryCoalescingState.reset()
        stopObservingAudioHardware()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("app.status.stopped"),
            logReason: "app_stop"
        )
        stopLongRecording(reason: "app_stop")
        finishRC003VoiceExtensionTest(reason: "app_stop")
        voiceInputDestinationCoordinator.shutdown()
        voiceFnTapSession.shutdown()
        bluetoothBridges.values.forEach { $0.stop() }
        discoveryBluetoothBridge?.stop()
        bluetoothBridges.removeAll()
        bluetoothBridgeStates.removeAll()
        discoveryBluetoothBridge = nil
        activeBluetoothVoiceDeviceIdentifier = nil
        phoneRemoteServer.stop()
        watchBluetoothServer.stop()
        webRemoteClient.stop()
        isPhoneRemoteConnectionEnabled = false
        isPhoneRemoteConnected = false
        isWatchRemoteConnected = false
        webRemoteState = .disabled
        bluetoothVoiceActive = false
        let cancelledPendingRestart = mobileVoiceLifecycle.reset()
        let completion = pendingMobileVoiceRestartCompletion
        pendingMobileVoiceRestartCompletion = nil
        if cancelledPendingRestart {
            completion?(.unavailable)
        }
        voiceSessionUsageSource = nil
        releaseVoiceKeyIfNeeded()
        stopHIDMonitors()
        isAudioOutputReady = false
        virtualAudioReleaseGeneration &+= 1
        pendingVirtualAudioRelease = nil
        managedDefaultInputTransition = nil
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

    func refreshTranscriptRecords() {
        transcriptArchiveOperationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let records = try transcriptArchiveStore.loadAll()
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptRecords = records
                }
            } catch {
                AppLogger.shared.write(
                    "TRANSCRIPT ARCHIVE load_failed reason=load_all " +
                        AppLogger.errorFields(error)
                )
            }
        }
        refreshRecordingAssets()
        recordingToggleCancellable = settings.$localOriginalAudioRecordingEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if !isEnabled {
                    self.recordingAssetCoordinator.cancel(reason: "feature_disabled")
                }
                self.refreshRecordingAssets()
            }
    }

    func refreshRecordingAssets() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let assets = try self.recordingAssetStore.loadAll()
                DispatchQueue.main.async { [weak self] in
                    self?.recordingAssets = assets
                }
            } catch {
                AppLogger.shared.write(
                    "RECORDING ASSET load_failed reason=load_all " +
                        AppLogger.errorFields(error)
                )
            }
        }
    }

    func playRecording(_ asset: RecordingAssetManifest) {
        recordingPlaybackError = nil
        var stage = RecordingPlaybackStage.resolveAsset
        var prepareResult: Bool?
        do {
            let url = try recordingAssetStore.mediaURL(for: asset)
            recordingPlayback?.stop()
            recordingPlayback = nil
            stage = .initializePlayer
            recordingPlayback = try AVAudioPlayer(contentsOf: url)
            stage = .preparePlayer
            prepareResult = recordingPlayback?.prepareToPlay()
            stage = .startPlayback
            guard recordingPlayback?.play() == true else {
                throw RecordingPlaybackOperationError.playerRejected
            }
        } catch {
            let playerDurationMilliseconds = recordingPlayback.map {
                Int(($0.duration * 1_000).rounded())
            } ?? -1
            let playerChannelCount = recordingPlayback?.numberOfChannels ?? -1
            let playerSampleRate = recordingPlayback.map {
                Int($0.format.sampleRate.rounded())
            } ?? -1
            recordingPlayback?.stop()
            recordingPlayback = nil
            let failure: RecordingPlaybackFailure = error is RecordingPlaybackOperationError
                ? .playerUnavailable
                : .classify(error)
            recordingPlaybackError = failure
            let failureFields = [
                "RECORDING ASSET playback_failed",
                "record_id=\(asset.id.uuidString)",
                "session_id=\(asset.sessionID.uuidString)",
                "application_key=\(AppLogger.stableToken(asset.applicationKey ?? "__unknown__"))",
                "date=\(asset.localDateKey)",
                "reason=\(failure.logReason)",
                "stage=\(stage.rawValue)",
                "source=\(asset.source.rawValue)",
                "manifest_format_supported=\(asset.format == "m4a-aac")",
                "manifest_bytes=\(asset.byteCount)",
                "manifest_duration_ms=\(asset.durationMilliseconds)",
                "prepare_result=\(prepareResult.map { String($0) } ?? "not_attempted")",
                "player_duration_ms=\(playerDurationMilliseconds)",
                "player_channels=\(playerChannelCount)",
                "player_sample_rate_hz=\(playerSampleRate)",
                AppLogger.errorFields(error)
            ]
            AppLogger.shared.write(failureFields.joined(separator: " "))
            logRecordingPlaybackIntegrity(asset)
        }
    }

    private func logRecordingPlaybackIntegrity(_ asset: RecordingAssetManifest) {
        recordingPlaybackDiagnosticQueue.async { [weak self] in
            guard let self else { return }
            do {
                let diagnostics = try self.recordingAssetStore.integrityDiagnostics(for: asset)
                AppLogger.shared.write(
                    "RECORDING ASSET playback_integrity " +
                        "record_id=\(asset.id.uuidString) " +
                        "session_id=\(asset.sessionID.uuidString) " +
                        "actual_bytes=\(diagnostics.actualByteCount) " +
                        "byte_count_match=\(diagnostics.byteCountMatches) " +
                        "sha256_match=\(diagnostics.sha256Matches)"
                )
            } catch {
                AppLogger.shared.write(
                    "RECORDING ASSET playback_integrity_failed " +
                        "record_id=\(asset.id.uuidString) " +
                        "session_id=\(asset.sessionID.uuidString) " +
                        AppLogger.errorFields(error)
                )
            }
        }
    }

    func clearRecordingPlaybackError() {
        recordingPlaybackError = nil
    }

    func stopRecordingPlayback() {
        recordingPlayback?.stop()
        recordingPlayback = nil
    }

    func exportRecording(_ asset: RecordingAssetManifest) {
        guard let sourceURL = try? recordingAssetStore.mediaURL(for: asset) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "回眸-\(asset.localDateKey).m4a"
        panel.allowedFileTypes = ["m4a"]
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.trashItem(at: destinationURL, resultingItemURL: nil)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                AppLogger.shared.write("RECORDING ASSET export_failed")
            }
        }
    }

    func deleteRecording(_ asset: RecordingAssetManifest) {
        stopRecordingPlayback()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.recordingAssetStore.delete(id: asset.id)
                self.refreshRecordingAssets()
            } catch {
                AppLogger.shared.write("RECORDING ASSET delete_failed")
            }
        }
    }

    func deleteRecordingApplication(applicationKey: String) {
        stopRecordingPlayback()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.recordingAssetStore.deleteApplication(applicationKey: applicationKey)
                self.refreshRecordingAssets()
            } catch {
                AppLogger.shared.write("RECORDING ASSET delete_application_failed")
            }
        }
    }

    func deleteAllRecordings() {
        stopRecordingPlayback()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.recordingAssetStore.deleteAll()
                self.refreshRecordingAssets()
            } catch {
                AppLogger.shared.write("RECORDING ASSET delete_all_failed")
            }
        }
    }

    @discardableResult
    func copyTranscript(_ record: TranscriptRecord) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([record.originalTranscript as NSString])
    }

    func deleteTranscriptRecord(_ record: TranscriptRecord) {
        updateTranscriptArchive {
            try self.transcriptArchiveStore.deleteRecord(id: record.id)
        }
    }

    func deleteTranscriptApplication(applicationKey: String) {
        updateTranscriptArchive {
            try self.transcriptArchiveStore.deleteApplication(applicationKey: applicationKey)
        }
    }

    func deleteAllTranscripts() {
        updateTranscriptArchive {
            try self.transcriptArchiveStore.deleteAll()
        }
    }

    static func shouldRecoverHIDAfterCompletedUpdate(
        completedUpdate: Bool,
        customMappingEnabled: Bool
    ) -> Bool {
        completedUpdate && customMappingEnabled
    }

    static func shouldReapplyHIDSettings(
        previousState: BluetoothBridgeState?,
        currentState: BluetoothBridgeState
    ) -> Bool {
        guard case .ready = currentState else { return false }
        guard let previousState else { return true }
        if case .ready = previousState { return false }
        return true
    }

    static func canStartBluetoothVoice(
        mode: VoiceKeyMode,
        voiceFnTapModeEnabled: Bool = false,
        isVoiceKeyNeutralized: Bool
    ) -> Bool {
        (mode == .function && !voiceFnTapModeEnabled) || isVoiceKeyNeutralized
    }

    static func canFallbackVoiceKeyMode(
        isStreaming: Bool,
        allowVoiceKeyModeFallback: Bool
    ) -> Bool {
        !isStreaming && allowVoiceKeyModeFallback
    }

    @discardableResult
    static func importConfiguration(
        from data: Data,
        into settings: AppSettings,
        isStreaming: Bool,
        releaseVoiceKey: () -> Bool
    ) throws -> Bool {
        let importedVoiceKeyConfiguration = try settings.voiceKeyConfigurationState(in: data)
        let changesVoiceKeyConfiguration =
            importedVoiceKeyConfiguration != settings.voiceKeyConfigurationState
        if changesVoiceKeyConfiguration {
            guard !isStreaming, releaseVoiceKey() else {
                throw AppConfigurationError.unsafeVoiceKeyChange
            }
        }
        try settings.importConfiguration(from: data)
        return changesVoiceKeyConfiguration
    }

    func recoverHIDAfterCompletedUpdate(delay: TimeInterval = 2) {
        guard started, settings.customMappingEnabled else { return }
        completedUpdateHIDRecoveryWorkItem?.cancel()
        stopHIDMonitors()
        AppLogger.shared.write("HID UPDATE RECOVERY scheduled delay_ms=\(Int(delay * 1_000))")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.settings.customMappingEnabled else { return }
            self.completedUpdateHIDRecoveryWorkItem = nil
            self.applyHIDSettings()
            AppLogger.shared.write("HID UPDATE RECOVERY applied")
        }
        completedUpdateHIDRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func refreshHIDAfterPermissionChange() {
        let current = HIDPermissionSnapshot.current
        guard HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: started,
            customMappingEnabled: settings.customMappingEnabled,
            voiceKeyMode: settings.voiceKeyMode,
            voiceFnTapModeEnabled: settings.voiceFnTapModeEnabled,
            softwareVoiceKeyHeld: voiceKeyLatch.isHeld,
            previous: appliedHIDPermissionSnapshot,
            current: current
        ) else { return }
        let previous = appliedHIDPermissionSnapshot
        AppLogger.shared.write(
            "HID PERMISSIONS changed " +
                "input=\(previous?.inputMonitoringGranted ?? false)->\(current.inputMonitoringGranted) " +
                "accessibility=\(previous?.accessibilityGranted ?? false)->\(current.accessibilityGranted) " +
                "recovery=apply_settings"
        )
        applyHIDSettings()
    }

    func reconnect() {
        guard started else { return }
        if bluetoothBridges.isEmpty && discoveryBluetoothBridge == nil {
            AppLogger.shared.write("BLE RECONNECT starting_missing_bridges")
            startBluetoothConnections()
            return
        }
        if let selectedBluetoothBridge {
            selectedBluetoothBridge.reconnectNow()
        } else {
            bluetoothBridges.values.forEach { $0.reconnectNow() }
            discoveryBluetoothBridge?.reconnectNow()
        }
    }

    private func recoverBluetoothAfterSystemWake() {
        let targets: [XiaomiBluetoothBridge]
        if let selectedBluetoothBridge {
            targets = [selectedBluetoothBridge]
        } else {
            targets = Array(bluetoothBridges.values)
        }
        AppLogger.shared.write(
            "BLE WAKE recovery_begin target_bridges=\(targets.count) " +
                "discovery=\(discoveryBluetoothBridge != nil) " +
                "ready_bridges=\(readyBluetoothBridgeCount)"
        )
        if targets.isEmpty, discoveryBluetoothBridge == nil {
            startBluetoothConnections()
            AppLogger.shared.write("BLE WAKE recovery_started_missing_bridges")
            return
        }
        targets.forEach { $0.recoverAfterSystemWake() }
        discoveryBluetoothBridge?.recoverAfterSystemWake()
    }

    func refreshRemoteDiscovery() {
        guard started else { return }
        if discoveryBluetoothBridge == nil {
            startBluetoothDiscoveryIfNeeded()
        } else {
            discoveryBluetoothBridge?.reconnectNow()
        }
        AppLogger.shared.write("BLE DISCOVERY refreshed_from_foreground")
    }

    func enablePhoneRemoteConnection() {
        guard started, !isPhoneRemoteConnectionEnabled else { return }
        isPhoneRemoteConnectionEnabled = true
        phoneRemoteServer.start()
        watchBluetoothServer.start()
        AppLogger.shared.write("PHONE REMOTE enabled_by_user")
    }

    func disablePhoneRemoteConnection() {
        guard isPhoneRemoteConnectionEnabled else { return }
        isPhoneRemoteConnectionEnabled = false
        isPhoneRemoteConnected = false
        isWatchRemoteConnected = false
        cancelPhoneApproval()
        phoneRemoteServer.stop()
        watchBluetoothServer.stop()
        AppLogger.shared.write("PHONE REMOTE disabled_by_user")
    }

    func togglePhoneRemoteConnection() {
        if isPhoneRemoteConnectionEnabled {
            disablePhoneRemoteConnection()
        } else {
            enablePhoneRemoteConnection()
        }
    }

    var isWatchRemoteConnectionEnabled: Bool {
        isPhoneRemoteConnectionEnabled
    }

    func enableWatchRemoteConnection() {
        enablePhoneRemoteConnection()
    }

    func toggleWatchRemoteConnection() {
        togglePhoneRemoteConnection()
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
        applicationProfileIDs: [RemoteButton: UUID] = [:],
        customApplicationProfiles: [CustomApplicationProfile] = [],
        localization: LocalizationStore
    ) {
        var titles: [String: String] = [:]
        for button in RemoteButton.allCases {
            let action = bindings[button] ?? .disabled
            guard action != AppSettings.defaultBindings[button] else { continue }
            let fullTitle: String
            if action == .customShortcut {
                fullTitle = shortcuts[button]?.displayName(using: localization)
                    ?? action.displayName(using: localization)
            } else if action == .openCustomApplication,
                      let profileID = applicationProfileIDs[button],
                      let profile = customApplicationProfiles.first(where: { $0.id == profileID })
            {
                fullTitle = profile.displayName
            } else {
                fullTitle = action.displayName(using: localization)
            }
            titles[button.rawValue] = String(fullTitle.prefix(10))
        }
        remoteButtonTitles = titles
        phoneRemoteServer.updateButtonTitles(titles)
        watchBluetoothServer.updateButtonTitles(titles)
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
                if self.systemAudioSuspensionState.isSuspended {
                    AppLogger.shared.write(
                        "SYSTEM AUDIO startup_release reasons=\(self.systemAudioSuspensionState.diagnostic) " +
                            "state={\(outputState)}"
                    )
                    self.releaseVirtualAudioOutputIfUnused(reason: "startup_system_suspended")
                }
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
        guard shouldKeepVirtualAudioActive else {
            releaseVirtualAudioOutputIfUnused(reason: reason)
            return
        }
        _ = configureVirtualAudioOutput(reason: reason)
    }

    func handleSystemAudioLifecycle(_ event: SystemAudioLifecycleEvent) {
        let changed = systemAudioSuspensionState.apply(event)
        AppLogger.shared.write(
            "SYSTEM AUDIO event=\(event.rawValue) changed=\(changed) " +
                "suspended=\(systemAudioSuspensionState.isSuspended) " +
                "reasons=\(systemAudioSuspensionState.diagnostic) started=\(started) " +
                "ready_bridges=\(readyBluetoothBridgeCount) " +
                "bluetooth_voice=\(bluetoothVoiceActive) " +
                "mobile_voice=\(activeMobileVoiceSource != nil) " +
                "test_tone=\(isPlayingTestTone) audio_ready=\(isAudioOutputReady)"
        )
        guard started, changed else { return }
        guard !audioStartupPending else {
            AppLogger.shared.write(
                "SYSTEM AUDIO lifecycle_deferred event=\(event.rawValue) cause=audio_startup_pending " +
                    "suspended=\(systemAudioSuspensionState.isSuspended)"
            )
            return
        }

        if event.isSuspending {
            if hasActiveVirtualAudioSource {
                AppLogger.shared.write(
                    "SYSTEM AUDIO suspend_deferred event=\(event.rawValue) " +
                        "bluetooth_voice=\(bluetoothVoiceActive) " +
                        "mobile_voice=\(activeMobileVoiceSource != nil) " +
                        "test_tone=\(isPlayingTestTone)"
                )
                return
            }
            releaseVirtualAudioOutputIfUnused(reason: "system_\(event.rawValue)")
            return
        }

        guard !systemAudioSuspensionState.isSuspended else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_deferred event=\(event.rawValue) " +
                    "remaining_reasons=\(systemAudioSuspensionState.diagnostic)"
            )
            return
        }
        resumeVirtualAudioOutputIfNeeded(reason: "system_\(event.rawValue)")
        if BluetoothWakeRecoveryPolicy.shouldForceReconnect(event: event, started: started) {
            recoverBluetoothAfterSystemWake()
        }
    }

    @discardableResult
    private func configureVirtualAudioOutput(reason: String) -> Bool {
        cancelVirtualAudioReleaseIfPending(trigger: "rebind_\(reason)")
        virtualAudioReleaseGeneration &+= 1
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
                "ready=\(isAudioOutputReady) selected_available=\(selectedAudioDeviceIsAvailable) " +
                "state={\(audioOutput.diagnosticState())}"
        )
        if configured {
            restoreManagedDefaultInputIfAppropriate(reason: reason)
        }
        return configured
    }

    @discardableResult
    private func ensureVirtualAudioOutputReady(reason: String) -> Bool {
        isAudioOutputReady = audioOutput.isReadyForTestTone
        guard !isAudioOutputReady else {
            AppLogger.shared.write(
                "AUDIO HEALTH ready reason=\(reason) state={\(audioOutput.diagnosticState())}"
            )
            return true
        }
        AppLogger.shared.write(
            "AUDIO HEALTH stale reason=\(reason) state={\(audioOutput.diagnosticState())}"
        )
        return configureVirtualAudioOutput(reason: reason)
    }

    private func startObservingAudioHardware() {
        guard observedAudioHardwareAddresses.isEmpty else { return }
        rememberCurrentUserInputDeviceIfNeeded(reason: "audio_monitor_start")
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
                AppLogger.shared.write(
                    "AUDIO RECOVERY listener_failed selector=\(selector) " +
                        AppLogger.errorFields(domain: "os_status", code: Int(result))
                )
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
            if details == "properties=default_input" {
                self.rememberCurrentUserInputDeviceIfNeeded(reason: "hardware_change")
            }
            guard !self.settings.selectedAudioDeviceUID.isEmpty else {
                AppLogger.shared.write("AUDIO RECOVERY ignored reason=\(reason) detail=\(details) no_selected_device")
                return
            }
            guard details != "properties=default_input" else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) explicit_output_unchanged"
                )
                return
            }
            let configurationHealthy = self.audioOutput.isConfigurationHealthyForDiagnostics
            guard !VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
                details: details,
                configurationHealthy: configurationHealthy
            ) else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) " +
                        "explicit_output_healthy=true state={\(self.audioOutput.diagnosticState())}"
                )
                return
            }
            guard self.shouldKeepVirtualAudioActive else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) virtual_audio_inactive"
                )
                return
            }
            self.audioRecoveryCoalescingState.recordEvent()
            self.audioRecoveryGeneration &+= 1
            let generation = self.audioRecoveryGeneration
            self.audioRecoveryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.started,
                      self.audioRecoveryGeneration == generation
                else { return }
                let coalescedEvents = self.audioRecoveryCoalescingState.consumePendingEventCount()
                AppLogger.shared.write(
                    "AUDIO RECOVERY begin id=\(generation) reason=\(reason) detail=\(details) " +
                        "coalesced_events=\(coalescedEvents) " +
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
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
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

        cancelVirtualAudioReleaseIfPending(trigger: "test_tone_start")
        guard ensureVirtualAudioOutputReady(reason: "test_tone") else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_configure_failed")
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
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_start_failed")
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
        releaseVirtualAudioOutputIfUnused(reason: "test_tone_finished")
    }

    private func cancelTestToneIfNeeded(statusMessage: LocalizedMessage, logReason: String) {
        guard isPlayingTestTone else { return }
        testToneGeneration &+= 1
        isPlayingTestTone = false
        audioOutput.cancelTestTone()
        testToneStatus = statusMessage
        AppLogger.shared.write("AUDIO TEST_TONE cancelled reason=\(logReason)")
    }

    func applyHIDSettings(allowVoiceKeyModeFallback: Bool = true) {
        let permissionSnapshot = HIDPermissionSnapshot.current
        appliedHIDPermissionSnapshot = permissionSnapshot
        if !permissionSnapshot.accessibilityGranted {
            _ = releaseVoiceKeyIfNeeded()
        }
        if started, permissionSnapshot.inputMonitoringGranted {
            preferredInputSourceMonitor.start()
        } else {
            preferredInputSourceMonitor.stop(
                preservingExplicitVoiceSession:
                    voiceKeyLatch.isHeld && heldVoiceKeyMode?.requiresAccessibility == true
            )
        }
        if !settings.customMappingEnabled {
            stopLongRecording(reason: "mapping_disabled")
        }
        if !settings.experimentalContinuousRecordingEnabled {
            stopLongRecording(reason: "feature_disabled")
        }

        let requestedVoiceKeyMode = settings.voiceKeyMode
        let accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
        let requestedFnTapMode = settings.voiceFnTapModeEnabled && requestedVoiceKeyMode == .function
        if settings.voiceFnTapModeEnabled != requestedFnTapMode {
            settings.voiceFnTapModeEnabled = requestedFnTapMode
        }
        if !requestedFnTapMode, voiceFnTapSession.requiresCleanupBeforeMapping {
            voiceFnTapSession.setEnabled(false) { [weak self] in
                self?.applyHIDSettings(
                    allowVoiceKeyModeFallback: allowVoiceKeyModeFallback
                )
            }
            return
        }
        requestNextHIDPermissionIfNeeded(
            voiceFnTapModeRequested: requestedFnTapMode,
            voiceKeyModeRequested: requestedVoiceKeyMode
        )
        let canFallbackVoiceKeyMode = Self.canFallbackVoiceKeyMode(
            isStreaming: isStreaming,
            allowVoiceKeyModeFallback: allowVoiceKeyModeFallback
        )
        var powerKeySuppressed: Bool
        if requestedFnTapMode, accessibilityGranted {
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if voiceFunctionMapper.isVoiceKeyNeutralized {
                voiceFnTapSession.setEnabled(true)
            } else if !canFallbackVoiceKeyMode, isStreaming {
                AppLogger.shared.write(
                    "VOICE FN TAP mode_preserved reason=voice_active_mapping_failed"
                )
            } else if !canFallbackVoiceKeyMode {
                AppLogger.shared.write(
                    "VOICE FN TAP mode_preserved reason=voice_start_mapping_failed"
                )
            } else if HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure(
                hasMatchingServices: voiceFunctionMapper.hasMatchingServices
            ) {
                voiceFnTapSession.setEnabled(false)
                AppLogger.shared.write(
                    "VOICE FN TAP mode_pending_mapping reason=no_matching_service"
                )
                scheduleHIDMappingRecoveryIfNeeded()
            } else {
                settings.voiceFnTapModeEnabled = false
                voiceFnTapSession.setEnabled(false)
                powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            }
        } else if requestedVoiceKeyMode != .function {
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if !voiceFunctionMapper.isVoiceKeyNeutralized {
                if voiceFunctionMapper.hasMatchingServices {
                    if isStreaming {
                        voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                        AppLogger.shared.write(
                            "VOICE KEY mode_preserved reason=voice_active_mapping_failed " +
                                "mode=\(requestedVoiceKeyMode.rawValue)"
                        )
                    } else if canFallbackVoiceKeyMode {
                        settings.voiceKeyMode = .function
                        powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
                        AppLogger.shared.write(
                            "VOICE KEY mode_fallback reason=voice_mapping_failed " +
                                "mode=\(requestedVoiceKeyMode.rawValue)"
                        )
                    } else {
                        voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                        AppLogger.shared.write(
                            "VOICE KEY mode_preserved reason=voice_start_mapping_failed " +
                                "mode=\(requestedVoiceKeyMode.rawValue)"
                        )
                    }
                } else if !accessibilityGranted {
                    voiceShortcutStatus = LocalizedMessage(
                        "connection.voice_key_mode.command_permission"
                    )
                    AppLogger.shared.write(
                        "VOICE KEY mode_pending_permission_and_mapping " +
                            "mode=\(requestedVoiceKeyMode.rawValue)"
                    )
                } else {
                    voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                    AppLogger.shared.write(
                        "VOICE KEY mode_pending_mapping reason=no_matching_service " +
                            "mode=\(requestedVoiceKeyMode.rawValue)"
                    )
                }
            } else if !accessibilityGranted {
                voiceShortcutStatus = LocalizedMessage(
                    "connection.voice_key_mode.command_permission"
                )
                AppLogger.shared.write(
                    "VOICE KEY mode_pending_permission mode=\(requestedVoiceKeyMode.rawValue)"
                )
            }
        } else {
            if requestedFnTapMode {
                settings.voiceFnTapModeEnabled = false
            }
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
        }
        startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
        completeHIDMappingRecoveryIfNeeded()
    }

    private func scheduleHIDMappingRecoveryIfNeeded() {
        guard hidMappingRecoveryWorkItem == nil else { return }
        guard let delay = HIDMappingRecoveryPolicy.retryDelay(
            forAttempt: hidMappingRecoveryAttempt,
            started: started,
            readyBridgeCount: readyBluetoothBridgeCount,
            hasMatchingServices: voiceFunctionMapper.hasMatchingServices
        ) else {
            if started,
               readyBluetoothBridgeCount > 0,
               !voiceFunctionMapper.hasMatchingServices,
               hidMappingRecoveryAttempt == HIDMappingRecoveryPolicy.retryDelays.count {
                AppLogger.shared.write(
                    "HID MAPPING RECOVERY exhausted attempts=\(hidMappingRecoveryAttempt) " +
                        "ready_bridges=\(readyBluetoothBridgeCount)"
                )
            }
            return
        }

        let attempt = hidMappingRecoveryAttempt + 1
        hidMappingRecoveryAttempt = attempt
        hidMappingRecoveryGeneration &+= 1
        let generation = hidMappingRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hidMappingRecoveryGeneration == generation else { return }
            self.hidMappingRecoveryWorkItem = nil
            guard self.started,
                  self.readyBluetoothBridgeCount > 0,
                  !self.voiceFunctionMapper.hasMatchingServices
            else {
                self.cancelHIDMappingRecovery(reason: "conditions_changed")
                return
            }
            AppLogger.shared.write(
                "HID MAPPING RECOVERY applying attempt=\(attempt) " +
                    "ready_bridges=\(self.readyBluetoothBridgeCount)"
            )
            self.applyHIDSettings()
            if !self.voiceFunctionMapper.hasMatchingServices {
                self.scheduleHIDMappingRecoveryIfNeeded()
            }
        }
        hidMappingRecoveryWorkItem = workItem
        AppLogger.shared.write(
            "HID MAPPING RECOVERY scheduled attempt=\(attempt) " +
                "delay_ms=\(Int(delay * 1_000)) ready_bridges=\(readyBluetoothBridgeCount)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func completeHIDMappingRecoveryIfNeeded() {
        guard voiceFunctionMapper.hasMatchingServices,
              hidMappingRecoveryWorkItem != nil || hidMappingRecoveryAttempt > 0
        else { return }
        let attempts = hidMappingRecoveryAttempt
        hidMappingRecoveryGeneration &+= 1
        hidMappingRecoveryWorkItem?.cancel()
        hidMappingRecoveryWorkItem = nil
        hidMappingRecoveryAttempt = 0
        AppLogger.shared.write(
            "HID MAPPING RECOVERY completed attempts=\(attempts) " +
                "matched=\(voiceFunctionMapper.matchedServiceCount)"
        )
    }

    private func cancelHIDMappingRecovery(reason: String) {
        guard hidMappingRecoveryWorkItem != nil || hidMappingRecoveryAttempt > 0 else { return }
        let attempts = hidMappingRecoveryAttempt
        hidMappingRecoveryGeneration &+= 1
        hidMappingRecoveryWorkItem?.cancel()
        hidMappingRecoveryWorkItem = nil
        hidMappingRecoveryAttempt = 0
        AppLogger.shared.write(
            "HID MAPPING RECOVERY cancelled reason=\(reason) attempts=\(attempts)"
        )
    }

    private func startHIDMonitors(powerKeySuppressed: Bool) {
        stopHIDMonitors()
        hidPowerKeySuppressed = powerKeySuppressed
        hidAllowedLocationIDs = settings.customMappingEnabled
            ? voiceFunctionMapper.powerSuppressedLocationIDs
            : nil
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
            monitor.start(
                powerKeySuppressed: powerKeySuppressed,
                allowedLocationIDs: hidAllowedLocationIDs
            )
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
        monitor.start(
            powerKeySuppressed: hidPowerKeySuppressed,
            allowedLocationIDs: hidAllowedLocationIDs
        )
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
            ownsEventSuppressor: false,
            actionPerformer: { [weak self] _, _, configured in
                self?.performExternalConfiguredAction(configured) ?? false
            },
            overrideActionPerformer: { [weak self] profileID, button, trigger in
                self?.performButtonProfileBoundAction(
                    profileID: profileID,
                    button: button,
                    trigger: trigger
                ) == true
            },
            hasOverrideBinding: { [weak self] profileID, button, trigger in
                self?.macroFeature.hasActiveBinding(
                    profileID: profileID,
                    button: button,
                    trigger: trigger
                ) == true
            }
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
            self.lastRemoteButtonPress = button
            let existingProfileID = profileID
                ?? self.settings.profileID(forHIDFingerprint: fingerprint)
            let resolvedProfileID = existingProfileID
                ?? self.settings.registerHIDRemote(fingerprint: fingerprint)
            if resolvedProfileID == self.settings.selectedRemoteProfileID,
               self.macroFeature.isEditorActive {
                self.macroFeature.noteButtonInteraction(button: button)
            }
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
            if self.macroFeature.isEditorActive {
                AppLogger.shared.write(
                    "HID BUTTON button=\(button.rawValue) path=binding_editor_capture"
                )
            }
            return (resolvedProfileID, !self.macroFeature.isEditorActive)
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
        guard settings.voiceKeyMode == .function else {
            settings.voiceFnTapModeEnabled = false
            return
        }
        if enabled {
            enableVoiceFnTapMode()
            return
        }
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false) { [weak self] in
            self?.applyHIDSettings()
        }
    }

    func importConfiguration(from data: Data) throws {
        let changedVoiceKeyConfiguration: Bool
        do {
            changedVoiceKeyConfiguration = try Self.importConfiguration(
                from: data,
                into: settings,
                isStreaming: isStreaming,
                releaseVoiceKey: { releaseVoiceKeyIfNeeded() }
            )
        } catch AppConfigurationError.unsafeVoiceKeyChange {
            AppLogger.shared.write(
                "CONFIGURATION IMPORT rejected reason=unsafe_voice_key_change"
            )
            throw AppConfigurationError.unsafeVoiceKeyChange
        }
        if changedVoiceKeyConfiguration {
            preferredInputSourceMonitor.endVoiceSession()
        }
        applyAudioSettings(reason: "configuration_import")
        applyHIDSettings()
    }

    func setVoiceKeyMode(_ mode: VoiceKeyMode) {
        guard mode != settings.voiceKeyMode else { return }
        let previousMode = settings.voiceKeyMode.rawValue
        AppLogger.shared.write(
            "VOICE KEY mode_change requested from=\(previousMode) to=\(mode.rawValue)"
        )
        guard !isStreaming else {
            AppLogger.shared.write(
                "VOICE KEY mode_change_rejected reason=voice_active requested=\(mode.rawValue)"
            )
            return
        }

        guard releaseVoiceKeyIfNeeded() else {
            AppLogger.shared.write(
                "VOICE KEY mode_change_rejected reason=release_failed requested=\(mode.rawValue)"
            )
            return
        }
        preferredInputSourceMonitor.endVoiceSession()
        if mode != .function {
            settings.voiceFnTapModeEnabled = false
            voiceFnTapSession.setEnabled(false) { [weak self] in
                guard let self else { return }
                self.settings.voiceKeyMode = mode
                self.applyHIDSettings()
                AppLogger.shared.write(
                    "VOICE KEY mode_change completed from=\(previousMode) to=\(mode.rawValue) result=applied"
                )
            }
            return
        }

        settings.voiceKeyMode = .function
        applyHIDSettings()
        AppLogger.shared.write(
            "VOICE KEY mode_change completed from=\(previousMode) to=fn result=applied"
        )
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
            voiceFnTapSession.setEnabled(false)
            if HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure(
                hasMatchingServices: voiceFunctionMapper.hasMatchingServices
            ) {
                settings.voiceFnTapModeEnabled = true
                AppLogger.shared.write(
                    "VOICE FN TAP mode_pending_mapping reason=no_matching_service"
                )
                startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
                scheduleHIDMappingRecoveryIfNeeded()
                return
            }
            settings.voiceFnTapModeEnabled = false
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
        voiceFnTapModeRequested: Bool? = nil,
        voiceKeyModeRequested: VoiceKeyMode? = nil
    ) {
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeRequested ?? settings.voiceFnTapModeEnabled,
            voiceKeyMode: voiceKeyModeRequested ?? settings.voiceKeyMode,
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
        let bridgeObjectID = ObjectIdentifier(bridge)
        let previousState = bluetoothBridgeStates[bridgeObjectID]
        let shouldReapplyHIDSettings = Self.shouldReapplyHIDSettings(
            previousState: previousState,
            currentState: state
        )
        bluetoothBridgeStates[bridgeObjectID] = state
        if case .ready = state {
            _ = registerBluetoothBridgeIfNeeded(bridge)
            voiceFnTapSession.resume()
            if shouldReapplyHIDSettings {
                applyHIDSettings()
                scheduleHIDMappingRecoveryIfNeeded()
            }
        } else {
            if readyBluetoothBridgeCount == 0 {
                cancelHIDMappingRecovery(reason: "bluetooth_not_ready")
            }
            let identifier = bluetoothIdentifier(for: bridge)
            if let identifier,
               let profileID = settings.profileID(forBluetoothIdentifier: identifier) {
                remoteBatteryLevels.removeValue(forKey: profileID)
                remotePowerStates.removeValue(forKey: profileID)
            }
            let voiceWasActive = identifier == activeBluetoothVoiceDeviceIdentifier
            if voiceWasActive {
                if rc003VoiceExtensionTestEnabled,
                   rc003VoiceExtensionActive,
                   rc003VoiceExtensionBridge === bridge {
                    finishRC003VoiceExtensionTest(reason: "bluetooth_not_ready")
                }
                bluetoothVoiceActive = false
                activeBluetoothVoiceDeviceIdentifier = nil
                releaseVoiceKeyIfNeeded(owner: .bluetooth, forceSoftware: false)
                endVoiceSessionIfNeeded(flushAudio: false)
            }
            if longRecordingRequested {
                finishLongRecording(reason: "bluetooth_not_ready")
            }
        }
        refreshBluetoothPresentation()
        if isConnected {
            voiceFnTapSession.resume()
            if shouldKeepVirtualAudioActive {
                cancelVirtualAudioReleaseIfPending(trigger: "bluetooth_ready")
                _ = ensureVirtualAudioOutputReady(reason: "bluetooth_ready")
            } else if !isAudioOutputReady {
                AppLogger.shared.write(
                    "AUDIO REBIND deferred reason=bluetooth_ready " +
                        "system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                        "reasons=\(systemAudioSuspensionState.diagnostic)"
                )
            }
        } else {
            voiceFnTapSession.suspend { [weak self] in
                self?.releaseVirtualAudioOutputIfUnused(reason: "bluetooth_not_ready")
            }
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        guard let identifier = bridge.deviceIdentifier else { return }
        let isRC003Continuation = rc003VoiceExtensionTestEnabled &&
            rc003VoiceExtensionActive &&
            rc003VoiceExtensionAwaitingReopen &&
            rc003VoiceExtensionBridge === bridge
        let profileID = activateRemoteProfile(for: bridge)
        if let activeBluetoothVoiceDeviceIdentifier,
           activeBluetoothVoiceDeviceIdentifier != identifier {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected_busy")
            return
        }
        if settings.voiceKeyMode != .function || settings.voiceFnTapModeEnabled {
            applyHIDSettings(allowVoiceKeyModeFallback: false)
        }
        guard Self.canStartBluetoothVoice(
            mode: settings.voiceKeyMode,
            voiceFnTapModeEnabled: settings.voiceFnTapModeEnabled,
            isVoiceKeyNeutralized: voiceFunctionMapper.isVoiceKeyNeutralized
        ) else {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write(
                "ATVV STREAM rejected reason=voice_key_not_neutralized " +
                    "mode=\(settings.voiceKeyMode.rawValue)"
            )
            return
        }
        guard ensureVirtualAudioOutputReady(reason: "bluetooth_voice_start") else {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected_audio_output")
            return
        }
        activeBluetoothVoiceDeviceIdentifier = identifier
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = true
        guard updateVoiceKeyState(
            streaming: true,
            forceSoftware: false,
            owner: .bluetooth
        ) else {
            _ = bridge.requestMicrophoneClose()
            bluetoothVoiceActive = false
            activeBluetoothVoiceDeviceIdentifier = nil
            AppLogger.shared.write(
                "ATVV STREAM rejected reason=voice_key mode=\(settings.voiceKeyMode.rawValue)"
            )
            return
        }
        let model = profileID
            .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
            ?? .unknown
        bluetoothVoiceTraceCounter &+= 1
        activeBluetoothVoiceTraceID = bluetoothVoiceTraceCounter
        bluetoothVoiceTraceStartedAt = Date()
        bluetoothVoiceTraceModel = model
        bluetoothVoiceDecodedBatchCount = 0
        bluetoothVoiceDecodedSampleCount = 0
        resetCurrentVoiceSampleReceipt()
        bluetoothVoiceEnqueueFailureCount = 0
        bluetoothVoiceTraceRoute = "none"
        bluetoothVoiceTailDiagnostics.reset()
        AppLogger.shared.write(
            "ATVV STREAM accepted trace=\(bluetoothVoiceTraceCounter) model=\(model.rawValue)"
        )
        cancelVirtualAudioReleaseIfPending(trigger: "bluetooth_voice_start")
        if !isAudioOutputReady {
            let configured = configureVirtualAudioOutput(reason: "bluetooth_voice_start")
            AppLogger.shared.write(
                "SYSTEM AUDIO voice_start_recovery configured=\(configured) " +
                    "suspended=\(systemAudioSuspensionState.isSuspended) " +
                    "reasons=\(systemAudioSuspensionState.diagnostic)"
            )
        }
        if longRecordingRequested {
            longRecordingOpenTimer?.cancel()
            longRecordingOpenTimer = nil
            AppLogger.shared.write("LONG RECORDING started")
        }
        if isRC003Continuation {
            rc003VoiceExtensionAwaitingReopen = false
            rc003VoiceExtensionDidReceiveAudio = false
            rc003VoiceExtensionOpenTimer?.cancel()
            rc003VoiceExtensionOpenTimer = nil
            AppLogger.shared.write(
                "RC003 EXTENSION physical_segment_reopened trace=\(activeBluetoothVoiceTraceID ?? 0)"
            )
        } else {
            _ = voiceFnTapSession.startVoice()
            beginVoiceSessionIfNeeded()
            if rc003VoiceExtensionTestEnabled {
                rc003VoiceExtensionActive = true
                rc003VoiceExtensionAwaitingReopen = false
                rc003VoiceExtensionDidReceiveAudio = false
                rc003VoiceExtensionBridge = bridge
                rc003VoiceExtensionGeneration &+= 1
                scheduleRC003VoiceExtensionDeadline(
                    generation: rc003VoiceExtensionGeneration
                )
                AppLogger.shared.write(
                    "RC003 EXTENSION test_started max_duration_s=\(Int(Self.rc003VoiceExtensionMaximumDuration))"
                )
            }
        }
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        guard bridge.deviceIdentifier == activeBluetoothVoiceDeviceIdentifier else { return }
        if rc003VoiceExtensionTestEnabled,
           rc003VoiceExtensionActive,
           rc003VoiceExtensionBridge === bridge {
            bluetoothVoiceActive = false
            loggedBluetoothVoiceAudioDeviceIdentifier = nil
            rc003VoiceExtensionAwaitingReopen = true
            rc003VoiceExtensionDidReceiveAudio = false
            rc003VoiceExtensionTimer?.cancel()
            rc003VoiceExtensionTimer = nil
            rc003VoiceExtensionGeneration &+= 1
            let opened = bridge.requestMicrophoneOpen()
            if opened {
                scheduleRC003VoiceExtensionOpenTimeout(
                    generation: rc003VoiceExtensionGeneration
                )
            } else {
                finishRC003VoiceExtensionTest(reason: "reopen_rejected")
            }
            AppLogger.shared.write(
                "RC003 EXTENSION physical_stop reopen_requested=\(opened) " +
                    "generation=\(rc003VoiceExtensionGeneration)"
            )
            return
        }
        activeBluetoothVoiceDeviceIdentifier = nil
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = false
        releaseVoiceKeyIfNeeded(owner: .bluetooth, forceSoftware: false)
        if longRecordingRequested {
            finishLongRecording(reason: "remote_stop")
        } else if longRecordingCloseTimer != nil {
            longRecordingCloseTimer?.cancel()
            longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_confirmed")
        }
        let handledByFnTapMode = voiceFnTapSession.stopVoice()
        let traceID = activeBluetoothVoiceTraceID ?? 0
        let durationMilliseconds = bluetoothVoiceTraceStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0) * 1_000))
        } ?? 0
        let shouldFlushAudio = BluetoothVoiceStopPolicy.shouldFlushAudio(
            handledByFnTapMode: handledByFnTapMode
        )
        let pendingBuffers = audioOutput.pendingVoiceBufferCountForDiagnostics
        let tailSnapshot = bluetoothVoiceTailDiagnostics.snapshot(
            at: ProcessInfo.processInfo.systemUptime
        )
        AppLogger.shared.write(
            "ATVV STREAM summary trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue) " +
                "duration_ms=\(durationMilliseconds) batches=\(bluetoothVoiceDecodedBatchCount) " +
                "samples=\(bluetoothVoiceDecodedSampleCount) " +
                "enqueue_failures=\(bluetoothVoiceEnqueueFailureCount) " +
                "route=\(bluetoothVoiceTraceRoute) pending_buffers=\(pendingBuffers) " +
                "flush=\(shouldFlushAudio) audio_ready=\(audioOutput.isReadyForTestTone) " +
                "audio_state={\(audioOutput.diagnosticState())}"
        )
        AppLogger.shared.write(
            "ATVV STREAM tail trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue) " +
                "route=\(bluetoothVoiceTraceRoute) " +
                "fn_pressed_at_stop=\(preferredInputSourceMonitor.functionKeyIsPressedForDiagnostics) " +
                "last_audio_age_ms=\(tailSnapshot.lastAudioAgeMilliseconds.map(String.init) ?? "none") " +
                "tail_ms=\(tailSnapshot.durationMilliseconds) " +
                "tail_samples=\(tailSnapshot.sampleCount) " +
                "tail_nonzero=\(tailSnapshot.nonZeroSampleCount) " +
                "tail_peak=\(tailSnapshot.peak) tail_rms=\(tailSnapshot.rms) " +
                "final_window_ms=\(tailSnapshot.finalWindowDurationMilliseconds) " +
                "final_window_samples=\(tailSnapshot.finalWindowSampleCount) " +
                "final_window_nonzero=\(tailSnapshot.finalWindowNonZeroSampleCount) " +
                "final_window_peak=\(tailSnapshot.finalWindowPeak) " +
                "final_window_rms=\(tailSnapshot.finalWindowRMS)"
        )
        audioOutput.logWhenPendingVoiceAudioDrains(
            context: "trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue)"
        )
        activeBluetoothVoiceTraceID = nil
        bluetoothVoiceTraceStartedAt = nil
        bluetoothVoiceTailDiagnostics.reset()
        endVoiceSessionIfNeeded(flushAudio: shouldFlushAudio)
        if systemAudioSuspensionState.isSuspended {
            releaseVirtualAudioOutputIfUnused(reason: "system_suspended_after_bluetooth_voice")
        }
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        guard let identifier = bridge.deviceIdentifier,
              identifier == activeBluetoothVoiceDeviceIdentifier
        else { return }
        recordingAssetCoordinator.append(samples: samples)
        let deliveryGeneration = voiceAudioDeliveryDiagnostic.generation
        let handledByFnTapMode = voiceFnTapSession.receive(samples)
        let enqueued: Bool
        if handledByFnTapMode {
            enqueued = true
        } else {
            enqueued = audioOutput.enqueue(
                samples: samples,
                deliveryGeneration: deliveryGeneration
            )
            recordVoiceAudioEnqueueOutcome(
                accepted: enqueued,
                deliveryGeneration: deliveryGeneration
            )
        }
        recordVoiceAudioReceipt(
            samples: samples,
            route: handledByFnTapMode ? .virtualAudioViaFnTap : .virtualAudioDirect
        )
        bluetoothVoiceDecodedBatchCount += 1
        bluetoothVoiceDecodedSampleCount += samples.count
        bluetoothVoiceTailDiagnostics.append(samples, at: ProcessInfo.processInfo.systemUptime)
        publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: samples.count)
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
        if rc003VoiceExtensionTestEnabled,
           rc003VoiceExtensionActive,
           rc003VoiceExtensionBridge === bridge,
           !rc003VoiceExtensionAwaitingReopen,
           !rc003VoiceExtensionDidReceiveAudio {
            rc003VoiceExtensionDidReceiveAudio = true
            startRC003VoiceExtensionTimer()
            AppLogger.shared.write(
                "RC003 EXTENSION AUDIO_READY session_segment=\(activeBluetoothVoiceTraceID ?? 0) " +
                    "samples=\(samples.count)"
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
            guard self.isPhoneRemoteConnectionEnabled else {
                completion(false)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "允许“\(deviceName)”连接无线麦？"
            if Self.isAppleWatchDeviceName(deviceName) {
                alert.informativeText = "这块 Apple Watch 将与无线麦通信，代替实体遥控器发送按键和麦克风声音。请确认 Apple Watch 上显示的 2 位校验码与下方一致。允许后，本次安装会成为受信任设备。"
            } else {
                alert.informativeText = "这台 iPhone 将与无线麦通信，代替实体遥控器发送按键和麦克风声音。请确认 iPhone 上显示的 2 位校验码与下方一致。允许后，本次安装会成为受信任设备。"
            }
            let codeLabel = NSTextField(labelWithString: pairingCode.map(String.init).joined(separator: " "))
            codeLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
            codeLabel.alignment = .center
            codeLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
            codeLabel.textColor = .controlAccentColor
            codeLabel.setAccessibilityLabel("校验码 \(pairingCode)")
            alert.accessoryView = codeLabel
            alert.addButton(withTitle: "允许连接")
            alert.addButton(withTitle: "拒绝")
            alert.addButton(withTitle: LocalizedMessage("connection.phone.cancel_waiting").text(
                using: LocalizationStore(settings: self.settings)
            ))
            self.phoneApprovalAlert = alert
            let response = alert.runModal()
            guard self.phoneApprovalAlert === alert else {
                completion(false)
                return
            }
            self.phoneApprovalAlert = nil
            if response == .alertThirdButtonReturn {
                completion(false)
                self.disablePhoneRemoteConnection()
                return
            }
            let allowed = response == .alertFirstButtonReturn
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

    nonisolated static func appRemoteButton(rawValue: String) -> RemoteButton? {
        RemoteButton(rawValue: rawValue)
    }

    nonisolated static func appRemoteButtonPhase(rawValue: String) -> RemoteButtonPhase? {
        RemoteButtonPhase(rawValue: rawValue)
    }

    nonisolated static func isAppleWatchDeviceName(_ deviceName: String) -> Bool {
        deviceName.range(of: "watch", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func performPhoneCommand(
        _ button: RemoteButton,
        source: UsageEventSource
    ) -> Bool {
        performMobileConfiguredAction(for: button, trigger: .singleClick, source: source)
    }

    private func observeMobileButton(_ button: RemoteButton, source: UsageEventSource) {
        lastMobileRemoteButtonObservation = MobileRemoteButtonObservation(
            source: source,
            button: button
        )
    }

    private func handleMobileButtonEvent(
        _ button: RemoteButton,
        phase: RemoteButtonPhase,
        source: UsageEventSource
    ) -> Bool {
        if macroFeature.isEditorActive {
            if phase == .press {
                macroFeature.noteButtonInteraction(button: button)
            }
            AppLogger.shared.write(
                "PHONE REMOTE button=\(button.rawValue) phase=\(phase.rawValue) " +
                    "path=binding_editor_capture"
            )
            return true
        }
        let profileID = settings.selectedRemoteProfileID
        let recognizesDoubleClick = settings.configuredAction(
            for: button,
            trigger: .doubleClick
        ).action != .disabled || macroFeature.hasActiveBinding(
            profileID: profileID,
            button: button,
            trigger: .doubleClick
        )
        let recognizesLongPress = settings.configuredAction(
            for: button,
            trigger: .longPress
        ).action != .disabled || macroFeature.hasActiveBinding(
            profileID: profileID,
            button: button,
            trigger: .longPress
        )

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
        if performButtonProfileBoundAction(
            profileID: settings.selectedRemoteProfileID,
            button: button,
            trigger: trigger
        ) {
            settings.recordButtonPress(control: .remoteButton(button), source: source)
            AppLogger.shared.write(
                "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) action=private_feature"
            )
            return true
        }
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
        guard performExternalConfiguredAction(configured) else {
            return false
        }
        settings.recordButtonPress(control: .remoteButton(button), source: source)
        AppLogger.shared.write(
            "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "action=\(configured.action.rawValue)"
        )
        return true
    }

    private func performButtonProfileBoundAction(
        profileID: UUID?,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        macroFeature.executeBoundAction(
            profileID: profileID,
            button: button,
            trigger: trigger,
            hostActionPerformer: { [weak self] payload in
                self?.performButtonProfileHostAction(payload) ?? false
            },
            shortcutPerformer: { [weak self] keyCode, modifiers in
                self?.performButtonProfileShortcut(keyCode: keyCode, modifiers: modifiers) ?? false
            }
        )
    }

    private func performButtonProfileHostAction(_ payload: Data) -> Bool {
        guard let configured = try? JSONDecoder().decode(ConfiguredButtonAction.self, from: payload)
        else { return false }
        if configured.action.isAppInternal {
            return performInternalAction(configured.action)
        }
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        return performExternalConfiguredAction(configured)
    }

    private func performButtonProfileShortcut(
        keyCode: UInt16,
        modifiers: [String]
    ) -> Bool {
        var modifierFlags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": modifierFlags.insert(.command)
            case "shift": modifierFlags.insert(.shift)
            case "option": modifierFlags.insert(.option)
            case "control": modifierFlags.insert(.control)
            case "function": modifierFlags.insert(.function)
            default: return false
            }
        }
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        return performExternalConfiguredAction(ConfiguredButtonAction(
            action: .customShortcut,
            shortcut: CustomKeyboardShortcut(
                keyCode: keyCode,
                modifierFlags: modifierFlags,
                keyLabel: "Key Code \(keyCode)"
            )
        ))
    }

    private func performExternalConfiguredAction(_ configured: ConfiguredButtonAction) -> Bool {
        let applicationProfile = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )
        let requestID = settings.voiceFnTapModeEnabled
            ? VoiceInputDestinationIntent.resolve(
                configured: configured,
                applicationProfile: applicationProfile
            ).map { voiceInputDestinationCoordinator.beginTargetSwitch(intent: $0) }
            : nil
        let handled = KeyboardInjector.send(
            configured.action,
            shortcut: configured.shortcut,
            applicationProfile: applicationProfile
        )
        if !handled, let requestID {
            voiceInputDestinationCoordinator.cancel(requestID: requestID, reason: .actionFailed)
        }
        return handled
    }

    private func handleVoiceInputDestinationState(_ state: VoiceInputDestinationState) {
        guard settings.voiceFnTapModeEnabled else { return }
        switch state {
        case .waiting:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting_for_input")
        case .ready:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_ready")
        case .cancelled:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_unavailable")
        }
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
              !bluetoothVoiceActive,
              activeMobileVoiceSource == nil
        else {
            AppLogger.shared.write(
                "LONG RECORDING rejected connected=\(isConnected) audio_ready=\(isAudioOutputReady) " +
                    "bluetooth_voice=\(bluetoothVoiceActive) mobile_voice=\(activeMobileVoiceSource != nil)"
            )
            return false
        }
        guard ensureVirtualAudioOutputReady(reason: "long_recording_start") else {
            AppLogger.shared.write(
                "LONG RECORDING rejected connected=true audio_ready=false " +
                    "bluetooth_voice=false mobile_voice=false"
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
    }

    private func scheduleRC003VoiceExtensionOpenTimeout(generation: UInt64) {
        rc003VoiceExtensionOpenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.rc003VoiceExtensionOpenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.rc003VoiceExtensionActive,
                  self.rc003VoiceExtensionAwaitingReopen,
                  self.rc003VoiceExtensionGeneration == generation
            else { return }
            self.finishRC003VoiceExtensionTest(reason: "reopen_timeout")
        }
        rc003VoiceExtensionOpenTimer = timer
        timer.resume()
    }

    private func scheduleRC003VoiceExtensionDeadline(generation: UInt64) {
        rc003VoiceExtensionDeadlineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.rc003VoiceExtensionMaximumDuration)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.rc003VoiceExtensionActive,
                  self.rc003VoiceExtensionGeneration == generation
            else { return }
            self.finishRC003VoiceExtensionTest(reason: "safe_timeout")
        }
        rc003VoiceExtensionDeadlineTimer = timer
        timer.resume()
    }

    private func startRC003VoiceExtensionTimer() {
        guard rc003VoiceExtensionTimer == nil,
              rc003VoiceExtensionActive,
              !rc003VoiceExtensionAwaitingReopen,
              rc003VoiceExtensionDidReceiveAudio,
              let bridge = rc003VoiceExtensionBridge
        else { return }
        let generation = rc003VoiceExtensionGeneration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.rc003VoiceExtensionInterval,
            repeating: Self.rc003VoiceExtensionInterval
        )
        timer.setEventHandler { [weak self, weak bridge] in
            guard let self,
                  let bridge,
                  self.rc003VoiceExtensionActive,
                  !self.rc003VoiceExtensionAwaitingReopen,
                  self.rc003VoiceExtensionGeneration == generation,
                  self.rc003VoiceExtensionDidReceiveAudio
            else { return }
            guard bridge.requestMicrophoneExtend() else {
                AppLogger.shared.write("RC003 EXTENSION MIC_EXTEND failed")
                self.finishRC003VoiceExtensionTest(reason: "extend_rejected")
                return
            }
            AppLogger.shared.write("RC003 EXTENSION MIC_EXTEND sent")
        }
        rc003VoiceExtensionTimer = timer
        timer.resume()
    }

    private func finishRC003VoiceExtensionTest(reason: String) {
        guard rc003VoiceExtensionActive || rc003VoiceExtensionAwaitingReopen else { return }
        let bridge = rc003VoiceExtensionBridge
        let wasStreaming = bluetoothVoiceActive
        rc003VoiceExtensionActive = false
        rc003VoiceExtensionAwaitingReopen = false
        rc003VoiceExtensionDidReceiveAudio = false
        rc003VoiceExtensionGeneration &+= 1
        rc003VoiceExtensionTimer?.cancel()
        rc003VoiceExtensionTimer = nil
        rc003VoiceExtensionOpenTimer?.cancel()
        rc003VoiceExtensionOpenTimer = nil
        rc003VoiceExtensionDeadlineTimer?.cancel()
        rc003VoiceExtensionDeadlineTimer = nil
        rc003VoiceExtensionBridge = nil
        if wasStreaming {
            _ = bridge?.requestMicrophoneClose()
            AppLogger.shared.write("RC003 EXTENSION stopping reason=\(reason) close_requested=true")
            return
        }
        activeBluetoothVoiceDeviceIdentifier = nil
        bluetoothVoiceActive = false
        _ = voiceFnTapSession.stopVoice()
        releaseVoiceKeyIfNeeded(owner: .bluetooth, forceSoftware: false)
        endVoiceSessionIfNeeded(flushAudio: true)
        AppLogger.shared.write("RC003 EXTENSION finished reason=\(reason)")
    }

    private func startPhoneVoice(source: MobileVoiceSource) -> RemoteVoiceStartResult {
        guard activeMobileVoiceSource == nil else {
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=busy requested=\(source.logName) " +
                    "active=\(activeMobileVoiceSource?.logName ?? "none")"
            )
            return .busy
        }
        cancelVirtualAudioReleaseIfPending(trigger: "mobile_voice_start_\(source.logName)")
        guard ensureVirtualAudioOutputReady(reason: "mobile_voice_start") else {
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=audio_output requested=\(source.logName)"
            )
            releaseVirtualAudioOutputIfUnused(reason: "mobile_voice_configure_failed")
            return .unavailable
        }
        guard updateVoiceKeyState(
            streaming: true,
            forceSoftware: true,
            owner: .mobile
        ) else {
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=function_key requested=\(source.logName)"
            )
            releaseVirtualAudioOutputIfUnused(reason: "mobile_voice_function_key_failed")
            return .unavailable
        }
        resetCurrentVoiceSampleReceipt()
        mobileVoiceLifecycle.markStarted(source)
        mobileVoiceAudioBatchCount = 0
        mobileVoiceAudioEnqueueFailureCount = 0
        mobileVoiceAudioSourceMismatchCount = 0
        mobileVoiceAudioSignalMetrics = WatchBluetoothAudioSignalMetrics()
        beginVoiceSessionIfNeeded()
        AppLogger.shared.write("MOBILE VOICE started source=\(source.logName)")
        return .started
    }

    private func requestPhoneVoiceStart(
        source: MobileVoiceSource,
        completion: @escaping (RemoteVoiceStartResult) -> Void
    ) {
        switch mobileVoiceLifecycle.requestStart(source) {
        case .startNow:
            completion(startPhoneVoice(source: source))
        case .deferUntilStopped:
            pendingMobileVoiceRestartCompletion = completion
            AppLogger.shared.write("MOBILE VOICE restart_deferred source=\(source.logName)")
        case .busy:
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=busy requested=\(source.logName) " +
                    "active=\(activeMobileVoiceSource?.logName ?? "none") " +
                    "stopping=\(stoppingMobileVoiceSource?.logName ?? "none")"
            )
            completion(.busy)
        }
    }

    private func stopPhoneVoice(source: MobileVoiceSource) {
        switch mobileVoiceLifecycle.beginStop(source) {
        case .ignoredInactive:
            AppLogger.shared.write(
                "MOBILE VOICE stop_ignored requested=\(source.logName) " +
                    "active=\(activeMobileVoiceSource?.logName ?? "none")"
            )
            return
        case let .ignoredAlreadyStopping(cancelledPendingRestart):
            if cancelledPendingRestart {
                let completion = pendingMobileVoiceRestartCompletion
                pendingMobileVoiceRestartCompletion = nil
                completion?(.unavailable)
                AppLogger.shared.write(
                    "MOBILE VOICE restart_cancelled source=\(source.logName) reason=stop_before_ready"
                )
            }
            AppLogger.shared.write("MOBILE VOICE stop_ignored reason=already_stopping source=\(source.logName)")
            return
        case let .begin(stopGeneration):
            logMobileVoiceAudioSummary(source: source, reason: "voice_stop")
            audioOutput.endSessionAfterDraining { [weak self] in
                guard let self else { return }
                switch self.mobileVoiceLifecycle.completeStop(
                    source,
                    generation: stopGeneration
                ) {
                case .ignored:
                    return
                case .stopped:
                    self.releaseVoiceKeyIfNeeded(owner: .mobile, forceSoftware: true)
                    self.endVoiceSessionIfNeeded()
                    AppLogger.shared.write("MOBILE VOICE stopped source=\(source.logName)")
                    self.releaseVirtualAudioOutputIfUnused(reason: "mobile_voice_stopped")
                case let .restart(restartSource):
                    self.releaseVoiceKeyIfNeeded(owner: .mobile, forceSoftware: true)
                    self.endVoiceSessionIfNeeded()
                    AppLogger.shared.write("MOBILE VOICE stopped source=\(source.logName)")
                    let completion = self.pendingMobileVoiceRestartCompletion
                    self.pendingMobileVoiceRestartCompletion = nil
                    let result = self.startPhoneVoice(source: restartSource)
                    AppLogger.shared.write(
                        "MOBILE VOICE restart_completed source=\(restartSource.logName) result=\(result)"
                    )
                    completion?(result)
                }
            }
        }
    }

    private var readyBluetoothBridgeCount: Int {
        bluetoothBridgeStates.values.reduce(into: 0) { count, state in
            if case .ready = state {
                count += 1
            }
        }
    }

    private var shouldKeepVirtualAudioActive: Bool {
        VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: readyBluetoothBridgeCount,
            bluetoothVoiceActive: bluetoothVoiceActive,
            mobileVoiceActive: activeMobileVoiceSource != nil,
            testToneActive: isPlayingTestTone,
            systemSuspended: systemAudioSuspensionState.isSuspended
        )
    }

    private var hasActiveVirtualAudioSource: Bool {
        bluetoothVoiceActive || activeMobileVoiceSource != nil || isPlayingTestTone
    }

    private func resumeVirtualAudioOutputIfNeeded(reason: String) {
        guard shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_skipped reason=\(reason) required=false " +
                    "ready_bridges=\(readyBluetoothBridgeCount) selected=\(!settings.selectedAudioDeviceUID.isEmpty)"
            )
            return
        }
        cancelVirtualAudioReleaseIfPending(trigger: "resume_\(reason)")
        guard !settings.selectedAudioDeviceUID.isEmpty else {
            AppLogger.shared.write("SYSTEM AUDIO resume_skipped reason=\(reason) selected=false")
            return
        }
        isAudioOutputReady = audioOutput.isReadyForTestTone
        guard !isAudioOutputReady else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_skipped reason=\(reason) already_ready=true " +
                    "state={\(audioOutput.diagnosticState())}"
            )
            return
        }
        let configured = configureVirtualAudioOutput(reason: reason)
        AppLogger.shared.write(
            "SYSTEM AUDIO resume_completed reason=\(reason) configured=\(configured) " +
                "selected_available=\(selectedAudioDeviceIsAvailable) " +
                "state={\(audioOutput.diagnosticState())}"
        )
    }

    private var selectedAudioDeviceIsAvailable: Bool {
        let selectedUID = settings.selectedAudioDeviceUID
        return !selectedUID.isEmpty && audioDevices.contains { $0.uid == selectedUID }
    }

    private func releaseVirtualAudioOutputIfUnused(reason: String) {
        guard !shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "AUDIO RELEASE skipped reason=\(reason) still_required=true " +
                    "system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                    "bluetooth_voice=\(bluetoothVoiceActive) " +
                    "mobile_voice=\(activeMobileVoiceSource != nil) test_tone=\(isPlayingTestTone)"
            )
            return
        }
        guard pendingVirtualAudioRelease == nil else { return }
        switchDefaultInputToFallbackIfNeeded(reason: reason)
        let pendingVoiceBufferCount = audioOutput.pendingVoiceBufferCountForDiagnostics
        guard VirtualAudioConnectionLifecyclePolicy.shouldScheduleRelease(
            hasPendingRelease: pendingVirtualAudioRelease != nil,
            hasAllocatedOutputResources: audioOutput.hasAllocatedOutputResources,
            pendingVoiceBufferCount: pendingVoiceBufferCount
        ) else {
            isAudioOutputReady = false
            testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            return
        }
        virtualAudioReleaseGeneration &+= 1
        let generation = virtualAudioReleaseGeneration
        pendingVirtualAudioRelease = (generation, reason)
        AppLogger.shared.write(
            "AUDIO RELEASE requested reason=\(reason) generation=\(generation) " +
                "system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                "pending_buffers=\(pendingVoiceBufferCount) " +
                "state={\(audioOutput.diagnosticState())}"
        )
        audioOutput.endSessionAfterDraining { [weak self] in
            guard let self else { return }
            guard self.virtualAudioReleaseGeneration == generation else {
                return
            }
            self.pendingVirtualAudioRelease = nil
            guard !self.shouldKeepVirtualAudioActive else {
                AppLogger.shared.write(
                    "AUDIO RELEASE cancelled reason=\(reason) generation=\(generation) " +
                        "cause=required_again system_suspended=\(self.systemAudioSuspensionState.isSuspended) " +
                        "bluetooth_voice=\(self.bluetoothVoiceActive) " +
                        "mobile_voice=\(self.activeMobileVoiceSource != nil) " +
                        "test_tone=\(self.isPlayingTestTone)"
                )
                return
            }
            self.audioOutput.stop()
            self.isAudioOutputReady = false
            self.testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            AppLogger.shared.write(
                "AUDIO RELEASE completed reason=\(reason) generation=\(generation) " +
                    "system_suspended=\(self.systemAudioSuspensionState.isSuspended) " +
                    "ready_bridges=\(self.readyBluetoothBridgeCount) " +
                    "state={\(self.audioOutput.diagnosticState())}"
            )
        }
    }

    private func cancelVirtualAudioReleaseIfPending(
        trigger: String,
        cause: String = "required_again"
    ) {
        guard let pendingVirtualAudioRelease else { return }
        virtualAudioReleaseGeneration &+= 1
        self.pendingVirtualAudioRelease = nil
        audioOutput.cancelPendingDrain()
        AppLogger.shared.write(
            "AUDIO RELEASE cancelled reason=\(pendingVirtualAudioRelease.reason) " +
                "generation=\(pendingVirtualAudioRelease.generation) " +
                "current_generation=\(virtualAudioReleaseGeneration) cause=\(cause) " +
                "trigger=\(trigger) system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                "ready_bridges=\(readyBluetoothBridgeCount) " +
                "bluetooth_voice=\(bluetoothVoiceActive) " +
                "mobile_voice=\(activeMobileVoiceSource != nil) test_tone=\(isPlayingTestTone)"
        )
    }

    private func switchDefaultInputToFallbackIfNeeded(reason: String) {
        guard managedDefaultInputTransition == nil else { return }
        let selectedUID = settings.selectedAudioDeviceUID
        guard !selectedUID.isEmpty,
              CoreAudioDeviceCatalog.defaultInputDevice()?.uid == selectedUID
        else { return }
        guard let fallback = preferredFallbackInput(excludingUID: selectedUID) else {
            AppLogger.shared.write("AUDIO DEFAULT_INPUT fallback_failed reason=\(reason) no_candidate")
            return
        }
        let result = CoreAudioDeviceCatalog.setDefaultInputDevice(fallback)
        guard result == noErr else {
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT fallback_failed reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(fallback))} " +
                    AppLogger.errorFields(domain: "os_status", code: Int(result))
            )
            return
        }
        managedDefaultInputTransition = ManagedDefaultInputTransition(
            virtualUID: selectedUID,
            fallbackUID: fallback.uid
        )
        AppLogger.shared.write(
            "AUDIO DEFAULT_INPUT fallback_applied reason=\(reason) " +
                "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(fallback))}"
        )
    }

    private func preferredFallbackInput(excludingUID: String) -> AudioDeviceInfo? {
        CoreAudioDeviceCatalog.preferredFallbackInput(
            excludingUID: excludingUID,
            preferredUID: settings.lastUserSelectedInputDeviceUID
        )
    }

    private func rememberCurrentUserInputDeviceIfNeeded(reason: String) {
        let current = CoreAudioDeviceCatalog.defaultInputDevice()
        let decision = DefaultInputFallbackPolicy.observationDecision(
            currentUID: current?.uid,
            selectedVirtualUID: settings.selectedAudioDeviceUID,
            managedFallbackUID: managedDefaultInputTransition?.fallbackUID,
            lastRememberedUID: settings.lastUserSelectedInputDeviceUID
        )
        switch decision {
        case .ignore:
            return
        case .clearManagedTransition:
            managedDefaultInputTransition = nil
            return
        case let .remember(uid, clearManagedTransition):
            if clearManagedTransition {
                managedDefaultInputTransition = nil
            }
            settings.lastUserSelectedInputDeviceUID = uid
        }
        AppLogger.shared.write(
            "AUDIO DEFAULT_INPUT remembered reason=\(reason) target={\(CoreAudioDeviceCatalog.deviceDiagnostic(current))}"
        )
    }

    private func restoreManagedDefaultInputIfAppropriate(reason: String) {
        guard let transition = managedDefaultInputTransition else { return }
        let currentDefault = CoreAudioDeviceCatalog.defaultInputDevice()
        guard DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: transition.virtualUID,
            selectedVirtualUID: settings.selectedAudioDeviceUID,
            managedFallbackUID: transition.fallbackUID,
            currentDefaultUID: currentDefault?.uid
        ) else {
            managedDefaultInputTransition = nil
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_skipped reason=\(reason) current={\(CoreAudioDeviceCatalog.deviceDiagnostic(currentDefault))}"
            )
            return
        }
        guard let virtualInput = CoreAudioDeviceCatalog.inputDevices().first(where: {
            $0.uid == transition.virtualUID
        }) else {
            AppLogger.shared.write("AUDIO DEFAULT_INPUT restore_failed reason=\(reason) virtual_unavailable")
            return
        }
        let result = CoreAudioDeviceCatalog.setDefaultInputDevice(virtualInput)
        if result == noErr {
            managedDefaultInputTransition = nil
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_applied reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(virtualInput))}"
            )
        } else {
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_failed reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(virtualInput))} " +
                    AppLogger.errorFields(domain: "os_status", code: Int(result))
            )
        }
    }

    private func receivePhoneAudio(_ samples: [Int16], source: MobileVoiceSource) {
        guard activeMobileVoiceSource == source else {
            mobileVoiceAudioSourceMismatchCount += 1
            if mobileVoiceAudioSourceMismatchCount == 1 ||
                mobileVoiceAudioSourceMismatchCount.isMultiple(of: 20) {
                AppLogger.shared.write(
                    "MOBILE VOICE audio_dropped reason=source_mismatch requested=\(source.logName) " +
                        "active=\(activeMobileVoiceSource?.logName ?? "none") " +
                        "count=\(mobileVoiceAudioSourceMismatchCount)"
                )
            }
            return
        }
        recordingAssetCoordinator.append(samples: samples)
        publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: samples.count)
        mobileVoiceAudioBatchCount += 1
        mobileVoiceAudioSignalMetrics.append(samples)
        let deliveryGeneration = voiceAudioDeliveryDiagnostic.generation
        let accepted = audioOutput.enqueue(
            samples: samples,
            deliveryGeneration: deliveryGeneration
        )
        recordVoiceAudioReceipt(
            samples: samples,
            route: .virtualAudioDirect
        )
        recordVoiceAudioEnqueueOutcome(
            accepted: accepted,
            deliveryGeneration: deliveryGeneration
        )
        if !accepted { mobileVoiceAudioEnqueueFailureCount += 1 }
        if mobileVoiceAudioBatchCount == 1 || mobileVoiceAudioBatchCount.isMultiple(of: 20) {
            AppLogger.shared.write(
                "MOBILE VOICE audio source=\(source.logName) batches=\(mobileVoiceAudioBatchCount) " +
                    "samples=\(mobileVoiceAudioSignalMetrics.sampleCount) " +
                    "nonzero=\(mobileVoiceAudioSignalMetrics.nonZeroSampleCount) " +
                    "peak=\(mobileVoiceAudioSignalMetrics.peak) rms=\(mobileVoiceAudioSignalMetrics.rms) " +
                    "accepted=\(accepted) enqueue_failures=\(mobileVoiceAudioEnqueueFailureCount) " +
                    "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
            )
        }
    }

    private func logMobileVoiceAudioSummary(source: MobileVoiceSource, reason: String) {
        AppLogger.shared.write(
            "MOBILE VOICE audio_summary source=\(source.logName) reason=\(reason) " +
                "batches=\(mobileVoiceAudioBatchCount) " +
                "samples=\(mobileVoiceAudioSignalMetrics.sampleCount) " +
                "nonzero=\(mobileVoiceAudioSignalMetrics.nonZeroSampleCount) " +
                "peak=\(mobileVoiceAudioSignalMetrics.peak) rms=\(mobileVoiceAudioSignalMetrics.rms) " +
                "enqueue_failures=\(mobileVoiceAudioEnqueueFailureCount) " +
                "source_mismatches=\(mobileVoiceAudioSourceMismatchCount) " +
                "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
        )
    }

    private func resetCurrentVoiceSampleReceipt() {
        guard hasReceivedCurrentVoiceSamples else { return }
        hasReceivedCurrentVoiceSamples = false
    }

    private func publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: Int) {
        guard VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedCurrentVoiceSamples,
            sampleCount: sampleCount
        ) else { return }
        hasReceivedCurrentVoiceSamples = true
    }

    func voiceAudioDeliveryDiagnosticSnapshot() -> VoiceAudioDeliveryDiagnostic {
        var diagnostic = voiceAudioDeliveryDiagnostic
        diagnostic.outputAtObservation = audioOutput.diagnosticSnapshot(
            deliveryGeneration: diagnostic.generation
        )
        return diagnostic
    }

    private func recordVoiceAudioReceipt(
        samples: [Int16],
        route: VoiceAudioDeliveryRoute
    ) {
        guard !samples.isEmpty, voiceAudioDeliveryDiagnostic.generation > 0 else { return }
        voiceAudioDeliveryDiagnostic.route = route
        voiceAudioDeliveryDiagnostic.receivedBatches += 1
        voiceAudioDeliveryDiagnostic.receivedSamples += samples.count
        voiceAudioDeliveryDiagnostic.outputAtObservation = audioOutput.diagnosticSnapshot(
            deliveryGeneration: voiceAudioDeliveryDiagnostic.generation
        )
    }

    private func recordVoiceAudioEnqueueOutcome(
        accepted: Bool,
        deliveryGeneration: Int
    ) {
        guard !accepted,
              deliveryGeneration > 0,
              voiceAudioDeliveryDiagnostic.generation == deliveryGeneration
        else { return }
        voiceAudioDeliveryDiagnostic.enqueueFailures += 1
        voiceAudioDeliveryDiagnostic.outputAtObservation = audioOutput.diagnosticSnapshot(
            deliveryGeneration: deliveryGeneration
        )
    }

    private func enqueueVoiceFnTapAudio(_ samples: [Int16]) {
        let deliveryGeneration = voiceAudioDeliveryDiagnostic.generation
        let accepted = audioOutput.enqueue(
            samples: samples,
            deliveryGeneration: deliveryGeneration
        )
        recordVoiceAudioEnqueueOutcome(
            accepted: accepted,
            deliveryGeneration: deliveryGeneration
        )
        if !accepted {
            bluetoothVoiceEnqueueFailureCount += 1
        }
    }

    private func archiveCapturedTranscript(_ capture: CapturedTranscript) {
        let transcript = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingAssetCoordinator.updateApplication(
            sessionID: capture.sessionID,
            applicationName: capture.applicationName,
            bundleIdentifier: capture.bundleIdentifier
        )
        guard settings.localTranscriptHistoryEnabled, !transcript.isEmpty else { return }
        let record = TranscriptRecord(
            sessionID: capture.sessionID,
            startedAt: capture.startedAt,
            endedAt: capture.endedAt,
            applicationName: capture.applicationName,
            bundleIdentifier: capture.bundleIdentifier,
            source: capture.source,
            originalTranscript: transcript
        )
        updateTranscriptArchive {
            try self.transcriptArchiveStore.append(record)
        }
    }

    private func updateTranscriptArchive(_ operation: @escaping () throws -> Void) {
        transcriptArchiveOperationQueue.async { [weak self] in
            guard let self else { return }
            do {
                try operation()
                let records = try transcriptArchiveStore.loadAll()
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptRecords = records
                }
            } catch {
                AppLogger.shared.write("TRANSCRIPT ARCHIVE update_failed")
            }
        }
    }

    private func beginVoiceSessionIfNeeded() {
        guard !isStreaming else { return }
        privateFeature.startVoiceSession()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.blocked_voice_active"),
            logReason: "voice_start"
        )
        let startedAt = Date()
        let source = currentVoiceUsageSource
        let sessionID = UUID()
        voiceAudioDeliveryGeneration &+= 1
        let audioSnapshot = audioOutput.diagnosticSnapshot(
            deliveryGeneration: voiceAudioDeliveryGeneration
        )
        voiceAudioDeliveryDiagnostic = VoiceAudioDeliveryDiagnostic(
            generation: voiceAudioDeliveryGeneration,
            source: source.rawValue,
            outputAtStart: audioSnapshot,
            outputAtObservation: audioSnapshot,
            countersAtStart: audioSnapshot.counters
        )
        activeVoiceSource = source
        settings.recordButtonPress(control: .voice, source: source, at: startedAt)
        voiceSessionStartedAt = startedAt
        voiceSessionID = sessionID
        voiceSessionUsageSource = source
        let frontmostApplication = FrontmostApplicationMetadata.current(
            excludingBundleIdentifier: Bundle.main.bundleIdentifier
        )
        recordingAssetCoordinator.start(
            sessionID: sessionID,
            startedAt: startedAt,
            source: source,
            applicationMetadata: frontmostApplication
        )
        if let frontmostApplication {
            AppLogger.shared.write(
                "RECORDING ASSET application_fallback " +
                    "bundle=\(frontmostApplication.bundleIdentifier)"
            )
        } else {
            AppLogger.shared.write("RECORDING ASSET application_fallback unavailable")
        }
        transcriptCaptureCoordinator.startSession(sessionID: sessionID, startedAt: startedAt, source: source)
        isStreaming = true
    }

    private func endVoiceSessionIfNeeded(flushAudio: Bool = true) {
        guard !bluetoothVoiceActive, activeMobileVoiceSource == nil, isStreaming else { return }
        let endedAt = Date()
        if let voiceSessionStartedAt {
            settings.recordVoiceDuration(
                endedAt.timeIntervalSince(voiceSessionStartedAt),
                startedAt: voiceSessionStartedAt,
                source: voiceSessionUsageSource ?? .unknown,
                at: endedAt
            )
            self.voiceSessionStartedAt = nil
        }
        voiceSessionUsageSource = nil
        let sessionID = voiceSessionID
        voiceSessionID = nil
        voiceAudioDeliveryDiagnostic.sessionEnded = true
        voiceAudioDeliveryDiagnostic.outputAtObservation = audioOutput.diagnosticSnapshot(
            deliveryGeneration: voiceAudioDeliveryDiagnostic.generation
        )
        isStreaming = false
        activeVoiceSource = nil
        if flushAudio {
            audioOutput.endSession()
        }
        privateFeature.finishVoiceSession()
        transcriptCaptureCoordinator.finishSession(endedAt: endedAt)
        if sessionID != nil {
            recordingAssetCoordinator.finish(endedAt: endedAt)
        }
    }

    private var currentVoiceUsageSource: UsageEventSource {
        if bluetoothVoiceActive { return .bluetoothRemote }
        switch activeMobileVoiceSource {
        case .nearbyPhone, .nearbyWatch: return .nearbyPhone
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
                applied
                    ? "voice_button.status.\(settings.voiceKeyMode.rawValue)_enabled"
                    : "voice_button.status.waiting"
            )
        }
        return !settings.customMappingEnabled || voiceFunctionMapper.isPowerKeySuppressed
    }

    @discardableResult
    private func updateVoiceKeyState(
        streaming: Bool,
        forceSoftware: Bool,
        owner: VoiceFunctionKeyLatch.Owner
    ) -> Bool {
        let mode = streaming ? settings.voiceKeyMode : (heldVoiceKeyMode ?? settings.voiceKeyMode)
        guard forceSoftware || !mode.usesHardwareMapping else { return true }
        guard let transition = voiceKeyLatch.transition(
            streaming: streaming,
            owner: owner
        ) else {
            return true
        }
        let shouldHold = transition == .press
        guard KeyboardInjector.setVoiceKeyPressed(mode, isPressed: shouldHold) else {
            voiceKeyLatch.rollback(transition, owner: owner)
            AppLogger.shared.write(
                "VOICE KEY \(mode.rawValue) \(shouldHold ? "DOWN" : "UP") failed"
            )
            return false
        }
        if mode != .function {
            if shouldHold {
                preferredInputSourceMonitor.beginVoiceSession()
            } else {
                preferredInputSourceMonitor.endVoiceSession()
            }
        }
        if shouldHold {
            heldVoiceKeyMode = mode
        } else {
            heldVoiceKeyMode = nil
        }
        isVoiceTriggerEnabled = !shouldHold
        voiceShortcutStatus = LocalizedMessage(
            shouldHold
                ? "voice_button.status.\(mode.rawValue)_pressed"
                : "voice_button.status.\(mode.rawValue)_released"
        )
        AppLogger.shared.write(
            "VOICE KEY mode=\(mode.rawValue) \(shouldHold ? "DOWN" : "UP")"
        )
        return true
    }

    @discardableResult
    private func releaseVoiceKeyIfNeeded(
        owner: VoiceFunctionKeyLatch.Owner,
        forceSoftware: Bool
    ) -> Bool {
        guard !updateVoiceKeyState(
            streaming: false,
            forceSoftware: forceSoftware,
            owner: owner
        ) else { return true }
        return releaseVoiceKeyIfNeeded()
    }

    @discardableResult
    private func releaseVoiceKeyIfNeeded() -> Bool {
        guard voiceKeyLatch.isHeld else {
            heldVoiceKeyMode = nil
            return true
        }
        guard let heldVoiceKeyMode else { return false }

        var forcedAfterPermissionChange = false
        var released = KeyboardInjector.setVoiceKeyPressed(
            heldVoiceKeyMode,
            isPressed: false
        )
        if !released {
            forcedAfterPermissionChange = true
            released = KeyboardInjector.setVoiceKeyPressed(
                heldVoiceKeyMode,
                isPressed: false,
                accessibilityTrusted: { true }
            )
        }
        guard released else { return false }

        voiceKeyLatch.reset()
        self.heldVoiceKeyMode = nil
        if heldVoiceKeyMode != .function {
            preferredInputSourceMonitor.endVoiceSession()
        }
        isVoiceTriggerEnabled = true
        voiceShortcutStatus = LocalizedMessage(
            "voice_button.status.\(heldVoiceKeyMode.rawValue)_released"
        )
        AppLogger.shared.write(
            "VOICE KEY mode=\(heldVoiceKeyMode.rawValue) UP" +
                (forcedAfterPermissionChange ? " forced_after_permission_change" : "")
        )
        return true
    }
}
