import Foundation

/// Gesture timing shared by every ordinary button on one remote model.
struct RemoteButtonGestureTiming: Codable, Equatable {
    var doubleClickMilliseconds: Int = 300
    var longPressMilliseconds: Int = 550

    var isValid: Bool {
        (150...500).contains(doubleClickMilliseconds) && doubleClickMilliseconds % 50 == 0 &&
        (300...1000).contains(longPressMilliseconds) && longPressMilliseconds % 50 == 0
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
    var repeatAllowed = true
    var opaqueDouble = false
    var opaqueLong = false
    var recognizesDouble: Bool { opaqueDouble || double.action != .disabled }
    var recognizesLong: Bool { opaqueLong || long.action != .disabled }

    func withMode(_ mode: RemoteButtonHoldMode?) -> Self {
        var copy = self
        copy.mode = mode
        return copy
    }

    func hasSameBinding(as other: Self) -> Bool {
        mode == other.mode && single == other.single && double == other.double && long == other.long &&
            hasOpaqueBinding == other.hasOpaqueBinding && opaqueDouble == other.opaqueDouble && opaqueLong == other.opaqueLong
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
