import Foundation

/// Gesture timing shared by every ordinary button on one remote model.
struct RemoteButtonGestureTiming: Codable, Equatable {
    var doubleClickMilliseconds: Int = 300
    var longPressMilliseconds: Int = 550
    /// 学习后保存的重复启动时间。旧配置缺少此值时使用既有时间。
    var repeatSingleStartMilliseconds: Int? = nil

    var isValid: Bool {
        (50...500).contains(doubleClickMilliseconds) && doubleClickMilliseconds % 50 == 0 &&
        (300...1000).contains(longPressMilliseconds) && longPressMilliseconds % 50 == 0 &&
        (repeatSingleStartMilliseconds.map { $0 > 0 && $0 % 50 == 0 } ?? true)
    }
}

/// Per-profile button behavior. The timing fields remain for format compatibility; runtime
/// replaces them with the timing owned by the remote model.
struct RemoteButtonInteractionSettings: Codable, Equatable {
    var doubleClickMilliseconds: Int = 300
    var longPressMilliseconds: Int = 550
    var modes: [String: String] = [:]
    var migratedRepeatButtons: [String]? = nil
    init(
        doubleClickMilliseconds: Int = 300,
        longPressMilliseconds: Int = 550,
        modes: [String: String] = [:],
        migratedRepeatButtons: [String]? = nil
    ) {
        self.doubleClickMilliseconds = doubleClickMilliseconds
        self.longPressMilliseconds = longPressMilliseconds
        self.modes = modes
        self.migratedRepeatButtons = migratedRepeatButtons
    }

    private enum CodingKeys: String, CodingKey {
        case doubleClickMilliseconds, longPressMilliseconds, modes, migratedRepeatButtons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        doubleClickMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .doubleClickMilliseconds
        ) ?? 300
        longPressMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .longPressMilliseconds
        ) ?? 550
        modes = try container.decodeIfPresent([String: String].self, forKey: .modes) ?? [:]
        migratedRepeatButtons = try container.decodeIfPresent(
            [String].self,
            forKey: .migratedRepeatButtons
        )
        // Raw key-down came from an unshipped candidate design. "once" is retained as
        // an internal marker so a user-cleared hold choice does not regain a later default.
        modes = modes.filter { $0.value != "holdSingle" }
    }

    var isValid: Bool {
        timing.isValid
    }

    var isWellFormed: Bool {
        isValid && modes.allSatisfy { RemoteButton(rawValue: $0.key) != nil && RemoteButtonHoldMode(rawValue: $0.value) != nil } &&
            (migratedRepeatButtons ?? []).allSatisfy { RemoteButton(rawValue: $0) != nil }
    }

    func mode(for button: RemoteButton) -> RemoteButtonHoldMode? {
        guard let value = modes[button.rawValue] else {
            return .once
        }
        return RemoteButtonHoldMode(rawValue: value)
    }

    var timing: RemoteButtonGestureTiming {
        get {
            RemoteButtonGestureTiming(
                doubleClickMilliseconds: doubleClickMilliseconds,
                longPressMilliseconds: longPressMilliseconds
            )
        }
        set {
            doubleClickMilliseconds = newValue.doubleClickMilliseconds
            longPressMilliseconds = newValue.longPressMilliseconds
        }
    }
}

enum RemoteButtonHoldMode: String, CaseIterable, Codable, Identifiable {
    case once, repeatLong, repeatSingle
    /// 按住期间把单击动作里的方向键真正按下去。
    case singleHold
    /// 达到长按时间后把长按动作里的方向键真正按下去。
    case longHold
    var id: String { rawValue }
    var localizationKey: String { "button_mapping.hold_mode.\(rawValue.lowercased())" }

    /// 按住编辑区的四个并列选项，最多只能选一个。
    static let selectableCases: [Self] = [.repeatSingle, .repeatLong, .singleHold, .longHold]

    var isHoldDown: Bool { self == .singleHold || self == .longHold }
}

extension ConfiguredButtonAction {
    var allowsHoldRepeat: Bool {
        action != .disabled && action != .appSwitcher && allowsSingleClickRepeat
    }
}

struct RemoteButtonInteractionSnapshot {
    var settings: RemoteButtonInteractionSettings
    var mode: RemoteButtonHoldMode?
    var single: ConfiguredButtonAction
    var double: ConfiguredButtonAction
    var long: ConfiguredButtonAction
    var hasOpaqueBinding = false
    var repeatInterval: UInt64 = 100
    var repeatSingleStartMilliseconds: Int? = nil
    var repeatAllowed = true
    /// 解析后的单击动作（方案覆盖优先）。「单击按住」只看它能否被按住。
    var holdableSingle: ConfiguredButtonAction?
    /// 解析后的长按动作（方案覆盖优先）。「长按按住」只看它能否被按住。
    var holdableLong: ConfiguredButtonAction?
    var opaqueDouble = false
    var opaqueLong = false
    var recognizesDouble: Bool { opaqueDouble || double.action != .disabled }
    var recognizesLong: Bool { opaqueLong || long.action != .disabled }

