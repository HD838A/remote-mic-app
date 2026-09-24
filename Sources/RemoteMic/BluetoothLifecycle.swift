import Foundation

enum XiaomiVoiceRemoteNameMatcher {
    /// 白名单集中在 `VoiceRemoteCatalog.adoptedAdvertisedNames`，这里不再单独维护一份。
    private static let approvedNames: Set<String> = VoiceRemoteCatalog.adoptedAdvertisedNames

    static func matches(_ rawName: String?) -> Bool {
        recognizedName(rawName) != nil
    }

    /// 返回命中的规范名，便于日志说明「按哪个名字认出来的」。
    static func recognizedName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, approvedNames.contains(normalized) else { return nil }
        return normalized
    }
}

/// 别的产品也会用同一个通用 ATVV 服务。它们是私有 Chromecast 适配包的目标，
/// **宿主的 Xiaomi 桥必须一律拒绝**——否则会出现「连上了 Chromecast Remote、界面显示
/// Xiaomi 遥控器已连接、按键与语音键全无反应」，而且两条链路会互相抢同一台设备。
///
/// 名单与私有包 `ChromecastRemoteModel.advertisedNameHints`（含 RemoteG10 样机）保持一致；
/// 归一化规则也与 `ChromecastRemoteModelMatcher` 一致（大小写、下划线、连字符、连续空格）。
enum ForeignVoiceRemoteProduct {
    /// 真机日志里出现过裸 `name=Chromecast`（Bluetooth 系统名不带 Remote），所以裸名也必须算；
    /// 只写 `chromecast remote` 会漏掉这类变体。
    private static let rejectedNames: Set<String> = [
        "chromecast",
        "chromecast remote",
        "chromecast 遥控器",
        "remote g10",
        "remoteg10",
        "g10",
    ]

    static func isRejected(name: String?) -> Bool {
        rejectedName(name) != nil
    }

    static func rejectedName(_ name: String?) -> String? {
        guard let normalized = normalized(name) else { return nil }
        return rejectedNames.contains(normalized) ? normalized : nil
    }

    private static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let collapsed = trimmed.split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

/// 遥控器发现准入结论。
///
/// 为什么必须是「白名单 + 明确结论」而不是布尔值：App 里每款遥控器都有**真机图片**和按键页，
/// 采用一台认不出来的 ATVV 设备就等于给它套上别的型号的图和按键集合，界面会声称一个从未
/// 验证过的设备「已连接」。宁可明确不采用，也不能猜。
enum VoiceRemoteAdmissionDecision: Equatable {
    /// 已保存身份命中：用户此前采用过这台设备，改名后依然可用。
    case adoptSavedIdentity
    /// 名称命中本产品的已知型号。
    case adoptRecognizedName(String)
    /// 别的产品（Chromecast Remote / RemoteG10 等）。
    case rejectForeignProduct(String)
    /// 广播/上报了名字，但不是任何已知型号：不采用（无身份、又认不出）。
    case rejectUnrecognizedName(String)
    /// 完全拿不到名字：无法证明是已知型号，不采用。
    case rejectUnnamed
    /// 与本桥无关（既不是 ATVV 设备，也不是本桥的目标标识）。
    case ignore

    var isAdopted: Bool {
        switch self {
        case .adoptSavedIdentity, .adoptRecognizedName: return true
        case .rejectForeignProduct, .rejectUnrecognizedName, .rejectUnnamed, .ignore: return false
        }
    }

