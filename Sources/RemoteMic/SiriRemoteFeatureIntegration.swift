import Foundation

#if canImport(SayAllSiriRemote)
import SayAllSiriRemote
#endif

struct SiriRemoteConnectionObservation: Equatable {
    let fingerprint: String
    let isConnected: Bool
}

struct SiriRemoteControlObservation: Equatable {
    let control: String
    let phase: String
    let fingerprintToken: String
}

final class SiriRemoteFeatureIntegration {
    var onConnection: ((SiriRemoteConnectionObservation) -> Void)?
    var onControl: ((SiriRemoteControlObservation) -> Void)?
    var onVoiceSamples: (([Int16]) -> Void)?
    var onStatus: ((String) -> Void)?

#if canImport(SayAllSiriRemote)
    private let feature: SayAllSiriRemoteFeature
#endif

    init(logger: @escaping (String) -> Void = AppLogger.shared.write) {
#if canImport(SayAllSiriRemote)
        feature = SayAllSiriRemoteFeature(logger: logger)
        feature.onConnection = { [weak self] connection in
            self?.onConnection?(SiriRemoteConnectionObservation(
                fingerprint: connection.fingerprint,
                isConnected: connection.isConnected
            ))
        }
        feature.onControlEvent = { [weak self] event in
            self?.onControl?(SiriRemoteControlObservation(
                control: event.control.rawValue,
                phase: event.phase.rawValue,
                fingerprintToken: event.device.instanceToken
            ))
        }
        feature.onSeizedSystemControlEvent = { [weak self] event in
            self?.onControl?(SiriRemoteControlObservation(
                control: event.control.rawValue,
                phase: event.phase.rawValue,
                fingerprintToken: event.device.instanceToken
            ))
        }
        feature.onSamples = { [weak self] samples in
            self?.onVoiceSamples?(samples)
        }
        feature.onStatus = { [weak self] status in
            self?.onStatus?(status)
        }
#endif
    }

    func start(customMappingEnabled: Bool) {
#if canImport(SayAllSiriRemote)
        feature.start()
        feature.restart(customMappingEnabled: customMappingEnabled)
#else
        _ = customMappingEnabled
#endif
    }

    func stop() {
#if canImport(SayAllSiriRemote)
        feature.stop()
#endif
    }

    @discardableResult
    func beginCapture() -> Bool {
#if canImport(SayAllSiriRemote)
        return feature.beginCapture()
#else
        return false
#endif
    }

    @discardableResult
    func resumeCaptureIfStopping() -> Bool {
#if canImport(SayAllSiriRemote)
        return feature.resumeCaptureIfStopping()
#else
        return false
#endif
    }

    func stopCapture(completion: @escaping () -> Void) {
#if canImport(SayAllSiriRemote)
        feature.stopCapture(completion: completion)
#else
        completion()
#endif
    }

    func setVoiceTouchSuppressed(_ suppressed: Bool) {
#if canImport(SayAllSiriRemote)
        feature.setVoiceTouchSuppressed(suppressed)
#else
        _ = suppressed
#endif
    }
}
