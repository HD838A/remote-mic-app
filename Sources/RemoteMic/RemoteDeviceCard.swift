import SwiftUI

/// Observed readiness, not proof that an external app received a key or recognized speech.
enum RemoteFunctionReadiness: Equatable {
    case ready, checking, failed, unknown

    static func buttons(statusKey: String?) -> Self {
        guard let statusKey else { return .unknown }
        if statusKey.hasPrefix("button_mapping.error.") || statusKey.hasPrefix("button_mapping.permission.") {
            return .failed
        }
        if statusKey == "button_mapping.status.connected" || statusKey == "button_mapping.status.connected_fallback" ||
            statusKey == "button_mapping.status.system_managed" { return .ready }
        if statusKey == "button_mapping.status.connected_system_actions_may_remain" { return .failed }
        return .checking
    }
}

enum RemoteDeviceCardStatus: String, CaseIterable {
    case connected, disconnected, checking, confirming
    case buttonsFailed = "buttons_failed", voiceFailed = "voice_failed", deviceFailed = "device_failed"
    case connecting, notFound = "not_found", paused, cancelled

    var message: LocalizedMessage { LocalizedMessage("remote.card.status.\(rawValue)") }
    var isProgressing: Bool { self == .checking || self == .confirming || self == .connecting }
    var isFailure: Bool { self == .buttonsFailed || self == .voiceFailed || self == .deviceFailed || self == .notFound }
    var color: Color {
        if self == .connected { return .green }
        if isFailure { return .red }
        if isProgressing { return .orange }
        return .secondary
    }

    static func resolve(
        connected: Bool,
        buttons: RemoteFunctionReadiness,
        voice: RemoteFunctionReadiness,
        voiceRequired: Bool
    ) -> Self {
        guard connected else { return .disconnected }
        let voice = voiceRequired ? voice : .ready
        if buttons == .failed && voice == .failed { return .deviceFailed }
        if buttons == .failed { return .buttonsFailed }
        if voice == .failed { return .voiceFailed }
        if buttons == .checking || voice == .checking { return .checking }
        if buttons == .unknown || voice == .unknown { return .confirming }
        return .connected
    }
}

/// One fixed three-row card shared by mapping, current connections and connection history.
struct RemoteDeviceCard: View {
    let modelName: String
    let systemName: String
    let status: RemoteDeviceCardStatus
    let statusDetail: String
    let selected: Bool
    let batteryLevel: Int?
    let powerState: RemotePowerState?
    let showsBattery: Bool
    let enableTitle: String?
    let membershipTitle: String?
    let connectionTitle: String?
    let actionsDisabled: Bool
    let connectionDisabled: Bool
    let onSelect: () -> Void
    let onEnable: () -> Void
    let onMembership: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: onSelect) {
                    Text(modelName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .modifier(CompatibilityFocusEffectDisabledModifier())
                .help(modelName)
                .accessibilityLabel("\(modelName), \(systemName), \(statusDetail)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                if let enableTitle {
                    Button(enableTitle, action: onEnable)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .disabled(actionsDisabled)
                        .fixedSize()
                }
            }
            .frame(height: 16)
            Text(systemName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(systemName)
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    if status.isProgressing {
                        ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 10, height: 12)
                    } else {
                        Circle().fill(status.color).frame(width: 4, height: 4)
                    }
                    Text(LocalizedStringKey(status.message.key)).foregroundStyle(status.color)
                }
                .help(statusDetail)
                if showsBattery { batteryLabel }
                Spacer(minLength: 0)
                if let membershipTitle {
                    Button(membershipTitle, action: onMembership)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                }
                if let connectionTitle {
                    Button(connectionTitle, action: onConnect)
                        .compatibilityButtonStyle(.standard)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(connectionDisabled)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .frame(height: 16)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: SettingsPageBehavior.mappingRemoteCardWidth, height: SettingsPageBehavior.mappingRemoteCardHeight)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onSelect)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045))
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18))
                .allowsHitTesting(false)
        }
    }

    private var batteryLabel: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: batterySymbol).font(.system(size: 13, weight: .medium))
                if powerState == .charging || powerState == .externalPower {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 3, y: 3)
                }
            }.frame(width: 20)
            Text(batteryLevel.map { "\($0)%" } ?? "—")
        }
        .foregroundStyle(batteryLevel.map { $0 <= 10 ? Color.red : $0 <= 25 ? .orange : .secondary } ?? Color.secondary)
        .help(Text(powerState == .charging ? "remote.device.power.charging" : powerState == .externalPower ? "remote.device.power.external" : "remote.device.power.battery"))
    }

    private var batterySymbol: String {
        guard let batteryLevel else { return "battery.0percent" }
        switch batteryLevel {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
