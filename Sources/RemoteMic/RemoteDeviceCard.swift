import SwiftUI

/// Observed readiness, not proof that an external app received a key or recognized speech.
enum RemoteFunctionReadiness: Equatable {
    case ready, checking, failed, unknown

    var diagnosticValue: String {
        switch self {
        case .ready: return "ready"
        case .checking: return "checking"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }

    /// Chromecast 的卡片按键就绪。
    ///
    /// 私有包当前只暴露 `isHIDRemotePresent` 快照，宿主不能把缓存 `nil` 当成“按键未知”；
    /// 实时在线优先，避免“按键已响应但卡片一直状态确认中”。
    static func chromecastButtons(cachedPresent: Bool?, livePresent: Bool) -> Self {
        if livePresent || cachedPresent == true {
            return .ready
        }
        // HID 缺失没有可靠的“已确认失败”信号；此时只能保持未知，不能伪报按键异常。
        return .unknown
    }

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
    /// Readiness states that normally resolve shortly after the link connects.
    /// They must not be presented until they survive the settling window.
    var isTransientReadiness: Bool { self == .checking || self == .confirming }
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

/// The exact inputs that produced a card status.
///
/// The status line alone cannot explain a persistent `confirming` state. This
/// snapshot records only booleans, stable state names and localization keys:
/// no device names, identifiers, paths or user content.
struct RemoteCardReadinessSnapshot: Equatable {
    let status: RemoteDeviceCardStatus
    let model: String
    let connected: Bool
    let history: Bool
    let buttons: RemoteFunctionReadiness
    let buttonReason: String
    let voice: RemoteFunctionReadiness
    let voiceReason: String
    let profileHasHID: Bool
    let profileHasBluetooth: Bool
    let hidMonitorPresent: Bool
    let buttonReadinessCached: Bool
    let appleConnected: Bool
    let audioStatusKey: String
    let audioReady: Bool
    let audioSelected: Bool
    let bridgeState: String
    let siriAudioClass: String
    let profileCount: Int
    let connectedProfileCount: Int

    func diagnosticLine(cardIndex: Int, operationID: UInt64) -> String {
        "REMOTE CARD_READINESS operation_id=card_\(operationID) card_index=\(cardIndex) " +
            "state=\(status.rawValue) model=\(model) connected=\(connected) history=\(history) " +
            "buttons=\(buttons.diagnosticValue) button_reason=\(buttonReason) " +
            "voice=\(voice.diagnosticValue) voice_reason=\(voiceReason) " +
            "profile_hid=\(profileHasHID) profile_bt=\(profileHasBluetooth) " +
            "hid_monitor=\(hidMonitorPresent) button_cache=\(buttonReadinessCached) " +
            "apple_connected=\(appleConnected) audio_status=\(audioStatusKey) " +
            "audio_ready=\(audioReady) audio_selected=\(audioSelected) " +
            "bridge=\(bridgeState) siri_audio=\(siriAudioClass) " +
            "profiles=\(profileCount) connected_profiles=\(connectedProfileCount)"
    }
}

/// Whether the card should offer the explicit audio-output recovery fallback.
///
/// This is intentionally narrow: a green/confirming card, a history card, an
/// Apple non-member card, or a voice failure caused by the component,
/// membership, HID mapping or the remote link must not show an audio retry
/// button. The button is only a last-resort recovery for a selected virtual
/// output that is not ready.
enum RemoteVoiceRecoveryPolicy {
    static func shouldOfferAudioRecovery(
        connected: Bool,
        history: Bool,
        voiceRequired: Bool,
        cardStatus: RemoteDeviceCardStatus,
        audioOutputReady: Bool,
        selectedAudioDeviceUID: String,
        audioStatusKey: String
    ) -> Bool {
        guard connected,
              !history,
              voiceRequired,
              cardStatus == .voiceFailed,
              !audioOutputReady,
              !selectedAudioDeviceUID.isEmpty
        else { return false }
        return audioStatusKey.hasPrefix("audio.output.") &&
            audioStatusKey != "audio.output.current_format"
    }
}

/// What the card's status line is allowed to show right now.
///
/// `isVerifying` keeps the line neutral while the link is already connected but
/// button/voice readiness is still being determined. It deliberately does not
/// claim that every function is ready until `RemoteDeviceCardStatus.connected`
/// is observed.
struct RemoteDeviceCardStatusDisplay: Equatable {
    let status: RemoteDeviceCardStatus
    let isVerifying: Bool

    static func settled(_ status: RemoteDeviceCardStatus) -> Self {
        Self(status: status, isVerifying: false)
    }

    static let verifyingConnection = Self(status: .connected, isVerifying: true)
}

/// Holds short-lived `checking`/`confirming` states back so a fast connection
/// goes straight to its final status instead of flashing orange on the way.
struct RemoteCardStatusSettlingPolicy {
    /// Decrypted `REMOTE CARD_STATUS` logs from 2.0.8 build 404 show
    /// checking → connected in 30–259 ms (median 53 ms). 0.8 s keeps a ~3×
    /// margin while still surfacing a genuinely stuck check quickly.
    static let gracePeriod: TimeInterval = 0.8

    private(set) var display: RemoteDeviceCardStatusDisplay?
    private(set) var transientStartedAt: Date?

    /// Returns the display to use and, when a transient state is still being
    /// held back, how long until the caller must observe again.
    mutating func observe(
        _ observed: RemoteDeviceCardStatus,
        at now: Date
    ) -> (display: RemoteDeviceCardStatusDisplay, refreshAfter: TimeInterval?) {
        guard observed.isTransientReadiness else {
            transientStartedAt = nil
            let display = RemoteDeviceCardStatusDisplay.settled(observed)
            self.display = display
            return (display, nil)
        }
        if transientStartedAt == nil { transientStartedAt = now }
        let deadline = (transientStartedAt ?? now).addingTimeInterval(Self.gracePeriod)
        if now >= deadline {
            let display = RemoteDeviceCardStatusDisplay.settled(observed)
            self.display = display
            return (display, nil)
        }
        if let display, !display.isVerifying,
           display.status == .connected || display.status.isFailure {
            // A previously verified or failed function must not be downgraded
            // to "checking" by a short recheck.
            return (display, deadline.timeIntervalSince(now))
        }
        display = .verifyingConnection
        return (.verifyingConnection, deadline.timeIntervalSince(now))
    }
}

/// One fixed three-row card shared by mapping, current connections and connection history.
struct RemoteDeviceCard: View {
    let modelName: String
    let systemName: String
    let status: RemoteDeviceCardStatus
    let statusDetail: String
    /// Screenshot fixtures can pin the presented state; production passes nil.
    let statusDisplayOverride: RemoteDeviceCardStatusDisplay?
    /// Absorbs transient readiness states on the live button page. History and
    /// screenshot fixtures keep the observed status so explicit states remain
    /// inspectable.
    let settlesTransientStatus: Bool
    let selected: Bool
    let batteryLevel: Int?
    let powerState: RemotePowerState?
    let showsBattery: Bool
    let enableTitle: String?
    let membershipTitle: String?
    let voiceRecoveryTitle: String?
    let voiceRecoveryHelp: String?
    let connectionTitle: String?
    let actionsDisabled: Bool
    let voiceRecoveryDisabled: Bool
    let connectionDisabled: Bool
    let onSelect: () -> Void
    let onEnable: () -> Void
    let onMembership: () -> Void
    let onRecoverVoice: () -> Void
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
                .help("\(modelName) · \(systemName)")
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
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
            HStack(spacing: 6) {
                RemoteDeviceCardStatusReadout(
                    observed: status,
                    displayOverride: statusDisplayOverride,
                    settlesTransientStatus: settlesTransientStatus,
                    onSelect: onSelect
                )
                if showsBattery { batteryLabel }
                Spacer(minLength: 0)
                if let voiceRecoveryTitle {
                    Button(voiceRecoveryTitle, action: onRecoverVoice)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                        .disabled(voiceRecoveryDisabled)
                        .help(voiceRecoveryHelp ?? voiceRecoveryTitle)
                        .accessibilityLabel(voiceRecoveryHelp ?? voiceRecoveryTitle)
                }
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
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture(perform: onSelect)
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
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
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
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
        }
        .foregroundStyle(batteryLevel.map { $0 <= 10 ? Color.red : $0 <= 25 ? .orange : .secondary } ?? Color.secondary)
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

private struct RemoteDeviceCardStatusReadout: View {
    let observed: RemoteDeviceCardStatus
    let displayOverride: RemoteDeviceCardStatusDisplay?
    let settlesTransientStatus: Bool
    let onSelect: () -> Void

    @State private var display: RemoteDeviceCardStatusDisplay
    @State private var policy: RemoteCardStatusSettlingPolicy

    init(
        observed: RemoteDeviceCardStatus,
        displayOverride: RemoteDeviceCardStatusDisplay?,
        settlesTransientStatus: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.observed = observed
        self.displayOverride = displayOverride
        self.settlesTransientStatus = settlesTransientStatus
        self.onSelect = onSelect
        var policy = RemoteCardStatusSettlingPolicy()
        let initial: RemoteDeviceCardStatusDisplay
        if let displayOverride {
            initial = displayOverride
        } else if settlesTransientStatus {
            initial = policy.observe(observed, at: Date()).display
        } else {
            initial = .settled(observed)
        }
        _display = State(initialValue: initial)
        _policy = State(initialValue: policy)
    }

    var body: some View {
        HStack(spacing: 4) {
            if display.isVerifying {
                Circle().fill(Color.secondary).frame(width: 4, height: 4)
            } else if display.status.isProgressing {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 10, height: 12)
            } else {
                Circle().fill(display.status.color).frame(width: 4, height: 4)
            }
            Text(LocalizedStringKey(presentedStatus.message.key))
                .foregroundStyle(presentationColor)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .task(id: observed) {
            while let delay = apply(observed) {
                try? await Task.sleep(nanoseconds: UInt64(max(0.001, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
        }
    }

    private var presentedStatus: RemoteDeviceCardStatus {
        display.isVerifying ? .connected : display.status
    }

    private var presentationColor: Color {
        display.isVerifying ? .secondary : display.status.color
    }

    /// Updates the presented state and returns how long the caller must wait
    /// before a still-transient observed state becomes visible.
    @discardableResult
    private func apply(_ observed: RemoteDeviceCardStatus, now: Date = Date()) -> TimeInterval? {
        if let displayOverride {
            display = displayOverride
            return nil
        }
        guard settlesTransientStatus else {
            display = .settled(observed)
            return nil
        }
        var policy = self.policy
        let decision = policy.observe(observed, at: now)
        self.policy = policy
        display = decision.display
        return decision.refreshAfter
    }
}
