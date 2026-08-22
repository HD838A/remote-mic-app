import Foundation

enum XiaomiRemoteModel: String, Codable, CaseIterable, Identifiable {
    case rc001
    case rc003
    case unknown

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .rc001: return "remote.device.model.rc001"
        case .rc003: return "remote.device.model.rc003"
        case .unknown: return "remote.device.model.unknown"
        }
    }

    static func identified(by modelNumber: String) -> XiaomiRemoteModel? {
        switch modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "RC001": return .rc001
        case "RC003": return .rc003
        // ARN9 is the 蓝牙遥控器 2 hardware reporting its own model string;
        // treat it as the RC family so the UI badge resolves.
        case let value where value.contains("ARN9"): return .rc003
        default: return nil
        }
    }
}

enum RemotePowerState: Equatable {
    case onBattery
    case externalPower
    case charging
    case unknown

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

    init(
        buttonBindings: [RemoteButton: ButtonAction],
        buttonShortcuts: [RemoteButton: CustomKeyboardShortcut],
        buttonApplicationProfileIDs: [RemoteButton: UUID] = [:],
        secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]]
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
