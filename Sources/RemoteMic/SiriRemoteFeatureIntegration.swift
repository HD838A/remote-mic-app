import Foundation

#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
import SayAllSiriRemote
#endif

struct SiriRemoteDeviceIdentity: Hashable {
    let adapterID: String
    let instanceToken: String
}

/// 苹果遥控器**自报**的能力位（宿主镜像，rawValue 与私有包的 `RemoteHardwareCapability` 无关，
/// 只按顺序对应：controlEdges / touchSurface / continuousScroll / voiceStream / batteryLevel / powerState）。
///
/// 界面（是否出现触摸类设置）与策略只读这里，**宿主不再为苹果遥控器维护第二份型号能力表**；
/// 链路不可用时为空集合，此时才回退到 `RemoteVoiceCapabilities` 里那份与自报值等价的默认表。
struct SiriRemoteDeclaredCapabilities: OptionSet, Equatable {
    let rawValue: Int

    static let controlEdges = SiriRemoteDeclaredCapabilities(rawValue: 1 << 0)
    static let touchSurface = SiriRemoteDeclaredCapabilities(rawValue: 1 << 1)
    static let continuousScroll = SiriRemoteDeclaredCapabilities(rawValue: 1 << 2)
    static let voiceStream = SiriRemoteDeclaredCapabilities(rawValue: 1 << 3)
    static let batteryLevel = SiriRemoteDeclaredCapabilities(rawValue: 1 << 4)
    static let powerState = SiriRemoteDeclaredCapabilities(rawValue: 1 << 5)
}

extension SiriRemoteDeclaredCapabilities {
    /// 投影到宿主通用的能力位集合。
    ///
    /// **必须逐个具名映射**：苹果遥控器链路（`RemoteHardwareCapability`）与 Chromecast 链路
    /// （`ChromecastCapabilityFlags`）的位序不同，按 `rawValue` 直接复制会把「触摸面」读成
    /// 「语音流」这类错值。将来任一侧新增能力位，这里会因为漏写而容易被 review 发现。
    var asDeclaredVoiceCapabilities: ChromecastDeclaredCapabilities {
        var common: ChromecastDeclaredCapabilities = []
        if contains(.controlEdges) { common.insert(.controlEdges) }
        if contains(.touchSurface) { common.insert(.touchSurface) }
        if contains(.voiceStream) { common.insert(.voiceStream) }
        if contains(.batteryLevel) { common.insert(.battery) }
        // continuousScroll 与 powerState 不影响宿主的能力判定（无对应位），此处不投影。
        return common
    }
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
    case scrolled(
        pixels: Double,
        speed: Double
    )
    case clicked
}

enum SiriRemoteTouchRoutingMode: String, Equatable {
    case standard
    case circularNavigation = "circular_navigation"
}

final class SiriRemoteFeatureIntegration {
    var onConnection: ((SiriRemoteConnection) -> Void)?
    /// 遥控器自报的能力（连接可用时给出位域，链路不可用时给出空集合）。
    var onDeclaredCapabilitiesChange: ((SiriRemoteDeclaredCapabilities) -> Void)?
    var onControlEvent: ((SiriRemoteControlEvent) -> Void)?
    var onSamples: (([Int16]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onPowerSnapshot: ((SiriRemotePowerSnapshot) -> Void)?
    var onTouchFeedback: ((SiriRemoteTouchFeedbackKind) -> Void)?
    var onContextualScroll: ((Double) -> Bool)?
    var onCenterTapConfirmation: ((SiriRemoteDeviceIdentity) -> Bool)?

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
            // 当前私有包版本尚未公开能力集合；清空自报值后由宿主按型号默认能力回退。
            self?.onDeclaredCapabilitiesChange?([])
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
                self?.onTouchFeedback?(.scrolled(
                    pixels: pixels,
                    speed: speed
                ))
            case .clicked:
                self?.onTouchFeedback?(.clicked)
            }
        }
        feature.onContextualScroll = { [weak self] pixels in
            self?.onContextualScroll?(pixels) ?? false
        }
        feature.onCenterTapConfirmation = { [weak self] device in
            self?.onCenterTapConfirmation?(Self.hostDevice(device)) ?? false
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

    func setTouchRoutingMode(_ mode: SiriRemoteTouchRoutingMode) {
        #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
        guard let privateMode = SayAllSiriRemoteTouchRoutingMode(rawValue: mode.rawValue) else {
            return
        }
        feature.setTouchRoutingMode(privateMode)
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
