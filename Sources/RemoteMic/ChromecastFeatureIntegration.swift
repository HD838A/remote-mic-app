import Foundation

#if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
import SayAllChromecast
#endif

/// Chromecast 链路状态。宿主只依赖这个平台无关的枚举，不接触 CoreBluetooth 或 ATVV 字节。
enum ChromecastLinkStatus: Equatable {
    /// 私有包未编入本次构建；设置页必须完全隐藏该硬件，且不得报错。
    case unavailable
    /// 包已编入但用户未启用。
    case disabled
    case searching
    case connecting
    /// 缺少蓝牙权限。
    case unauthorized
    /// 设备被识别为第一版不支持的型号（例如只有 8 kHz 的样机）。
    case unsupported(reason: String)
    case connected(displayName: String)
    case disconnected

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .searching, .connecting, .connected: return true
        default: return false
        }
    }

    var localizationKey: String {
        switch self {
        case .unavailable: return "chromecast.status.unavailable"
        case .disabled: return "chromecast.status.disabled"
        case .searching: return "chromecast.status.searching"
        case .connecting: return "chromecast.status.connecting"
        case .unauthorized: return "chromecast.status.unauthorized"
        case .unsupported: return "chromecast.status.unsupported"
        case .connected: return "chromecast.status.connected"
        case .disconnected: return "chromecast.status.disconnected"
        }
    }
}

/// 语音手势模式。`toggle` 为本产品默认；`hold` 保留给习惯按住说话的用户。
enum ChromecastVoiceMode: String, CaseIterable, Codable, Identifiable {
    case toggle
    case hold

    var id: String { rawValue }

    static let productDefault: ChromecastVoiceMode = .toggle

    var localizationKey: String {
        switch self {
        case .toggle: return "chromecast.mode.toggle"
        case .hold: return "chromecast.mode.hold"
        }
    }

    var detailLocalizationKey: String {
        switch self {
        case .toggle: return "chromecast.mode.toggle.detail"
        case .hold: return "chromecast.mode.hold.detail"
        }
    }
}

/// 语音结束原因，仅用于日志与统计，不参与业务判断。
enum ChromecastVoiceEndReason: Equatable {
    case holdRelease
    case toggleSecondTap
    case hostStop
    case cancelled(String)

    var logToken: String {
        switch self {
        case .holdRelease: return "hold_release"
        case .toggleSecondTap: return "toggle_second_tap"
        case .hostStop: return "host_stop"
        case .cancelled(let reason): return "cancelled.\(reason)"
        }
    }

    /// 合同要求区分 `completion=normal|forced`。
    var isNormal: Bool {
        switch self {
        case .holdRelease, .toggleSecondTap: return true
        case .hostStop, .cancelled: return false
        }
    }
}

/// 遥控器**自报**的能力（宿主侧镜像，与私有包 `ChromecastCapabilityFlags` 的位一一对应）。
///
/// 这是宿主判断「这台遥控器能做什么」的唯一来源：私有包在连接变化时通过 `onConnection`
/// 把型号声明的能力位一起报上来，界面与语音键驱动只读这里，**不再在宿主维护第二份型号表**。
/// 链路不可用（未连接、型号不支持、断开）时为空集合，此时才回退到 `RemoteVoiceCapabilities`
/// 里那份与自报值等价的默认表（由跨仓一致性测试锁定）。
struct ChromecastDeclaredCapabilities: OptionSet, Equatable {
    let rawValue: Int

    static let controlEdges = ChromecastDeclaredCapabilities(rawValue: 1 << 0)
    static let voiceStream = ChromecastDeclaredCapabilities(rawValue: 1 << 1)
    static let touchSurface = ChromecastDeclaredCapabilities(rawValue: 1 << 2)
    static let battery = ChromecastDeclaredCapabilities(rawValue: 1 << 3)
    static let toggleVoiceGesture = ChromecastDeclaredCapabilities(rawValue: 1 << 4)
}

/// Chromecast 遥控器的普通按键。
///
/// 与私有包的 `ChromecastControl` 一一对应（rawValue 相同），宿主用 `…Remote…` 前缀命名是为了
/// 与 `import SayAllChromecast` 之后的同名类型区分：本仓库里苹果遥控器链路也是同样的命名约定。
///
/// 语音键不在这里：该遥控器的语音键不产生可靠 HID 边沿，语音由 ATVV 控制流驱动。
enum ChromecastRemoteControl: String, CaseIterable, Equatable {
    case power
    case up
    case down
    case left
    case right
    case select
    case back
    case home
    case mute
    case youtube
    case netflix
    case input
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"