    /// 当前按住模式真正要按下去的动作；重复模式返回 nil。
    var holdDownAction: ConfiguredButtonAction? {
        switch mode {
        case .singleHold: return holdableSingle
        case .longHold: return holdableLong
        case .once, .repeatSingle, .repeatLong, nil: return nil
        }
    }

    /// 当前按住模式能否执行：动作必须是方向键，且当前前台 App 允许。
    var isHoldDownActive: Bool {
        guard let action = holdDownAction else { return false }
        return action.holdableKey != nil && repeatAllowed
    }

    func withMode(_ mode: RemoteButtonHoldMode?) -> Self {
        var copy = self
        copy.mode = mode
        return copy
    }

    func hasSameBinding(as other: Self) -> Bool {
        mode == other.mode && single == other.single && double == other.double && long == other.long &&
            hasOpaqueBinding == other.hasOpaqueBinding && opaqueDouble == other.opaqueDouble &&
            opaqueLong == other.opaqueLong && holdableSingle == other.holdableSingle &&
            holdableLong == other.holdableLong
    }

    var unavailableReason: String? {
        guard settings.isValid, let mode else { return "button_mapping.hold_invalid" }
        switch mode {
        case .once: return nil
        case .repeatLong:
            return !hasOpaqueBinding && long.allowsHoldRepeat ? nil : "button_mapping.hold_repeat_long_unavailable"
        case .repeatSingle:
            return !hasOpaqueBinding && single.allowsHoldRepeat && !recognizesLong
                ? nil : "button_mapping.hold_repeat_single_unavailable"
        case .singleHold:
            return holdableSingle?.holdableKey != nil ? nil : "button_mapping.hold_single_hold_unavailable"
        case .longHold:
            return holdableLong?.holdableKey != nil ? nil : "button_mapping.hold_long_hold_unavailable"
        }
    }
}

/// Concrete reason a hold mode cannot run for one button. Each case carries the configured
/// action that blocks it, so the editor can name the real cause instead of quoting a rule.
enum RemoteButtonHoldBlocker: Equatable {
    case timingInvalid
    case profileOwned
    case actionUnset
    case actionNotRepeatable(ConfiguredButtonAction)
    case actionNotHoldable(ConfiguredButtonAction)
    case longPressConfigured(ConfiguredButtonAction)
    case longPressOwnedByProfile
}

extension RemoteButtonInteractionSnapshot {
    /// Empty means the mode can run. The order is the order the editor explains them.
    func blockers(for mode: RemoteButtonHoldMode) -> [RemoteButtonHoldBlocker] {
        guard mode != .once else { return [] }
        guard settings.isValid else { return [.timingInvalid] }
        // 按住执行由宿主直接按键，方案覆盖的动作也能按住，因此不受“方案接管”限制。
        switch mode {
        case .once:
            return []
        case .singleHold:
            return Self.holdBlockers(for: holdableSingle)
        case .longHold:
            return Self.holdBlockers(for: holdableLong)
        case .repeatLong:
            if hasOpaqueBinding { return [.profileOwned] }
            return opaqueLong ? [.longPressOwnedByProfile] : Self.blockers(for: long)
        case .repeatSingle:
            if hasOpaqueBinding { return [.profileOwned] }
            var reasons = Self.blockers(for: single)
            if opaqueLong {
                reasons.append(.longPressOwnedByProfile)
            } else if long.action != .disabled {
                reasons.append(.longPressConfigured(long))
            }
            return reasons
        }
    }

    private static func holdBlockers(
        for configured: ConfiguredButtonAction?
    ) -> [RemoteButtonHoldBlocker] {
        guard let configured else { return [.actionUnset] }
        if configured.action == .disabled ||
            (configured.action == .customShortcut && configured.shortcut == nil) {
            return [.actionUnset]
        }
        return configured.holdableKey == nil ? [.actionNotHoldable(configured)] : []
    }

    private static func blockers(for configured: ConfiguredButtonAction) -> [RemoteButtonHoldBlocker] {
        if configured.action == .disabled ||
            (configured.action == .customShortcut && configured.shortcut == nil) {
            return [.actionUnset]
        }
        return configured.allowsHoldRepeat ? [] : [.actionNotRepeatable(configured)]
    }
}

/// First-edit default for the hold behavior. Storage is only ever raised from "unset" to
/// `repeatSingle`; an existing choice, a cleared marker, or a mode inherited from the base
/// buttons is never rewritten. A configuration conflict therefore degrades at runtime through
/// `unavailableReason` and disappears by itself once the conflicting gesture is removed.
enum RemoteButtonHoldModeDefault {
    static func storedMode(
        explicit: RemoteButtonHoldMode?,
        snapshot: RemoteButtonInteractionSnapshot
    ) -> RemoteButtonHoldMode? {
        guard explicit == nil, snapshot.mode == .once else { return nil }
        return snapshot.withMode(.repeatSingle).unavailableReason == nil ? .repeatSingle : nil
    }
}