    /// 用于日志的机器可读原因。拒绝必须带原因：设备名对不上、名字没拿到、名字不认识，
    /// 这几种情况在没有原因字段的日志里长得完全一样，无法二分。
    var logReason: String {
        switch self {
        case .adoptSavedIdentity: return "saved_identity"
        case .adoptRecognizedName: return "recognized_name"
        case .rejectForeignProduct: return "foreign_product"
        case .rejectUnrecognizedName: return "unrecognized_name"
        case .rejectUnnamed: return "unnamed"
        case .ignore: return "ignore"
        }
    }
}

/// 把「发现了什么」翻译成「能不能采用」的纯判定。
///
/// 三条发现路径——已保存标识、系统已连接设备、扫描广播——**必须共用这一份判定**，
/// 否则「遥控器已在系统设置里配对过」这类设备会被其中一条路径漏掉或误收。
enum VoiceRemoteAdmission {
    static func decide(
        identifier: UUID,
        targetIdentifier: UUID?,
        advertisesVoiceService: Bool,
        name: String?,
        advertisedName: String?
    ) -> VoiceRemoteAdmissionDecision {
        let nameForMatch = advertisedName ?? name
        // 别的产品优先否决，且优先于已保存身份：早先版本误把 Chromecast Remote 存成
        // Xiaomi 档案的情况真实发生过，只按 UUID 采纳会让这个错误一直重连下去。
        if let foreign = ForeignVoiceRemoteProduct.rejectedName(nameForMatch) {
            return .rejectForeignProduct(foreign)
        }
        if let targetIdentifier {
            // 身份优先于名称：用户改过名的遥控器仍然必须是同一台设备。
            return identifier == targetIdentifier ? .adoptSavedIdentity : .ignore
        }
        if let recognized = XiaomiVoiceRemoteNameMatcher.recognizedName(nameForMatch) {
            return .adoptRecognizedName(recognized)
        }
        guard advertisesVoiceService else { return .ignore }
        if let nameForMatch, !nameForMatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejectUnrecognizedName(nameForMatch)
        }
        // 只认名字，不认「服务存在」：ATVV 是通用服务，协议相同不等于型号相同。
        return .rejectUnnamed
    }
}

enum BluetoothLifecyclePhase: Equatable {
    case stopped
    case scanning(UInt64)
    case connecting(UInt64)
    case discovering(UInt64)
    case awaitingCapabilities(UInt64)
    case ready(UInt64)
    case disconnecting(UInt64)
    case waitingReconnect(UInt64)
    case waitingBluetoothPower(UInt64)

    var generation: UInt64? {
        switch self {
        case .connecting(let value),
             .scanning(let value),
             .discovering(let value),
             .awaitingCapabilities(let value),
             .ready(let value),
             .disconnecting(let value),
             .waitingReconnect(let value),
             .waitingBluetoothPower(let value):
            return value
        case .stopped:
            return nil
        }
    }

    func acceptsDidConnect(generation: UInt64) -> Bool {
        self == .connecting(generation)
    }

    func acceptsDidFailToConnect(generation: UInt64) -> Bool {
        self == .connecting(generation) || self == .disconnecting(generation)
    }

    func acceptsInitializationCallback(generation: UInt64) -> Bool {
        self == .discovering(generation)
    }

    func acceptsNotificationUpdate(generation: UInt64) -> Bool {
        switch self {
        case .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation):
            return true
        default:
            return false
        }
    }

    func acceptsCapabilities(generation: UInt64) -> Bool {
        self == .awaitingCapabilities(generation)
    }

    func acceptsProtocolData(generation: UInt64) -> Bool {
        self == .ready(generation)
    }

    func acceptsDisconnect(generation: UInt64) -> Bool {
        switch self {
        case .connecting(generation),
             .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation),
             .disconnecting(generation):
            return true
        default:
            return false
        }
    }
}

struct BluetoothReconnectPolicy {
    static let baseDelay: TimeInterval = 3
    static let maximumDelay: TimeInterval = 60
    static let jitterRatio = 0.1

    private(set) var consecutiveFailureCount = 0
    private(set) var allowsCachedTargetRetrieval = true

    mutating func nextAutomaticDelay(
        bypassCachedTarget: Bool,
        jitterUnit: Double
    ) -> TimeInterval {
        consecutiveFailureCount += 1
        if bypassCachedTarget {
            allowsCachedTargetRetrieval = false
        }

        let exponent = min(consecutiveFailureCount - 1, 5)
        let nominalDelay = min(
            Self.maximumDelay,
            Self.baseDelay * pow(2, Double(exponent))
        )
        let normalizedJitter = min(1, max(0, jitterUnit))
        let jitterFactor = (1 - Self.jitterRatio) +
            (normalizedJitter * Self.jitterRatio * 2)
        return min(Self.maximumDelay, nominalDelay * jitterFactor)
    }

    mutating func reset() {
        consecutiveFailureCount = 0
        allowsCachedTargetRetrieval = true
    }
}

enum BluetoothCentralRecoveryEvent {
    case poweredOn
    case poweredOff
    case resetting
    case unauthorized
    case unsupported
}