    /// 该按键对应的宿主映射键位。私有画布的控制 ID 与本类型的 rawValue 同值。
    var remoteButton: RemoteButton {
        switch self {
        case .power: return .power
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .select: return .ok
        case .back: return .back
        case .home: return .home
        case .mute: return .mute
        case .youtube: return .youtube
        case .netflix: return .netflix
        case .input: return .input
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        }
    }

    /// 画布用的控制 ID。与 `ChromecastMappingCanvas.configurableControlIDs` 同值。
    var canvasControlID: String { rawValue }

    /// 系统占用、宿主不接管的按键。与私有包 `ChromecastControl.systemReservedControls` 对称。
    ///
    /// 真机实测（2026-09-16）：这三颗键的 HID 报告 usage 在系统眼里是 Menu Up / Menu Down /
    /// Menu Left，macOS 配件服务（BT-AACP）直接消费成媒体控制（上一首/下一首/播放暂停），
    /// **不经过 CGEvent**——事件抑制器与设备属性都无法拦截。接管只会造成双执行，
    /// 因此按产品决策完全交给系统（画布置灰、运行时跳过）。详见
    /// `Testing/ChromecastVoicePitfalls.md`。
    static let systemReservedControls: Set<ChromecastRemoteControl> = [.left, .right, .select]

    /// 该键此刻是否仍交给系统。主开关全放开；`exceptions` 逐颗放开（两者相加生效）。
    static func isSystemManaged(
        _ control: ChromecastRemoteControl,
        allowSystemReservedKeys: Bool,
        exceptions: Set<String> = []
    ) -> Bool {
        guard systemReservedControls.contains(control) else { return false }
        return !(allowSystemReservedKeys || exceptions.contains(control.rawValue))
    }

    /// 给画布用的置灰表：从默认表里去掉已放开的键。
    static func canvasReservedControlIDs(
        allowSystemReservedKeys: Bool,
        exceptions: Set<String>
    ) -> Set<String> {
        Set(systemReservedControls
            .filter { isSystemManaged($0, allowSystemReservedKeys: allowSystemReservedKeys, exceptions: exceptions) }
            .map(\.rawValue))
    }
}

enum ChromecastRemoteControlPhase: String, Equatable {
    case began
    case ended
    case cancelled
}

struct ChromecastRemoteControlEvent: Equatable {
    let control: ChromecastRemoteControl
    let phase: ChromecastRemoteControlPhase
    let sequence: Int
    let cancellationReason: String?
}

/// Chromecast 硬件接入层。
///
/// 隔离保证：本类型与 Siri Remote 接入层互不引用；私有包缺失时全部方法退化为 no-op，
/// 宿主的编译、运行和打包都不受影响。
final class ChromecastFeatureIntegration {
    /// 本次构建是否编入了私有包。
    static var isPackageIncluded: Bool {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        return true
        #else
        return false
        #endif
    }

    /// 链路状态变化。宿主据此刷新设置页与日志。
    var onStatusChange: ((ChromecastLinkStatus) -> Void)?
    /// 遥控器自报的能力变化（连接可用时给出位域，链路不可用时给出空集合）。
    var onDeclaredCapabilitiesChange: ((ChromecastDeclaredCapabilities) -> Void)?
    /// 遥控器请求开始收音。宿主必须在此回调内准备好音频出口并合成语音键按下。
    var onVoiceStart: (() -> Void)?
    /// 收音继续，用户可见状态不变。宿主不得产生第二次用户可见动作。
    var onVoiceSustain: (() -> Void)?
    /// 遥控器请求结束收音。宿主结束会话并自然排空尾音，不得 flush。
    var onVoiceStop: ((ChromecastVoiceEndReason) -> Void)?
    /// 普通按键的按下/抬起边沿。宿主据此执行键位映射。
    var onControlEvent: ((ChromecastRemoteControlEvent) -> Void)?
    /// HID 侧是否看到了本遥控器（用于诊断，不参与业务判断）。
    var onHIDPresenceChange: ((Bool) -> Void)?
    /// 解码后的 16 kHz 单声道 PCM。
    var onSamples: (([Int16], Int) -> Void)?
    /// 诊断日志。
    var onLog: ((String) -> Void)?

    #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
    private let feature: SayAllChromecastFeature
    #endif

    init() {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature = SayAllChromecastFeature()
        feature.onConnection = { [weak self] connection in
            self?.handle(connection)
        }
        feature.onVoiceIntent = { [weak self] intent in
            self?.handle(intent)
        }
        feature.onSamples = { [weak self] samples, generation in
            self?.onSamples?(samples, generation)
        }
        feature.onStatus = { [weak self] status in
            // 包内文案只进日志：界面文案一律由宿主本地化，避免中英混排。
            self?.onLog?("CHROMECAST STATUS \(status)")
        }
        feature.onLog = { [weak self] message in
            self?.onLog?(message)
        }
        feature.onControlEvent = { [weak self] event in
            guard let control = ChromecastRemoteControl(rawValue: event.control.rawValue),
                  let phase = ChromecastRemoteControlPhase(rawValue: event.phase.rawValue)
            else { return }
            self?.onControlEvent?(ChromecastRemoteControlEvent(
                control: control,
                phase: phase,
                sequence: event.sequence,
                cancellationReason: event.cancellationReason?.logToken
            ))
        }
        #endif
    }

