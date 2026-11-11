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
    /// 打开「按住执行」的按键：按住期间把目标键真正压在按下状态，而不是反复点按。
    /// 缺失表示旧配置，全部按键保持既有重复行为。
    var holdExecutions: [String]? = nil

    init(
        doubleClickMilliseconds: Int = 300,
        longPressMilliseconds: Int = 550,
        modes: [String: String] = [:],
        migratedRepeatButtons: [String]? = nil,
        holdExecutions: [String]? = nil
    ) {
        self.doubleClickMilliseconds = doubleClickMilliseconds
        self.longPressMilliseconds = longPressMilliseconds
        self.modes = modes
        self.migratedRepeatButtons = migratedRepeatButtons
        self.holdExecutions = holdExecutions
    }

    private enum CodingKeys: String, CodingKey {
        case doubleClickMilliseconds, longPressMilliseconds, modes, migratedRepeatButtons, holdExecutions
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
        holdExecutions = try container.decodeIfPresent(
            [String].self,
            forKey: .holdExecutions
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
            (migratedRepeatButtons ?? []).allSatisfy { RemoteButton(rawValue: $0) != nil } &&
            (holdExecutions ?? []).allSatisfy { RemoteButton(rawValue: $0) != nil }
    }

    func mode(for button: RemoteButton) -> RemoteButtonHoldMode? {
        guard let value = modes[button.rawValue] else {
            return .once
        }
        return RemoteButtonHoldMode(rawValue: value)
    }

    func holdExecution(for button: RemoteButton) -> Bool {
        holdExecutions?.contains(button.rawValue) == true
    }

    mutating func setHoldExecution(_ enabled: Bool, for button: RemoteButton) {
        var values = Set(holdExecutions ?? [])
        if enabled {
            values.insert(button.rawValue)
        } else {
            values.remove(button.rawValue)
        }
        holdExecutions = values.isEmpty ? nil : values.sorted()
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
    var id: String { rawValue }
    var localizationKey: String { "button_mapping.hold_mode.\(rawValue.lowercased())" }

    static let selectableCases: [Self] = [.repeatSingle, .repeatLong]
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
    /// 用户为这颗按键打开了「按住执行」。
    var holdExecution = false
    /// 按住执行要按下去的动作：解析后的「长按动作」。只有方向键能像物理键盘一样被按住。
    var holdExecutionAction: ConfiguredButtonAction?
    var opaqueDouble = false
    var opaqueLong = false
    var recognizesDouble: Bool { opaqueDouble || double.action != .disabled }
    var recognizesLong: Bool { opaqueLong || long.action != .disabled }

    /// 长按动作是方向键时才能按住执行；与上面的重复方式无关。
    var canHoldExecution: Bool { holdExecutionAction?.holdableKey != nil }

    /// 运行时是否真的按“按住执行”处理：开关打开、长按动作可按住，且当前前台 App 允许。
    var isHoldExecutionActive: Bool { holdExecution && canHoldExecution && repeatAllowed }

    func withMode(_ mode: RemoteButtonHoldMode?) -> Self {
        var copy = self
        copy.mode = mode
        return copy
    }

    func hasSameBinding(as other: Self) -> Bool {
        mode == other.mode && single == other.single && double == other.double && long == other.long &&
            hasOpaqueBinding == other.hasOpaqueBinding && opaqueDouble == other.opaqueDouble &&
            opaqueLong == other.opaqueLong && holdExecution == other.holdExecution &&
            holdExecutionAction == other.holdExecutionAction
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
    case longPressConfigured(ConfiguredButtonAction)
    case longPressOwnedByProfile
}

extension RemoteButtonInteractionSnapshot {
    /// Empty means the mode can run. The order is the order the editor explains them.
    func blockers(for mode: RemoteButtonHoldMode) -> [RemoteButtonHoldBlocker] {
        guard mode != .once else { return [] }
        guard settings.isValid else { return [.timingInvalid] }
        if hasOpaqueBinding { return [.profileOwned] }
        switch mode {
        case .once:
            return []
        case .repeatLong:
            return opaqueLong ? [.longPressOwnedByProfile] : Self.blockers(for: long)
        case .repeatSingle:
            var reasons = Self.blockers(for: single)
            if opaqueLong {
                reasons.append(.longPressOwnedByProfile)
            } else if long.action != .disabled {
                reasons.append(.longPressConfigured(long))
            }
            return reasons
        }
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
