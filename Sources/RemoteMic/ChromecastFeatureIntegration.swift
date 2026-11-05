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

    /// 当前产品允许全部普通键配置，包含左、确定、右。
    /// 历史豁免设置继续可读，但不得再次限制这三键。
    static let systemReservedControls: Set<ChromecastRemoteControl> = []

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
/// 隔离保证：本类型与 Siri Remote 接入层互不引用；公开构建使用独立 G9N9N 后端，
/// 带私有包的构建保持原来的 Google 后端，不同时启动两个 BLE 客户端。
final class ChromecastFeatureIntegration {
    static var usesPublicG9N9N: Bool {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        false
        #else
        true
        #endif
    }
    var remoteModel: XiaomiRemoteModel { Self.usesPublicG9N9N ? .googleTVRemoteG9N9N : .chromecastVoiceRemote }
    var isPublicNativeInputReady: Bool {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        false
        #else
        g9.hid.isNativeMappingPrepared && g9.hid.isPresent
        #endif
    }
    func setG9HCIEnabled(_ enabled: Bool) {
        guard hardwareEnabled, Self.usesPublicG9N9N else { return }
        #if !canImport(SayAllChromecast)
        UserDefaults.standard.set(enabled, forKey: "g9n9n.hci.enabled")
        g9HCIEnabled = enabled
        if enabled {
            g9HCI.start()
            g9.prepareHCIIdentity()
        } else {
            g9HCI.stop()
            onG9HCIStatus?("disabled")
        }
        #endif
    }

    func cancelG9Learning() {
        #if !canImport(SayAllChromecast)
        g9.hid.cancelLearning()
        #endif
    }
    func learnG9Control(_ control: ChromecastRemoteControl) {
        guard hardwareEnabled else { return }
        #if !canImport(SayAllChromecast)
        g9.hid.learn(control)
        #endif
    }

    static var nativeInputProductIDs: Set<Int> {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        return [0x9450]
        #else
        return [0x9450]
        #endif
    }
    var prepareNativeInput: (([UInt64]) -> Bool)? {
        didSet {
            #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
            feature.prepareNativeInput = prepareNativeInput
            #endif
        }
    }
    var restoreNativeInput: (() -> Void)? {
        didSet {
            #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
            feature.restoreNativeInput = restoreNativeInput
            #endif
        }
    }
    /// 本次构建是否包含可用的 Chromecast-family 后端。
    static var isPackageIncluded: Bool {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        return true
        #else
        return true // Public builds include the independent G9N9N backend.
        #endif
    }

    var onG9HCIStatus: ((String) -> Void)?
    var onG9UnmappedInput: (() -> Void)?
    var onG9LearningChange: ((String?) -> Void)?

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
    #else
    private let g9 = G9N9NBluetoothBridge()
    private let g9HCI = G9N9NHCIController()
    private var g9HCIEnabled = false
    #endif

    private let hardwareEnabled: Bool

    init(hardwareEnabled: Bool = true) {
        self.hardwareEnabled = hardwareEnabled
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
        #else
        g9.onStatus = { [weak self] status in
            guard let self else { return }
            if !status.isConnected { self.g9HCI.disconnected() }
            self.onStatusChange?(status)
        }
        g9.onHCIIdentity = { [weak self] in
            guard let self, self.g9HCIEnabled else { return }
            self.g9HCI.identify(serial: $0)
        }
        g9HCI.requestIdentityRead = { [weak self] in self?.g9.requestHCIIdentityRead() }
        g9HCI.onControl = { [weak self] in self?.onControlEvent?($0) }
        g9HCI.onStatus = { [weak self] in self?.onG9HCIStatus?($0) }
        g9.onCapabilities = { [weak self] in self?.onDeclaredCapabilitiesChange?($0) }
        g9.onVoiceStart = { [weak self] in self?.onVoiceStart?() }
        g9.onVoiceStop = { [weak self] in self?.onVoiceStop?($0) }
        g9.onSamples = { [weak self] in self?.onSamples?($0, $1) }
        g9.onLog = { [weak self] in self?.onLog?($0) }
        g9.hid.prepareNativeInput = { [weak self] in self?.prepareNativeInput?($0) == true }
        g9.hid.restoreNativeInput = { [weak self] in self?.restoreNativeInput?() }
        g9.hid.onUnmappedInput = { [weak self] in self?.onG9UnmappedInput?() }
        g9.hid.onLearningChange = { [weak self] in self?.onG9LearningChange?($0) }
        g9.hid.onEvent = { [weak self] event in
            guard let self, !self.g9HCIEnabled else { return }
            self.onControlEvent?(event)
        }
        g9.hid.onPresence = { [weak self] in self?.onHIDPresenceChange?($0) }
        #endif
    }

    func start() {
        guard hardwareEnabled else { return }
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.start()
        #else
        g9HCIEnabled = UserDefaults.standard.bool(forKey: "g9n9n.hci.enabled")
        if g9HCIEnabled { g9HCI.start(); g9.prepareHCIIdentity() }
        g9.start()
        #endif
    }

    func stop() {
        guard hardwareEnabled else { return }
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.stop()
        #else
        g9.stop()
        g9HCI.stop()
        #endif
    }

    /// 用户在设置页点「重新连接」。
    func reconnect() {
        guard hardwareEnabled else { return }
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.reconnect()
        #else
        g9.reconnect()
        #endif
    }

    func setVoiceMode(_ mode: ChromecastVoiceMode) {
        guard hardwareEnabled else { return }
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.setVoiceGestureMode(mode == .hold ? .hold : .toggle)
        #endif
    }

    /// 宿主「按键映射」总开关。开启后私有包独占该遥控器的 HID 设备，关闭时只观察。
    ///
    /// 公开后端使用经 Jieli 厂商筛选的主机服务级按键抑制。幂等。
    func setControlMappingEnabled(_ enabled: Bool) {
        guard hardwareEnabled else { return }
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.setControlMappingEnabled(enabled)
        #else
        g9.hid.setMappingEnabled(enabled)
        #endif
    }

    /// HID 侧是否已看到当前后端对应的遥控器。
    var isHIDRemotePresent: Bool {
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        return feature.isHIDRemotePresent
        #else
        return g9.hid.isPresent
        #endif
    }

    /// 宿主侧语音会话被关闭（用户关闭语音、切换输入源）。包内 latched 状态必须同步清空。
    func notifyHostVoiceSessionEnded() {
        guard hardwareEnabled else { return }
        #if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
        feature.notifyHostVoiceSessionEnded()
        #else
        g9.hostEnded()
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
