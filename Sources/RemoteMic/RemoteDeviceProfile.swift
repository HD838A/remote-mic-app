import Foundation

enum XiaomiRemoteModel: String, Codable, CaseIterable, Identifiable {
    case rc001
    case rc003
    case appleSiriRemoteA2854 = "apple_siri_remote_a2854"
    case appleSiriRemoteA2540 = "apple_siri_remote_a2540"
    /// Chromecast（Google Chromecast 语音遥控器）。与苹果遥控器同理，case 始终存在以保证
    /// 持久化数据在任何构建里都能解码；只有展示文案受私有包门禁控制。
    case chromecastVoiceRemote = "chromecast_voice_remote"
    case unknown

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .rc001: return "remote.device.model.rc001"
        case .rc003: return "remote.device.model.rc003"
        case .appleSiriRemoteA2854:
#if SAYALL_SIRI_REMOTE_ENABLED
            return "remote.device.model.apple_siri_remote_a2854"
#else
            return "remote.device.model.unknown"
#endif
        case .appleSiriRemoteA2540:
#if SAYALL_SIRI_REMOTE_ENABLED
            return "remote.device.model.apple_siri_remote_a2540"
#else
            return "remote.device.model.unknown"
#endif
        case .chromecastVoiceRemote:
#if SAYALL_CHROMECAST_ENABLED
            return "remote.device.model.chromecast_voice_remote"
#else
            return "remote.device.model.unknown"
#endif
        case .unknown: return "remote.device.model.unknown"
        }
    }

    var stableHardwareModelID: String? {
        switch self {
        case .rc001: "xiaomi-remote-rc001"
        case .rc003: "xiaomi-remote-2-pro"
        case .appleSiriRemoteA2854: "apple-siri-remote-a2854"
        case .appleSiriRemoteA2540: "apple-siri-remote-a2540"
        case .chromecastVoiceRemote: "chromecast-voice-remote"
        case .unknown: nil
        }
    }

    var isAppleSiriRemote: Bool {
        self == .appleSiriRemoteA2854 || self == .appleSiriRemoteA2540
    }

    /// 该型号由 Chromecast 私有包的 HID 通道驱动，不走小米 HID 发现链路。
    var isChromecastRemote: Bool {
        self == .chromecastVoiceRemote
    }

    /// 该型号是否由私有包的专用链路驱动（苹果遥控器或 Chromecast）。
    /// 这类型号的档案不得被小米 HID 发现链路当成候选。
    var usesPrivateAdapter: Bool {
        isAppleSiriRemote || isChromecastRemote
    }

    /// 按 DIS 型号串识别型号。规则集中在 `VoiceRemoteCatalog`——这里不再单独写名单。
    static func identified(by modelNumber: String) -> XiaomiRemoteModel? {
        VoiceRemoteCatalog.entry(matchingDISModelNumber: modelNumber)?.model
    }}

/// 目录条目：一款被验证过的遥控器。
///
/// App 内置每款遥控器的真机图与按键页，所以「支持 ATVV 桥」不等于「支持这款遥控器」：
/// 只有目录里有条目的型号才允许被采用，未收录的一律不采用。
struct VoiceRemoteCatalogEntry {
    /// 型号。
    let model: XiaomiRemoteModel
    /// 真机图资源名（不含扩展名）。每款都必须显式给图；共用必须显式声明，不允许默认套用别款。
    let photoResource: String
    /// 该型号的 DIS Model Number（0x180A / 0x2A24），大写、去首尾空白后匹配。
    let disModelNumbers: [String]
}

/// 已验证遥控器目录：本 App 支持哪些遥控器的**唯一事实源**。
///
/// 准入、型号识别、真机图都必须从这里取，不允许各自另写一份名单——
/// 写成三份就会出现「某处漏收/误收，且只在特定配对状态下复现」的缺陷。
enum VoiceRemoteCatalog {
    static let entries: [VoiceRemoteCatalogEntry] = [
        // rc001 与 rc003 外观几乎一致，用户确认共用同一份真机素材（2026-09-19）——
        // 共用是显式声明，不是默认行为。
        VoiceRemoteCatalogEntry(
            model: .rc001,
            photoResource: "RC003-remote-photo",
            // 真机证实（2026-09-19）：小米蓝牙遥控器 2 的 DIS 报 RC001。
            disModelNumbers: ["RC001"]
        ),
        VoiceRemoteCatalogEntry(
            model: .rc003,
            photoResource: "RC003-remote-photo",
            // 真机证实（2026-09-19）：小米蓝牙遥控器 2 Pro 的 DIS 报 RC003。
            //
            // ARN9 **不**列入型号目录：两台真机（2 与 2 Pro）的 DIS 都不是 ARN9，
            // 全部历史日志里也从未出现过，没有任何证据表明它属于哪一款——型号不猜。
            // 但 ARN9 的两处功能保留：①广播名白名单里的 "arn9"（连接层，老固件设备
            // 可能广播这个名字）；②桥里 contains("ARN9") 的 ADPCM low-nibble-first
            // 翻转（解码层，见 ATVVProtocol.lowNibbleFirst）——两者都不依赖型号归属。
            disModelNumbers: ["RC003"]
        ),
    ]

