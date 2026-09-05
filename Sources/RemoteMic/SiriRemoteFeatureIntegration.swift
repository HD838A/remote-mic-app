import Foundation

#if SAYALL_SIRI_REMOTE_ENABLED
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

enum SiriRemoteTouchFeedbackKind: Equatable {
    case pointerMoved(deltaX: Double, deltaY: Double, speed: Double)
    case scrolled(pixels: Double, speed: Double)
    case clicked
}

final class SiriRemoteFeatureIntegration {
    var onConnection: ((SiriRemoteConnectionObservation) -> Void)?
    var onControl: ((SiriRemoteControlObservation) -> Void)?
    var onVoiceSamples: (([Int16]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onTouchFeedback: ((SiriRemoteTouchFeedbackKind) -> Void)?

#if SAYALL_SIRI_REMOTE_ENABLED
    private let feature: SayAllSiriRemoteFeature
#endif

    init(logger: @escaping (String) -> Void = AppLogger.shared.write) {
#if SAYALL_SIRI_REMOTE_ENABLED
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
        feature.onTouchFeedback = { [weak self] feedback in
            switch feedback {
            case let .pointerMoved(deltaX, deltaY, speed):
                self?.onTouchFeedback?(.pointerMoved(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    speed: speed
                ))
            case let .scrolled(pixels, speed):
                self?.onTouchFeedback?(.scrolled(pixels: pixels, speed: speed))
            case .clicked:
                self?.onTouchFeedback?(.clicked)
            }
        }
        feature.onStatus = { [weak self] status in
            self?.onStatus?(status)
        }
#endif
    }

    func start(customMappingEnabled: Bool) {
#if SAYALL_SIRI_REMOTE_ENABLED
        feature.start()
        feature.restart(customMappingEnabled: customMappingEnabled)
#else
        _ = customMappingEnabled
#endif
    }

    func stop() {
#if SAYALL_SIRI_REMOTE_ENABLED
        feature.stop()
#endif
    }

    @discardableResult
    func beginCapture() -> Bool {
#if SAYALL_SIRI_REMOTE_ENABLED
        return feature.beginCapture()
#else
        return false
#endif
    }

    @discardableResult
    func resumeCaptureIfStopping() -> Bool {
#if SAYALL_SIRI_REMOTE_ENABLED
        return feature.resumeCaptureIfStopping()
#else
        return false
#endif
    }

    func stopCapture(completion: @escaping () -> Void) {
#if SAYALL_SIRI_REMOTE_ENABLED
        feature.stopCapture(completion: completion)
#else
        completion()
#endif
    }

    func setVoiceTouchSuppressed(_ suppressed: Bool) {
#if SAYALL_SIRI_REMOTE_ENABLED
        feature.setVoiceTouchSuppressed(suppressed)
#else
        _ = suppressed
#endif
    }
}
