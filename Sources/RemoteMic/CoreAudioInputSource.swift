import Foundation
#if canImport(SayAllAudioInputKit)
import SayAllAudioInputKit
#endif

enum MicrophoneAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined
    case restricted

    var isAuthorized: Bool { self == .authorized }
}

enum MicrophonePermission {
    static var status: MicrophoneAuthorization {
#if canImport(SayAllAudioInputKit)
        switch SayAllAudioInputKit.MicrophonePermission.status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        }
#else
        return .restricted
#endif
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
#if canImport(SayAllAudioInputKit)
        SayAllAudioInputKit.MicrophonePermission.request(completion)
#else
        completion(false)
#endif
    }
}

enum ContinuousAudioPreemptor: Hashable {
    case bluetoothRemote
    case nearbyPhone
    case webRemote
}

enum ContinuousInputCommand: Equatable {
    case none
    case start
    case stop
}

struct ContinuousInputArbiter {
    private(set) var enabled = false
    private(set) var ready = false
    private(set) var capturing = false
    private(set) var preemptors = Set<ContinuousAudioPreemptor>()

    mutating func setEnabled(_ enabled: Bool) -> ContinuousInputCommand {
        self.enabled = enabled
        return reconcile()
    }

    mutating func setReady(_ ready: Bool) -> ContinuousInputCommand {
        self.ready = ready
        return reconcile()
    }

    mutating func setPreempting(_ source: ContinuousAudioPreemptor, active: Bool) -> ContinuousInputCommand {
        if active {
            preemptors.insert(source)
        } else {
            preemptors.remove(source)
        }
        return reconcile()
    }

    mutating func teardown() -> ContinuousInputCommand {
        enabled = false
        ready = false
        preemptors.removeAll()
        return reconcile()
    }

    private mutating func reconcile() -> ContinuousInputCommand {
        let shouldCapture = enabled && ready && preemptors.isEmpty
        guard shouldCapture != capturing else { return .none }
        capturing = shouldCapture
        return shouldCapture ? .start : .stop
    }
}

enum CoreAudioInputGate {
    enum Block: Equatable {
        case disabled
        case componentUnavailable
        case permission
        case inputMissing
        case outputMissing
        case sameDevice
    }

    static func block(
        enabled: Bool,
        componentAvailable: Bool = CoreAudioInputSource.isAvailable,
        authorized: Bool,
        inputUID: String,
        outputUID: String,
        outputReady: Bool
    ) -> Block? {
        guard enabled else { return .disabled }
        guard componentAvailable else { return .componentUnavailable }
        guard authorized else { return .permission }
        guard !inputUID.isEmpty else { return .inputMissing }
        guard outputReady, !outputUID.isEmpty else { return .outputMissing }
        guard inputUID != outputUID else { return .sameDevice }
        return nil
    }
}

final class CoreAudioInputSource {
    var onSamples: (([Int16], UInt64) -> Void)?
    var onFailure: ((String, UInt64) -> Void)?
    var onDeviceConfigurationChange: ((String) -> Void)?

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var isCapturing = false
    private(set) var lastError: String?

    static var isAvailable: Bool {
#if canImport(SayAllAudioInputKit)
        true
#else
        false
#endif
    }

#if canImport(SayAllAudioInputKit)
    private let capture = AudioInputCapture()

    init() {
        capture.onSamples = { [weak self] samples, session in
            self?.onSamples?(samples, session)
        }
        capture.onFailure = { [weak self] code, session in
            self?.lastError = code
            self?.isCapturing = false
            self?.onFailure?(code, session)
        }
        capture.onDeviceConfigurationChange = { [weak self] properties in
            self?.onDeviceConfigurationChange?(properties)
        }
    }
#else
    init() {}
#endif

    @discardableResult
    func start(deviceUID: String, gainDB: Double, session: UInt64) -> Bool {
#if canImport(SayAllAudioInputKit)
        let started = capture.start(deviceUID: deviceUID, gainDB: gainDB, session: session)
        lastError = capture.lastError
        isCapturing = started
        selectedDevice = capture.selectedDevice.map {
            AudioDeviceInfo(id: $0.id, uid: $0.uid, name: $0.name)
        }
        if started {
            AppLogger.shared.write(
                "AUDIO INPUT started target={\(CoreAudioDeviceCatalog.deviceDiagnostic(selectedDevice))} " +
                    "session=\(session) component=sayall-audio-input-kit"
            )
        }
        return started
#else
        lastError = "private_audio_input_component_unavailable"
        isCapturing = false
        selectedDevice = nil
        return false
#endif
    }

    func stop() {
        let wasCapturing = isCapturing
#if canImport(SayAllAudioInputKit)
        capture.stop()
#endif
        isCapturing = false
        selectedDevice = nil
        if wasCapturing { AppLogger.shared.write("AUDIO INPUT stopped") }
    }
}