    /// 本桥会考虑的广播名（设备自报，小写）。**只作连接前的辅助筛选**：
    /// 广播名与型号不是一一对应（真机实测：广播名「小米蓝牙语音遥控器」、DIS 报 RC003），
    /// 型号判定一律以 DIS 为准。
    ///
    /// 「小米蓝牙遥控器2」「小米蓝牙遥控器2 pro」「arn9」对应的就是**小米蓝牙遥控器 2 / 2 Pro**
    /// （硬件型号 ARN9）——这是老版本用户的主力设备，**绝不能从这份名单里移除**，
    /// 否则老用户升级后遥控器永远无法首次采纳。
    static let adoptedAdvertisedNames: Set<String> = [
        "mi rc",
        "xiaomi bluetooth remote 2",
        "xiaomi bluetooth remote 2 pro",
        "小米蓝牙语音遥控器",
        "小米蓝牙遥控器2",
        "小米蓝牙遥控器2 pro",
        "arn9",
    ]

    /// 按 DIS 型号串识别型号。`raw` 是设备上报的原始串，子串命中即认——
    /// 只有目录里登记的型号串才会命中，登记之外的（如 ARN9）返回 nil，型号不猜。
    static func entry(matchingDISModelNumber raw: String) -> VoiceRemoteCatalogEntry? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        return entries.first { entry in
            entry.disModelNumbers.contains { normalized.contains($0) }
        }
    }

    /// 该型号应该用的真机图资源名；目录里没有这个型号（包括 `.unknown`）返回 nil，
    /// 调用方必须显示「未识别」占位，不允许套用任何真机图。
    static func photoResource(for model: XiaomiRemoteModel) -> String? {
        entries.first { $0.model == model }?.photoResource
    }
}

enum RemotePowerState: Equatable {
    case onBattery
    case externalPower
    case charging
    case unknown

    var logValue: String {
        switch self {
        case .onBattery: return "on_battery"
        case .externalPower: return "external_power"
        case .charging: return "charging"
        case .unknown: return "unknown"
        }
    }

    static func decodeBatteryLevelStatus(_ data: Data) -> RemotePowerState? {
        guard data.count >= 3 else { return nil }
        let powerState = UInt16(data[data.startIndex + 1]) |
            UInt16(data[data.startIndex + 2]) << 8
        let batteryPresent = powerState & 0x0001 == 0x0001
        guard batteryPresent else { return .unknown }

        let wiredExternalPower = (powerState >> 1) & 0x0003
        let wirelessExternalPower = (powerState >> 3) & 0x0003
        let chargeState = (powerState >> 5) & 0x0003

        if chargeState == 0x0001 {
            return .charging
        }
        if wiredExternalPower == 0x0001 || wirelessExternalPower == 0x0001 {
            return .externalPower
        }
        if wiredExternalPower == 0 && wirelessExternalPower == 0 {
            return .onBattery
        }
        return .unknown
    }
}

struct RemoteDeviceMappings: Codable, Equatable {
    var buttonBindings: [String: ButtonAction]
    var buttonShortcuts: [String: CustomKeyboardShortcut]
    var buttonApplicationProfileIDs: [String: UUID]?
    var secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    var buttonRapidPressEnabled: [String: Bool]?

    init(
        buttonBindings: [RemoteButton: ButtonAction],
        buttonShortcuts: [RemoteButton: CustomKeyboardShortcut],
        buttonApplicationProfileIDs: [RemoteButton: UUID] = [:],
        secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]],
        buttonRapidPressEnabled: [RemoteButton: Bool] = [:]
    ) {
        self.buttonBindings = Dictionary(
            uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) }
        )
        self.buttonShortcuts = Dictionary(
            uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) }
        )
        let applicationProfileIDs = Dictionary(
            uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
        )
        self.buttonApplicationProfileIDs = applicationProfileIDs.isEmpty ? nil : applicationProfileIDs
        self.secondaryButtonBindings = Dictionary(
            uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                (
                    button.rawValue,
                    Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                )
            }
        )
        let rapidPressEnabled = Dictionary(
            uniqueKeysWithValues: buttonRapidPressEnabled
                .filter { $0.value }
                .map { ($0.key.rawValue, $0.value) }
        )
        self.buttonRapidPressEnabled = rapidPressEnabled.isEmpty ? nil : rapidPressEnabled
    }

    var parsedButtonBindings: [RemoteButton: ButtonAction] {
        Dictionary(uniqueKeysWithValues: buttonBindings.compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedButtonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        Dictionary(uniqueKeysWithValues: buttonShortcuts.compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedButtonApplicationProfileIDs: [RemoteButton: UUID] {
        Dictionary(uniqueKeysWithValues: (buttonApplicationProfileIDs ?? [:]).compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedButtonRapidPressEnabled: [RemoteButton: Bool] {
        Dictionary(uniqueKeysWithValues: (buttonRapidPressEnabled ?? [:]).compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedSecondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        Dictionary(uniqueKeysWithValues: secondaryButtonBindings.compactMap { buttonKey, bindings in
            guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
            let parsed = Dictionary(uniqueKeysWithValues: bindings.compactMap { triggerKey, value in
                ButtonTrigger(rawValue: triggerKey).map { ($0, value) }
            })
            return parsed.isEmpty ? nil : (button, parsed)
        })
    }
}

struct RemoteDeviceProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var model: XiaomiRemoteModel
    var customName: String
    var bluetoothIdentifier: UUID?
    var hidFingerprint: String?
    var mappings: RemoteDeviceMappings

    var displayNameFallbackKey: String { model.localizationKey }

    init(
        id: UUID = UUID(),
        model: XiaomiRemoteModel = .unknown,
        customName: String = "",
        bluetoothIdentifier: UUID? = nil,
        hidFingerprint: String? = nil,
        mappings: RemoteDeviceMappings
    ) {
        self.id = id
        self.model = model
        self.customName = customName
        self.bluetoothIdentifier = bluetoothIdentifier
        self.hidFingerprint = hidFingerprint
        self.mappings = mappings
    }
}