enum BluetoothWakeRecoveryPolicy {
    /// A system sleep tears down the CoreBluetooth connection cycle, so a
    /// reconnect has to run after the following wake.
    ///
    /// The intent must outlive the wake event itself: macOS can deliver
    /// `systemDidWake` while the display is still asleep, and the resume path is
    /// still suspended by `screenSleeping` at that point, so it returns before
    /// reaching Bluetooth recovery. Arming a flag lets the recovery run at the
    /// first moment the app is actually no longer suspended.
    ///
    /// `systemDidWake` arms on its own as well, so a wake whose `systemWillSleep`
    /// was never observed still recovers.
    ///
    /// Display-only sleep/wake cycles never arm it — those happen constantly
    /// while the machine stays awake and must not restart the connection cycle.
    static func pendingRecovery(
        after event: SystemAudioLifecycleEvent,
        current: Bool
    ) -> Bool {
        switch event {
        case .systemWillSleep, .systemDidWake:
            return true
        case .screenDidSleep, .screenDidWake, .sessionDidResignActive, .sessionDidBecomeActive:
            return current
        }
    }

    /// A short sleep can end with CoreBluetooth restoring the connection before
    /// the resume path runs. Forcing a reconnect then tears down a bridge that
    /// already came back, so recovery only runs while no bridge is ready.
    static func shouldForceReconnect(
        pendingRecovery: Bool,
        started: Bool,
        readyBridgeCount: Int
    ) -> Bool {
        started && pendingRecovery && readyBridgeCount == 0
    }
}

struct BluetoothCentralRecoveryTransition: Equatable {
    let phase: BluetoothLifecyclePhase
    let shouldCancelScheduledReconnect: Bool
    let shouldDiscover: Bool
    let shouldStartFreshConnectionCycle: Bool
    let shouldReleaseCentral: Bool
}

enum BluetoothCentralRecoveryPolicy {
    static func transition(
        from phase: BluetoothLifecyclePhase,
        generation: UInt64,
        event: BluetoothCentralRecoveryEvent,
        shouldRun: Bool
    ) -> BluetoothCentralRecoveryTransition {
        switch event {
        case .poweredOff, .resetting:
            guard shouldRun else {
                return BluetoothCentralRecoveryTransition(
                    phase: .stopped,
                    shouldCancelScheduledReconnect: true,
                    shouldDiscover: false,
                    shouldStartFreshConnectionCycle: false,
                    shouldReleaseCentral: true
                )
            }
            return BluetoothCentralRecoveryTransition(
                phase: .waitingBluetoothPower(generation),
                shouldCancelScheduledReconnect: true,
                shouldDiscover: false,
                shouldStartFreshConnectionCycle: false,
                shouldReleaseCentral: false
            )
        case .poweredOn:
            guard shouldRun else {
                return BluetoothCentralRecoveryTransition(
                    phase: .stopped,
                    shouldCancelScheduledReconnect: true,
                    shouldDiscover: false,
                    shouldStartFreshConnectionCycle: false,
                    shouldReleaseCentral: true
                )
            }
            let requiresFreshConnectionCycle = phase == .waitingReconnect(generation) ||
                phase == .waitingBluetoothPower(generation)
            return BluetoothCentralRecoveryTransition(
                phase: requiresFreshConnectionCycle ? .stopped : phase,
                shouldCancelScheduledReconnect: requiresFreshConnectionCycle,
                shouldDiscover: !requiresFreshConnectionCycle &&
                    phase == .scanning(generation),
                shouldStartFreshConnectionCycle: requiresFreshConnectionCycle,
                shouldReleaseCentral: false
            )
        case .unauthorized, .unsupported:
            return BluetoothCentralRecoveryTransition(
                phase: .stopped,
                shouldCancelScheduledReconnect: true,
                shouldDiscover: false,
                shouldStartFreshConnectionCycle: false,
                shouldReleaseCentral: true
            )
        }
    }
}

enum ATVVSessionGate {
    static let cancelledOpenSuppressionInterval: TimeInterval = 2

    static func canOpenMicrophone(
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        capabilitiesConfirmed: Bool,
        sampleRate: Double
    ) -> Bool {
        phase.acceptsProtocolData(generation: generation) &&
            capabilitiesConfirmed &&
            ATVVProtocol.supportsAudio(sampleRate: sampleRate)
    }

    static func cancelledOpenDate(
        microphoneOpened: Bool,
        streaming: Bool,
        now: Date = Date()
    ) -> Date? {
        microphoneOpened && !streaming ? now : nil
    }

    static func shouldIgnoreStreamAfterCancelledOpen(
        cancelledAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let cancelledAt else { return false }
        return now < cancelledAt.addingTimeInterval(cancelledOpenSuppressionInterval)
    }
}
