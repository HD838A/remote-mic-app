import Foundation

#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
import SayAllSiriRemote
#endif

struct SiriRemoteDeviceIdentity: Hashable {
    let adapterID: String
    let instanceToken: String
}

struct SiriRemoteConnection: Equatable {
    let device: SiriRemoteDeviceIdentity
    let model: XiaomiRemoteModel
    let fingerprint: String
    let isConnected: Bool
}

enum SiriRemoteControl: String, CaseIterable, Equatable {
    case up
    case down
    case left
    case right
    case select
    case back
    case tv
    case siri
    case playPause = "play_pause"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case mute
    case power

    var remoteButton: RemoteButton? {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .select: .ok
        case .back: .back
        case .tv: .tv
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .playPause: .playPause
        case .mute: .mute
        case .power: .power
        case .siri: nil
        }
    }

    var nativeEvents: Set<RemoteNativeEvent> {
        switch self {
        case .playPause: [.systemKey(type: 2), .systemKey(type: 16)]
        case .mute: [.systemKey(type: 3), .systemKey(type: 7)]
        case .power: [.keyboard(keyCode: 90), .systemKey(type: 6)]
        default: remoteButton?.nativeEvents ?? []
        }
    }
}

enum SiriRemoteControlPhase: String, Equatable {
    case began
    case ended
    case cancelled
}

struct SiriRemoteControlEvent: Equatable {
    let device: SiriRemoteDeviceIdentity
    let control: SiriRemoteControl
    let phase: SiriRemoteControlPhase
    let sequence: UInt64
    let cancellationReason: String?
}

struct SiriRemotePowerSnapshot: Equatable {
    enum Availability: String {
        case available
        case unavailable
        case stale
    }

    let device: SiriRemoteDeviceIdentity
    let model: XiaomiRemoteModel
    let level: Int?
    let powerState: RemotePowerState
    let observedAtUptime: Double
    let availability: Availability
    let source: String
}

enum SiriRemoteTouchFeedbackKind: Equatable {
    case pointerMoved(deltaX: Double, deltaY: Double, speed: Double)
    case scrolled(pixels: Double, speed: Double)
    case clicked
}

final class SiriRemoteFeatureIntegration {
    var onConnection: ((SiriRemoteConnection) -> Void)?
    var onControlEvent: ((SiriRemoteControlEvent) -> Void)?
    var onSamples: (([Int16]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onPowerSnapshot: ((SiriRemotePowerSnapshot) -> Void)?
    var onTouchFeedback: ((SiriRemoteTouchFeedbackKind) -> Void)?

    #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
    private let feature: SayAllSiriRemoteFeature
    #endif

    init(logger: @escaping (String) -> Void = { _ in }) {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        feature = SayAllSiriRemoteFeature(logger: logger)
        feature.onConnection = { [weak self] connection in
            guard let model = Self.hostModel(connection.model) else { return }
            self?.onConnection?(SiriRemoteConnection(
                device: Self.hostDevice(connection.device),
                model: model,
                fingerprint: connection.fingerprint,
                isConnected: connection.isConnected
            ))
        }
        feature.onControlEvent = { [weak self] event in
            guard let control = SiriRemoteControl(rawValue: event.control.rawValue),
                  let phase = SiriRemoteControlPhase(rawValue: event.phase.rawValue)
            else { return }
            self?.onControlEvent?(SiriRemoteControlEvent(
                device: Self.hostDevice(event.device),
                control: control,
                phase: phase,
                sequence: event.sequence,
                cancellationReason: event.cancellationReason
            ))
        }
        feature.onSamples = { [weak self] samples in self?.onSamples?(samples) }
        feature.onStatus = { [weak self] status in self?.onStatus?(status) }
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
        feature.onPowerSnapshot = { [weak self] snapshot in
            guard let model = Self.hostModel(snapshot.model),
                  let availability = SiriRemotePowerSnapshot.Availability(
                      rawValue: snapshot.availability.rawValue
                  )
            else { return }
            let powerState = RemotePowerState(rawSiriRemoteValue: snapshot.powerState.rawValue)
            self?.onPowerSnapshot?(SiriRemotePowerSnapshot(
                device: Self.hostDevice(snapshot.device),
                model: model,
                level: snapshot.level,
                powerState: powerState,
                observedAtUptime: snapshot.observedAtUptime,
                availability: availability,
                source: snapshot.source
            ))
        }
        #endif
    }

    func start() {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        feature.start()
        #endif
    }

    func restart(customMappingEnabled: Bool) {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        feature.restart(customMappingEnabled: customMappingEnabled)
        #endif
    }

    func stop() {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        feature.stop()
        #endif
    }

    @discardableResult
    func beginCapture() -> Bool {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        return feature.beginCapture()
        #else
        return false
        #endif
    }

    @discardableResult
    func resumeCaptureIfStopping() -> Bool {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        return feature.resumeCaptureIfStopping()
        #else
        return false
        #endif
    }

    func stopCapture(completion: @escaping () -> Void) {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        feature.stopCapture(completion: completion)
        #else
        completion()
        #endif
    }

    func setVoiceTouchSuppressed(_ suppressed: Bool) {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        feature.setVoiceTouchSuppressed(suppressed)
        #endif
    }

    #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
    private static func hostDevice(_ device: SayAllSiriRemoteDeviceID) -> SiriRemoteDeviceIdentity {
        SiriRemoteDeviceIdentity(
            adapterID: device.adapterID,
            instanceToken: device.instanceToken
        )
    }

    private static func hostModel(_ model: SayAllSiriRemoteModel) -> XiaomiRemoteModel? {
        switch model {
        case .a2854: .appleSiriRemoteA2854
        case .a2540: .appleSiriRemoteA2540
        }
    }
    #endif
}

private extension RemotePowerState {
    init(rawSiriRemoteValue: String) {
        switch rawSiriRemoteValue {
        case "on_battery": self = .onBattery
        case "external_power": self = .externalPower
        case "charging": self = .charging
        default: self = .unknown
        }
    }
}