    func start() {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.start()
        #endif
    }

    func stop() {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.stop()
        #endif
    }

    /// 用户在设置页点「重新连接」。
    func reconnect() {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.reconnect()
        #endif
    }

    func setVoiceMode(_ mode: ChromecastVoiceMode) {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.setVoiceGestureMode(mode == .hold ? .hold : .toggle)
        #endif
    }

    /// 宿主「按键映射」总开关。开启后私有包独占该遥控器的 HID 设备，关闭时只观察。
    ///
    /// 缺包时 no-op。幂等，可安全重复调用。
    func setControlMappingEnabled(_ enabled: Bool) {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.setControlMappingEnabled(enabled)
        #endif
    }

    /// HID 侧是否已看到本遥控器。缺包时恒为 false。
    var isHIDRemotePresent: Bool {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        return feature.isHIDRemotePresent
        #else
        return false
        #endif
    }

    /// 宿主侧语音会话被关闭（用户关闭语音、切换输入源）。包内 latched 状态必须同步清空。
    func notifyHostVoiceSessionEnded() {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.notifyHostVoiceSessionEnded()
        #endif
    }

    #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
    private func handle(_ connection: ChromecastConnection) {
        // `instanceKey` 只用于进程内路由，按合同不得写日志或上传。
        onLog?(
            "CHROMECAST CONNECTION state=\(Self.logToken(connection.state)) "
                + "model=\(connection.modelID) sequence=\(connection.sequence) "
                + "capabilities=\(Self.capabilityLogToken(connection.capabilities))"
        )
        // 自报能力只在链路可用时有意义；其余状态一律清零，避免「断开后界面还留着上一个型号的能力」。
        onDeclaredCapabilitiesChange?(
            connection.state.isUsable
                ? ChromecastDeclaredCapabilities(rawValue: connection.capabilities.rawValue)
                : []
        )
        switch connection.state {
        case .available:
            onStatusChange?(.connected(displayName: connection.displayName))
        case .discovering:
            onStatusChange?(.searching)
        case .connecting:
            onStatusChange?(.connecting)
        case .unauthorized:
            onStatusChange?(.unauthorized)
        case .unavailable(let reason):
            // 型号不支持时包在扫描阶段就会拒绝连接，这里必须如实展示原因。
            onStatusChange?(.unsupported(reason: reason))
        case .disconnected:
            onStatusChange?(.disconnected)
        }
    }

    private func handle(_ intent: ChromecastVoiceIntent) {
        switch intent {
        case .startRecognition:
            onVoiceStart?()
        case .sustainRecognition:
            // 远端换流不产生第二次用户可见动作，否则识别会被立刻关掉。
            onVoiceSustain?()
        case .latchStream:
            onVoiceSustain?()
        case .stopRecognition(let end, _):
            onVoiceStop?(Self.hostReason(end))
        }
    }

    private static func hostReason(_ end: ChromecastVoiceEnd) -> ChromecastVoiceEndReason {
        switch end {
        case .holdRelease: return .holdRelease
        case .toggleSecondTap: return .toggleSecondTap
        case .hostStop: return .hostStop
        case .cancelled(let reason): return .cancelled(reason.logToken)
        }
    }

    /// 合同要求异常原因必须出现在日志里，因此这里输出稳定 token 而不是反射结果。
    private static func logToken(_ state: ChromecastConnectionState) -> String {
        switch state {
        case .discovering: return "discovering"
        case .connecting: return "connecting"
        case .available: return "available"
        case .unauthorized: return "unauthorized"
        case .unavailable: return "unavailable"
        case .disconnected(let reason): return "disconnected.\(reason.logToken)"
        }
    }

    /// 把自报能力位写成可读的日志标记，便于真机核对「设备到底报了什么」。
    private static func capabilityLogToken(_ capabilities: ChromecastCapabilityFlags) -> String {
        let declared = ChromecastDeclaredCapabilities(rawValue: capabilities.rawValue)
        var names: [String] = []
        if declared.contains(.controlEdges) { names.append("control_edges") }
        if declared.contains(.voiceStream) { names.append("voice_stream") }
        if declared.contains(.touchSurface) { names.append("touch_surface") }
        if declared.contains(.battery) { names.append("battery") }
        if declared.contains(.toggleVoiceGesture) { names.append("toggle_voice") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }
    #endif
}
